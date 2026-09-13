-- Blood Trail Mod Menu - actor spawner
--
-- The catalogue lives in spawn_list.lua, which is GENERATED from
-- BTVR\Binaries\Win64\CXXHeaderDump - every class in the game that descends
-- from AActor (401 of them), minus the game-framework classes that crash or
-- hijack the session when duplicated.
--
-- Classes are resolved by short name at runtime rather than by hardcoded asset
-- path: the paths are not knowable without unpacking the 25 GB pak, but the
-- class names are exact.

local SpawnerMods = {}

local okList, list = pcall(require, "spawn_list")
SpawnerMods.Categories = okList and list or {}

if not okList then
    print("[ModMenu] spawn_list.lua failed to load: " .. tostring(list) .. "\n")
end

local classCache = {}

-- class name -> asset object path, built from the catalogue on first use
local pathOf = nil

local function buildPathIndex()
    pathOf = {}
    for _, cat in ipairs(SpawnerMods.Categories) do
        for _, entry in ipairs(cat.items) do
            local cls, path = entry[2], entry[3]
            if path and path ~= "" then pathOf[cls] = path end
        end
    end
end

local function isValid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- Resolve a UClass from a blueprint short name, e.g. "BP_AK_C".
--
-- Steps 1 and 2 only find things already in memory, which is why the first
-- version reported "class not loaded" for anything not used by the current map.
-- Step 3 fixes that: the asset paths in spawn_list.lua were recovered from the
-- .pak index, so UE4SS can force-load the blueprint on demand.
local function ResolveClass(shortName)
    local cached = classCache[shortName]
    if isValid(cached) then return cached end
    classCache[shortName] = nil

    -- 1. the class object itself, if the blueprint is already loaded
    local ok, cls = pcall(FindObject, "Class", shortName)
    if ok and isValid(cls) then
        classCache[shortName] = cls
        return cls
    end

    -- 2. borrow the class off any instance already in the level
    local okI, inst = pcall(FindFirstOf, shortName)
    if okI and isValid(inst) then
        local okC, c = pcall(function() return inst:GetClass() end)
        if okC and isValid(c) then
            classCache[shortName] = c
            return c
        end
    end

    -- 3. force-load the asset, then look again
    if pathOf == nil then buildPathIndex() end
    local objectPath = pathOf[shortName]
    if objectPath and type(LoadAsset) == "function" then
        -- "/Game/Dir/BP_AK.BP_AK_C" -> asset is "/Game/Dir/BP_AK"
        local assetPath = string.match(objectPath, "^(.-)%.[^%.]+$") or objectPath
        pcall(function() LoadAsset(assetPath) end)

        local okS, found = pcall(StaticFindObject, objectPath)
        if okS and isValid(found) then
            classCache[shortName] = found
            return found
        end

        -- some blueprints resolve by short name only after the load
        local okF, again = pcall(FindObject, "Class", shortName)
        if okF and isValid(again) then
            classCache[shortName] = again
            return again
        end
    end

    return nil
end

SpawnerMods.ResolveClass = ResolveClass

-- Full asset object path for a class name, or nil. Used by the enemy scan to
-- check a class is loaded (cheap hash lookup) before calling FindAllOf on it,
-- which crashes the game if the class is absent.
function SpawnerMods.PathFor(shortName)
    if pathOf == nil then buildPathIndex() end
    return pathOf[shortName]
end

function SpawnerMods.CategoryCount()
    return #SpawnerMods.Categories
end

function SpawnerMods.Category(i)
    return SpawnerMods.Categories[i]
end

-- entry = { display, class, asset path, spawnable }
-- spawnable is 0 for native engine classes, which resolve fine but spawn an
-- empty actor with no mesh or behaviour, and for blueprints with no asset path.
function SpawnerMods.IsSpawnable(entry)
    return entry and entry[4] == 1
end

-- How many entries in a category are actually worth showing.
function SpawnerMods.AvailableCount(i)
    local cat = SpawnerMods.Categories[i]
    if not cat then return 0 end
    local n = 0
    for _, e in ipairs(cat.items) do
        if SpawnerMods.IsSpawnable(e) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- post-spawn setup
---------------------------------------------------------------------------
-- An actor dropped into the world with SpawnActor is not wired into anything.
-- Enemies in this game are normally created by BP_WaveSpawner_C and then driven
-- by BP_AiCoordinator_C, which holds ActiveNPCs / Enemies_ALL / wendigoRef. A
-- hand-spawned NPC is in neither list, so nothing tells it who the player is
-- and it just stands there.
--
-- This does what can be done from outside: point the enemy at the player and
-- tell it that it has seen them. On a level with AI navigation that is enough to
-- get them moving. In the Main Lobby it is not, because that room has no
-- navmesh for them to path on - see the README.

