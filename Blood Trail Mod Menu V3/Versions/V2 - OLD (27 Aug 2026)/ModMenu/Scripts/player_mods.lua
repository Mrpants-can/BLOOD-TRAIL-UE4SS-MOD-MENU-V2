-- Blood Trail Mod Menu - player / combat / enemy mods
--
-- ===================================================================
-- READ THIS BEFORE TOUCHING ANY PROPERTY
--
-- Asking UE4SS for a property that the object's class does NOT have makes it
-- dereference a null FProperty. That is an access violation *inside UE4SS.dll*
-- (read at offset 0xC from null) and pcall CANNOT catch it - the game just
-- dies. It crashed three times because "Infinite Mana" read MaxMana on the
-- Wendigo pawn, which has no such property.
--
-- So every read/write goes through get()/set(), which check pawn_schema.lua
-- first. That file is generated from CXXHeaderDump and lists every property
-- each class really has, inherited ones included.
-- ===================================================================
--
-- The game ships TWO player pawn classes with different property names:
--   WendigoVrChar_C   : AVRCharacter  - Invincible, playerhealthmax,
--                       Ammo_akmag..., has CharacterMovement.  THE ONE YOU PLAY.
--   BP_VRCharacter_C  : APawn         - Dead, PlayerMaxHealth, 9mm_Ammo...,
--                       CourageLevel, Mana, Arrows, no movement component.

local PlayerMods = {}

local okSchema, SCHEMA = pcall(require, "pawn_schema")
if not okSchema or type(SCHEMA) ~= "table" then
    print("[ModMenu] WARNING: pawn_schema.lua missing - property guards are off\n")
    SCHEMA = {}
end

local WENDIGO = "WendigoVrChar_C"
local LEGACY  = "BP_VRCharacter_C"
local PAWN_CLASSES = { WENDIGO, LEGACY }

-- Blood Trail has several unrelated enemy classes. Scanning only the ALS one
-- meant the ESP found nothing during real gameplay, where the enemies are
-- BP_*AttackZombie_C and BP_NPC_Man_C.
--
-- Widening it naively killed the game: the scan caught actors that had only just
-- been spawned and were still being constructed. IsValid() returns true for
-- those. The fix is the settle gate below - an actor must survive two
-- consecutive scans before we touch it, so anything mid-construction is skipped
-- until it is fully alive.
-- All three zombie types derive from BP_MeleeAI_Character_C, so that one entry
-- covers them; BP_NPC_Man_C derives from BP_NPC_C.
--
-- CRITICAL: calling FindAllOf on a class that is not currently loaded kills the
-- game - it crashed on the very first sweep, before any enemy existed. So each
-- class is checked with StaticFindObject (a hash lookup on the full asset path,
-- not an object-array walk) and only enumerated once it is known to be loaded.
-- ONLY the ALS class. Do not add the zombie/NPC classes here.
--
-- Three separate attempts to widen this all killed the game, the last one even
-- with a loaded-class check AND a two-sweep settle gate. The fault is inside
-- FindAllOf itself: walking the object array touches a zombie that is still
-- being constructed, so it faults before any guard of ours can skip it. Idle
-- sweeps were fine; it died the instant zombies spawned.
--
-- ALS_Player_CharacterBPai_C is the campaign enemy (BP_VRCharacter references it
-- as ActiveEnemyA and in RagdollArray) and enumerating it has been stable across
-- every session. The survival-mode zombies derive from BP_MeleeAI_Character_C
-- and are NOT covered.
--
-- The way to fix this properly is NotifyOnNewObject: register a callback for the
-- enemy classes, keep our own registry, and never call FindAllOf at all.
local ENEMY_CLASS = "ALS_Player_CharacterBPai_C"
local ENEMY_CLASSES = { ENEMY_CLASS }

-- The other enemy families, reached WITHOUT FindAllOf. See EnemyWatch below.
local WATCH_CLASSES = {
    "BP_MeleeAI_Character_C",     -- base of all three zombie types
    "BP_HardAttackZombie_C",
    "BP_MediumAttackZombie_C",
    "BP_EasyAttackZombie_C",
    "BP_NPC_Man_C",
}

-- Enemies handed to us by NotifyOnNewObject: { {obj = ..., born = tick}, ... }
local watched = {}
local watchTick = 0

-- ALS enemies come from a FindAllOf sweep; cache the result and refresh it every
-- few passes rather than walking the object array every time.
local alsCache = nil
local alsStamp = -1
local alsPass = 0
local ALS_REFRESH_PASSES = 4

-- Closure over the variable, so it follows every reassignment of `watched`.
-- Published to status: if watchhits climbs while this stays 0, the filter is
-- throwing entries away; if watchhits stops climbing, the hook itself is dead.
PlayerMods.WatchListSize = function() return #watched end
local WATCH_SETTLE_TICKS = 10   -- ~1 s before an entry is touched at all


-- addresses seen in the previous sweep; only these are safe to read/write
-- (forEachSettledEnemy itself is defined below, after isValid exists)
local settledActors = {}
local GUN_SKEL    = "SkeletalGun_C"

-- The base class plus every concrete gun blueprint that derives from it.
-- FindAllOf returns instances of the EXACT class only, so sweeping the base
-- class alone never touched a real gun - which is why no-recoil never reached
-- the shotgun.
local gunSweepPass = 0
local GUN_SUBCLASSES = {
    "SkeletalGun_C",
    "bp_Skel_shotgun_C", "bp_Skel_ak_C", "bp_skel_glock_C", "bp_skel_92fs_C",
}
local GUN_PHYS    = "BP_PhysicalMagazineFirearm_C"
local MAG_SKEL    = "BP_SkeletalMag_C"
local MAG_STD     = "BP_Magazine_C"

PlayerMods.state = {
    GodMode            = true,
    InfiniteBulletTime = true,
    InfiniteCourage    = true,
    InstantCrackRegen  = false,
    InfiniteMana       = false,
    InfiniteArrows     = false,
    InfiniteAmmo       = true,
    NoRecoil           = true,
    FullAuto           = false,
    MeleeWeaponDamage  = false,
    MeleeKnockback     = 10.0,   -- multiplier on the reported swing speed
    MeleeDamage        = 100.0,  -- flat damage per hit from a melee weapon
    MeleeWeightClass   = 10,
    -- Forgiving hit detection: widen the box/sphere a swing has to overlap,
    -- so grazing swings still land. VERIFIED live (reachset=5, no crash) -
    -- SetBoxExtent/SetSphereRadius are survivable, unlike AddImpulse.
    MeleeAlwaysHits    = true,
    -- Your hand kept brushing the headlamp / NVG on your chest and flipping
    -- them mid-fight. On by default - it is a fix, not a cheat.
    NoAccidentalLamp   = true,
    -- Grab a body with either hand and throw it
    GrabEnemies        = false,
    GrabRange          = 90,      -- cm from the hand
    ThrowForce         = 1800.0,
    MeleeReach         = 60,     -- half-extent in cm of the hit volume     -- how heavy every melee weapon swings
    -- Real fists. Separate from the above: that one boosts what a WEAPON does,
    -- this one gives the bare hand a blunt weapon's weight and damage.
    -- Flight / noclip / crouch. Direction is the HMD: you fly where you look,
    -- and looking level hovers so you can stop.
    MasterVolume       = 1.0,     -- pushed into the pawn's four volume multipliers
    -- Panel geometry. The component cannot be moved, so size stands in for
    -- distance and blank padding lines stand in for height; see gui.lua.
    PanelSize          = 3.8,     -- text world size; SMALLER reads as further away
    PanelLift          = 0,       -- manual trim in lines ON TOP of the auto-aiming
    PanelOnTop         = false,   -- true draws the menu over walls, hands and guns
    PanelSolidBg       = false,   -- stencil backing plate; see the note in gui.lua
    PanelDepthFix      = true,    -- swap the game's no-depth HUD material for one that occludes
    -- The motion controller reports its GRIP pose, whose forward runs down
    -- the handle, not where you naturally point. Pitch the ray to match the
    -- aim direction; negative tips it forward/down off the grip axis.
    PointerPitch       = 0,       -- degrees, solved by CALIBRATE
    PointerYaw         = 0,       -- degrees, solved by CALIBRATE
    TwoPointers        = true,    -- a laser from both hands at once
    -- Reach out and touch the panel instead of aiming at it. No ray
    -- direction is involved, so there is no aim offset to get wrong.
    AimFromWidget      = true,    -- use the game's own WidgetInteraction ray (exact)
    -- OFF by default: this reads the hyphenated "HandMesh-Left" property,
    -- which the schema generator deliberately skips, and enumerates every
    -- socket on a skeletal mesh. The widget ray below is both safer and
    -- more accurate, so the rig is only a fallback worth opting into.
    AimFromSocket      = false,
    -- OFF: the laser is the interaction. Live scan showed mode=touch/touch with
    -- the hands merely NEAR the panel plane, so hand-projection was hijacking
    -- the cursor while the player was trying to point - the cursor followed the
    -- hand, not the beam, which is exactly "the line pointer is not accurate".
    TouchPointer       = false,
    -- 25 cm: touch applies only when the hand is genuinely AT the panel.
    --
    -- This was briefly 100, to route around ray aiming entirely, because the
    -- aim axis looked unknowable. It is not: the game's own
    -- WidgetInteractionComponent on the teleport controller carries the exact
    -- pointing ray (see aimFromWidget). With a correct ray there is no reason
    -- to bypass pointing, so touch goes back to meaning touch.
    TouchRange         = 25,
    FlyMode            = false,
    NoClip             = false,   -- implies flight, and turns collision off
    FlySpeed           = 600.0,   -- cm/s
    FlyDeadzone        = 0.20,    -- how level counts as "level" (0..1)
    CrouchDown         = false,
    -- Brightness for any world, via the engine's own gamma
    BrightWorld        = false,
    Brightness         = 2.0,
    GammaDefault       = 2.2,    -- the engine's stock gamma, restored on off     -- 1.0 = normal, higher = brighter
    VirtualJump        = false,  -- the game has none; A button jumps
    CrouchOnStick      = true,    -- click the RIGHT stick to duck / stand
    -- Look-to-steer by DEFAULT. Requiring the stick meant hovering forever
    -- whenever that axis event does not arrive, which is what kept happening.
    FlyNeedsStick      = false,   -- optional: also require the stick
    FlyStickDeadzone   = 0.15,
    CrouchHeight       = 40.0,
    CrouchDrop         = 50.0,   -- cm the play space sinks when ducking   -- capsule half-height when ducked
    -- Turns off everything that touches enemies - the half of the mod that
    -- can still crash at the end of a round. Everything else keeps working.
    SafeMode           = false,
    StrengthFists      = false,
    FistStrikePower    = 10,     -- the hand's own StrikePower (weight class)
    FistDamage         = 150.0,
    -- Both VERIFIED live: ragdoll-only survived, ragdoll+launch survived four
    -- punches. Kept as separate switches so a future crash still bisects.
    FistRagdoll        = true,   -- go limp when punched (RagdollStart)
    FistLaunch         = true,   -- and fly (LastRagdollVelocity write)
    FistLaunchForce    = 900.0,  -- BaseDamage a punch delivers, like a hammer
    FireModeIndex      = 3,      -- which Enum_FireStates value counts as auto
    FireRateValue      = 0.06,   -- seconds between shots; lower is faster
    FreezeEnemies      = false,
    StopEnemySpawns    = false,
    SuperSpeed         = false,
    SpeedMultiplier    = 2.0,
    HighJump           = false,
    JumpMultiplier     = 2.0,
    TeleportBoost      = false,
    GoreForever        = false,
    TimeScale          = 1.0,
    -- forced max HP while God Mode is on, so BRUTAL's 1 HP cannot apply
    GodHP              = 10000.0,
    EnemyESP           = false,
}

PlayerMods.info = {
    pawn = "none", health = 0, healthmax = 0, kills = 0, enemies = 0,
}


local WENDIGO_AMMO = {
    "Ammo_armag", "Ammo_akmag", "Ammo_vectormag", "Ammo_glockmag",
    "Ammo_12gashell", "Ammo_pipebomb", "Ammo_92fsMag",
}
local LEGACY_AMMO = {
    "9mm_Ammo", "762x39_Ammo", "12GA_Ammo", "45ACP_Ammo", "556_Ammo",
    "308_Ammo", "50cal_Ammo", "338L_Ammo", "300B_Ammo", "38_Ammo",
    "40cal_Ammo", "Arrows",
}

---------------------------------------------------------------------------
-- schema-guarded property access
---------------------------------------------------------------------------

-- If we have no schema for a class we allow the access (best effort on an
-- unknown class); if we DO have one, it is enforced strictly.
-- Properties that ARE on the class per CXXHeaderDump but are missing from the
-- generated schema, because gen_pawn_schema.py drops names containing a hyphen.
-- Verified by hand in WendigoVrChar.hpp before being listed here - this bypasses
-- the guard, so nothing goes in without checking the header first.
local SCHEMA_EXTRA = {
    ["HandMesh-Right"] = true,   -- WendigoVrChar.hpp:29
    ["HandMesh-Left"]  = true,   -- WendigoVrChar.hpp:35
}

local function hasProp(cls, name)
    if SCHEMA_EXTRA[name] then return true end
    local s = SCHEMA[cls]
    if not s or not s.props then return true end
    return s.props[name] == true
end

local function hasFunc(cls, name)
    local s = SCHEMA[cls]
    if not s or not s.funcs then return true end
    return s.funcs[name] == true
end

PlayerMods.hasProp = hasProp

local function get(obj, cls, name)
    if not hasProp(cls, name) then return nil end
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

local function set(obj, cls, name, value)
    if not hasProp(cls, name) then return end
    pcall(function() obj[name] = value end)
end

-- Writing an FVector property with a plain Lua table does NOT stick. UE4SS
-- accepts the assignment without error and the value is unchanged when you read
-- it back - which is how a "working" ragdoll throw turned out to be a no-op.
-- What does work is fetching the existing struct and assigning its components,
-- so the write goes through UE4SS's own property wrapper.
--
-- Tries three forms and reports which one took, so this is never guesswork
-- again: component assignment, then :set(), then the plain table.
local function setVector(obj, cls, name, x, y, z)
    if not hasProp(cls, name) then return false end

    local function reads()
        local ok, v = pcall(function() return obj[name] end)
        if ok and v and type(v.X) == "number" then return v end
        return nil
    end

    -- 1. mutate the components of the struct the game already has
    pcall(function()
        local v = obj[name]
        v.X, v.Y, v.Z = x, y, z
    end)
    local got = reads()
    if got and math.abs(got.X - x) < 1.0 then
        PlayerMods.vecMode = "components"
        return true
    end

    -- 2. some UE4SS builds expose :set() on the struct
    pcall(function() obj[name]:set({ X = x, Y = y, Z = z }) end)
    got = reads()
    if got and math.abs(got.X - x) < 1.0 then
        PlayerMods.vecMode = "set()"
        return true
    end

    -- 3. plain table assignment (the form that silently did nothing)
    pcall(function() obj[name] = { X = x, Y = y, Z = z } end)
    got = reads()
    if got and math.abs(got.X - x) < 1.0 then
        PlayerMods.vecMode = "table"
        return true
    end

    PlayerMods.vecMode = "NONE WORKED"
    return false
end

local function call(obj, cls, name)
    if not hasFunc(cls, name) then return end
    pcall(function() obj[name](obj) end)
end

-- call() with a single argument. Same schema gate: a blueprint function that
-- does not exist on the class must never be touched.
-- Deliberately NOT varargs+unpack - `table.unpack` vs `unpack` differs between
-- Lua versions and the UE4SS runtime is not guaranteed to have either.
local function callWith3(obj, cls, name, a, b, c)
    if not hasFunc(cls, name) then return false end
    local ok = pcall(function() obj[name](obj, a, b, c) end)
    return ok
end

local function callWith2(obj, cls, name, a, b)
    if not hasFunc(cls, name) then return false end
    local ok = pcall(function() obj[name](obj, a, b) end)
    return ok
end

local function callWith(obj, cls, name, a)
    if not hasFunc(cls, name) then return false end
    local ok = pcall(function() obj[name](obj, a) end)
    return ok
end

local function isValid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

PlayerMods.isValid = isValid

-- forEachSettledEnemy is defined further down, once forEachOf exists.
local forEachSettledEnemy

---------------------------------------------------------------------------
-- pawn lookup
---------------------------------------------------------------------------
-- FindFirstOf walks the object array, which must never happen at tick rate -
-- during level travel it reads half-destroyed objects. So when the pawn is not
-- cached we only retry every RETRY_TICKS.

local cachedPawn, cachedKind = nil, nil
local retryIn = 0
local RETRY_TICKS = 5   -- at 100 ms per tick = twice a second