-- CRASH WARNING, learned the hard way twice now:
-- probing `actor.SomeProperty ~= nil` on an arbitrary class is NOT safe. UE4SS
-- returns a null FProperty for a name the class does not have and then
-- dereferences it - an access violation inside UE4SS.dll that pcall cannot
-- catch. Spawning a BP_NPC_C, which has none of the seven properties the first
-- version of this function probed, killed the game.
--
-- So setup is applied ONLY to classes whose layout is known from
-- pawn_schema.lua. Anything else is spawned and left alone.

local SETUP_BY_CLASS = {
    ALS_Player_CharacterBPai_C = "enemy",
    SkeletalGun_C              = "gun",
    BP_PhysicalMagazineFirearm_C = "physgun",
}

function SpawnerMods.PostSpawnSetup(shortName, actor, playerPawn)
    local how = SETUP_BY_CLASS[shortName]
    if not how or not isValid(actor) then return end

    local PM = SpawnerMods.PlayerMods
    local has = PM and PM.hasProp or nil
    local function put(name, value)
        if has and not has(shortName, name) then return end
        pcall(function() actor[name] = value end)
    end

    if how == "enemy" then
        pcall(function() actor:SetTargets() end)
        put("bHasSeenPlayer", true)
        put("bCanSeePlayer", true)
    elseif how == "gun" then
        local okM, maxA = pcall(function() return actor.AmmoMAX end)
        if okM and type(maxA) == "number" and maxA > 0 then put("Ammo", maxA) end
        put("RoundChambered", true)
    elseif how == "physgun" then
        put("bHasInfinateAmmo", true)
        put("bOutOfAmmo", false)
    end
end

---------------------------------------------------------------------------
-- spawning
---------------------------------------------------------------------------

-- count > 1 fans the spawns out in a small arc so they do not all land inside
-- one another.
function SpawnerMods.SpawnByClassName(shortName, getPawn, count)
    count = tonumber(count) or 1
    if count < 1 then count = 1 end
    if count > 25 then count = 25 end

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pawn = getPawn and getPawn() or nil
            if not isValid(pawn) then
                print("[ModMenu] spawn failed: no player pawn\n")
                return
            end

            local world = pawn:GetWorld()
            if not isValid(world) then
                print("[ModMenu] spawn failed: no world\n")
                return
            end

            local cls = ResolveClass(shortName)
            if not cls then
                print("[ModMenu] spawn failed: class not loaded: " .. tostring(shortName) ..
                      " (it may only exist on certain maps)\n")
                return
            end

            local loc = pawn:K2_GetActorLocation()
            local fwd = pawn:GetActorForwardVector()
            local rot = pawn:K2_GetActorRotation()

            -- sideways vector, on the horizontal plane
            local rightX, rightY = -fwd.Y, fwd.X
            local made = 0

            for i = 1, count do
                local offset = (i - 1) - ((count - 1) / 2.0)
                local where = {
                    X = loc.X + (fwd.X * 130.0) + (rightX * offset * 55.0),
                    Y = loc.Y + (fwd.Y * 130.0) + (rightY * offset * 55.0),
                    Z = loc.Z + 60.0,
                }
                local actor = world:SpawnActor(cls, where, rot)
                if isValid(actor) then
                    made = made + 1
                    SpawnerMods.PostSpawnSetup(shortName, actor, pawn)
                end
            end

            if made > 0 then
                print("[ModMenu] spawned " .. made .. " x " .. tostring(shortName) .. "\n")
            else
                print("[ModMenu] SpawnActor returned nothing for " .. tostring(shortName) .. "\n")
            end
        end)

        if not ok then
            print("[ModMenu] spawn error: " .. tostring(err) .. "\n")
        end
    end)
end

-- "Give me one of everything in this category", which is what the lobby room
-- effectively does. Capped so a 49-entry category cannot dump the whole set on
-- the player's head at once.
function SpawnerMods.SpawnWholeCategory(categoryIndex, getPawn, limit)
    local cat = SpawnerMods.Categories[categoryIndex]
    if not cat then return end
    limit = tonumber(limit) or 40

    local n = 0
    for _, entry in ipairs(cat.items) do
        if n >= limit then break end
        if SpawnerMods.IsSpawnable(entry) then
            n = n + 1
            SpawnerMods.SpawnByClassName(entry[2], getPawn, 1)
        end
    end
    print("[ModMenu] spawning " .. n .. " item(s) from " .. tostring(cat.name) .. "\n")
end

function SpawnerMods.DropCaches()
    classCache = {}
end

return SpawnerMods