-- GetFullName() is "ClassName Package.Path:Object", so the first token is the
-- class. Used once per acquisition, never per tick - resolving names in a hot
-- loop is its own crash.
local function classOf(obj)
    local ok, full = pcall(function() return obj:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil, nil end
    if string.find(full, "Default__", 1, true) then return nil, full end
    return string.match(full, "^(%S+)"), full
end

-- Ask the player controller which pawn it is POSSESSING.
--
-- This is the fix for "the ESP unlinks and then just sits in one spot".
-- FindFirstOf returns the first instance of a class in the object array, and
-- after a respawn the old pawn is often still there and still IsValid() - it is
-- simply no longer yours. The mod kept writing to that corpse's text component,
-- which naturally stays exactly where it died. Restarting did not help either,
-- because the re-lookup picked the same stale pawn again.
-- The controller is cached: FindFirstOf walks the object array, and this is
-- consulted every second to confirm we still hold the right pawn.
local cachedPC = nil

-- Forget the cached controller so the next acquisition re-finds it. Needed by
-- the ESP restart: keeping the controller means keeping whatever pawn it last
-- handed back, corpse included.
function PlayerMods.DropController()
    cachedPC = nil
end

-- THE controller class in this game is a blueprint: ASteam_VR_Player_Controller_C
-- (CXXHeaderDump/Steam_VR_Player_Controller.hpp), deriving AVRPlayerController.
-- Looking up the engine base name "PlayerController" found NOTHING, so
-- possessedPawn() always returned nil and every acquisition silently fell
-- through to the class sweep below - which is what kept picking the corpse and
-- is why the restart button appeared to do nothing. Search the concrete class
-- first, then the VRExpansion base, then the engine base as a last resort.
local PC_CLASSES = {
    "Steam_VR_Player_Controller_C",
    "VRPlayerController",
    "PlayerController",
}

-- which path last produced the pawn - published to status.txt so a bad
-- acquisition is visible instead of being guessed at
PlayerMods.pawnSource = "none"

-- Read the pawn a candidate controller is possessing, or nil.
local function pawnOf(pc)
    if not isValid(pc) then return nil end
    for _, field in ipairs({ "Pawn", "AcknowledgedPawn" }) do
        local okP, p = pcall(function() return pc[field] end)
        if okP and isValid(p) then return p end
    end
    return nil
end

local function possessedPawn(allowSearch)
    if not isValid(cachedPC) then
        cachedPC = nil
        if not allowSearch then return nil end
        for _, cls in ipairs(PC_CLASSES) do
            local ok, pc = pcall(FindFirstOf, cls)
            -- Only accept a candidate that is really possessing something.
            -- That single test does all the work: a name lookup that misses
            -- hands back an unrelated object, and a class-default object never
            -- possesses a pawn, so both fail it. Do NOT also demand classOf(pc)
            -- here - the controller's identity is irrelevant, and requiring a
            -- resolvable name rejected the real controller outright, which put
            -- us straight back on the corpse-picking sweep.
            if ok and isValid(pc) and pawnOf(pc) then
                cachedPC = pc
                break
            end
        end
    end
    return pawnOf(cachedPC)
end

local verifyIn = 0
local VERIFY_TICKS = 10     -- ~1 s: re-check we still hold the possessed pawn

function PlayerMods.GetPawn()
    -- Periodically confirm the cached pawn is still the one being possessed,
    -- not just still a valid object.
    if isValid(cachedPawn) then
        verifyIn = verifyIn - 1
        if verifyIn > 0 then return cachedPawn, cachedKind end
        verifyIn = VERIFY_TICKS

        -- cached controller only; never sweep the object array on this path
        local live = possessedPawn(false)
        if live == nil then return cachedPawn, cachedKind end
        -- Only switch for a pawn we actually understand. In this game the
        -- controller can be possessing a VR helper pawn rather than the player
        -- character, and chasing that leaves the mod with nothing usable.
        local liveCls = classOf(live)
        if liveCls ~= WENDIGO and liveCls ~= LEGACY then
            return cachedPawn, cachedKind
        end
        local okA, a = pcall(function() return cachedPawn:GetAddress() end)
        local okB, b = pcall(function() return live:GetAddress() end)
        if okA and okB and a == b then return cachedPawn, cachedKind end
        -- possession changed: fall through and re-acquire
    end

    cachedPawn, cachedKind = nil, nil
    verifyIn = VERIFY_TICKS

    -- Everything below walks the object array, so it all sits behind the retry
    -- gate - otherwise a menu with no pawn would sweep it several times a tick.
    if retryIn > 0 then
        retryIn = retryIn - 1
        return nil, nil
    end
    retryIn = RETRY_TICKS

    -- 1. whatever the controller is actually possessing, IF it is one of the two
    --    player character classes. Anything else (VR helper pawns) is ignored so
    --    the sweep below can still find the real character.
    local live = possessedPawn(true)
    if isValid(live) then
        local cls = classOf(live)
        if cls == WENDIGO or cls == LEGACY then
            cachedPawn, cachedKind = live, cls
            PlayerMods.pawnSource = "controller"
            return cachedPawn, cachedKind
        end
    end

    -- 2. Fall back to a class sweep - but pick the instance that HAS a
    --    controller. A dead pawn left behind after a respawn is still valid and
    --    is often first in the object array; it is unpossessed, so its
    --    Controller is null. That is what makes the ESP sit on a corpse.
    for _, cls in ipairs(PAWN_CLASSES) do
        local ok, list = pcall(FindAllOf, cls)
        if ok and list then
            local firstValid = nil
            for _, obj in ipairs(list) do
                -- never accept a class-default object: it has no world, and
                -- every property read on it is a different flavour of crash
                if isValid(obj) and classOf(obj) then
                    if firstValid == nil then firstValid = obj end
                    local okC, ctrl = pcall(function() return obj.Controller end)
                    if okC and isValid(ctrl) then
                        -- A corpse can keep a stale Controller pointer, so the
                        -- controller must agree that it possesses THIS pawn.
                        -- Without the back-check the sweep happily re-picks the
                        -- body it just left, which is the whole bug.
                        local mutual = true
                        local okB, back = pcall(function() return ctrl.Pawn end)
                        if okB and isValid(back) then
                            local okX, x = pcall(function() return back:GetAddress() end)
                            local okY, y = pcall(function() return obj:GetAddress() end)
                            if okX and okY then mutual = (x == y) end
                        end
                        if mutual then
                            cachedPawn, cachedKind = obj, cls
                            PlayerMods.pawnSource = "sweep"
                            return cachedPawn, cachedKind
                        end
                    end
                end
            end
            -- nothing possessed: better to use one than none
            if firstValid then
                cachedPawn, cachedKind = firstValid, cls
                PlayerMods.pawnSource = "fallback"
                return cachedPawn, cachedKind
            end
        end
    end
    PlayerMods.pawnSource = "none"
    return nil, nil
end

-- Caches declared further down the file register a reset here. Round end
-- destroys every actor in the world, and a tick that then walks a cache full of
-- dead ones is the crash. IsValid() does NOT save you - it returns true for a
-- half-destroyed actor. Adding a cache without registering it here is exactly
-- the bug that made the mod crash at the end of a round.
local extraResets = {}
local function onDropCaches(fn) extraResets[#extraResets + 1] = fn end

-- A ROUND ENDING IS NOT A WORLD CHANGE.
--
-- The crash was `EXCEPTION_ACCESS_VIOLATION reading address 0x268` with UE4SS in
-- the stack - a property read off an object whose guts are gone. Dropping caches
-- on world change did not help, because when a ROUND ends the map does not
-- change at all: same world address, but every enemy is destroyed. So anything
-- still holding an enemy across ticks (a fling in progress, a grabbed body) was
-- handing UE4SS a corpse pointer on the very next tick.
--
-- IsValid() does not save you here - it returns true for a half-destroyed actor.
-- The only reliable rule: NEVER touch an enemy unless the current sweep just
-- handed it back. This registry records who was seen alive and when; anything
-- not seen in the last couple of sweeps is dropped untouched.
local liveSeen = {}         -- [address] = sweep number it was last seen in
-- The OBJECT the current sweep handed back, per address. Holding our own
-- reference across passes is not safe even with an address check: when a body
-- is destroyed the engine reuses that memory for a NEW enemy, so the address
-- looks alive while the reference we stored is still the dead one. That is the
-- memcpy fault - a struct write to a recycled pointer. Always write through the
-- object THIS sweep returned, never a stored one.
local liveObj = {}
local liveSweep = 0
onDropCaches(function() liveSeen = {} liveObj = {} liveSweep = 0 end)

local function markLive(e)
    local ok, addr = pcall(function() return e:GetAddress() end)
    if ok and addr then
        liveSeen[addr] = liveSweep
        liveObj[addr] = e
    end
    return ok and addr or nil
end

-- The live object for an address, or nil. This is the ONLY safe way to reach an
-- enemy we noted on an earlier pass.
local function liveEnemy(addr)
    if not addr then return nil end
    if liveSeen[addr] ~= liveSweep then return nil end
    return liveObj[addr]
end

-- Is this address still one the sweep is returning? Allow a sweep or two of
-- slack so a body is not dropped between passes.
-- THE CRASH, PRECISELY.
--
-- The dump faults inside VCRUNTIME140.dll - a memcpy - reading null+0x268. That
-- is a STRUCT copy: reading or writing an FVector property (TargetRagdollLocation,
-- K2_GetActorLocation) on an actor whose guts are already gone.
--
-- The old guard allowed two sweeps of slack, so at 2 Hz a body destroyed nearly
-- a second ago still passed and got a struct write. There is no safe amount of
-- slack: an enemy is touchable only while the CURRENT sweep is still handing it
-- back. Anything older is a corpse pointer.
local function stillLive(addr)
    if not addr then return false end
    return liveSeen[addr] == liveSweep
end

PlayerMods.LiveCount = function()
    local n = 0
    for _, v in pairs(liveSeen) do if (liveSweep - v) <= 2 then n = n + 1 end end
    return n
end


function PlayerMods.DropCaches()
    for _, fn in ipairs(extraResets) do pcall(fn) end
    cachedPawn, cachedKind = nil, nil
    cachedPC = nil
    verifyIn = 0
    retryIn = 0
    -- every actor from the old world is gone; nothing is settled any more
    settledActors = {}
    watched = {}
    alsCache = nil
    alsPass = 0
    alsStamp = -1
    PlayerMods.lastEnemy, PlayerMods.lastEnemyClass = nil, nil
end

function PlayerMods.PawnLabel()
    if cachedKind == WENDIGO then return "Wendigo" end
    if cachedKind == LEGACY  then return "VRChar"  end
    return "none"
end

-- Does a given toggle do anything on the pawn that is live right now? Used to
-- show "n/a" instead of letting the player wonder why nothing happened.
local REQUIRES = {
    GodMode            = { "Invincible", "playerhealth" },
    InfiniteBulletTime = { "BullettimePercent" },
    InfiniteCourage    = { "CourageLevel" },
    InstantCrackRegen  = { "CrackRegenTime" },
    InfiniteMana       = { "MaxMana" },
    InfiniteArrows     = { "MaxArrows" },
    StopEnemySpawns    = { "ShouldSpawnEnemies" },
    GoreForever        = { "RagdollLifetimeInSeconds" },
    SuperSpeed         = { "CharacterMovement" },
    HighJump           = { "CharacterMovement" },
    TeleportBoost      = { "TraditionalDistance", "DirectionalTeleportDistance" },
}

function PlayerMods.Applies(key)
    local need = REQUIRES[key]
    if not need then return true end
    if not cachedKind then return true end
    for _, prop in ipairs(need) do
        if hasProp(cachedKind, prop) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- god mode
---------------------------------------------------------------------------
-- Wendigo has a real Invincible flag - use it. The legacy pawn has none, so
-- hold health AND max health high there; topping up to the pawn's own max is
-- not enough, a single hit bigger than max still kills between ticks.

-- The ROUND OPTIONS board sets max HP per difficulty, and BRUTAL sets it to 1.
-- ChangeDifficulty() rewrites playerhealthmax every time a difficulty is picked,
-- so God Mode has to FORCE the maximum rather than read it - otherwise on BRUTAL
-- "restore to full" means restoring to 1 HP.
local function ApplyGodMode(pawn, kind)
    local hp = PlayerMods.state.GodHP
    if type(hp) ~= "number" or hp <= 0 then hp = 10000.0 end

    if kind == WENDIGO then
        set(pawn, kind, "Invincible", true)
        set(pawn, kind, "playerhealthmax", hp)
        set(pawn, kind, "playerhealth", hp)
    else
        set(pawn, kind, "PlayerMaxHealth", hp)
        set(pawn, kind, "playerhealth", hp)
        set(pawn, kind, "Dead", false)
    end
end

-- Turning God Mode off hands max HP back to the difficulty the player chose,
-- by asking the game to re-apply it rather than guessing a number.
local function ClearGodMode(pawn, kind)
    set(pawn, kind, "Invincible", false)
    local diff = get(pawn, kind, "Difficulty")
    if type(diff) == "number" and hasFunc(kind, "ChangeDifficulty") then
        pcall(function() pawn:ChangeDifficulty(diff) end)
    end
end

---------------------------------------------------------------------------
-- ammo
---------------------------------------------------------------------------

local function RefillReserveAmmo(pawn, kind)
    if kind == WENDIGO then
        for _, field in ipairs(WENDIGO_AMMO) do
            local maxV = get(pawn, kind, field .. "max")
            if type(maxV) == "number" and maxV > 0 then set(pawn, kind, field, maxV) end
        end
        call(pawn, kind, "FullAmmoRefill")
    else
        for _, field in ipairs(LEGACY_AMMO) do
            local maxV = get(pawn, kind, "Max" .. field)
            if type(maxV) == "number" and maxV > 0 then set(pawn, kind, field, maxV) end
        end
        call(pawn, kind, "InstantFullAmmo")
    end
end

-- defined just below; declared here so RefillSkeletalGun can reference it
local RechamberSkeletalGun
-- defined below, used by the pre-fire refill above it
local ZeroRecoil

local function RefillSkeletalGun(gun)
    if not isValid(gun) then return end
    local s, C = PlayerMods.state, GUN_SKEL

    if s.InfiniteAmmo then
        local maxA = get(gun, C, "AmmoMAX")
        set(gun, C, "Ammo", (type(maxA) == "number" and maxA > 0) and maxA or 999)
        set(gun, C, "RoundChambered", true)
        set(gun, C, "HasSpentShell", false)

        local mag = get(gun, C, "MagRef")
        if isValid(mag) then
            local magMax = get(mag, MAG_SKEL, "MaxAmmo")
            set(mag, MAG_SKEL, "magazineAmmo",
                (type(magMax) == "number" and magMax > 0) and magMax or 999)
        end
    end

    -- No-recoil is applied in the POST-fire hook (afterShot), not here: the
    -- game writes the kick as part of firing, so anything set beforehand is
    -- immediately overwritten. The periodic sweep still calls ZeroRecoil so a
    -- gun you just picked up starts out clean.
    if s.NoRecoil then ZeroRecoil(gun) end

    -- Full auto. Enum_FireStates has four values whose display names were lost
    -- in the dump (NewEnumerator0/1/2/5), so which one is "auto" is a guess -
    -- hence FireModeIndex is adjustable rather than hardcoded. Keeping the burst
    -- counters topped up means burst mode never runs out either way.
    if s.FullAuto then
        set(gun, C, "Firingmode", math.floor(s.FireModeIndex or 3))
        set(gun, C, "FireRate", s.FireRateValue or 0.06)
        set(gun, C, "BurstAmount", 999)
        set(gun, C, "BurstRemain", 999)
        RechamberSkeletalGun(gun)
    end
end

-- "Never needs pumping": put the gun back into the ready-to-fire state.
--
-- This MUST run AFTER the shot (post-hook). The first version ran as a pre-hook,
-- so it chambered a round and then the shot immediately cleared it again - which
-- is exactly why it appeared to do nothing.
--
-- It also previously set `separatebolt = false` and `bReadyToChamber = true`.
-- `bReadyToChamber` does not exist on this class at all (so it was silently
-- dropped by the schema guard), and `separatebolt`/`shotgun`/`revolver` are
-- weapon-TYPE configuration, not cycle state - clearing them mangles the gun's
-- own logic instead of skipping the pump. The real gates are these:
-- readable snapshot of the cycle flags, published to status so "the shotgun
-- still needs pumping" can be checked instead of argued about
-- Diagnostic only, but it walks the whole object array - at one write per
-- second that was the single most expensive thing in the status pass. Cache it
-- and refresh every 10th call; a gun's chamber flags do not need 1 Hz.
local gunStateCache, gunStatePass = "no gun", 0

function PlayerMods.GunState()
    gunStatePass = gunStatePass + 1
    if gunStatePass % 10 ~= 1 then return gunStateCache end

    local out = nil
    local ok, list = pcall(FindAllOf, GUN_SKEL)
    if ok and list then
        for _, g in ipairs(list) do
            if isValid(g) then
                out = string.format(
                    "chambered=%s spent=%s cocked=%s boltback=%s canfire=%s",
                    tostring(get(g, GUN_SKEL, "RoundChambered")),
                    tostring(get(g, GUN_SKEL, "HasSpentShell")),
                    tostring(get(g, GUN_SKEL, "FullyCocked")),
                    tostring(get(g, GUN_SKEL, "BoltLockedBack")),
                    tostring(get(g, GUN_SKEL, "CanBeFired")))
                break
            end
        end
    end
    gunStateCache = out or "no gun"
    return gunStateCache
end

-- Kill the kick. This must run AFTER the shot: the game writes these vectors
-- as part of firing, so zeroing them beforehand (which is where this used to
-- live, inside the pre-fire refill) was overwritten a moment later and did
-- nothing. Same mistake as the shotgun chamber.
ZeroRecoil = function(gun)
    if not isValid(gun) then return end
    local C = GUN_SKEL
    setVector(gun, C, "recoilrotationstblz",    0.0, 0.0, 0.0)
    setVector(gun, C, "recoiltranslationstblz", 0.0, 0.0, 0.0)
    setVector(gun, C, "recoilrotation1hnd",     0.0, 0.0, 0.0)
    setVector(gun, C, "recoiltranslation1hnd",  0.0, 0.0, 0.0)
    set(gun, C, "RecoilDecayRate", 999.0)
    set(gun, C, "RecoilLerpRate", 0.0)
    set(gun, C, "RecoilDelay", 0.0)
    PlayerMods.recoilZeroed = (PlayerMods.recoilZeroed or 0) + 1
end

RechamberSkeletalGun = function(gun)
    if not isValid(gun) then return end
    local C = GUN_SKEL
    set(gun, C, "RoundChambered", true)   -- a live round is up
    set(gun, C, "HasSpentShell", false)   -- no spent case in the way
    set(gun, C, "FullyCocked", true)      -- hammer/striker is cocked
    set(gun, C, "SuccessfulCock", true)   -- the cock action counts as done
    set(gun, C, "CanCock", true)
    set(gun, C, "boltset", true)
    set(gun, C, "BoltLockedBack", false)  -- bolt/slide is forward, not held open
    set(gun, C, "PullBackInitiated", false)
    set(gun, C, "GunFired", false)        -- clear the "already fired" latch
    set(gun, C, "CanBeFired", true)       -- master gate, set last
end

local function RefillPhysicalGun(gun)
    if not isValid(gun) then return end
    local s, C = PlayerMods.state, GUN_PHYS

    if s.InfiniteAmmo then
        set(gun, C, "bHasInfinateAmmo", true) -- yes, the game misspells it
        set(gun, C, "bOutOfAmmo", false)
        set(gun, C, "bBulletChambered", true)

        local maxInt = get(gun, C, "MaxInternalAmmo")
        if type(maxInt) == "number" and maxInt > 0 then
            set(gun, C, "InternalAmmo", maxInt)
        end

        local mag = get(gun, C, "CurrentMag")
        if isValid(mag) then
            local magMax = get(mag, MAG_STD, "MaxAmmo")
            set(mag, MAG_STD, "CurrentAmmo",
                (type(magMax) == "number" and magMax > 0) and magMax or 999)
        end
    end

    -- The physical firearm has no FireRate float; it drives fire from a curve
    -- and a burst counter, so the lever here is the burst limit.
    if s.FullAuto then
        set(gun, C, "MaxBurstCount", 999)
        set(gun, C, "CurrentBurstNumber", 0)
    end

    if s.NoRecoil then
        set(gun, C, "UseRecoil", false)
        set(gun, C, "CurrentVRecoil", 0.0)
        set(gun, C, "CurrentHRecoil", 0.0)
        set(gun, C, "TargetVRecoil", 0.0)
        set(gun, C, "TargetHRecoil", 0.0)
    end
end

local function RefillLooseMag(mag, cls, field)
    if not isValid(mag) then return end
    local maxV = get(mag, cls, "MaxAmmo")
    set(mag, cls, field, (type(maxV) == "number" and maxV > 0) and maxV or 999)
end

---------------------------------------------------------------------------
-- damage hooks - THIS is what actually makes God Mode work
---------------------------------------------------------------------------
-- Holding playerhealth at max on a 10 Hz timer does not stop you dying: the
-- damage function subtracts health AND runs the death check inside the same
-- call, long before the next tick can restore anything. The pawn's `Invincible`
-- flag is set too, but these blueprint damage paths plainly do not consult it.
--
-- So intercept the damage itself. Wendigo takes damage through four functions
-- from PlayerDmgInterface, each with a single float parameter; the legacy pawn
-- uses the standard engine ReceiveXDamage events. Zero the parameter before the
-- function body runs and health never moves.

-- Blueprint hooks want the FULL object path, not the short class name. These
-- were recovered from the pak index - note the original mod hooked
-- "/Game/Weapons/BP_PhysicalMagazineFirearm..." which does not exist, so that
-- hook never bound at all. Both forms are registered here: whichever UE4SS
-- accepts wins, and a duplicate zeroing of the same damage is harmless.
PlayerMods.PATHS = {
    Wendigo  = "/Game/VRExpansion/Vive/WendigoVrChar.WendigoVrChar_C",
    Legacy   = "/Game/WeaponMaster/Blueprints/Basic/BP_VRCharacter.BP_VRCharacter_C",
    SkelGun  = "/Game/VRExpansion/Guns/skeletalguns/SkeletalGun.SkeletalGun_C",
    PhysGun  = "/Game/WeaponMaster/Blueprints/Basic/BP_PhysicalMagazineFirearm.BP_PhysicalMagazineFirearm_C",
}

-- Build "<full path>:Fn" and "<ShortClass>:Fn" for one function.
local function targets(fullPath, shortClass, fn)
    return { fullPath .. ":" .. fn, shortClass .. ":" .. fn }
end

local WENDIGO_DAMAGE_FNS = { "BulletDamage", "PunchDamage", "MeleeDamage", "ExplosiveDamage" }
local LEGACY_DAMAGE_FNS  = { "ReceiveAnyDamage", "ReceivePointDamage", "ReceiveRadialDamage" }

PlayerMods.damageHooks = 0
-- counts damage events actually intercepted, so it is possible to tell
-- "the hook never bound" from "nothing has hit you yet"
PlayerMods.damageBlocked = 0

-- Targets already bound, so retries never double-register the same function.
local hookedTargets = {}
PlayerMods.lastHookError = nil

function PlayerMods.RegisterDamageHooks()
    if not RegisterHook then return end

    local function zeroDamage(target)
        if hookedTargets[target] then return true end
        local ok, err = pcall(function()
            RegisterHook(target,
                -- pre: neuter the incoming damage
                function(self, damageParam)
                    if not PlayerMods.state.GodMode then return end
                    PlayerMods.damageBlocked = PlayerMods.damageBlocked + 1
                    pcall(function() damageParam:set(0.0) end)
                end,
                -- post: belt and braces, put health back where it was
                function(self)
                    if not PlayerMods.state.GodMode then return end
                    pcall(function()
                        local obj = self
                        local okG, got = pcall(function() return self:get() end)
                        if okG and got then obj = got end
                        if not isValid(obj) then return end
                        local maxHp = get(obj, WENDIGO, "playerhealthmax")
                                   or get(obj, LEGACY, "PlayerMaxHealth")
                        if type(maxHp) == "number" and maxHp > 0 then
                            pcall(function() obj.playerhealth = maxHp end)
                        end
                    end)
                end)
        end)
        if ok then
            hookedTargets[target] = true
            PlayerMods.damageHooks = PlayerMods.damageHooks + 1
        else
            -- UE4SS does not always raise a string here. When the target
            -- blueprint is not loaded yet the error object comes back as a
            -- function, which tostring() renders as "function: 000002109CA43F10".
            -- In the log that read like a real fault; it is just the expected
            -- early miss, and EnsureHooks binds them a second later. Say so in
            -- words rather than printing a pointer.
            if type(err) == "string" then
                PlayerMods.lastHookError = err
            elseif err == nil then
                PlayerMods.lastHookError = "no detail given"
            else
                PlayerMods.lastHookError =
                    "blueprint not loaded yet (" .. type(err) .. ") - will retry"
            end
        end
        return ok
    end

    for _, fn in ipairs(WENDIGO_DAMAGE_FNS) do
        for _, t in ipairs(targets(PlayerMods.PATHS.Wendigo, WENDIGO, fn)) do
            zeroDamage(t)
        end
    end
    for _, fn in ipairs(LEGACY_DAMAGE_FNS) do
        for _, t in ipairs(targets(PlayerMods.PATHS.Legacy, LEGACY, fn)) do
            zeroDamage(t)
        end
    end

    -- Only surface the error once nothing bound at all. A partial pass is
    -- normal: some blueprints load later than others, and the leftover
    -- lastHookError from those was being printed next to a successful
    -- "registered: 7", which made a healthy run look broken.
    local detail = ""
    if PlayerMods.damageHooks == 0 and PlayerMods.lastHookError then
        detail = "  (" .. PlayerMods.lastHookError .. ")"
    end
    print("[ModMenu] god-mode damage hooks registered: " ..
          PlayerMods.damageHooks .. detail .. "\n")
end

---------------------------------------------------------------------------
-- Hooks cannot be registered at mod-load time: the player's blueprint class is
-- not loaded yet, so every RegisterHook call fails and God Mode silently does
-- nothing (it reported "hooks registered: 0" in the live log). Keep retrying
-- until they bind, then stop.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Enemy watch: covering the zombie classes without FindAllOf
---------------------------------------------------------------------------
-- FindAllOf on the zombie families kills the game - it faults while walking an
-- actor that is still being constructed, and no guard placed after the call can
-- help. NotifyOnNewObject sidesteps the whole problem: the engine hands us each
-- new enemy as it appears, so we keep our own list and never enumerate anything.
--
-- The callback deliberately does NOTHING but store the reference. No property
-- reads, no GetAddress, no IsValid - the object is mid-construction at that
-- point and touching it is exactly what caused every previous crash. It is only
-- inspected later, once WATCH_SETTLE_TICKS have passed.

PlayerMods.watchCount = 0
PlayerMods.watchClasses = 0
local watchRegistered = {}

-- Hook the enemy's own BeginPlay instead of using NotifyOnNewObject.
--
-- NotifyOnNewObject was tried first and never fired: short names, full asset
-- paths, and re-registration after load all reported success and produced no
-- callback. RegisterHook is proven in this game - it is what makes God Mode
-- work - and ReceiveBeginPlay is the right moment: the actor is fully
-- constructed by then, so keeping a reference is safe, unlike the
-- mid-construction objects that made FindAllOf fault.
--
-- BP_MeleeAI_Character_C is the base of all three zombie types and none of them
-- override ReceiveBeginPlay, so this single hook catches every zombie.
local BEGINPLAY_TARGETS = {
    { "BP_MeleeAI_Character_C",
      "/Game/WeaponMaster/AI/BP_MeleeAI_Character.BP_MeleeAI_Character_C" },
    { "BP_NPC_Man_C",
      "/Game/characters/Human/Blueprints/CharacterLogic/BP_NPC_Man.BP_NPC_Man_C" },
}

-- NOTE: there was a preload here that called LoadAsset on the enemy blueprints
-- at mod-init, to arm the BeginPlay hooks before the first wave. It has been
-- REMOVED. UE4SS throws a C++ exception (0xE06D7363) when LoadAsset cannot
-- resolve an asset, and pcall does not catch that - it killed the game during
-- startup, before the event loop had even settled. It also never achieved its
-- goal: the first spawn was still missed with it in place.
--
-- The hooks bind on their own once the class loads naturally; EnsureEnemyWatch
-- retries from the main loop and now checks the callback id, so it will not
-- falsely mark an unbound hook as registered.

function PlayerMods.RegisterEnemyWatch()
    if not RegisterHook then return end

    for _, pair in ipairs(BEGINPLAY_TARGETS) do
        local cls, path = pair[1], pair[2]
        for _, target in ipairs({ path .. ":ReceiveBeginPlay",
                                  cls  .. ":ReceiveBeginPlay" }) do
            -- lazy-load trap again: the zombie blueprints are not loaded at
            -- mod-start, so this is retried from the main loop until it takes
            if not watchRegistered[target] then
                -- RegisterHook returns the pre/post callback ids on a real bind.
                -- pcall alone is NOT a success test: when the class is not
                -- loaded yet UE4SS finds no function, returns nothing, and the
                -- pcall still succeeds - so the target got marked "registered"
                -- while nothing was actually hooked, and it was never retried.
                -- That is why the first wave of a session was never tracked.
                local ok, preId = pcall(function()
                    return RegisterHook(target, function(self)
                        local okG, obj = pcall(function() return self:get() end)
                        local actor = (okG and obj) or self
                        watched[#watched + 1] =
                            { obj = actor, born = watchTick, cls = cls }
                        PlayerMods.watchCount = PlayerMods.watchCount + 1
                    end)
                end)
                if ok and type(preId) == "number" and preId > 0 then
                    watchRegistered[target] = true
                    PlayerMods.watchClasses = PlayerMods.watchClasses + 1
                end
            end
        end
    end
end

-- Retried from the main loop, because the zombie blueprints load lazily.
function PlayerMods.EnsureEnemyWatch()
    local before = PlayerMods.watchClasses
    PlayerMods.RegisterEnemyWatch()
    if PlayerMods.watchClasses > before then
        print("[ModMenu] enemy watch now on " .. PlayerMods.watchClasses ..
              " registrations (zombies/NPCs reach the ESP)\n")
    end
end

PlayerMods.hooksBound = false

function PlayerMods.EnsureHooks()
    -- Fist hooks live on the ENEMY classes, which are not loaded when the player
    -- pawn appears - they arrive with the first enemy. The old code stopped
    -- retrying the moment the god-mode hooks bound, so the fist hooks were
    -- attempted once, against classes that did not exist yet, and never again.
    -- That is why Strength Fists did nothing. Each group retries on its own.
    if PlayerMods.hooksBound and (PlayerMods.meleeHooks or 0) > 0 then return end
    -- no point trying before the pawn - and therefore its class - exists
    if not PlayerMods.GetPawn() then return end

    if not PlayerMods.hooksBound then
        PlayerMods.RegisterDamageHooks()
        PlayerMods.RegisterAmmoHooks()

        if PlayerMods.damageHooks > 0 then
            PlayerMods.hooksBound = true
            print("[ModMenu] hooks bound (" .. PlayerMods.damageHooks ..
                  " damage hooks) - God Mode is live\n")
        end
    end

    if (PlayerMods.meleeHooks or 0) == 0 then
        PlayerMods.RegisterMeleeHooks()
        if (PlayerMods.meleeHooks or 0) > 0 then
            print("[ModMenu] melee hooks bound (" .. PlayerMods.meleeHooks ..
                  ") - Melee Weapon DMG is live\n")
        end
    end

    if (PlayerMods.inputHooks or 0) == 0 then
        PlayerMods.RegisterInputHooks()
    end

    if (PlayerMods.fistHooks or 0) == 0 then
        PlayerMods.RegisterFistHooks()
        if (PlayerMods.fistHooks or 0) > 0 then
            print("[ModMenu] fist hooks bound (" .. PlayerMods.fistHooks ..
                  ") - Strength Fists is live\n")
        end
    end
end

---------------------------------------------------------------------------
-- fire hooks
---------------------------------------------------------------------------

function PlayerMods.RegisterAmmoHooks()
    if not RegisterHook then return end

    local function hook(target, fn, postFn)
        if hookedTargets[target] then return end
        local function run(handler)
            return function(self)
                local s = PlayerMods.state
                if not (s.InfiniteAmmo or s.NoRecoil or s.FullAuto) then return end
                -- these run on the GAME thread, once per shot per hooked
                -- function, so the count matters for frame time
                PlayerMods.gunHookCalls = (PlayerMods.gunHookCalls or 0) + 1
                local ok, obj = pcall(function() return self:get() end)
                handler(ok and obj or self)
            end
        end
        local ok = pcall(function()
            -- Second callback is the POST hook. Cycle state has to be restored
            -- after the shot has been processed; doing it in the pre-hook only
            -- means the gun un-chambers itself immediately afterwards.
            if postFn then
                RegisterHook(target, run(fn), run(postFn))
            else
                RegisterHook(target, run(fn))
            end
        end)
        if ok then hookedTargets[target] = true end
    end

    -- POST-fire work: both of these have to happen after the shot, not before.
    local function afterShot(gun)
        if PlayerMods.state.NoRecoil then ZeroRecoil(gun) end
        if PlayerMods.state.FullAuto then
            RechamberSkeletalGun(gun)
            PlayerMods.rechambers = (PlayerMods.rechambers or 0) + 1
        end
    end

    for _, fn in ipairs({ "FireGun", "Firebulletauto", "FireBulletsingle", "FIREEVENT" }) do
        for _, t in ipairs(targets(PlayerMods.PATHS.SkelGun, GUN_SKEL, fn)) do
            hook(t, RefillSkeletalGun, afterShot)
        end
    end

    -- NO-RECOIL, PROPERLY: zero the vectors immediately BEFORE RecoilEvent runs.
    --
    -- `RecoilEvent()` is the function that actually applies the kick, and it
    -- reads those vectors when it runs. Zeroing them on the fire hook was too
    -- early (something repopulates them between firing and the recoil), and
    -- zeroing them afterwards was too late (the kick had already been applied).
    -- Hooking RecoilEvent itself puts the zeroing in the only moment that works.
    for _, fn in ipairs({ "RecoilEvent", "ManualRecoil" }) do
        for _, t in ipairs(targets(PlayerMods.PATHS.SkelGun, GUN_SKEL, fn)) do
            if not hookedTargets[t] then
                local ok = pcall(function()
                    RegisterHook(t, function(self, arg1)
                        local okS, gun = pcall(function() return self:get() end)
                        gun = okS and gun or self

                        -- THE KICK IS IN THE ARGUMENT, NOT THE FIELDS.
                        --
                        -- Live data proved the stored recoil vectors are already
                        -- 0/0/0 at the moment recoil is applied, yet the gun still
                        -- kicks - so those fields are not the source and zeroing
                        -- them can never work. `ManualRecoil(FTransform Recoiladd)`
                        -- takes the kick as a PARAMETER the caller computed, so
                        -- that is what has to be neutralised.
                        if arg1 ~= nil then
                            local okG, t0 = pcall(function() return arg1:get() end)
                            if okG and t0 then
                                -- record it once so we can see the real numbers
                                if not PlayerMods.recoilArgSeen then
                                    local tr = t0.Translation or t0.translation
                                    local rt = t0.Rotation or t0.rotation
                                    PlayerMods.recoilArgSeen = string.format(
                                        "T=%s R=%s",
                                        tr and string.format("%.1f/%.1f/%.1f",
                                            tr.X or 0, tr.Y or 0, tr.Z or 0) or "?",
                                        rt and string.format("%.2f/%.2f/%.2f/%.2f",
                                            rt.X or 0, rt.Y or 0, rt.Z or 0,
                                            rt.W or 0) or "?")
                                end
                                -- flatten it: no translation, identity rotation
                                if PlayerMods.state.NoRecoil then
                                    pcall(function()
                                        local tr = t0.Translation or t0.translation
                                        if tr then tr.X, tr.Y, tr.Z = 0.0, 0.0, 0.0 end
                                        local rt = t0.Rotation or t0.rotation
                                        if rt then
                                            rt.X, rt.Y, rt.Z, rt.W = 0.0, 0.0, 0.0, 1.0
                                        end
                                        arg1:set(t0)
                                    end)
                                    PlayerMods.recoilArgKilled =
                                        (PlayerMods.recoilArgKilled or 0) + 1
                                end
                            end
                        end

                        -- RECORD WHAT THE RECOIL ACTUALLY IS WHEN IT FIRES.
                        --
                        -- Three different guesses about WHEN to zero these have
                        -- now failed, so stop guessing: capture the values at the
                        -- exact moment the game applies recoil and publish them.
                        -- If they read 0 here and you still get kicked, the kick
                        -- is not coming from these fields at all and the whole
                        -- approach is wrong.
                        local function vz(name)
                            local v = get(gun, GUN_SKEL, name)
                            if v and type(v.X) == "number" then
                                return string.format("%.0f/%.0f/%.0f", v.X, v.Y, v.Z)
                            end
                            return "?"
                        end
                        PlayerMods.recoilSeen = string.format(
                            "stblzR=%s stblzT=%s 1hR=%s 1hT=%s",
                            vz("recoilrotationstblz"), vz("recoiltranslationstblz"),
                            vz("recoilrotation1hnd"), vz("recoiltranslation1hnd"))
                        PlayerMods.recoilEvents = (PlayerMods.recoilEvents or 0) + 1

                        if not PlayerMods.state.NoRecoil then return end
                        ZeroRecoil(gun)
                        -- and the int32 lerp/decay indices, which the vectors
                        -- alone may not cover
                        set(gun, GUN_SKEL, "RecoilLERPStblz", 0)
                        set(gun, GUN_SKEL, "RecoilDECAYStblz", 0)
                        set(gun, GUN_SKEL, "RecoilLERP1hnd", 0)
                        set(gun, GUN_SKEL, "RecoilDECAY1hnd", 0)
                    end)
                end)
                if ok then hookedTargets[t] = true end
            end
        end
    end
    for _, fn in ipairs({ "HandleFiring", "BeginFire" }) do
        for _, t in ipairs(targets(PlayerMods.PATHS.PhysGun, GUN_PHYS, fn)) do
            hook(t, RefillPhysicalGun)
        end
    end
end

---------------------------------------------------------------------------
-- Strength Fists
---------------------------------------------------------------------------
-- The enemy's own punch handler is `PunchDamage(FHitResult, float Velocity)` -
-- damage scales with how fast your fist was moving. So instead of guessing at
-- fist physics, hook that and scale the velocity the enemy is told about. Same
-- technique as God Mode, just in the opposite direction.
--
-- ALS enemies also expose ApplyMeleeDamage(float), which is the flat-damage
-- path; both are covered.

-- WHY THE FIRST VERSION DID NOTHING: it only scaled the `Velocity` argument and
-- hoped the blueprint turned that into proportional damage. It does not - the
-- graph maps velocity through its own curve/thresholds, so a 10x velocity is not
-- 10x damage, and past the top of the curve it changes nothing at all.
--
-- Instead, land real damage through the enemy's OWN health funnel, which is what
-- a melee weapon hit does:
--   ALS_Player_CharacterBPai_C : RemoveHPAndScream(float Damage), health `hp`
--   BP_NPC_Man_C               : health `HealthOverall`
-- The velocity boost is kept as well, purely so the game's own hit reaction and
-- ragdoll impulse still look like a heavy strike.
--
-- Punches arrive on three entry points, not one: a closed fist is PunchDamage,
-- an open hand is OpenHandDamageR/L. Only hooking PunchDamage missed most hits.

-- EVERY melee entry point on an enemy, not just the fists. Hooking only the
-- punch functions meant knives, pipes, hammers and bats were untouched:
--   PunchDamage / OpenHandDamageR / OpenHandDamageL - bare hands
--   BludgeonDamage                                  - blunt (pipe, hammer, bat)
--   StabbingDamage                                  - knife thrust
--   SlashDamage                                     - knife slash
--   HeadSlamDamage                                  - slamming a head into things
--   ApplyMeleeDamage                                - the flat-damage path
-- MEASURED THE HARD WAY: hooking all eight makes SPAWNING an enemy fatal. With
-- these three the same spawn-3-enemies test passed many times; with eight the
-- game died on the spawn every time, no dump, status frozen mid-tick. The extra
-- five must be reachable while the actor is still being constructed. Do not add
-- them back without testing a spawn specifically - binding cleanly and running
-- fine for a minute proves nothing here.
local MELEE_FNS = { "PunchDamage", "OpenHandDamageR", "OpenHandDamageL" }

-- Weapon paths that are NOT hooked for that reason: BludgeonDamage,
-- StabbingDamage, SlashDamage, HeadSlamDamage, ApplyMeleeDamage.
local MELEE_FNS_UNSAFE = { "BludgeonDamage", "StabbingDamage", "SlashDamage",
                           "HeadSlamDamage", "ApplyMeleeDamage" }

local MELEE_TARGETS = {
    { "ALS_Player_CharacterBPai_C",
      "/Game/characters/IK/blueprints/ALS_Player_CharacterBPai.ALS_Player_CharacterBPai_C",
      MELEE_FNS },
    { "BP_NPC_Man_C",
      "/Game/characters/Human/Blueprints/CharacterLogic/BP_NPC_Man.BP_NPC_Man_C",
      MELEE_FNS },
}

-- Strength Fists delivers its hit by CALLING BludgeonDamage, which is now also
-- hooked - so without this the hook would re-enter itself forever.
local inMeleeHook = false

-- Damage asked for by a hook, applied later by the sweep. Never apply it in the
-- hook: see the comment in the hook body.
local damageQueue = {}
onDropCaches(function() damageQueue = {} end)

-- health field per class, used when the class has no damage function to call
local MELEE_HP = {
    ALS_Player_CharacterBPai_C = "hp",
    BP_NPC_Man_C               = "HealthOverall",
}

PlayerMods.meleeHooks = 0
local meleeRegistered = {}

-- Apply the fist's damage to one enemy. Returns true if damage was delivered.
local function applyMeleeDamage(enemy, cls)
    if not isValid(enemy) then return false end
    local dmg = PlayerMods.state.MeleeDamage or 100.0

    local field = MELEE_HP[cls]
    local before = field and get(enemy, cls, field) or nil

    -- 1. the enemy's own damage routine - screams, gore and death all handled
    callWith(enemy, cls, "RemoveHPAndScream", dmg)

    -- 2. It reports success even when it quietly does nothing, so check. If the
    --    health did not move, take it down directly.
    if field and type(before) == "number" then
        local after = get(enemy, cls, field)
        if type(after) == "number" and after < before then return true end
        set(enemy, cls, field, math.floor(before - dmg))
        local forced = get(enemy, cls, field)
        return type(forced) == "number" and forced < before
    end
    return false
end

---------------------------------------------------------------------------
-- Strength Fists (the real one)
---------------------------------------------------------------------------
-- MeleeWeaponDamage above boosts what a WEAPON does to an enemy. It does not
-- make a bare fist hit like a pipe, because a punch is a different code path.
--
-- The player's hand is `GraspingHand_C` / `GraspingHand_Left_C`, and it carries
-- its own strike modifiers:
--     int32 StrikePower      - the hand's weight class, recomputed by
--                              EvaluateStrikePower() on every swing
--     float LastHitSpeed     - how fast the hand was moving
-- A blunt weapon hits through `BludgeonDamage(HitResult, Velocity, Direction,
-- WeightClass, BaseDamage)` on the enemy - and WeightClass is exactly the kind
-- of value StrikePower holds. So giving the fist a weapon's weight and routing
-- punches through the bludgeon path is what "punch like the pipe" means.

-- The hand's punch collision lives on these, per GraspingHand.hpp. Widening
-- only RootPhysics left bare fists whiffing while weapons connected.
local FINGER_CAPSULES = {
    "index_02", "index_03", "middle_02", "middle_03",
    "ring_02", "ring_03", "pinky_02", "pinky_03",
    "thumb_02", "thumb_03",
}

local HAND_CLASSES = {
    { "GraspingHand_C",
      "/Game/VRExpansion/Vive/Testing/GraspingHand/GraspingHand.GraspingHand_C" },
    { "GraspingHand_Left_C",
      "/Game/VRExpansion/Vive/Testing/GraspingHand/GraspingHand_Left.GraspingHand_Left_C" },
}

PlayerMods.fistHooks = 0
PlayerMods.fistHits = 0
local fistRegistered = {}

-- Give one hand the strike power of a heavy blunt weapon.
local handReachApplied = {}
onDropCaches(function() handReachApplied = {} end)

-- defined below, next to the grab logic; declared here so powerUpHand can
-- reference it (Lua locals are not visible before their declaration)
local handleGrab

local function powerUpHand(hand, cls)
    if not isValid(hand) then return false end
    local s = PlayerMods.state

    -- Stop the hand brushing the headlamp / night-vision volumes on your chest
    -- and toggling them by accident. The game fires those off an OVERLAP AGE
    -- that builds while the hand is inside the volume, so holding the age at
    -- zero means it never reaches the trigger point. Reaching up to use them
    -- deliberately still works - that is a different, longer press.
    if s.NoAccidentalLamp then
        set(hand, cls, "LampOverlapAge", 0.0)
        set(hand, cls, "NvgOverlapAge", 0.0)
    end

    if not s.StrengthFists then return true end

    local p = math.floor(s.FistStrikePower or 10)
    set(hand, cls, "StrikePower", p)

    -- Always-connect punches: the hand's own collision sphere is what has to
    -- touch the target, so widen it. Once per component, same as the weapons.
    if s.MeleeAlwaysHits then
        -- A punch does not land off the palm sphere - it lands off the FINGER
        -- capsules, which is why widening RootPhysics alone made weapons
        -- connect while bare fists still whiffed. Widen the knuckles too.
        local want = math.floor(s.MeleeReach or 60)

        local comp = get(hand, cls, "RootPhysics")
        if isValid(comp) then
            local okA, addr = pcall(function() return comp:GetAddress() end)
            if okA and handReachApplied[addr] ~= want then
                handReachApplied[addr] = want
    -- COLLISION CHANGES BELONG ON THE GAME THREAD.
    --
    -- The trailing `true` is bUpdateOverlaps: this does not just resize a shape,
    -- it re-runs overlap resolution against the physics scene. Doing that from
    -- the LoopAsync thread races the engine, and it bites hardest exactly when
    -- a round starts and dozens of actors are spawning and overlapping at once.
                ExecuteInGameThread(function()
                    if not isValid(comp) then return end
                    pcall(function() comp:SetSphereRadius(want, true) end)
                end)
                PlayerMods.reachSet = (PlayerMods.reachSet or 0) + 1
            end
        end

        -- knuckle and finger capsules: these are what actually touch a body
        for _, name in ipairs(FINGER_CAPSULES) do
            local c = get(hand, cls, name)
            if isValid(c) then
                local okA, addr = pcall(function() return c:GetAddress() end)
                if okA and handReachApplied[addr] ~= want then
                    handReachApplied[addr] = want
                    -- radius, half-height, update overlaps - game thread, as above
                    ExecuteInGameThread(function()
                        if not isValid(c) then return end
                        pcall(function()
                            c:SetCapsuleSize(want * 0.5, want * 0.5, true)
                        end)
                    end)
                    PlayerMods.reachSet = (PlayerMods.reachSet or 0) + 1
                end
            end
        end
    end
    -- the hand also reports how fast it was moving; a weapon swing reads high
    local spd = get(hand, cls, "LastHitSpeed")
    if type(spd) == "number" and spd > 0 then
        local mult = PlayerMods.state.MeleeKnockback or 10.0
        set(hand, cls, "LastHitSpeed", spd * mult)
    end
    return true
end

-- Keep both hands powered up. Cheap: two cached objects, no object-array walk.
local handCache, handPass = nil, 0
onDropCaches(function() handCache, handPass = nil, 0 end)
---------------------------------------------------------------------------
-- Grab an enemy and throw them (Hard Bullet / Blade & Sorcery)
---------------------------------------------------------------------------
-- Everything here is a property write plus RagdollStart, which is the only
-- combination proven survivable in this game. Specifically NOT used: any
-- transform call, and AddImpulse - both have been fatal.
--
-- A limp body is already driven by the game's own ragdoll update towards
-- `TargetRagdollLocation`, so writing that each tick drags them along with the
-- hand. Releasing writes `LastRagdollVelocity`, which is exactly how the punch
-- launch works.
-- defined with RagdollTick further down; declared here so the grab release can
-- use the same fling the punch does
local flingEnemy

local grabbed = {}          -- [handAddress] = { enemy, cls }
local lastHandPos = {}      -- [handAddress] = { X, Y, Z } from the previous tick
onDropCaches(function() grabbed, lastHandPos = {}, {} end)

local function actorPos(a)
    local ok, p = pcall(function() return a:K2_GetActorLocation() end)
    if ok and p and type(p.X) == "number" then return p end
    return nil
end

-- Who can actually be picked up and thrown. Dragging a limp body needs
-- TargetRagdollLocation and throwing needs LastRagdollVelocity; BP_NPC_Man_C
-- has RagdollStart but NEITHER of those, so grabbing one would just flop it on
-- the floor and never follow your hand. Better to not grab them at all than to
-- half-work.
local GRAB_OK = { ALS_Player_CharacterBPai_C = true }

-- Nearest live enemy to a point, within range. Uses the ESP's own tracked list
-- rather than sweeping the object array.
local function enemyNear(pos, range, fresh)
    local best, bestCls, bestD = nil, nil, range * range
    forEachSettledEnemy(function(e, c)
        if not GRAB_OK[c] then return end
        local p = actorPos(e)
        if not p then return end
        local dx, dy, dz = p.X - pos.X, p.Y - pos.Y, p.Z - pos.Z
        local d = (dx * dx) + (dy * dy) + (dz * dz)
        if d < bestD then best, bestCls, bestD = e, c, d end
    end, fresh)
    return best, bestCls
end

-- Is this body already in someone else's hand? Two hands on one body is the
-- point - "grab with both hands" - so a second hand joining is allowed, and
-- the throw that follows is stronger for it.
local function handsOn(enemy)
    local n = 0
    for _, h in pairs(grabbed) do
        if h.enemy == enemy then n = n + 1 end
    end
    return n
end

handleGrab = function(hand, cls)
    local okA, addr = pcall(function() return hand:GetAddress() end)
    if not okA then return end

    local held = grabbed[addr]
    local gripping = get(hand, cls, "GripHeld") == true
    local pos = actorPos(hand)

    -- released: throw whatever was in this hand
    if held and not gripping then
        grabbed[addr] = nil
        local obj = liveEnemy(held.eaddr)
        if obj then
            held.enemy = obj
            local force = PlayerMods.state.ThrowForce or 1800.0
            -- Two-handed throw hits harder. Count the hands that were on this
            -- body INCLUDING the one just released, so letting go of both at
            -- once still reads as a two-handed throw.
            local hands = handsOn(held.enemy) + 1
            if hands > 1 then force = force * 1.8 end

            local vx, vy, vz = 1.0, 0.0, 0.4
            -- throw along the way the hand was actually moving, so a real
            -- swing throws them where you swung
            local prev = lastHandPos[addr]
            if prev and pos then
                local dx, dy, dz = pos.X - prev.X, pos.Y - prev.Y, pos.Z - prev.Z
                local len = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
                if len > 1.0 then
                    vx, vy, vz = dx / len, dy / len, (dz / len) + 0.3
                end
            end
            setVector(held.enemy, held.cls, "LastRagdollVelocity",
                      vx * force, vy * force, vz * force)
            -- and drive them at a point out that way, which is what actually
            -- carries a body across the room
            flingEnemy(held.enemy, held.cls, vx, vy, force)
            PlayerMods.throws = (PlayerMods.throws or 0) + 1
            PlayerMods.lastThrowHands = hands
        end
    end

    if pos then lastHandPos[addr] = pos end
    if not gripping or not pos then return end

    -- grabbing: pick someone up
    if not held then
        local range = PlayerMods.state.GrabRange or 90
        local e, ecls = nil, nil

        -- FIRST look at what the OTHER hand is already holding. This is what
        -- makes two hands on one body work: once a body is grabbed it is often
        -- flagged dead/ragdolling and drops out of the enemy sweep entirely, so
        -- enemyNear() can no longer find it and the second hand had nothing to
        -- grab. Joining an existing grip does not need the sweep at all.
        local joinRange = range * 2.0
        for _, h in pairs(grabbed) do
            -- resolve through the sweep: reading a position off a stored
            -- reference is the same recycled-pointer hazard as the fling
            local other = e == nil and liveEnemy(h.eaddr) or nil
            if other then
                local hp = actorPos(other)
                if hp then
                    local dx, dy, dz = hp.X - pos.X, hp.Y - pos.Y, hp.Z - pos.Z
                    if ((dx * dx) + (dy * dy) + (dz * dz)) <= (joinRange * joinRange) then
                        e, ecls = other, h.cls
                    end
                end
            end
        end

        -- otherwise find a fresh body nearby
        if e == nil then e, ecls = enemyNear(pos, range) end

        if e then
            -- only ragdoll if nobody is holding them yet; a second hand just
            -- joins the grip rather than restarting the ragdoll underneath it
            if handsOn(e) == 0 then
                call(e, ecls, "RagdollStart")
                set(e, ecls, "bKnocked", true)
            end
            grabbed[addr] = { enemy = e, cls = ecls, eaddr = markLive(e) }
            PlayerMods.grabs = (PlayerMods.grabs or 0) + 1
        end
        return
    end

    -- holding: drag the limp body to the hand. With two hands on one body,
    -- drag it to the midpoint between them so it hangs between your hands
    -- instead of the two hands fighting over it.
    local heldObj = liveEnemy(held.eaddr)
    if heldObj then
        held.enemy = heldObj
        local tx, ty, tz, n = 0.0, 0.0, 0.0, 0
        for a, h in pairs(grabbed) do
            if h.enemy == held.enemy then
                local hp = lastHandPos[a]
                if hp then
                    tx, ty, tz, n = tx + hp.X, ty + hp.Y, tz + hp.Z, n + 1
                end
            end
        end
        if n > 0 then
            setVector(held.enemy, held.cls, "TargetRagdollLocation",
                      tx / n, ty / n, tz / n)
        else
            setVector(held.enemy, held.cls, "TargetRagdollLocation",
                      pos.X, pos.Y, pos.Z)
        end
    else
        grabbed[addr] = nil
    end
end

-- Prove grab-and-throw works without a headset, by driving the same code path
-- a real grip drives. Reports what actually changed on the body, not just that
-- the call ran.
function PlayerMods.StartGrabTest()
    PlayerMods.grabTest = "running..."
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            local okIn, errIn = pcall(function()
                local hand, hcls = nil, nil
                for _, entry in ipairs(handCache or {}) do
                    if isValid(entry[1]) then hand, hcls = entry[1], entry[2] break end
                end
                if not hand then
                    PlayerMods.grabTest = "no hand found yet - wait a moment"
                    return
                end
                local pos = actorPos(hand)
                if not pos then
                    PlayerMods.grabTest = "hand has no position"
                    return
                end

                -- fresh sweep: this runs deferred, so the memo cannot be trusted
                local e, ecls = enemyNear(pos, 100000, true)
                if not e then
                    PlayerMods.grabTest = "no grabbable enemy - spawn an ALS one"
                    return
                end

                -- GRAB: ragdoll and drag to the hand
                call(e, ecls, "RagdollStart")
                set(e, ecls, "bKnocked", true)
                -- setVector verifies its own write by reading the value back,
                -- so trust its result. Do NOT re-check with type(v)=="table":
                -- UE4SS hands back a userdata struct, not a table, and that
                -- wrong check reported FAIL on writes that had actually worked.
                local dragged = setVector(e, ecls, "TargetRagdollLocation",
                                          pos.X, pos.Y, pos.Z)
                local limp = get(e, ecls, "bRagdolling")

                -- THROW: write the velocity, exactly as releasing does
                local f = PlayerMods.state.ThrowForce or 1800.0
                local thrown = setVector(e, ecls, "LastRagdollVelocity",
                                         f, 0.0, f * 0.4)

                -- TWO-HANDED: put both hands on this one body and check the
                -- carry point is the midpoint between them, and that letting go
                -- throws harder than one hand would.
                local twoHanded = "no 2nd hand"
                local h2, h2cls = nil, nil
                for _, entry in ipairs(handCache or {}) do
                    if isValid(entry[1]) and entry[1] ~= hand then
                        h2, h2cls = entry[1], entry[2] break
                    end
                end
                if h2 then
                    local a1 = select(2, pcall(function() return hand:GetAddress() end))
                    local a2 = select(2, pcall(function() return h2:GetAddress() end))
                    local p2 = actorPos(h2)
                    if a1 and a2 and p2 then
                        -- eaddr matters: every read goes through liveEnemy(eaddr)
                        local ea = markLive(e)
                        grabbed[a1] = { enemy = e, cls = ecls, eaddr = ea }
                        grabbed[a2] = { enemy = e, cls = ecls, eaddr = ea }
                        lastHandPos[a1], lastHandPos[a2] = pos, p2
                        local n = 0
                        for _, h in pairs(grabbed) do
                            if h.enemy == e then n = n + 1 end
                        end
                        -- carry point should be halfway between the two hands.
                        -- GripHeld must be TRUE or handleGrab takes the release
                        -- path instead of the hold path - which is what made
                        -- this read midpoint=false on the first attempt.
                        local wasGrip = get(hand, hcls, "GripHeld")
                        set(hand, hcls, "GripHeld", true)
                        handleGrab(hand, hcls)
                        set(hand, hcls, "GripHeld", wasGrip == true)
                        local mid = get(e, ecls, "TargetRagdollLocation")
                        local wantX = (pos.X + p2.X) / 2
                        local midOK = mid and type(mid.X) == "number"
                                      and math.abs(mid.X - wantX) < 2.0
                        twoHanded = string.format("hands=%d midpoint=%s", n,
                                                  tostring(midOK))
                        grabbed[a1], grabbed[a2] = nil, nil
                    end
                end

                PlayerMods.grabTest = string.format(
                    "%s limp=%s dragged=%s thrown=%s force=%d | 2H: %s",
                    (dragged and thrown) and "PASS" or "FAIL",
                    tostring(limp), tostring(dragged), tostring(thrown),
                    math.floor(f), twoHanded)
            end)
            if not okIn then
                PlayerMods.grabTest = "threw: " .. tostring(errIn)
            end
        end)
    end)
    if not ok then PlayerMods.grabTest = "error: " .. tostring(err) end
end

-- Readable proof the lamp/NVG lock is holding: these ages are what the game
-- counts up to decide you meant to press the thing. Pinned at 0 = it can never
-- reach the trigger, so a passing hand cannot flip your headlamp mid-fight.
-- Prove the lamp/NVG lock actually pins the age down, without a headset.
-- Comparing the ages with the lock on vs off proves nothing on the desktop:
-- the hand never touches the volume, so both read 0.0 either way. Instead push
-- the age UP the way an overlap would, then see whether the lock clears it.
function PlayerMods.StartLampTest()
    PlayerMods.lampTest = "running..."
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            local okIn, errIn = pcall(function()
                local hand, cls = nil, nil
                for _, e in ipairs(handCache or {}) do
                    if isValid(e[1]) then hand, cls = e[1], e[2] break end
                end
                if not hand then
                    PlayerMods.lampTest = "no hand yet - wait a moment"
                    return
                end
                -- simulate a hand sitting in the lamp volume
                set(hand, cls, "LampOverlapAge", 99.0)
                set(hand, cls, "NvgOverlapAge", 99.0)
                local before = get(hand, cls, "LampOverlapAge")

                -- one sweep is what the lock gets to react
                powerUpHand(hand, cls)
                local after = get(hand, cls, "LampOverlapAge")
                local afterN = get(hand, cls, "NvgOverlapAge")

                local locked = PlayerMods.state.NoAccidentalLamp == true
                local cleared = (after == 0.0 and afterN == 0.0)
                local verdict
                if locked and cleared then verdict = "PASS lock clears it"
                elseif locked then verdict = "FAIL lock did not clear it"
                elseif not cleared then verdict = "PASS unlocked leaves it alone"
                else verdict = "FAIL cleared while unlocked" end

                PlayerMods.lampTest = string.format("%s  %s -> %s (locked=%s)",
                    verdict, tostring(before), tostring(after), tostring(locked))
            end)
            if not okIn then PlayerMods.lampTest = "threw: " .. tostring(errIn) end
        end)
    end)
    if not ok then PlayerMods.lampTest = "error: " .. tostring(err) end
end

function PlayerMods.LampState()
    for _, entry in ipairs(handCache or {}) do
        local hand, cls = entry[1], entry[2]
        if isValid(hand) then
            local l = get(hand, cls, "LampOverlapAge")
            local n = get(hand, cls, "NvgOverlapAge")
            if type(l) == "number" or type(n) == "number" then
                return string.format("lamp=%s nvg=%s locked=%s",
                    tostring(l), tostring(n),
                    tostring(PlayerMods.state.NoAccidentalLamp == true))
            end
        end
    end
    return "no hand"
end

PlayerMods.HeldCount = function()
    local n = 0
    for _ in pairs(grabbed) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Flight, NoClip and Crouch
---------------------------------------------------------------------------
-- All of this is pawn-only work: property writes and two ACharacter calls on
-- the ONE cached pawn. No object-array sweeps, no enemy structs - so it rides
-- the ungated fast tick like God Mode does, and none of the round-end hazards
-- apply.
--
-- Direction comes from the HMD: you fly where you are looking. Looking level
-- (within a deadzone) hovers, so tilting your head is the throttle and
-- straightening up is the brake - otherwise there is no way to stop.
local MOVE_FLYING, MOVE_WALKING = 5, 1
local flyWasOn, clipWasOff, crouchWasOn = false, false, false
local crouchOrigHeight = nil
local crouchOrigOffset = nil
local crouchOrigSquat = nil
onDropCaches(function()
    flyWasOn, clipWasOff, crouchWasOn = false, false, false
    crouchOrigHeight = nil
    crouchOrigOffset = nil
    crouchOrigSquat = nil
end)

-- Where the headset is pointing.
local function lookDir(pawn, kind)
    local cam = get(pawn, kind, "VRReplicatedCamera")
    if isValid(cam) then
        local ok, v = pcall(function() return cam:GetForwardVector() end)
        if ok and v and type(v.X) == "number" then
            PlayerMods.lookSrc = "camera"
            return v
        end
    end
    -- No camera: the BODY forward is always level, so Z is ~0 and you can never
    -- leave the hover deadzone however hard you look up or down. Say so rather
    -- than silently pretending to steer.
    local ok2, f = pcall(function() return pawn:GetActorForwardVector() end)
    if ok2 and f and type(f.X) == "number" then
        PlayerMods.lookSrc = "BODY (no camera - pitch always flat)"
        return f
    end
    PlayerMods.lookSrc = "none"
    return nil
end

-- VR STICK INPUT.
--
-- Flying "wherever you look, always" moves you with no way to stop, which is
-- not control - it is drift. The pawn exposes its own input events, so hook
-- them and only fly while you are actually pushing the stick:
--   InpAxisEvt_ControllerMovementLeft_...  - left stick, the movement axis
--   InpActEvt_ThumbPressRight_...          - right stick CLICK, for crouch
--
-- These callbacks only touch numbers and booleans. Nothing calls back into the
-- engine from inside them - that is the rule that stopped the crashes.
local stickAxis, stickStamp = 0.0, -999
-- press/release alternation for the right-stick click
local stickEverSeen = false
local stickEverPushed = false
local stickPushTick   = -999   -- last tick the axis showed a REAL push
local stickPadMag   = 0.0
local stickPadStamp = -99
local stickClickDown = false
local buttonADown = false
local buttonXDown = false
local triggerLDown = false
local triggerRDown = false
local INPUT_TARGETS = {
    -- LEFT stick only. Listening to the right axis too meant holding the right
    -- stick steered the flight, tangling it up with the crouch click - the
    -- right stick belongs to crouch and nothing else.
    axis = { "InpAxisEvt_ControllerMovementLeft_K2Node_InputAxisEvent_283" },
    thumbR = { "InpActEvt_ThumbPressRight_K2Node_InputActionEvent_17",
               "InpActEvt_ThumbPressRight_K2Node_InputActionEvent_16" },
    -- Face buttons. A and X fire a PAIR (press + release) so they need the
    -- alternation trick; Y and B fire only ONE event each, so they are a
    -- straight press and must NOT be alternated or they would need two clicks.
    buttonA = { "InpActEvt_FaceButtonRightLower_A_K2Node_InputActionEvent_21",
                "InpActEvt_FaceButtonRightLower_A_K2Node_InputActionEvent_20" },
    buttonX = { "InpActEvt_FaceButtonLeftLower_A_K2Node_InputActionEvent_19",
                "InpActEvt_FaceButtonLeftLower_A_K2Node_InputActionEvent_18" },
    buttonY = { "InpActEvt_FaceButtonLeftUpper_Y_K2Node_InputActionEvent_13" },
    buttonB = { "InpActEvt_FaceButtonRightUpper_B_K2Node_InputActionEvent_12" },
    triggerL = { "InpActEvt_TriggerLeft_K2Node_InputActionEvent_7",
                 "InpActEvt_TriggerLeft_K2Node_InputActionEvent_6" },
    triggerR = { "InpActEvt_TriggerRight_K2Node_InputActionEvent_5",
                 "InpActEvt_TriggerRight_K2Node_InputActionEvent_4" },
}
PlayerMods.inputHooks = 0
local inputRegistered = {}

function PlayerMods.RegisterInputHooks()
    if not RegisterHook then return end
    local path = PlayerMods.PATHS and PlayerMods.PATHS.Wendigo
    if not path then return end

    local function hook(fn, cb, post)
        for _, target in ipairs({ path .. ":" .. fn, "WendigoVrChar_C:" .. fn }) do
            if not inputRegistered[target] then
                local ok, pre = pcall(function()
                    if post then return RegisterHook(target, cb, post) end
                    return RegisterHook(target, cb)
                end)
                if ok and type(pre) == "number" and pre > 0 then
                    inputRegistered[target] = true
                    PlayerMods.inputHooks = PlayerMods.inputHooks + 1
                end
            end
        end
    end

    -- THE REAL STICK SOURCE.
    --
    -- The two InpAxisEvt hooks bind and fire, but always report 0.00 on this
    -- controller, which is why the gate had to be dropped and why flight then
    -- ran nonstop. CalcPadRotationAndMagnitude is the game's OWN thumbpad
    -- maths - it receives the raw X/Y and returns the deadzoned magnitude, so
    -- it reports real numbers whatever the axis events do. Read it, do not
    -- change it: this is a pre-hook that only samples the arguments.
    for _, fn in ipairs({ "CalcPadRotationAndMagnitude" }) do
        hook(fn, function(_self, yAxis, xAxis)
            local okY, y = pcall(function() return yAxis:get() end)
            local okX, x = pcall(function() return xAxis:get() end)
            if not (okY and okX) then return end
            if type(y) ~= "number" or type(x) ~= "number" then return end
            local mag = math.sqrt((x * x) + (y * y))
            stickEverSeen = true
            stickPadMag   = mag
            stickPadStamp = PlayerMods.tickStamp or 0
            if mag > (PlayerMods.state.FlyStickDeadzone or 0.15) then
                stickEverPushed = true
                stickPushTick   = PlayerMods.tickStamp or 0
            end
        end)
    end

    for _, fn in ipairs(INPUT_TARGETS.axis) do
        hook(fn, function(_self, axis)
            local okA, v = pcall(function() return axis:get() end)
            if okA and type(v) == "number" then
                stickEverSeen = true
                if math.abs(v) > (PlayerMods.state.FlyStickDeadzone or 0.15) then
                    stickEverPushed = true
                    stickPushTick   = PlayerMods.tickStamp or 0
                end
                if math.abs(v) > math.abs(stickAxis) or
                   (PlayerMods.tickStamp or 0) ~= stickStamp then
                    stickAxis = v
                end
                stickStamp = PlayerMods.tickStamp or 0
            end
        end)
    end

    -- The game re-measures your height in these; re-apply the crouch after
    -- each one so it cannot stand us back up.
    for _, fn in ipairs({ "VRCapsuleHeightCheck", "AutoCalibrateHeight",
                          "SquatCheck", "InitiateHeightcheck" }) do
        hook(fn, function() end, function() PlayerMods.ApplyCrouchNow() end)
    end

    -- Y: fly on/off. Single event, so every press counts.
    for _, fn in ipairs(INPUT_TARGETS.buttonY) do
        hook(fn, function()
            local now = PlayerMods.tickStamp or 0
            if (now - (PlayerMods.lastYPress or -99)) < 3 then return end
            PlayerMods.lastYPress = now
            PlayerMods.state.FlyMode = not PlayerMods.state.FlyMode
            PlayerMods.flyToggles = (PlayerMods.flyToggles or 0) + 1
        end)
    end

    -- X: noclip on/off. Paired event, so act on every other one.
    for _, fn in ipairs(INPUT_TARGETS.buttonX) do
        hook(fn, function()
            buttonXDown = not buttonXDown
            if not buttonXDown then return end
            PlayerMods.state.NoClip = not PlayerMods.state.NoClip
            PlayerMods.clipToggles = (PlayerMods.clipToggles or 0) + 1
        end)
    end

    -- Trigger: click whatever the pointer is over, but ONLY while the menu is
    -- open, so it stays a normal trigger the rest of the time. Paired event.
    for _, fn in ipairs(INPUT_TARGETS.triggerL) do
        hook(fn, function()
            triggerLDown = not triggerLDown
            if not triggerLDown then return end
            if PlayerMods.PointerClick then PlayerMods.PointerClick(true) end
        end)
    end
    for _, fn in ipairs(INPUT_TARGETS.triggerR) do
        hook(fn, function()
            triggerRDown = not triggerRDown
            if not triggerRDown then return end
            if PlayerMods.PointerClick then PlayerMods.PointerClick(false) end
        end)
    end

    -- B: open / close the headset menu.
    for _, fn in ipairs(INPUT_TARGETS.buttonB) do
        hook(fn, function()
            local now = PlayerMods.tickStamp or 0
            if (now - (PlayerMods.lastBPress or -99)) < 3 then return end
            PlayerMods.lastBPress = now
            if PlayerMods.ToggleMenu then PlayerMods.ToggleMenu() end
            PlayerMods.menuToggles = (PlayerMods.menuToggles or 0) + 1
        end)
    end

    for _, fn in ipairs(INPUT_TARGETS.buttonA) do
        hook(fn, function()
            -- same press/release alternation as the crouch click, so one press
            -- of A is one jump however long you hold it.
            --
            -- The alternation now runs BEFORE the VirtualJump check: it has to
            -- stay in step whether or not jumping is enabled, or the first
            -- press after toggling jump on lands on the release half.
            buttonADown = not buttonADown
            if not buttonADown then return end

            -- With the menu open A calibrates the laser instead of jumping. It
            -- is the one button free in that context, and the aim offset cannot
            -- be read from the game, so it has to be solved by pointing.
            if PlayerMods.MenuIsOpen and PlayerMods.MenuIsOpen() then
                if PlayerMods.PointerCalibrate then PlayerMods.PointerCalibrate() end
                return
            end

            if not PlayerMods.state.VirtualJump then return end
            PlayerMods.DoJump()
        end)
    end

    for _, fn in ipairs(INPUT_TARGETS.thumbR) do
        hook(fn, function()
            -- WHY CROUCH WOULD NOT STAY DOWN.
            --
            -- The action has TWO events bound (_16 and _17) - press and
            -- release. Toggling on both meant one click flipped it twice and
            -- left it exactly where it started, which looks like "it only works
            -- while I hold the stick down".
            --
            -- Which of the two is press is not knowable from the name, so treat
            -- them as strictly alternating and act on every OTHER event. That
            -- gives one toggle per physical click, hold length irrelevant.
            if not PlayerMods.state.CrouchOnStick then return end
            stickClickDown = not stickClickDown
            if not stickClickDown then return end       -- this was the release

            PlayerMods.state.CrouchDown = not PlayerMods.state.CrouchDown
            PlayerMods.crouchToggles = (PlayerMods.crouchToggles or 0) + 1
        end)
    end
end

-- VIRTUAL JUMP.
--
-- Blood Trail has no jump at all, so there is nothing to enable - it has to be
-- created. ACharacter::LaunchCharacter is the right tool: it hands the engine a
-- velocity and lets its own movement and gravity do the rest, rather than us
-- moving the actor (which is the fatal category in this game).
PlayerMods.DoJump = function()
    if not PlayerMods.state.VirtualJump then return end
    local pawn, kind = PlayerMods.GetPawn()
    if not isValid(pawn) then return end

    -- the same Jump Multiplier slider that drives High Jump
    local power = 420.0 * (PlayerMods.state.JumpMultiplier or 2.0)

    local mv = get(pawn, kind, "CharacterMovement")

    -- A jump is two things, and doing only one of them does nothing:
    --   1. leave the ground - while MovementMode is Walking the movement code
    --      zeroes any vertical velocity you write, so put the character into
    --      Falling first. This is what made velZ read 0 -> 0.
    --   2. give it upward velocity.
    -- LaunchCharacter is called too, but on its own it only sets a PENDING
    -- velocity the engine applies on a later tick, so it cannot be verified
    -- immediately and is not enough by itself.
    if isValid(mv) then
        set(mv, nil, "MovementMode", 3)          -- MOVE_Falling
        setVector(mv, nil, "Velocity", 0.0, 0.0, power)
    end
    callWith3(pawn, kind, "LaunchCharacter",
              { X = 0.0, Y = 0.0, Z = power }, false, true)
    PlayerMods.jumps = (PlayerMods.jumps or 0) + 1
end

-- Prove the jump launches, without a headset: read the vertical velocity
-- before and after, so "it ran" and "it moved you" are distinguishable.
function PlayerMods.StartJumpTest()
    PlayerMods.jumpTest = "running..."
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            local okIn, errIn = pcall(function()
                local pawn, kind = PlayerMods.GetPawn()
                if not isValid(pawn) then
                    PlayerMods.jumpTest = "no pawn"
                    return
                end
                local mv = get(pawn, kind, "CharacterMovement")
                local before = 0.0
                if isValid(mv) then
                    local v = get(mv, nil, "Velocity")
                    if v and type(v.Z) == "number" then before = v.Z end
                end

                local wasOn = PlayerMods.state.VirtualJump
                PlayerMods.state.VirtualJump = true
                PlayerMods.DoJump()
                PlayerMods.state.VirtualJump = wasOn

                local after = before
                if isValid(mv) then
                    local v = get(mv, nil, "Velocity")
                    if v and type(v.Z) == "number" then after = v.Z end
                end
                PlayerMods.jumpTest = string.format("%s  velZ %.0f -> %.0f  (x%.1f)",
                    (after > before + 1.0) and "PASS" or "FAIL",
                    before, after, PlayerMods.state.JumpMultiplier or 2.0)
            end)
            if not okIn then PlayerMods.jumpTest = "threw: " .. tostring(errIn) end
        end)
    end)
    if not ok then PlayerMods.jumpTest = "error: " .. tostring(err) end
end

-- Is the player pushing the movement stick right now?
local function stickPushed()
    local now  = PlayerMods.tickStamp or 0
    local dz   = PlayerMods.state.FlyStickDeadzone or 0.15

    -- Preferred source: the game's own pad magnitude. It is only recomputed
    -- while the pad is being touched, so a stale sample means "let go".
    if (now - stickPadStamp) <= 3 then
        return stickPadMag > dz
    end

    -- Fallback: the raw axis events - but ONLY while they are demonstrably
    -- alive.
    --
    -- This used to test a permanent `stickEverPushed` latch, and that is what
    -- made flight collapse to a hover after loading a map. The axis hook fires
    -- every tick, so once a single transient reading tripped the latch, this
    -- branch owned the gate for the rest of the session - and the axis reads
    -- 0.00 even while the stick is pushed, so it answered "not pushed" for
    -- ever. One blip on level load cost you flight until you restarted.
    --
    -- Trusting it only for a few seconds after it last reported a REAL value
    -- keeps it usable as a throttle on a controller where it works, while a
    -- stray reading costs three seconds instead of the whole session.
    if (now - stickPushTick) <= 30 and (now - stickStamp) <= 3 then
        return math.abs(stickAxis) > dz
    end

    -- NOTHING IS REPORTING THE STICK -> FLY WHERE YOU LOOK.
    --
    -- Neither source works on this controller: the InpAxisEvt hooks fire but
    -- always read 0.00, and CalcPadRotationAndMagnitude binds but is never
    -- called (padage climbs for ever). Returning false here meant no thrust at
    -- all, which is what killed look-direction flight.
    --
    -- Hovering was only the safe default while flight had no off switch. Y is
    -- that switch now, so the right behaviour with no readable throttle is to
    -- thrust where you look and let the button stop it. If a stick source ever
    -- does report, the branches above take over and it becomes a real throttle.
    return true
end

---------------------------------------------------------------------------
-- audio
---------------------------------------------------------------------------
-- The pawn carries four volume multipliers (MusicVolume, SoundEffectsVolume,
-- GunfireVolume, VoiceVolume) and a RefreshAllVolumeMulties() that re-applies
-- them to the live audio components. If any of them end up at or near zero the
-- game goes quiet - gunfire, hits and ambience all at once - which is exactly
-- what "no audio at all" looks like. Read them first, then offer the fix.

local VOLUME_KEYS = { "MusicVolume", "SoundEffectsVolume", "GunfireVolume", "VoiceVolume" }

function PlayerMods.AudioReport()
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then return "no pawn" end
    local parts = {}
    for _, k in ipairs(VOLUME_KEYS) do
        local v = get(pawn, kind, k)
        parts[#parts + 1] = string.format("%s=%s", string.sub(k, 1, 5),
                                          (type(v) == "number") and string.format("%.2f", v) or "nil")
    end
    -- Time dilation quietens and detunes everything attached to the actor, so a
    -- stuck CustomTimeDilation looks exactly like a volume problem. Report it
    -- next to the volumes rather than chasing one without the other.
    local td = get(pawn, kind, "CustomTimeDilation")
    parts[#parts + 1] = string.format("dilation=%s",
        (type(td) == "number") and string.format("%.2f", td) or "nil")

    return table.concat(parts, " ")
end

-- Sets all four to MasterVolume and asks the game to re-apply them. Both halves
-- matter: writing the floats alone does nothing until the blueprint pushes them
-- into the audio components.
function PlayerMods.FixAudio()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        local vol = PlayerMods.state.MasterVolume
        if type(vol) ~= "number" or vol < 0 then vol = 1.0 end
        if vol > 1.0 then vol = 1.0 end
        for _, k in ipairs(VOLUME_KEYS) do
            set(pawn, kind, k, vol)
        end
        call(pawn, kind, "RefreshAllVolumeMulties")
        PlayerMods.audioFixes = (PlayerMods.audioFixes or 0) + 1
    end)
end

---------------------------------------------------------------------------
-- pointer calibration, saved across sessions
---------------------------------------------------------------------------
-- Solved in VR, so it must outlive the game. control.txt cannot hold it (the
-- desktop app rewrites that file and reseeds stale values at every launch), so
-- it gets its own tiny file next to the bridge.

local CAL_PATH = "D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/pointercal.txt"

function PlayerMods.SavePointerCal()
    pcall(function()
        local f = io.open(CAL_PATH, "w")
        if not f then return end
        f:write(string.format("pitch=%s%syaw=%s%s",
                tostring(PlayerMods.state.PointerPitch or 0), "\n",
                tostring(PlayerMods.state.PointerYaw or 0), "\n"))
        f:close()
    end)
end

function PlayerMods.LoadPointerCal()
    pcall(function()
        local f = io.open(CAL_PATH, "r")
        if not f then return end
        local text = f:read("*a") or ""
        f:close()
        local p = tonumber(string.match(text, "pitch=([-%d%.]+)"))
        local y = tonumber(string.match(text, "yaw=([-%d%.]+)"))
        if p then PlayerMods.state.PointerPitch = p end
        if y then PlayerMods.state.PointerYaw   = y end
        PlayerMods.calLoaded = string.format("p=%s y=%s", tostring(p), tostring(y))
    end)
end

---------------------------------------------------------------------------
-- VR pointer: the hand that aims at the menu, and the game's own beam
---------------------------------------------------------------------------
-- Blood Trail already draws a laser from a controller (TogglePointerBeam) and
-- already knows how to click a widget with one (IfOverWidgetUse), so the menu
-- pointer reuses the game's beam rather than trying to draw its own. Nothing
-- here spawns or re-parents anything.
--
-- Defaults to the LEFT hand: the right hand is usually holding a gun, and the
-- trigger that clicks the menu is the same trigger that fires it.

function PlayerMods.GetHand(useLeft)
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then return nil end
    local name = useLeft and "LeftMotionController" or "RightMotionController"
    if not PlayerMods.hasProp(kind, name) then return nil end
    local ok, c = pcall(function() return pawn[name] end)
    if not ok or not c then return nil end
    local okV, valid = pcall(function() return c:IsValid() end)
    if okV and valid == false then return nil end
    return c
end

-- The beam is a multicast in the blueprint, so it is fired through the pawn.
-- Failure is fine and silent: without it the pointer still works, you just do
-- not get the visible line.
PlayerMods.beamOn = { [true] = nil, [false] = nil }

function PlayerMods.SetPointerBeam(useLeft, active)
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then return false end
    -- tracked PER HAND: one shared flag meant turning the second laser on
    -- looked like a no-op and the first hand's beam was never turned off
    useLeft = useLeft and true or false
    if PlayerMods.beamOn[useLeft] == active then return true end
    PlayerMods.beamOn[useLeft] = active
    -- ON THE GAME THREAD.
    --
    -- TogglePointerBeam is a blueprint that builds and tears down beam visuals.
    -- Calling it from the LoopAsync thread is the same mistake that produced
    -- the earlier access violations: the last crash was
    -- EXCEPTION_ACCESS_VIOLATION reading 0x268 with UE4SS sitting in the middle
    -- of a game callstack, i.e. a Lua-initiated call into game code that found
    -- a half-built object. Visual/render work belongs on the game thread.
    PlayerMods.beamOk = true
    ExecuteInGameThread(function()
        local p2, k2 = PlayerMods.GetPawn()
        if not isValid(p2) then return end
        callWith2(p2, k2, "TogglePointerBeam", useLeft and true or false,
                  active and true or false)
    end)
    return true
end

PlayerMods.StickState = function()
    return string.format("pad=%.2f padage=%d axis=%.2f pushage=%d pushed=%s seen=%s everpushed=%s hooks=%d",
        stickPadMag, (PlayerMods.tickStamp or 0) - stickPadStamp,
        stickAxis, (PlayerMods.tickStamp or 0) - stickPushTick,
        tostring(stickPushed()), tostring(stickEverSeen),
        tostring(stickEverPushed), PlayerMods.inputHooks or 0)
end

-- SAFE MODE.
--
-- The end-of-round crash has been chased through several real causes, each one
-- found and fixed, and it still comes back intermittently. What IS established
-- by controlled testing: with every enemy-touching feature off, the same
-- round-wipe loop runs clean, and with them on it eventually dies.
--
-- So rather than pretend it is solved, this switch turns off exactly that set
-- and leaves everything else working. It is the difference between a mod that
-- might drop you at the end of a round and one that does not.
local SAFE_MODE_OFF = {
    "EnemyESP", "StrengthFists", "FistRagdoll", "FistLaunch",
    "MeleeWeaponDamage", "GrabEnemies", "MeleeAlwaysHits", "FreezeEnemies",
}

-- Does SAFE MODE hold this key down? The menu needs to know so it can show the
-- row as locked instead of letting you click it and watch it snap back.
PlayerMods.SAFE_MODE_OFF = SAFE_MODE_OFF

function PlayerMods.SafeModeSuppresses(key)
    if not PlayerMods.state.SafeMode then return false end
    for _, k in ipairs(SAFE_MODE_OFF) do
        if k == key then return true end
    end
    return false
end

function PlayerMods.SafeModeTick()
    if not PlayerMods.state.SafeMode then
        PlayerMods.safeMode = false
        return
    end
    PlayerMods.safeMode = true
    for _, key in ipairs(SAFE_MODE_OFF) do
        PlayerMods.state[key] = false
    end
end

-- Force the crouch onto the pawn right now. Called every tick AND from the
-- post-hooks of the game's own height routines, so whatever they recalculate is
-- overwritten the instant they finish. Pinning on a timer alone loses the race,
-- which is what "sinks a bit then shoots straight back up" was.
function PlayerMods.ApplyCrouchNow()
    local s = PlayerMods.state
    if not s.CrouchDown then return end
    local pawn, kind = PlayerMods.GetPawn()
    if not isValid(pawn) then return end

    -- STOP FIGHTING THE GAME OVER ITS OWN HEIGHT.
    --
    -- `ChosenPlayerHeight` is recalculated from the headset constantly, so
    -- writing it produced exactly what you described: it sinks for a frame,
    -- the game recomputes, and you pop straight back up. Trying to out-write
    -- that is a race we lose every time.
    --
    -- `VRCapsuleOffset` is not part of that calculation - it is the offset
    -- between your capsule and your head - so shifting it lowers you and the
    -- game has no opinion about it. Nothing to fight.
    local root = get(pawn, kind, "VRRootReference")
    if isValid(root) and crouchOrigOffset then
        setVector(root, nil, "VRCapsuleOffset",
                  crouchOrigOffset.X, crouchOrigOffset.Y,
                  crouchOrigOffset.Z + (s.CrouchDrop or 50.0))
        local now = get(root, nil, "VRCapsuleOffset")
        PlayerMods.crouchOffsetZ = (now and now.Z) or 0
    end
    PlayerMods.crouchForced = (PlayerMods.crouchForced or 0) + 1
end

function PlayerMods.FlightTick()
    local s = PlayerMods.state
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then return end

    ---------------------------------------------------------------- crouch
    if s.CrouchDown ~= crouchWasOn then
        crouchWasOn = s.CrouchDown

        -- VIRTUAL CROUCH, the way Hard Bullet and Blade & Sorcery do it: your
        -- play space is lowered so your hands reach the floor without you
        -- physically ducking.
        --
        -- Two things were wrong before. `Crouch()` / `bIsCrouched` are standard
        -- ACharacter and do nothing on a VRExpansion pawn. And
        -- `SetCharacterHalfHeightVR` takes TWO arguments - (HalfHeight,
        -- bUpdateOverlaps) - so calling it with one silently did nothing.
        --
        -- What actually moves you is `VRCapsuleOffset` on the VR root: the
        -- offset between your capsule and your head. Shift it and the world
        -- rises around you.
        local root = get(pawn, kind, "VRRootReference")

        if s.CrouchDown then
            if crouchOrigHeight == nil then
                local h = get(pawn, kind, "ChosenPlayerHeight")
                if type(h) == "number" then crouchOrigHeight = h end
            end
            if crouchOrigSquat == nil then
                local q = get(pawn, kind, "SquatHeightLow")
                if type(q) == "number" then crouchOrigSquat = q end
            end
            if crouchOrigOffset == nil and isValid(root) then
                local o = get(root, nil, "VRCapsuleOffset")
                if o and type(o.Z) == "number" then
                    crouchOrigOffset = { X = o.X, Y = o.Y, Z = o.Z }
                end
            end

            local drop = s.CrouchDrop or 50.0
            if isValid(root) and crouchOrigOffset then
                setVector(root, nil, "VRCapsuleOffset",
                          crouchOrigOffset.X, crouchOrigOffset.Y,
                          crouchOrigOffset.Z + drop)
            end
            -- offset only; ChosenPlayerHeight is the game's and stays the game's
            PlayerMods.ApplyCrouchNow()
        else
            if isValid(root) and crouchOrigOffset then
                setVector(root, nil, "VRCapsuleOffset",
                          crouchOrigOffset.X, crouchOrigOffset.Y,
                          crouchOrigOffset.Z)
                -- report the restored value, or the readout keeps showing the
                -- crouched offset and it looks like standing up failed
                local now = get(root, nil, "VRCapsuleOffset")
                PlayerMods.crouchOffsetZ = (now and now.Z) or crouchOrigOffset.Z
                crouchOrigOffset = nil
            end
            if crouchOrigHeight then
                if crouchOrigHeight > 0 then
                    callWith2(pawn, kind, "SetCharacterHalfHeightVR",
                              crouchOrigHeight, true)
                end
                -- deliberately NOT restoring ChosenPlayerHeight: we never
                -- changed it, and writing it here would yank your height
                crouchOrigHeight = nil
            end
            -- hand height control back to the game
            if crouchOrigSquat then
                set(pawn, kind, "SquatHeightLow", crouchOrigSquat)
                crouchOrigSquat = nil
            end
            call(pawn, kind, "InitiateHeightcheck")
        end
        PlayerMods.crouchApplied = (PlayerMods.crouchApplied or 0) + 1
    end
    -- Keep BOTH pinned. The game re-checks your height every frame and would
    -- otherwise stand you straight back up - which is the other half of "it does
    -- not stay crouched".
    if s.CrouchDown then
        -- "Sinks a bit then shoots straight back up" is the game's own height
        -- check winning. `AutoCalibrateHeight` re-measures you from the headset
        -- and overwrites everything we set, so it has to be suppressed for as
        -- long as we are holding the crouch - pinning the values alone just
        -- loses the race every frame.
        PlayerMods.ApplyCrouchNow()
    end

    ---------------------------------------------------------------- noclip
    local wantNoClip = s.NoClip == true
    if wantNoClip ~= clipWasOff then
        clipWasOff = wantNoClip
        callWith(pawn, kind, "SetActorEnableCollision", not wantNoClip)
    end

    ---------------------------------------------------------------- flight
    local wantFly = (s.FlyMode == true) or wantNoClip
    local move = get(pawn, kind, "CharacterMovement")
    if not isValid(move) then return end

    if wantFly ~= flyWasOn then
        flyWasOn = wantFly
        -- MOVE_Flying lets the engine carry us and ignores gravity; going back
        -- to MOVE_Walking hands control cleanly back to the game.
        set(move, nil, "MovementMode", wantFly and MOVE_FLYING or MOVE_WALKING)
        if not wantFly then setVector(move, nil, "Velocity", 0.0, 0.0, 0.0) end
    end
    if not wantFly then
        PlayerMods.flyState = "off"
        PlayerMods.moveStatePass = (PlayerMods.moveStatePass or 0) + 1
    if PlayerMods.moveStatePass % 10 ~= 1 then return end
    PlayerMods.moveState = string.format("mode=%s crouched=%s",
            tostring(get(move, nil, "MovementMode")),
            tostring(PlayerMods.crouchOffsetZ or 0))
        return
    end

    -- keep asserting it: the game switches us back to walking on landing
    set(move, nil, "MovementMode", MOVE_FLYING)

    local dir = lookDir(pawn, kind)
    if not dir then return end

    -- You move ONLY while pushing the stick. The head aims, the stick throttles
    -- - otherwise you drift wherever you happen to be looking, which is what
    -- made this feel like it was flying you around by itself.
    if s.FlyNeedsStick ~= false and not stickPushed() then
        setVector(move, nil, "Velocity", 0.0, 0.0, 0.0)
        PlayerMods.flyState = "hover (stick gate on, stick not pushed)"
        PlayerMods.moveStatePass = (PlayerMods.moveStatePass or 0) + 1
    if PlayerMods.moveStatePass % 10 ~= 1 then return end
    PlayerMods.moveState = string.format("mode=%s crouched=%s",
            tostring(get(move, nil, "MovementMode")),
            tostring(PlayerMods.crouchOffsetZ or 0))
        return
    end

    local speed = s.FlySpeed or 600.0
    setVector(move, nil, "Velocity",
              dir.X * speed, dir.Y * speed, dir.Z * speed)
    PlayerMods.flyState = string.format("flying %.0f", speed)
    PlayerMods.moveStatePass = (PlayerMods.moveStatePass or 0) + 1
    if PlayerMods.moveStatePass % 10 ~= 1 then return end
    PlayerMods.moveState = string.format("mode=%s crouched=%s",
        tostring(get(move, nil, "MovementMode")),
        tostring(PlayerMods.crouchOffsetZ or 0))
end

function PlayerMods.FistTick()
    local s = PlayerMods.state
    -- The hand sweep also drives the lamp/NVG lock and grabbing, so it must run
    -- when ANY of those is on - not only for Strength Fists.
    if not (s.StrengthFists or s.NoAccidentalLamp or s.GrabEnemies
            or s.MeleeAlwaysHits) then
        return
    end

    handPass = handPass + 1
    if handCache == nil or handPass >= 3 then
        handPass = 0
        -- ONLY the hands belonging to the pawn we are actually playing.
        -- FindAllOf returned nine "hands" - leftovers from previous rounds and
        -- other pawns - so the grab was polling GripHeld on hands that are not
        -- in front of you, and the stale ones are dead actors waiting to be
        -- touched. GraspingHand carries WendigoVRref pointing at its owner.
        local pawn = PlayerMods.GetPawn()
        local pawnAddr = nil
        if pawn then
            local okP, a = pcall(function() return pawn:GetAddress() end)
            if okP then pawnAddr = a end
        end

        local found = {}
        for _, h in ipairs(HAND_CLASSES) do
            local ok, list = pcall(FindAllOf, h[1])
            if ok and list then
                for _, obj in ipairs(list) do
                    if isValid(obj) then
                        local mine = true
                        if pawnAddr then
                            mine = false
                            local okR, ref = pcall(function()
                                return obj.WendigoVRref
                            end)
                            if okR and ref then
                                local okA, ra = pcall(function()
                                    return ref:GetAddress()
                                end)
                                if okA and ra == pawnAddr then mine = true end
                            end
                        end
                        if mine then found[#found + 1] = { obj, h[1] } end
                    end
                end
            end
        end
        handCache = found
    end

    local kept = {}
    for _, entry in ipairs(handCache or {}) do
        if powerUpHand(entry[1], entry[2]) then kept[#kept + 1] = entry end
    end
    handCache = kept
    PlayerMods.handsPowered = #kept
end

-- Throw a ragdolled enemy away from the player, the way a heavy hit does in
-- Hard Bullet or Blade & Sorcery. AddImpulse lives on the inherited Mesh
-- (USkeletalMeshComponent); bVelChange=true makes the push mass-independent so
-- every body type flies the same distance.
---------------------------------------------------------------------------
-- Hard Bullet / Blade & Sorcery punch - DEFERRED, one layer at a time
---------------------------------------------------------------------------
-- The first attempt ran RagdollStart() + bKnocked + Mesh:AddImpulse INSIDE the
-- damage callback and killed the game on the first live punch. That is not
-- proof the ragdoll itself is impossible - it was done while the game was
-- half-way through processing its own damage, and re-entering an actor there is
-- exactly the pattern that has been fatal four times in this project.
--
-- So: the punch only QUEUES the body. The main loop ragdolls it on a later
-- tick, once the game has finished with it. Layers are separately switchable so
-- a crash can be bisected to the exact call instead of the whole feature:
--     FistRagdoll  - go limp  (RagdollStart)
--     FistLaunch   - fly away (LastRagdollVelocity, a property write, NOT
--                              AddImpulse - the native physics call is the one
--                              thing already proven fatal)
local ragdollQueue = {}
onDropCaches(function() ragdollQueue = {} end)

local function queueRagdoll(enemy, cls)
    if not PlayerMods.state.FistRagdoll then return end
    if #ragdollQueue > 8 then return end     -- never let this grow unbounded
    ragdollQueue[#ragdollQueue + 1] = { enemy = enemy, cls = cls }
end

-- Runs from the main loop, NOT from inside a damage hook.
-- WHY PUNCHES DID NOT SEND ANYONE FLYING, WHILE THROWING THEM DID.
--
-- Writing LastRagdollVelocity once does not move a body. What actually moves a
-- ragdoll in this game is the engine driving it toward TargetRagdollLocation
-- every frame - which is exactly what the grab does while you carry someone,
-- and why releasing them works. A punch set the velocity and stopped, so the
-- body just went limp on the spot.
--
-- So a hit now FLINGS: pick a point out in the hit direction and keep driving
-- the body at it for a short burst, the same way a carry does.
local flinging = {}         -- { enemy, cls, tx, ty, tz, ticksLeft }
onDropCaches(function() flinging = {} end)

local FLING_TICKS = 6       -- driven at the sweep rate: ~3 s of travel

flingEnemy = function(enemy, cls, dx, dy, force)
    -- only fling something the sweep has actually seen alive
    local addr = markLive(enemy)
    if not stillLive(addr) then
        PlayerMods.flingWhy = "not live addr=" .. tostring(addr)
        return false
    end
    local p = actorPos(enemy)
    if not p then
        PlayerMods.flingWhy = "no position"
        return false
    end
    PlayerMods.flingWhy = "ok"

    -- WHY THE FIRST VERSION DID NOT VISIBLY THROW ANYONE.
    --
    -- It aimed TargetRagdollLocation at a point ~12 m away and held it there.
    -- Carrying a body works because the point is right next to them and MOVES -
    -- the ragdoll is dragged along behind it. A target that far away in one
    -- jump does not drag, it just sits there being unreachable.
    --
    -- So walk the target away from them a step at a time, which is exactly what
    -- your hand does when you carry someone and then whip them - the mechanism
    -- that already works.
    local perTick = (force * 0.6) / FLING_TICKS
    flinging[#flinging + 1] = {
        -- deliberately NO object reference: only the address, resolved fresh
        cls = cls, addr = addr,
        -- start ON the body, then walk outward
        tx = p.X, ty = p.Y, tz = p.Z,
        sx = dx * perTick,
        sy = dy * perTick,
        sz = perTick * 0.35,        -- a little lift so they leave the floor
        ticksLeft = FLING_TICKS,
    }
    PlayerMods.flings = (PlayerMods.flings or 0) + 1
    return true
end

PlayerMods.FlingEnemy = flingEnemy

function PlayerMods.RagdollTick()
    -- 1. bodies queued by a hit: ragdoll them, then start the fling
    if #ragdollQueue > 0 then
        local queue = ragdollQueue
        ragdollQueue = {}

        local force = PlayerMods.state.FistLaunchForce or 900.0
        local dx, dy = 1.0, 0.0
        local pawn = PlayerMods.GetPawn()
        if pawn then
            local okF, f = pcall(function() return pawn:GetActorForwardVector() end)
            if okF and f and type(f.X) == "number" then dx, dy = f.X, f.Y end
        end

        for _, item in ipairs(queue) do
            local enemy, cls = item.enemy, item.cls
            if isValid(enemy) then
                call(enemy, cls, "RagdollStart")
                PlayerMods.ragdolls = (PlayerMods.ragdolls or 0) + 1
                if PlayerMods.state.FistLaunch then
                    -- The LastRagdollVelocity write used to sit here. It does
                    -- not move anything (that was the whole discovery) and it
                    -- was throwing, which silently aborted the whole tick
                    -- through timed()'s pcall - so the fling that follows it
                    -- never ran. Dropped: the fling does the work.
                    flingEnemy(enemy, cls, dx, dy, force)
                end
            end
        end
    end

    -- 2. keep driving anything mid-fling
    if #flinging == 0 then return end
    local still = {}
    for _, f in ipairs(flinging) do
        -- stillLive() is the guard that matters. isValid() alone returns true
        -- for a body destroyed by the round ending, and touching that is the
        -- 0x268 access violation.
        -- resolve the address to whatever the sweep just returned. Never
        -- f.enemy: that reference can be a body the engine already freed and
        -- reissued to someone else.
        local obj = liveEnemy(f.addr)
        if f.ticksLeft > 0 and obj then
            -- advance the carry point, then drag them to it
            f.tx, f.ty, f.tz = f.tx + f.sx, f.ty + f.sy, f.tz + f.sz
            setVector(obj, f.cls, "TargetRagdollLocation", f.tx, f.ty, f.tz)
            -- a live enemy can get straight back up; hold them down for the
            -- duration of the throw or they never leave the floor
            set(obj, f.cls, "bRagdolling", true)
            f.ticksLeft = f.ticksLeft - 1
            still[#still + 1] = f
        end
    end
    flinging = still
    PlayerMods.flying = #still
end

local function launchEnemy(enemy, cls)
    queueRagdoll(enemy, cls)
    return true
end

---------------------------------------------------------------------------
-- Melee Weapon DMG - every melee weapon, the safe way
---------------------------------------------------------------------------
-- Hooking the enemy's weapon-damage receivers (BludgeonDamage, StabbingDamage,
-- SlashDamage, HeadSlamDamage, ApplyMeleeDamage) covered every weapon but made
-- SPAWNING an enemy fatal - those fire while the actor is still being built and
-- the callback then reads a half-constructed object.
--
-- So arm the WEAPON instead of intercepting the victim. Every melee weapon
-- carries its own damage numbers, and writing them is just a property set on a
-- cached actor - the same pattern that powers up the hands, which is stable.
--
--   BP_MeleeWeapon_C -> Damage, VelocityDamage      (knife, pipe)
--   MeleeBasedupe_C  -> BaseDamage, BludgeonWeightClass
--                       (conduit, corkscrew, both cult knives, screwdriver,
--                        ball-peen hammer)
local MELEE_WEAPON_CLASSES = {
    -- class, damage fields, weight field, hit-volume component
    { "BP_MeleeWeapon_C", { "Damage", "VelocityDamage" }, nil, "HitBox" },
    { "MeleeBasedupe_C",  { "BaseDamage" }, "BludgeonWeightClass", "Slashbox" },
}

-- "Always connect" - Hard Bullet / Blade & Sorcery style forgiving hit
-- detection. Each melee weapon swings a box that has to overlap the target;
-- this simply makes that box bigger, so a swing that grazes past still lands.
-- SetBoxExtent is a native component call, which is the risky category in this
-- game, so it is pcall'd, kept behind its own toggle, and applied once per
-- component rather than every tick.
local reachApplied = {}
onDropCaches(function() reachApplied = {} end)

local function widenHitVolume(weapon, cls, compName)
    if not compName then return end
    local comp = get(weapon, cls, compName)
    if not isValid(comp) then return end

    local okA, addr = pcall(function() return comp:GetAddress() end)
    if not okA then return end
    local want = math.floor(PlayerMods.state.MeleeReach or 60)
    if reachApplied[addr] == want then return end
    reachApplied[addr] = want

    -- game thread: bUpdateOverlaps touches the physics scene (see the note on
    -- the hand capsules)
    ExecuteInGameThread(function()
        if not isValid(comp) then return end
        pcall(function()
            comp:SetBoxExtent({ X = want, Y = want, Z = want }, true)
        end)
    end)
    PlayerMods.reachSet = (PlayerMods.reachSet or 0) + 1
end

local weaponCache, weaponPass = nil, 0
onDropCaches(function() weaponCache, weaponPass = nil, 0 end)

function PlayerMods.MeleeWeaponTick()
    if not PlayerMods.state.MeleeWeaponDamage then return end

    -- This runs on the 2 s scan tick, so 20 passes would be 40 seconds before a
    -- weapon you just picked up got armed. 3 passes = ~6 s, and the sweep is
    -- only two FindAllOf calls.
    weaponPass = weaponPass + 1
    if weaponCache == nil or weaponPass >= 1 then
        weaponPass = 0
        local found = {}
        for _, w in ipairs(MELEE_WEAPON_CLASSES) do
            local ok, list = pcall(FindAllOf, w[1])
            if ok and list then
                for _, obj in ipairs(list) do
                    if isValid(obj) then
                        found[#found + 1] = { obj, w[1], w[2], w[3], w[4] }
                    end
                end
            end
        end
        weaponCache = found
    end

    local dmg  = PlayerMods.state.MeleeDamage or 100.0
    local kept = {}
    for _, e in ipairs(weaponCache or {}) do
        local obj, cls, fields, weightField, hitComp = e[1], e[2], e[3], e[4], e[5]
        if isValid(obj) then
            for _, f in ipairs(fields) do set(obj, cls, f, dmg) end
            if weightField then
                set(obj, cls, weightField,
                    math.floor(PlayerMods.state.MeleeWeightClass or 10))
            end
            -- WEAPON HIT-BOX WIDENING IS REMOVED. It was the round-end crash.
            --
            -- Bisected against a Raid map: weapon DAMAGE arming (property
            -- writes) survives six rounds with weapons piling up to 14; adding
            -- the widening killed it by round 5 every time. The call is
            -- `comp:SetBoxExtent({X,Y,Z}, true)` - a native call taking a STRUCT
            -- on a component of a weapon the round is busy destroying, which is
            -- the memcpy fault in every dump.
            --
            -- The hand capsules are widened separately in powerUpHand and are
            -- fine (five clean rounds): the hands belong to the player pawn,
            -- which does not get destroyed when a round ends. That is the whole
            -- difference, and it is why fists still connect.
            local _ = hitComp
            kept[#kept + 1] = e
        end
    end
    weaponCache = kept
    PlayerMods.weaponsArmed = #kept
end

-- Deliver a punch as a blunt-weapon hit on the enemy.
local function applyFistDamage(enemy, cls, hit, vel)
    if not isValid(enemy) then return false end
    local power = math.floor(PlayerMods.state.FistStrikePower or 10)
    local dmg   = PlayerMods.state.FistDamage or 150.0

    -- A swing speed the blueprint will accept. It derives its own damage from
    -- this, and a zero makes the whole call a no-op.
    local speed = 300.0
    if vel ~= nil then
        local okV, v = pcall(function() return vel:get() end)
        if okV and type(v) == "number" and v > 0 then speed = v end
    end
    local hitVal = nil
    if hit ~= nil then
        local okH, h = pcall(function() return hit:get() end)
        if okH then hitVal = h end
    end

    local field  = MELEE_HP[cls]
    local before = field and get(enemy, cls, field) or nil

    -- Only QUEUE the ragdoll. Doing it here, inside the game's own damage
    -- processing, is what killed it last time.
    launchEnemy(enemy, cls)

    -- The blunt-weapon path: the same call a pipe or hammer makes, so the punch
    -- carries the weapon's weight class and produces its gore, impact sound and
    -- ragdoll impulse rather than a silent health subtraction.
    pcall(function()
        enemy:BludgeonDamage(hitVal, speed, { X = 0.0, Y = 0.0, Z = 0.0 },
                             power, dmg)
    end)

    -- pcall succeeding does NOT mean damage landed - the blueprint bails out on
    -- arguments it does not like and returns quite happily. Check the health
    -- actually moved, and guarantee the hit if it did not.
    if field and type(before) == "number" then
        local after = get(enemy, cls, field)
        if type(after) == "number" and after < before then return true end
    end
    -- Same trap one level down: callWith reports success for a call that ran and
    -- did nothing, so `callWith(...) or forceIt()` never reached the fallback and
    -- the punch silently stopped hurting. Verify after every attempt.
    callWith(enemy, cls, "RemoveHPAndScream", dmg)
    if field and type(before) == "number" then
        local after = get(enemy, cls, field)
        if type(after) == "number" and after < before then return true end
        -- neither the game's blunt path nor its damage routine took it, so take
        -- the health down directly. A punch always hurts.
        set(enemy, cls, field, math.floor(before - dmg))
        local forced = get(enemy, cls, field)
        return type(forced) == "number" and forced < before
    end
    return false
end

-- Both features hit the same three enemy functions, so they share ONE hook.
-- Registering twice on the same UFunction would mean relying on UE4SS stacking
-- callbacks, which is not worth betting on when one branch does the job.
PlayerMods.RegisterFistHooks = function() end

-- Prove a punch lands blunt-weapon damage, without a headset.
function PlayerMods.StartFistTest()
    PlayerMods.fistTest = "running..."
    local ok, err = pcall(function()
        ExecuteInGameThread(function()
            -- A throw INSIDE the game-thread closure is not caught by the pcall
            -- around ExecuteInGameThread - the closure just dies and the result
            -- is never written, which reads as "not run" and says nothing.
            local okIn, errIn = pcall(function()
                -- FRESH sweep, never the stored PlayerMods.lastEnemy: this
                -- callback runs deferred, and a stored reference may point at a
                -- body the engine has already freed and reissued.
                local target, cls = nil, nil
                forEachSettledEnemy(function(e, c)
                    if target == nil and MELEE_HP[c] then target, cls = e, c end
                end, true)
                if not (isValid(target) and cls and MELEE_HP[cls]) then
                    PlayerMods.fistTest = "no enemy - spawn one and wait a moment"
                    return
                end
                local field  = MELEE_HP[cls]
                local before = get(target, cls, field)
                local wasOn  = PlayerMods.state.StrengthFists
                PlayerMods.state.StrengthFists = true

                local landed = applyFistDamage(target, cls, nil, nil)

                local after = get(target, cls, field)
                PlayerMods.state.StrengthFists = wasOn
                local dropped = (type(before) == "number"
                                 and type(after) == "number" and after < before)
                PlayerMods.fistTest = string.format(
                    "%s hp %s->%s power=%d dmg=%s hooks=%d hands=%d",
                    dropped and "PASS"
                        or (landed and "FAIL-no-drop" or "FAIL-no-call"),
                    tostring(before), tostring(after),
                    math.floor(PlayerMods.state.FistStrikePower or 10),
                    tostring(PlayerMods.state.FistDamage or 150.0),
                    -- the shared punch hook, counted under meleeHooks
                    PlayerMods.meleeHooks or 0, PlayerMods.handsPowered or 0)
            end)
            if not okIn then
                PlayerMods.fistTest = "threw: " .. tostring(errIn)
            end
            print("[ModMenu] FISTTEST: " .. tostring(PlayerMods.fistTest) .. "\n")
        end)
    end)
    if not ok then PlayerMods.fistTest = "error: " .. tostring(err) end
end

function PlayerMods.RegisterMeleeHooks()
    if not RegisterHook then return end

    for _, t in ipairs(MELEE_TARGETS) do
        local cls, path, fns = t[1], t[2], t[3]
        for _, fn in ipairs(fns) do
            for _, target in ipairs({ path .. ":" .. fn, cls .. ":" .. fn }) do
                if not meleeRegistered[target] then
                    local ok, pre = pcall(function()
                        return RegisterHook(target, function(self, hit, vel)
                            local s = PlayerMods.state
                            if not (s.MeleeWeaponDamage or s.StrengthFists) then
                                return
                            end
                            -- our own damage calls land on these same functions
                            if inMeleeHook then return end
                            inMeleeHook = true
                            -- keep the game's own reaction looking like a heavy
                            -- hit by inflating the reported swing speed
                            if vel ~= nil then
                                local mult = s.MeleeKnockback or 10.0
                                local okG, cur = pcall(function() return vel:get() end)
                                if okG and type(cur) == "number" then
                                    pcall(function() vel:set(cur * mult) end)
                                end
                            end
                            -- QUEUE ONLY. Do not call back into game code from
                            -- inside a hook.
                            --
                            -- This is the crash in the reporter's stack: game ->
                            -- UE4SS -> game. The game invokes PunchDamage while a
                            -- round is tearing down, UE4SS dispatches this Lua,
                            -- and this Lua called straight back into the engine
                            -- (BludgeonDamage / RemoveHPAndScream / struct writes)
                            -- on a body already being destroyed. Boosting the
                            -- velocity above is safe - that is a value on the
                            -- stack - but anything touching the ACTOR has to wait
                            -- for the sweep that proves it is still alive.
                            local okS, obj = pcall(function() return self:get() end)
                            local enemy = okS and obj or self
                            local okA, addr = pcall(function()
                                return enemy:GetAddress()
                            end)
                            if okA and addr and #damageQueue < 24 then
                                damageQueue[#damageQueue + 1] = {
                                    addr = addr, cls = cls,
                                    fist = s.StrengthFists == true,
                                }
                            end
                            inMeleeHook = false
                        end)
                    end)
                    -- pcall success is NOT a bind: UE4SS returns nothing when the
                    -- class is not loaded yet, and the retry must keep trying.
                    if ok and type(pre) == "number" and pre > 0 then
                        meleeRegistered[target] = true
                        PlayerMods.meleeHooks = PlayerMods.meleeHooks + 1
                    end
                end
            end
        end
    end
end

-- Self-test: prove the fist actually damages an enemy, without a headset.
-- Calls the enemy's own punch handler on a live enemy and reports the health
-- change, the same way the God Mode test drives the damage path directly.
function PlayerMods.StartMeleeTest()
    -- report our own failures: a silent throw here just leaves the status
    -- reading "not run", which says nothing about why
    local ok, err = pcall(PlayerMods.RunMeleeTest)
    if not ok then
        PlayerMods.meleeTest = "error: " .. tostring(err)
    end
end

function PlayerMods.RunMeleeTest()
    -- The WHOLE test has to run inside the game thread - including both health
    -- reads. Applying the damage asynchronously and reading straight afterwards
    -- reads the health before the game has processed the hit, which reports a
    -- pass/fail that means nothing (it read "hp 250->250" while working).
    ExecuteInGameThread(function()
        -- Take the target from a FRESH sweep, not from PlayerMods.lastEnemy.
        -- A stored reference is the recycled-pointer hazard: by the time this
        -- deferred callback runs, that body may be destroyed and its memory
        -- handed to someone else.
        local target, cls = nil, nil
        forEachSettledEnemy(function(e, c)
            if target == nil and MELEE_HP[c] then target, cls = e, c end
        end, true)
        if not (isValid(target) and cls and MELEE_HP[cls]) then
            PlayerMods.meleeTest = "no enemy - spawn one and wait a moment"
            return
        end
        local field = MELEE_HP[cls]

        local before = get(target, cls, field)
        local wasOn  = PlayerMods.state.MeleeWeaponDamage
        PlayerMods.state.MeleeWeaponDamage = true

        local landed = applyMeleeDamage(target, cls)

        local after = get(target, cls, field)
        PlayerMods.state.MeleeWeaponDamage = wasOn

        local dropped = (type(before) == "number" and type(after) == "number"
                         and after < before)
        PlayerMods.meleeTest = string.format(
            "%s hp %s->%s dmg=%s hooks=%d",
            dropped and "PASS" or (landed and "FAIL-no-drop" or "FAIL-no-call"),
            tostring(before), tostring(after),
            tostring(PlayerMods.state.MeleeDamage or 100.0),
            PlayerMods.meleeHooks or 0)
        print("[ModMenu] MELEETEST: " .. PlayerMods.meleeTest .. "\n")
    end)
end

---------------------------------------------------------------------------
-- fast tick: cached pawn only, no object-array walking
---------------------------------------------------------------------------

local defaultWalkSpeed, defaultJumpZ = nil, nil
local defaultTeleportDist, defaultDirectionalDist = nil, nil
local godWasOn = false

function PlayerMods.FastTick()
    watchTick = watchTick + 1
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then
        PlayerMods.info.pawn = "none"
        return
    end
    local s = PlayerMods.state

    if s.GodMode then
        ApplyGodMode(pawn, kind)
        godWasOn = true
    elseif godWasOn then
        ClearGodMode(pawn, kind)
        godWasOn = false
    end

    if s.InfiniteBulletTime then set(pawn, kind, "BullettimePercent", 100) end
    if s.InfiniteCourage    then set(pawn, kind, "CourageLevel", 100) end

    if s.InstantCrackRegen then
        set(pawn, kind, "CrackRegenTime", 0.0)
        set(pawn, kind, "crackRockAvailable", true)
    end

    if s.InfiniteMana then
        local m = get(pawn, kind, "MaxMana")
        if type(m) == "number" and m > 0 then set(pawn, kind, "Mana", m) end
    end

    if s.InfiniteArrows then
        local a = get(pawn, kind, "MaxArrows")
        if type(a) == "number" and a > 0 then set(pawn, kind, "Arrows", a) end
    end

    if s.StopEnemySpawns then set(pawn, kind, "ShouldSpawnEnemies", false) end

    if s.GoreForever then
        set(pawn, kind, "RagdollLifetimeInSeconds", 99999)
        set(pawn, kind, "DecalLifetimeInSeconds", 99999)
    end

    -- Movement: only the Wendigo pawn has a CharacterMovement component.
    local cm = get(pawn, kind, "CharacterMovement")
    if isValid(cm) then
        -- the component is a native UCharacterMovementComponent; no schema
        -- entry for it, so hasProp() allows these through
        if defaultWalkSpeed == nil then defaultWalkSpeed = get(cm, nil, "MaxWalkSpeed") end
        if defaultJumpZ    == nil then defaultJumpZ    = get(cm, nil, "JumpZVelocity") end

        local baseWalk = (type(defaultWalkSpeed) == "number" and defaultWalkSpeed > 0)
                         and defaultWalkSpeed or 300.0
        local baseJump = (type(defaultJumpZ) == "number" and defaultJumpZ > 0)
                         and defaultJumpZ or 420.0

        set(cm, nil, "MaxWalkSpeed",  s.SuperSpeed and (baseWalk * s.SpeedMultiplier) or baseWalk)
        set(cm, nil, "JumpZVelocity", s.HighJump  and (baseJump * s.JumpMultiplier) or baseJump)
    end

    if hasProp(kind, "TraditionalDistance") then
        if defaultTeleportDist == nil then
            defaultTeleportDist = get(pawn, kind, "TraditionalDistance")
        end
        if type(defaultTeleportDist) == "number" and defaultTeleportDist > 0 then
            set(pawn, kind, "TraditionalDistance",
                s.TeleportBoost and (defaultTeleportDist * 2.5) or defaultTeleportDist)
        end
    end
    if hasProp(kind, "DirectionalTeleportDistance") then
        if defaultDirectionalDist == nil then
            defaultDirectionalDist = get(pawn, kind, "DirectionalTeleportDistance")
        end
        if type(defaultDirectionalDist) == "number" and defaultDirectionalDist > 0 then
            set(pawn, kind, "DirectionalTeleportDistance",
                s.TeleportBoost and (defaultDirectionalDist * 2.5) or defaultDirectionalDist)
        end
    end

    local info = PlayerMods.info
    info.pawn      = PlayerMods.PawnLabel()
    info.health    = get(pawn, kind, "playerhealth") or 0
    info.healthmax = get(pawn, kind, (kind == WENDIGO) and "playerhealthmax" or "PlayerMaxHealth") or 0
    info.kills     = get(pawn, kind, "Kills") or 0
end

---------------------------------------------------------------------------
-- scan tick: walks the object array, low rate only
---------------------------------------------------------------------------

local function forEachOf(cls, fn)
    local ok, list = pcall(FindAllOf, cls)
    if not ok or not list then return 0 end
    local n = 0
    for _, obj in ipairs(list) do
        n = n + 1
        fn(obj)
    end
    return n
end

-- Plain sweep of the one enemy class. Deliberately simple.
--
-- A "settle gate" version was tried - GetAddress() on every enemy to track which
-- had survived a previous sweep - and it made things WORSE: the game then
-- crashed even on ALS spawns, which had been stable for many sessions. Calling
-- GetAddress on a freshly spawned actor is evidently not safe here. The build
-- that produced the working ESP screenshot used exactly this loop, so this ships.
-- A corpse is still a perfectly valid actor - the game keeps ragdolls around for
-- RagdollLifetimeInSeconds - so IsValid() alone leaves dead bodies on the ESP.
-- Each family flags death differently, and each flag is only read on the class
-- that actually has it (reading an absent property is the UE4SS null-deref crash).
local DEAD_FLAG = {
    BP_MeleeAI_Character_C     = "bIsDead",
    BP_NPC_Man_C               = "Dead",
    ALS_Player_CharacterBPai_C = "bDead",
}

local function isEnemyDead(e, cls)
    local flag = DEAD_FLAG[cls]
    if flag then
        local ok, v = pcall(function() return e[flag] end)
        if ok and v == true then return true end
    end
    -- the zombie family also exposes Health, which ragdolls at or below zero
    if cls == "BP_MeleeAI_Character_C" then
        local okH, h = pcall(function() return e.Health end)
        if okH and type(h) == "number" and h <= 0 then return true end
    end
    return false
end

forEachSettledEnemy = function(fn, fresh)
    -- 1. The ALS campaign enemy, via the sweep that has always been stable.
    --    FindAllOf walks the whole UObject array, which measured as the second
    --    biggest cost in the mod, so the list is refreshed every few passes and
    --    reused in between - each entry is still revalidated before use, exactly
    --    like the watch registry.
    -- ALWAYS take a fresh list. Reusing it and revalidating with isValid() was
    -- the end-of-round crash: isValid() returns TRUE for a half-destroyed actor,
    -- so when a round wipes the wave the cache still holds every corpse and the
    -- next death-flag read is the access violation at 0x268. FindAllOf only ever
    -- hands back live objects, so a fresh sweep cannot contain a dead one.
    -- The old caching was a performance trick that traded away correctness.
    -- Fresh every TICK, but shared within one. The ESP scan and the hit watch
    -- both land on the same tick and were each doing a full object-array sweep
    -- for the identical list. A stamp lets them share one sweep without ever
    -- reusing a list from a previous tick - which is what made corpses linger.
    -- `fresh` forces a re-sweep. The per-tick memo is safe from the loop, but
    -- NOT from an ExecuteInGameThread callback: those run later while the tick
    -- stamp is unchanged, so the memo hands back a list from an earlier moment
    -- that may now be full of destroyed enemies - and reading a position off one
    -- is the memcpy crash. Every self-test must ask for a fresh sweep.
    if fresh or alsStamp ~= (PlayerMods.tickStamp or 0) or alsCache == nil then
        alsStamp = PlayerMods.tickStamp or 0
        local fresh = {}
        forEachOf(ENEMY_CLASS, function(e)
            if isValid(e) then fresh[#fresh + 1] = e end
        end)
        alsCache = fresh
    end

    local n = 0
    local keptAls = {}
    for _, e in ipairs(alsCache) do
        if isValid(e) then
            keptAls[#keptAls + 1] = e
            if not isEnemyDead(e, ENEMY_CLASS) then
                n = n + 1
                fn(e, ENEMY_CLASS)
            end
        end
    end
    alsCache = keptAls

    -- 2. zombies and NPCs, from the watch registry - never enumerated
    local keep = {}
    for _, entry in ipairs(watched) do
        if isValid(entry.obj) then
            local dead = isEnemyDead(entry.obj, entry.cls)
            -- Drop corpses from the registry entirely. Keeping them would leave
            -- dead bodies on the ESP and let the list grow all round long.
            if not dead then
                keep[#keep + 1] = entry
                -- leave brand-new arrivals alone until they have settled
                if (watchTick - entry.born) >= WATCH_SETTLE_TICKS then
                    n = n + 1
                    fn(entry.obj, entry.cls)
                end
            end
        end
    end
    watched = keep
    return n
end

local enemiesFrozen = false

function PlayerMods.ScanTick()
    local s = PlayerMods.state

    if s.InfiniteAmmo or s.NoRecoil or s.FullAuto then
        local pawn, kind = PlayerMods.GetPawn()
        if pawn and s.InfiniteAmmo then RefillReserveAmmo(pawn, kind) end

        -- FindAllOf returns instances of the EXACT class, so sweeping only
        -- SkeletalGun_C never touched the actual guns you hold - the shotgun,
        -- ak, glock and 92fs are all subclasses of it. That is why no-recoil
        -- never reached the shotgun. Sweep each concrete blueprint as well.
        -- Five FindAllOf sweeps every 2 s is the most expensive thing here, and
        -- the fire hooks already top up whatever you are holding - this sweep
        -- only needs to catch a gun you just picked up. Every other pass is
        -- plenty, and it halves the cost.
        gunSweepPass = gunSweepPass + 1
        if gunSweepPass % 2 == 1 then
            for _, gunCls in ipairs(GUN_SUBCLASSES) do
                forEachOf(gunCls, RefillSkeletalGun)
            end
        end
        forEachOf(GUN_PHYS, RefillPhysicalGun)

        if s.InfiniteAmmo then
            forEachOf(MAG_SKEL, function(m) RefillLooseMag(m, MAG_SKEL, "magazineAmmo") end)
            forEachOf(MAG_STD,  function(m) RefillLooseMag(m, MAG_STD,  "CurrentAmmo") end)
        end
    end
end

---------------------------------------------------------------------------
-- Enemy ESP
---------------------------------------------------------------------------
-- Deliberately positions-only. Resolving a name per actor means
-- GetClass():GetFName():ToString() - several wrapper calls ending in an
-- allocation - and doing that for every actor a few times a second is a known
-- way to crash these games from inside the C runtime. Distance and a clock
-- bearing need nothing but two vectors and some Lua arithmetic.

PlayerMods.esp = {}          -- { {dist = metres, clock = 1..12}, ... } nearest first
PlayerMods.ESP_ROWS = 8

local function bearingClock(fwdX, fwdY, dx, dy)
    -- signed angle from the player's facing to the target, in degrees
    local dot   = (fwdX * dx) + (fwdY * dy)
    local cross = (fwdX * dy) - (fwdY * dx)
    local ang = math.deg(math.atan(cross, dot))
    if ang < 0 then ang = ang + 360 end
    -- 12 o'clock is straight ahead
    local clock = math.floor(((ang + 15) % 360) / 30)
    if clock == 0 then clock = 12 end
    return clock
end

function PlayerMods.ScanESP()
    -- stand down with the rest of the mod while a round tears down
    if PlayerMods.dormant then return end
    if not PlayerMods.state.EnemyESP then
        if #PlayerMods.esp > 0 then PlayerMods.esp = {} end
        return
    end

    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then PlayerMods.esp = {} return end

    local okL, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    local okF, fwd = pcall(function() return pawn:GetActorForwardVector() end)
    if not (okL and okF and loc and fwd) then PlayerMods.esp = {} return end

    local found = {}
    forEachSettledEnemy(function(e)
        local okE, p = pcall(function() return e:K2_GetActorLocation() end)
        if not okE or not p then return end
        local dx, dy, dz = p.X - loc.X, p.Y - loc.Y, p.Z - loc.Z
        local d = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
        found[#found + 1] = { dist = d / 100.0,           -- cm -> metres
                              clock = bearingClock(fwd.X, fwd.Y, dx, dy) }
    end)

    table.sort(found, function(a, b) return a.dist < b.dist end)
    while #found > PlayerMods.ESP_ROWS do table.remove(found) end
    PlayerMods.esp = found
end

-- Separate and much slower: this is only wanted for the freeze toggle and the
-- on-screen counter, so it does not need to run with the ammo refills.
-- SEND THEM FLYING, WHATEVER HIT THEM.
--
-- A punch can fling because we hook the punch. A pipe, a knife or a bullet
-- cannot: those land through BludgeonDamage / StabbingDamage / BulletDamage on
-- the enemy, and hooking those is SPAWN-FATAL (it killed the game every time an
-- enemy spawned). So do not hook anything - just watch the health we already
-- read, and fling anyone whose health dropped since the last look. That covers
-- fists, melee weapons and guns alike, using only reads and writes already
-- proven safe.
local lastHp = {}
onDropCaches(function() lastHp = {} end)

local function watchForHit(e, cls)
    if not PlayerMods.state.FistLaunch then return end
    local field = MELEE_HP[cls]
    if not field then return end

    local okA, addr = pcall(function() return e:GetAddress() end)
    if not okA then return end

    local hp = get(e, cls, field)
    if type(hp) ~= "number" then return end

    local prev = lastHp[addr]
    lastHp[addr] = hp
    if prev == nil or hp >= prev then return end     -- no damage since last look

    -- hit: throw them away from the player
    local dx, dy = 1.0, 0.0
    local pawn = PlayerMods.GetPawn()
    local pp = pawn and actorPos(pawn) or nil
    local ep = actorPos(e)
    if pp and ep then
        local vx, vy = ep.X - pp.X, ep.Y - pp.Y
        local len = math.sqrt((vx * vx) + (vy * vy))
        if len > 1.0 then dx, dy = vx / len, vy / len end
    end

    call(e, cls, "RagdollStart")
    flingEnemy(e, cls, dx, dy, PlayerMods.state.FistLaunchForce or 900.0)
end

-- Runs several times a second so a hit throws them while it still reads as the
-- hit doing it. Only walks the enemy list the ESP already maintains.
-- Detect a ROUND ending, which is invisible to the world-address check because
-- the map never changes. The tell is the enemy list going from "several" to
-- "none": the wave was wiped and every one of those actors has just been
-- destroyed. Anything still holding one has to let go NOW.
local lastEnemyCount = 0
-- ~5 s of doing nothing after a wave collapses
local DORMANT_SWEEPS = 12
local dormantUntil = 0
onDropCaches(function() dormantUntil = 0 end)

function PlayerMods.HitWatchTick()
    -- This runs even with FistLaunch off: it is what keeps the live registry
    -- fresh, and the registry is what stops a dead body being touched.
    liveSweep = liveSweep + 1
    liveObj = {}                -- rebuilt from scratch every sweep

    -- still standing down after a wipe: touch nothing
    if liveSweep < dormantUntil then
        PlayerMods.dormant = true
        return
    end
    PlayerMods.dormant = false

    local n, nAls = 0, 0
    forEachSettledEnemy(function(e, c)
        n = n + 1
        if c == ENEMY_CLASS then nAls = nAls + 1 end
        markLive(e)
        if PlayerMods.state.FistLaunch and MELEE_HP[c] then watchForHit(e, c) end
    end)

    -- Damage the hooks asked for, applied against the object THIS sweep
    -- returned. Anything whose body is gone is simply dropped.
    if #damageQueue > 0 then
        local q = damageQueue
        damageQueue = {}
        for _, d in ipairs(q) do
            local obj = liveEnemy(d.addr)
            if obj then
                if d.fist then
                    if applyFistDamage(obj, d.cls, nil, nil) then
                        PlayerMods.fistHits = (PlayerMods.fistHits or 0) + 1
                    end
                else
                    if applyMeleeDamage(obj, d.cls) then
                        PlayerMods.meleeHits = (PlayerMods.meleeHits or 0) + 1
                    end
                end
            end
        end
    end

    -- Every enemy struct operation happens HERE, immediately after the sweep
    -- that proved those actors are alive. Driving flings on their own faster
    -- schedule meant touching bodies between sweeps - which is the memcpy fault.
    --
    -- Grabbing moved here for the same reason. It used to ride the 2 s scan
    -- tick, so this is also four times more responsive than it was.
    if PlayerMods.state.GrabEnemies then
        for _, entry in ipairs(handCache or {}) do
            if isValid(entry[1]) then handleGrab(entry[1], entry[2]) end
        end
    end

    PlayerMods.RagdollTick()

    -- GO DORMANT WHILE A ROUND TEARS DOWN.
    --
    -- Several distinct causes of the end-of-round crash have been found and
    -- fixed, and it kept coming back - which says the teardown is simply a
    -- hostile moment to be touching anything. So stop trying to be clever about
    -- WHICH object is unsafe and just stand down: when the enemy count collapses
    -- (a wave wiped, a round ending), do no enemy work at all for a few seconds.
    -- A mod that is idle cannot crash the game.
    --
    -- The threshold is a COLLAPSE, not merely a decrease, so ordinary kills
    -- during a fight do not keep switching it off.
    if lastEnemyCount >= 3 and nAls <= (lastEnemyCount * 0.4) then
        dormantUntil = liveSweep + DORMANT_SWEEPS
        flinging, grabbed, damageQueue = {}, {}, {}
        PlayerMods.dormancies = (PlayerMods.dormancies or 0) + 1
    end

    -- Key this off the ALS count, which comes fresh from FindAllOf and is
    -- therefore trustworthy. The total includes the watch registry, and that
    -- registry is exactly what goes stale - counting it would mask the very
    -- event we need to detect.
    if nAls == 0 and lastEnemyCount > 0 then
        -- Round over. Drop EVERY enemy reference, including the watch registry.
        --
        -- Missing `watched` here is what kept crashing: it holds zombie/NPC
        -- references from a BeginPlay hook, is only ever checked with isValid()
        -- (true for a half-destroyed actor), and the ESP reads a POSITION off
        -- each one - a struct copy, which is the memcpy fault in the dump.
        flinging = {}
        grabbed = {}
        liveSeen = {}
        watched = {}
        PlayerMods.lastEnemy, PlayerMods.lastEnemyClass = nil, nil
        PlayerMods.roundEnds = (PlayerMods.roundEnds or 0) + 1
    end
    lastEnemyCount = nAls
end

function PlayerMods.EnemyTick()
    -- stand down with the rest of the mod while a round tears down
    if PlayerMods.dormant then return end
    local s = PlayerMods.state
    if not s.FreezeEnemies and not enemiesFrozen and PlayerMods.info.enemies == 0 then
        -- nothing to do and nothing to report; still count occasionally below
    end

    -- CustomTimeDilation lives on AActor, so it is safe on every enemy class
    -- without a per-class schema entry - but only once the actor has settled.
    local count = forEachSettledEnemy(function(e, c)
        if s.FreezeEnemies then
            set(e, nil, "CustomTimeDilation", 0.0)
        elseif enemiesFrozen then
            set(e, nil, "CustomTimeDilation", 1.0)
        end
        -- Keep a handle on one live enemy for the fist self-test. Looking one up
        -- again from inside the test found nothing even while the ESP was
        -- tracking three, so reuse exactly what the ESP already sees.
        if MELEE_HP[c] then
            PlayerMods.lastEnemy, PlayerMods.lastEnemyClass = e, c
        end
    end)
    enemiesFrozen = s.FreezeEnemies
    PlayerMods.info.enemies = count
end

---------------------------------------------------------------------------
-- one-shot actions
---------------------------------------------------------------------------

function PlayerMods.RefillNow()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if pawn then RefillReserveAmmo(pawn, kind) end
        PlayerMods.ScanTick()
    end)
end

function PlayerMods.HealNow()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        local hp = PlayerMods.state.GodHP
        if type(hp) ~= "number" or hp <= 0 then hp = 10000.0 end
        set(pawn, kind, (kind == WENDIGO) and "playerhealthmax" or "PlayerMaxHealth", hp)
        set(pawn, kind, "playerhealth", hp)
        set(pawn, kind, "Dead", false)
    end)
end

function PlayerMods.KillAllEnemies()
    ExecuteInGameThread(function()
        local n = 0
        forEachSettledEnemy(function(e)
            pcall(function() e:K2_DestroyActor() end)
            n = n + 1
        end)
        print("[ModMenu] removed " .. n .. " enemies\n")
    end)
end

function PlayerMods.UnlockAll()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        set(pawn, kind, "UnlockedCheckpoint", 99)
        set(pawn, kind, "Unlockedchapter", 99)
        set(pawn, kind, "UnlockedRaidLevel", 99)
        print("[ModMenu] progression unlocked\n")
    end)
end

function PlayerMods.ToggleHeadlamp()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        if hasFunc(kind, "EventCycleHeadlamp") then
            call(pawn, kind, "EventCycleHeadlamp")
        else
            call(pawn, kind, "ToggleHeadlamp")
        end
    end)
end

function PlayerMods.ToggleNightVision()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        call(pawn, kind, "EventCycleNightVision")
    end)
end

---------------------------------------------------------------------------
-- God Mode self-test
---------------------------------------------------------------------------
-- Proves God Mode in the running game without needing to be shot at. Applies
-- real damage through the game's OWN damage function, twice:
--   A) God Mode off, small hit  -> health must DROP  (proves damage really lands
--                                  and that we are not blocking when switched off)
--   B) God Mode on, huge hit    -> health must NOT move
-- Then restores health and the original God Mode setting.

PlayerMods.testResult = "not run"

local function applyDamage(pawn, kind, amount)
    if kind == WENDIGO then
        return pcall(function() pawn:BulletDamage(amount) end)
    end
    -- legacy pawn has no single-float entry point; drive health directly so the
    -- control phase still means something
    return pcall(function() pawn.playerhealth = (get(pawn, kind, "playerhealth") or 0) - amount end)
end

function PlayerMods.GodModeSelfTest()
    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then
            PlayerMods.testResult = "FAIL no player pawn"
            print("[ModMenu] SELFTEST: " .. PlayerMods.testResult .. "\n")
            return
        end

        local wasGod = PlayerMods.state.GodMode
        local healthField = "playerhealth"
        local maxHp = get(pawn, kind, (kind == WENDIGO) and "playerhealthmax" or "PlayerMaxHealth")

        -- Phase A: control. Damage must land with protection fully off - which
        -- means clearing the pawn's own Invincible flag too, not just our
        -- toggle. (Leaving it set made the first run of this test inconclusive:
        -- nothing landed, because the game DOES honour Invincible here.)
        PlayerMods.state.GodMode = false
        set(pawn, kind, "Invincible", false)
        -- The game has damage cooldown frames; if a hit landed recently,
        -- ApplyingDamage is still set and the control shot is ignored, which
        -- makes the test report INCONCLUSIVE for no good reason.
        set(pawn, kind, "ApplyingDamage", false)
        local a0 = get(pawn, kind, healthField)
        applyDamage(pawn, kind, 5.0)
        local a1 = get(pawn, kind, healthField)

        -- phase B: the real test, protection back on.
        PlayerMods.state.GodMode = true
        set(pawn, kind, "Invincible", true)
        local hits0 = PlayerMods.damageBlocked
        local b0 = get(pawn, kind, healthField)
        applyDamage(pawn, kind, 999999.0)
        local b1 = get(pawn, kind, healthField)
        local hits1 = PlayerMods.damageBlocked

        -- put everything back
        if type(maxHp) == "number" and maxHp > 0 then
            set(pawn, kind, healthField, maxHp)
        end
        PlayerMods.state.GodMode = wasGod

        local controlWorked = (type(a0) == "number" and type(a1) == "number" and a1 < a0)
        local blocked = (type(b0) == "number" and type(b1) == "number" and b1 >= b0)
        local hookFired = hits1 > hits0

        local verdict
        if PlayerMods.damageHooks == 0 then
            verdict = "FAIL - no damage hooks bound"
        elseif not controlWorked then
            verdict = "INCONCLUSIVE - damage did not land even with God Mode off"
        elseif blocked and hookFired then
            verdict = "PASS - damage blocked by the hook"
        elseif blocked then
            verdict = "PASS? - health held but hook did not fire"
        else
            verdict = "FAIL - health dropped with God Mode on"
        end

        PlayerMods.testResult = string.format(
            "%s | pawn=%s hooks=%d | control %s->%s | test %s->%s | hits %d->%d",
            verdict, tostring(kind), PlayerMods.damageHooks,
            tostring(a0), tostring(a1), tostring(b0), tostring(b1), hits0, hits1)

        print("[ModMenu] SELFTEST: " .. PlayerMods.testResult .. "\n")
    end)
end

-- Ask the engine to render the player camera to a PNG. The desktop mirror is
-- black whenever the headset is idle, so this is the only way to actually SEE
-- what is in front of the player - including whether the menu/ESP text is
-- drawing - without wearing the HMD.
-- BRIGHTNESS, on any map.
--
-- There is no "fullbright" switch in a shipped build, but the engine's gamma
-- console command works everywhere and needs no per-level knowledge - so it
-- brightens a pitch-black Raid basement exactly like it brightens the lobby.
-- Applied only when the value changes; running a console command every tick
-- would be wasteful and noisy.
local lastGamma = nil
onDropCaches(function() lastGamma = nil end)

function PlayerMods.BrightnessTick()
    local s = PlayerMods.state
    -- TURNING IT OFF WAS MAKING THE GAME DARKER THAN STOCK.
    --
    -- Off used to mean `gamma 1.0`, but the engine's default is 2.2 - so
    -- switching the feature off did not restore the game, it dimmed it well
    -- below normal and stayed that way for the whole session. Off must restore
    -- 2.2, and we must not issue any gamma at all until the feature is used.
    local want = s.Brightness or 2.0
    if not s.BrightWorld then
        if lastGamma == nil then return end     -- never touched it; leave it alone
        want = s.GammaDefault or 2.2
    end
    if lastGamma ~= nil and math.abs(want - lastGamma) < 0.01 then return end

    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then return end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not isValid(ksl) then return end

    local ok = pcall(function()
        ksl:ExecuteConsoleCommand(pawn, string.format("gamma %.2f", want), nil)
    end)
    if ok then
        lastGamma = want
        PlayerMods.brightState = string.format("gamma %.2f", want)
    end
end

function PlayerMods.Screenshot()
    ExecuteInGameThread(function()
        local pawn = PlayerMods.GetPawn()
        if not isValid(pawn) then
            print("[ModMenu] screenshot: no pawn\n")
            return
        end
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not isValid(ksl) then
            print("[ModMenu] screenshot: KismetSystemLibrary not found\n")
            return
        end
        local ok = pcall(function()
            ksl:ExecuteConsoleCommand(pawn, "HighResShot 1280x720", nil)
        end)
        print("[ModMenu] screenshot requested, ok=" .. tostring(ok) .. "\n")
    end)
end

---------------------------------------------------------------------------
-- ESP self-test
---------------------------------------------------------------------------
-- Proves the three reported faults are actually fixed, in the running game:
--   A) a dead enemy leaves the list (corpses used to linger, because a ragdoll
--      is still a valid actor)
--   B) the display recovers by itself after the game hides it or wipes its text
--      (this used to stay broken until the round ended)
-- Runs as a small state machine across ticks, because both need real time to
-- pass before the result means anything.

PlayerMods.espTest = "not run"
local espPhase, espWait, espBefore, espResultA = 0, 0, 0, nil

function PlayerMods.StartESPTest()
    if #PlayerMods.esp == 0 and #watched == 0 then
        PlayerMods.espTest = "FAIL - no enemies tracked; spawn some first"
        print("[ModMenu] ESPTEST: " .. PlayerMods.espTest .. "\n")
        return
    end
    espPhase, espWait, espResultA = 1, 0, nil
    PlayerMods.espTest = "running..."
end

function PlayerMods.ESPTestTick(GUI)
    if espPhase == 0 then return end
    if espWait > 0 then espWait = espWait - 1 return end

    if espPhase == 1 then
        -- Compare the TOTAL tracked count, not #esp: the ESP list is capped at
        -- ESP_ROWS, so with more enemies than rows killing one changes nothing
        -- visible and the test would report a false failure.
        espBefore = PlayerMods.info.enemies or 0
        local killed = false
        for _, entry in ipairs(watched) do
            local flag = DEAD_FLAG[entry.cls]
            if flag and isValid(entry.obj) then
                pcall(function() entry.obj[flag] = true end)
                killed = true
                break
            end
        end
        if not killed then
            PlayerMods.espTest = "SKIP - no watched enemy to mark dead"
            espPhase = 0
            return
        end
        -- long enough for the 2 s EnemyTick, which is what updates the count
        espPhase, espWait = 2, 35

    elseif espPhase == 2 then
        local after = PlayerMods.info.enemies or 0
        espResultA = (after < espBefore)
            and string.format("dead body removed (%d->%d)", espBefore, after)
            or  string.format("FAIL corpse still listed (%d->%d)", espBefore, after)
        -- now simulate the game hiding our text / wiping it
        if GUI and GUI.SabotageDisplay then pcall(GUI.SabotageDisplay) end
        espPhase, espWait = 3, 40      -- longer than the ~2 s re-assert

    elseif espPhase == 3 then
        local hidden, hasText = nil, nil
        if GUI and GUI.DisplayState then hidden, hasText = GUI.DisplayState() end
        local recovered = (hidden == false) and (hasText == true)
        PlayerMods.espTest = string.format("%s | %s | display %s",
            (espResultA and not string.find(espResultA, "FAIL")) and "PASS" or "FAIL",
            tostring(espResultA),
            recovered and "recovered by itself" or
                ("FAIL still hidden=" .. tostring(hidden) .. " text=" .. tostring(hasText)))
        if not recovered then
            PlayerMods.espTest = "FAIL | " .. tostring(espResultA) ..
                                 " | display did NOT recover"
        end
        print("[ModMenu] ESPTEST: " .. PlayerMods.espTest .. "\n")
        espPhase = 0
    end
end

-- Full ESP re-link, usable mid-round. Everything the mod caches about the
-- player, the display and the tracked enemies is thrown away and rebuilt, so a
-- stale pawn, a swapped text component or a registry full of dead references all
-- clear without leaving the round or restarting the game.
function PlayerMods.RestartESP(GUI)
    watched = {}
    settledActors = {}
    PlayerMods.esp = {}
    PlayerMods.info.enemies = 0

    -- forget the pawn so it is looked up fresh
    PlayerMods.DropCaches()

    -- REATTACH TO THE NEW BODY.
    --
    -- DropCaches alone was not enough. After a respawn the old pawn is still in
    -- the object array and still reports IsValid(), so the very next lookup
    -- could hand back the corpse again - which is exactly why pressing Restart
    -- left the ESP stuck where it died. Drop the cached CONTROLLER too, then ask
    -- the controller which pawn it is possessing right now and adopt that one.
    PlayerMods.DropController()
    PlayerMods.lastEnemy, PlayerMods.lastEnemyClass = nil, nil

    ExecuteInGameThread(function()
        local pawn, kind = PlayerMods.GetPawn()
        PlayerMods.reattached = isValid(pawn) and (kind or "?") or "none"
        -- God Mode re-asserts itself on the body we just adopted, so it never
        -- keeps protecting the corpse while the live body takes hits.
        if isValid(pawn) then
            PlayerMods.FastTick()
        end
        print("[ModMenu] reattached to body: " ..
              tostring(PlayerMods.reattached) .. "\n")
    end)

    -- forget the display caches so the component is re-styled and re-written
    if GUI and GUI.DropCaches then pcall(GUI.DropCaches) end

    -- Re-arm anything that never bound. Do NOT clear watchRegistered: a hook
    -- lives on the UFunction and survives level changes, so re-registering an
    -- already-bound one stops it firing - which silently killed enemy tracking
    -- after a restart. The registration guards stay, and only targets that never
    -- took are retried.
    pcall(PlayerMods.RegisterEnemyWatch)
    PlayerMods.hooksBound = false
    pcall(PlayerMods.EnsureHooks)

        PlayerMods.espRestarts = (PlayerMods.espRestarts or 0) + 1
    print("[ModMenu] ESP restarted (" .. PlayerMods.espRestarts ..
          ") - pawn, display and enemy list rebuilt\n")
end

-- Travel to a map by path, so Raid Mode can be entered and tested without a
-- headset. e.g. /Game/Maps/Raid/Levels/V3/Map_Raid_lvl1
function PlayerMods.LoadMap(mapPath)
    if type(mapPath) ~= "string" or mapPath == "" then return end
    ExecuteInGameThread(function()
        local pawn = PlayerMods.GetPawn()
        if not isValid(pawn) then
            print("[ModMenu] loadmap: no pawn\n")
            return
        end
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not isValid(ksl) then return end
        print("[ModMenu] travelling to " .. mapPath .. "\n")
        pcall(function()
            ksl:ExecuteConsoleCommand(pawn, "open " .. mapPath, nil)
        end)
    end)
end

function PlayerMods.SetTimeScale(scale)
    PlayerMods.state.TimeScale = scale
    ExecuteInGameThread(function()
        pcall(function()
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if not isValid(gs) then return end
            local pawn = PlayerMods.GetPawn()
            if isValid(pawn) then gs:SetGlobalTimeDilation(pawn, scale) end
        end)
    end)
end

return PlayerMods
