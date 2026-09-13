-- Blood Trail Mod Menu - entry point
--
-- Game:   Blood Trail (BTVR), Unreal Engine 4.27
-- Loader: UE4SS 3.0.1
--
-- Keys are registered as raw Windows virtual-key codes rather than UE4SS's Key
-- enum: the enum names differ between builds and a wrong name fails silently,
-- while the VK numbers are stable.
--
-- F5 and F1 are deliberately NOT used - UE4SS itself owns those
-- (ToggleGUIHotkey / ToggleConsoleHotkey in UE4SS-settings.ini).

-- BREADCRUMB (temporary): the mod stopped producing status.txt at all, so
-- record how far load gets. Written straight to disk so it survives a crash.
local function bc(tag, reset)
    pcall(function()
        local f = io.open("D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/breadcrumb.txt",
                          reset and "w" or "a")
        if f then f:write(tostring(tag) .. "\n") f:close() end
    end)
end
bc("00-main-entered", true)   -- truncates, so it never grows

-- Fires each tag only once, so it can be dropped into the 10 Hz loop without
-- hammering the disk. Pinpoints which call in a status build takes the game out.
local bcSeen = {}
local function bcOnce(tag)
    if bcSeen[tag] then return end
    bcSeen[tag] = true
    bc(tag)
end


local okPlayer,  PlayerMods  = pcall(require, "player_mods")
local okSpawner, SpawnerMods = pcall(require, "spawner_mods")
local okGUI,     GUI         = pcall(require, "gui")
local okIPC,     IPC         = pcall(require, "ipc")
bc("01-requires-done p=" .. tostring(okPlayer) .. " s=" .. tostring(okSpawner) .. " g=" .. tostring(okGUI))

if not (okPlayer and okSpawner and okGUI) then
    print("[BloodTrail ModMenu] FAILED to load modules:\n")
    if not okPlayer  then print("  player_mods  : " .. tostring(PlayerMods)  .. "\n") end
    if not okSpawner then print("  spawner_mods : " .. tostring(SpawnerMods) .. "\n") end
    if not okGUI     then print("  gui          : " .. tostring(GUI)         .. "\n") end
    return
end

-- the spawner needs the schema guard to decide what is safe to touch after a spawn
SpawnerMods.PlayerMods = PlayerMods
-- the enemy scan needs asset paths to check a class is loaded before enumerating
PlayerMods.SpawnerMods = SpawnerMods

bc("02-before-gui-build")
GUI.Build(PlayerMods, SpawnerMods)
bc("03-gui-built")

-- the B button hook lives in player_mods, which cannot see GUI
PlayerMods.ToggleMenu = function() GUI.Toggle() end
-- the trigger hooks live in player_mods, which cannot see GUI
PlayerMods.PointerClick = function(useLeft) return GUI.PointerClick(useLeft) end
PlayerMods.MenuIsOpen   = function() return GUI.IsOpen == true end
PlayerMods.PointerCalibrate = function() return GUI.CalibratePointer(GUI.pointer.hand) end

---------------------------------------------------------------------------
-- one-shot commands, shared by the in-game menu and the desktop app
---------------------------------------------------------------------------

local function dispatch(action, arg)
    if     action == "spawn"       then SpawnerMods.SpawnByClassName(arg, PlayerMods.GetPawn, 1)
    elseif action == "spawnmany"   then
        local name, count = string.match(arg, "^(.-)|(%d+)$")
        SpawnerMods.SpawnByClassName(name or arg, PlayerMods.GetPawn, tonumber(count) or 1)
    elseif action == "spawncat"    then
        local idx = tonumber(arg)
        if idx then SpawnerMods.SpawnWholeCategory(idx, PlayerMods.GetPawn, 40) end
    elseif action == "heal"        then PlayerMods.HealNow()
    elseif action == "refill"      then PlayerMods.RefillNow()
    elseif action == "killall"     then PlayerMods.KillAllEnemies()
    elseif action == "unlock"      then PlayerMods.UnlockAll()
    elseif action == "fixaudio"    then PlayerMods.FixAudio()
    elseif action == "calibptr"    then GUI.CalibratePointer(GUI.pointer.hand)
    -- one-shot diagnostics: the heavy engine walks, run only when asked
    elseif action == "diag"        then
        local parts = {}
        for _, fn in ipairs({ "TextCompsReport", "MaterialReport", "PanelAngleReport",
                              "BeamProbeReport", "SocketProbeReport" }) do
            if GUI[fn] then
                local ok, v = pcall(GUI[fn])
                parts[#parts + 1] = fn .. "=" .. tostring(ok and v or "err")
            end
        end
        PlayerMods.diagOut = table.concat(parts, " | ")
    elseif action == "headlamp"    then PlayerMods.ToggleHeadlamp()
    elseif action == "nightvision" then PlayerMods.ToggleNightVision()
    elseif action == "timescale"   then PlayerMods.SetTimeScale(tonumber(arg) or 1.0)
    elseif action == "menu"        then GUI.Toggle()
    -- fires the pointer click without a trigger, so the click path can be
    -- exercised from the desktop while the controllers sit idle
    elseif action == "pointerclick" then GUI.PointerClick(GUI.pointer.hand)
    -- drives the in-game menu from the desktop, so the VR-side write path can
    -- be exercised without a controller
    elseif action == "menuactivate" then GUI.Activate()
    elseif action == "menunav"      then GUI.Nav(tonumber(arg) or 1)
    elseif action == "menupage"     then GUI.PageChange(tonumber(arg) or 1)
    elseif action == "godtest"     then PlayerMods.GodModeSelfTest()
    elseif action == "shot"        then PlayerMods.Screenshot()
    elseif action == "esptest"     then PlayerMods.StartESPTest()
    elseif action == "loadmap"     then PlayerMods.LoadMap(arg)
    elseif action == "espreset"    then PlayerMods.RestartESP(GUI)
    elseif action == "meleetest"   then PlayerMods.StartMeleeTest()
    elseif action == "fisttest"    then PlayerMods.StartFistTest()
    elseif action == "grabtest"    then PlayerMods.StartGrabTest()
    elseif action == "lamptest"    then PlayerMods.StartLampTest()
    elseif action == "jumptest"    then PlayerMods.StartJumpTest()
    else print("[ModMenu] unknown action: " .. tostring(action) .. "\n") end
end

---------------------------------------------------------------------------
-- keybinds
---------------------------------------------------------------------------

local VK = {
    INSERT = 0x2D, UP = 0x26, DOWN = 0x28, LEFT = 0x25, RIGHT = 0x27,
    RETURN = 0x0D, PAGEUP = 0x21, PAGEDOWN = 0x22, BACKSPACE = 0x08,
    NUMPAD0 = 0x60, END = 0x23,
}

-- A held key repeats, which would flip a toggle straight back off. Debounce
-- against the loop's tick counter instead of a clock, so we do not depend on
-- os.clock semantics inside the UE4SS Lua runtime. 1 tick = 100 ms.
local tickCount = 0
local lastFire = {}

local function bind(vk, name, fn, minTicks)
    if not RegisterKeyBind then return end
    minTicks = minTicks or 2
    pcall(function()
        RegisterKeyBind(vk, function()
            local last = lastFire[name]
            if last and (tickCount - last) < minTicks then return end
            lastFire[name] = tickCount
            pcall(fn)
        end)
    end)
end

bind(VK.INSERT,    "toggle",  function() GUI.Toggle() end)
bind(VK.NUMPAD0,   "toggle2", function() GUI.Toggle() end)
bind(VK.UP,        "up",      function() GUI.Nav(-1) end, 1)
bind(VK.DOWN,      "down",    function() GUI.Nav(1)  end, 1)
bind(VK.LEFT,      "left",    function() GUI.Adjust(-1) end, 1)
bind(VK.RIGHT,     "right",   function() GUI.Adjust(1)  end, 1)
bind(VK.RETURN,    "enter",   function() GUI.Activate() end)
bind(VK.PAGEUP,    "pgup",    function() GUI.PageChange(-1) end)
bind(VK.PAGEDOWN,  "pgdn",    function() GUI.PageChange(1)  end)
bind(VK.BACKSPACE, "back",    function() GUI.Back() end)
-- END re-links the ESP mid-round without touching the menu, so it can be hit
-- during combat the moment the overlay stops updating
bind(VK.END,       "espreset", function() PlayerMods.RestartESP(GUI) end)

---------------------------------------------------------------------------
-- hooks
---------------------------------------------------------------------------

-- First attempt. These usually fail this early because the player's blueprint
-- class is not loaded yet; the loop retries via EnsureHooks until they bind.
pcall(function() PlayerMods.LoadPointerCal() end)
bc("04-before-hooks")
pcall(function() PlayerMods.RegisterAmmoHooks() end)
pcall(function() PlayerMods.RegisterDamageHooks() end)
-- lets the ESP see zombies/NPCs without ever enumerating them
pcall(function() PlayerMods.RegisterEnemyWatch() end)
bc("05-hooks-done")

---------------------------------------------------------------------------
-- main loop
---------------------------------------------------------------------------

-- Everything cached from the engine dies on level travel, and walking the object
-- array while a level tears down reads half-destroyed objects. So track the
-- world address, drop caches when it changes, and refuse to SCAN until it has
-- been stable for a couple of seconds.
--
-- The per-pawn work (FastTick) is deliberately NOT behind that gate. It only
-- touches the one cached pawn and never enumerates objects, and gating it was
-- what broke God Mode: worldAddress() returns nil whenever the pawn is missing
-- or GetWorld() throws, so the address flickered, settledTicks reset on almost
-- every tick, and the god-mode write never ran at all.
local lastWorldAddr = nil
local settledTicks = 0

local function worldAddress()
    local pawn = PlayerMods.GetPawn()
    if not pawn then return nil end
    local ok, addr = pcall(function() return pawn:GetWorld():GetAddress() end)
    if ok then return addr end
    return nil
end

-- 10 Hz. An earlier build ran this at 30 Hz and the game crashed three times in
-- five minutes; the pawn writes gain nothing from the extra rate (God Mode is a
-- flag, not a race) and everything the loop touches gets three times cheaper.
---------------------------------------------------------------------------
-- cost measurement
---------------------------------------------------------------------------
-- Which part of the loop is expensive is not guessable - the sweeps, the file
-- bridge and the per-tick property writes all look plausible. Time them and
-- publish the totals, so "the game is lagging" can be answered with numbers.

local cost = { fast = 0, scan = 0, enemy = 0, esp = 0, ipc = 0, gui = 0,
               world = 0, status = 0, fist = 0 }
local costWindowStart = os.clock()
PlayerMods.costReport = "measuring..."

local function timed(bucket, fn, ...)
    local t0 = os.clock()
    local ok, err = pcall(fn, ...)
    cost[bucket] = cost[bucket] + (os.clock() - t0)
    return ok, err
end

local function reportCost()
    local elapsed = os.clock() - costWindowStart
    if elapsed <= 0 then return end
    -- percentage of wall time each section consumed
    local function pct(v) return (v / elapsed) * 100.0 end
    PlayerMods.costReport = string.format(
        "fast=%.1f%% scan=%.1f%% enemy=%.1f%% esp=%.1f%% ipc=%.1f%% status=%.1f%% gui=%.1f%% world=%.1f%% total=%.1f%%",
        pct(cost.fast), pct(cost.scan), pct(cost.enemy), pct(cost.esp),
        pct(cost.ipc), pct(cost.status), pct(cost.gui), pct(cost.world),
        pct(cost.fast + cost.scan + cost.enemy + cost.esp + cost.ipc
            + cost.status + cost.gui + cost.world))
    for k in pairs(cost) do cost[k] = 0 end
    costWindowStart = os.clock()
end

local TICK_MS      = 100
-- Weapon/mag sweep. Measured at 5.5% of wall time when it ran every 500 ms:
-- each sweep walks the whole UObject array four times, ~27 ms a go, twice a
-- second. That is the single most expensive thing the mod does and it showed up
-- as stutter. The fire hooks already top up the weapon you are actually using
-- on every shot, so this sweep only needs to catch guns you have just picked up
-- - 2 s is plenty, and it is 4x cheaper.
local SCAN_EVERY   = 20   -- ~2 s      weapons/mags
local ENEMY_EVERY  = 20   -- ~2 s      enemy freeze + counter
local WORLD_EVERY  = 5    -- ~500 ms   world-change check
local IPC_EVERY    = 3    -- ~300 ms
-- 1 Hz is plenty for a status read-out and halves the file-write cost.
local STATUS_EVERY = 10   -- ~1 s

if LoopAsync then
    LoopAsync(TICK_MS, function()
        tickCount = tickCount + 1
        -- lets the enemy sweep be shared by everything running on this tick
        PlayerMods.tickStamp = tickCount

        -- god mode and friends: every tick, no gate
        -- must run before anything reads the toggles
        timed("fast", PlayerMods.SafeModeTick)
        timed("fast", PlayerMods.FastTick)
        -- pawn-only: flight, noclip and crouch
        timed("fast", PlayerMods.FlightTick)
        -- console gamma, only re-issued when the value changes
        timed("fast", PlayerMods.BrightnessTick)
        pcall(function() PlayerMods.ESPTestTick(GUI) end)

        -- keep trying to bind the damage hooks until they take (twice a second)
        if tickCount % 5 == 0 then
            pcall(PlayerMods.EnsureHooks)
        end
        -- the zombie blueprints load lazily, so keep re-arming the enemy watch
        if tickCount % 30 == 0 then
            pcall(PlayerMods.EnsureEnemyWatch)
        end

        -- Checking the world means calling GetWorld() on the pawn; no need to
        -- do that 10 times a second.
        if tickCount % WORLD_EVERY == 0 then
            local wt0 = os.clock()
            local addr = worldAddress()
            cost.world = cost.world + (os.clock() - wt0)
            if addr == nil then
                -- Round end: the pawn is destroyed before the next world
                -- exists. Slam the gate shut and drop every cached actor NOW,
                -- rather than waiting for a new world to appear - the ticks in
                -- between are what were touching dead actors and crashing.
                settledTicks = 0
                if lastWorldAddr ~= nil then
                    lastWorldAddr = nil
                    PlayerMods.DropCaches()
                    SpawnerMods.DropCaches()
                    GUI.DropCaches()
                end
            elseif addr ~= lastWorldAddr then
                lastWorldAddr = addr
                settledTicks = 0
                PlayerMods.DropCaches()
                SpawnerMods.DropCaches()
                GUI.DropCaches()
            else
                settledTicks = settledTicks + WORLD_EVERY
            end
        end

        -- object-array work only once the world has held still for ~2 s
        if settledTicks > 20 then
            -- RagdollTick is NOT scheduled here any more. It touches enemy
            -- structs, so it runs inside HitWatchTick, right after the sweep
            -- that proved those actors are still alive.
            -- ~3 Hz: catches a body losing health and throws it, whatever hit it
            if tickCount % 4 == 0 then
                timed("enemy", PlayerMods.HitWatchTick)
            end
            if tickCount % SCAN_EVERY == 0 then
                timed("scan", PlayerMods.ScanTick)
                -- keeps both hands at weapon-grade StrikePower
                timed("fist", PlayerMods.FistTick)
                -- arms every melee weapon in the world
                timed("fist", PlayerMods.MeleeWeaponTick)
            end
            if tickCount % ENEMY_EVERY == 0 then
                timed("enemy", PlayerMods.EnemyTick)
            end
            -- ESP needs to be fresher than the 2 s enemy tick, but it still
            -- walks the object array, so 3 Hz is the compromise.
            -- 2 Hz: this now walks the object array once per enemy class, so it
            -- must not run as often as it used to
            if PlayerMods.state.EnemyESP and (tickCount % 5 == 0) then
                timed("esp", PlayerMods.ScanESP)
                GUI.MarkDirty()
            end
        end

        if okIPC and (tickCount % IPC_EVERY == 0) then
            timed("ipc", function() IPC.Poll(PlayerMods.state, dispatch) end)
        end

        if tickCount % STATUS_EVERY == 0 then
            GUI.MarkDirty()
            if okIPC then
                local i = PlayerMods.info
                local st0 = os.clock()
                pcall(function()
                    -- Tell the app which toggles cannot do anything on the pawn
                    -- that is currently live, so it can grey them out.
                    local na = {}
                    for key, v in pairs(PlayerMods.state) do
                        if type(v) == "boolean" and not PlayerMods.Applies(key) then
                            na[#na + 1] = key
                        end
                    end
                    table.sort(na)

                    -- Publish the mod's OWN state so the desktop app can echo
                    -- it. Now that control.txt is edge-triggered, the app's
                    -- widgets must track changes made from inside VR - otherwise
                    -- the next click in the app sends a stale value, which IS a
                    -- change, and silently undoes what the player just did.
                    local fields = {
                        { "alive",     1 },
                        { "tick",      tickCount },
                        { "pawn",      i.pawn or "none" },
                        { "health",    math.floor(tonumber(i.health) or 0) },
                        { "healthmax", math.floor(tonumber(i.healthmax) or 0) },
                        { "kills",     i.kills or 0 },
                        { "enemies",   i.enemies or 0 },
                        { "menu",      GUI.IsOpen and 1 or 0 },
                        { "na",        table.concat(na, ",") },
                        -- how many god-mode damage hooks actually bound; if this
                        -- is 0, God Mode cannot possibly work and that is the
                        -- first thing to look at
                        { "dmghooks",  PlayerMods.damageHooks or 0 },
                        { "godhits",   PlayerMods.damageBlocked or 0 },
                        { "pawnsrc",   PlayerMods.pawnSource or "none" },
                        { "meleehooks", PlayerMods.meleeHooks or 0 },
                        -- one shared punch hook serves both features
                        { "fisthooks",  PlayerMods.meleeHooks or 0 },
                        { "fisthits",   PlayerMods.fistHits or 0 },
                        { "handspowered", PlayerMods.handsPowered or 0 },
                        { "weaponsarmed", PlayerMods.weaponsArmed or 0 },
                        { "ragdolls",    PlayerMods.ragdolls or 0 },
                        { "reachset",    PlayerMods.reachSet or 0 },
                        { "grabs",       PlayerMods.grabs or 0 },
                        { "throws",      PlayerMods.throws or 0 },
                        { "held",        PlayerMods.HeldCount and PlayerMods.HeldCount() or 0 },
                        { "grabtest",    PlayerMods.grabTest or "not run" },
                        { "vecmode",     PlayerMods.vecMode or "untested" },
                        { "lampstate",   PlayerMods.LampState and PlayerMods.LampState() or "n/a" },
                        { "lamptest",    PlayerMods.lampTest or "not run" },
                        { "flying",      PlayerMods.flying or 0 },
                        { "flings",      PlayerMods.flings or 0 },
                        { "roundends",   PlayerMods.roundEnds or 0 },
                        { "flingwhy",    PlayerMods.flingWhy or "not tried" },
                        { "flystate",    PlayerMods.flyState or "off" },
                        { "looksrc",     PlayerMods.lookSrc or "n/a" },
                        { "lookpitch",   string.format("%.2f", PlayerMods.lookPitch or 0) },
                        { "recoilevents", PlayerMods.recoilEvents or 0 },
                        { "recoilseen",  PlayerMods.recoilSeen or "no shot yet" },
                        { "recoilarg",   PlayerMods.recoilArgSeen or "no arg seen" },
                        { "recoilkilled", PlayerMods.recoilArgKilled or 0 },
                        { "crouchoffset", string.format("%.1f", PlayerMods.crouchOffsetZ or 0) },
                        -- the panel reads this back instead of pushing its own copy,
                        -- so a right-stick crouch is not undone a second later
                        { "crouchdown", PlayerMods.state.CrouchDown and "1" or "0" },
                        { "menutrack", GUI.TrackReport and GUI.TrackReport() or "n/a" },
                        { "pointer", GUI.PointerReport and GUI.PointerReport() or "n/a" },
                        { "audio", PlayerMods.AudioReport and PlayerMods.AudioReport() or "n/a" },
                        { "audiofixes", PlayerMods.audioFixes or 0 },
                        { "panelstyle", GUI.PanelStyleReport and GUI.PanelStyleReport() or "n/a" },
                        { "selection", GUI.SelectionReport and GUI.SelectionReport() or "n/a" },
                        { "flymode", PlayerMods.state.FlyMode and "1" or "0" },
                        { "noclip",  PlayerMods.state.NoClip  and "1" or "0" },
                        { "stick",       PlayerMods.StickState and PlayerMods.StickState() or "n/a" },
                        { "inputhooks",  PlayerMods.inputHooks or 0 },
                        { "crouchtoggles", PlayerMods.crouchToggles or 0 },
                        { "flytoggles",  PlayerMods.flyToggles or 0 },
                        { "cliptoggles", PlayerMods.clipToggles or 0 },
                        { "menutoggles", PlayerMods.menuToggles or 0 },
                        { "jumps",       PlayerMods.jumps or 0 },
                        { "jumptest",    PlayerMods.jumpTest or "not run" },
                        { "dormant",     tostring(PlayerMods.dormant == true) },
                        { "safemode",    tostring(PlayerMods.safeMode == true) },
                        { "dormancies",  PlayerMods.dormancies or 0 },
                        { "crouchapplied", PlayerMods.crouchApplied or 0 },
                        { "crouchforced", PlayerMods.crouchForced or 0 },
                        { "brightness",  PlayerMods.brightState or "off" },
                        { "recoilzeroed", PlayerMods.recoilZeroed or 0 },
                        { "movestate",   PlayerMods.moveState or "n/a" },
                        { "livecount",   PlayerMods.LiveCount and PlayerMods.LiveCount() or 0 },
                        { "throws",      PlayerMods.throws or 0 },
                        { "throwhands",  PlayerMods.lastThrowHands or 0 },
                        { "fisttest",   PlayerMods.fistTest or "not run" },
                        { "lastactionerr", (okIPC and IPC.lastError) or "none" },
                        { "lastaction", (okIPC and IPC.lastAction) or "none" },
                        { "seqseen",    (okIPC and IPC.seenSeq) or "none" },
                        { "meleehits",  PlayerMods.meleeHits or 0 },
                        { "meleetest",  PlayerMods.meleeTest or "not run" },
                        { "rechambers", PlayerMods.rechambers or 0 },
                        { "gunstate",  PlayerMods.GunState and PlayerMods.GunState() or "n/a" },
                        { "esprestarts", PlayerMods.espRestarts or 0 },
                        { "godtest",   PlayerMods.testResult or "not run" },
                        { "esptest",   PlayerMods.espTest or "not run" },
                        { "hookerr",   PlayerMods.lastHookError or "" },
                        { "cost",      PlayerMods.costReport or "" },
                        { "shothooks", PlayerMods.gunHookCalls or 0 },
                        -- ESP diagnostics: panel=1 means the in-headset text
                        -- actor exists, esp=N is how many enemies it is tracking
                        { "panel",     GUI.panelReady and 1 or 0 },
                        { "panelgeom", GUI.panelGeom or "unknown" },
                        { "esp",       #(PlayerMods.esp or {}) },
                        -- watchhits = times the BeginPlay hook fired.
                        -- If this climbs but "enemies" stays 0, the filter is
                        -- dropping them; if it does not climb, the hook is dead.
                        { "watchhits", PlayerMods.watchCount or 0 },
                        { "watchlist", PlayerMods.WatchListSize and PlayerMods.WatchListSize() or -1 },
                    }
                    for k, v in pairs(PlayerMods.state) do
                        local t = type(v)
                        if t == "boolean" then
                            fields[#fields + 1] = { "st_" .. string.lower(k), v and "1" or "0" }
                        elseif t == "number" then
                            fields[#fields + 1] = { "st_" .. string.lower(k), tostring(v) }
                        end
                    end
                    IPC.WriteStatus(fields)
                end)
                cost.status = cost.status + (os.clock() - st0)
            end
        end

        timed("gui", GUI.Tick)

        -- publish the cost breakdown once every 10 s
        if tickCount % 100 == 0 then reportCost() end

        return false -- keep looping
    end)
end

print("[BloodTrail ModMenu] loaded.\n")
print("[BloodTrail ModMenu] INSERT (or Numpad 0) opens the in-game menu.\n")
print("[BloodTrail ModMenu] Arrows move/change, ENTER uses, PGUP/PGDN page, BACKSPACE back.\n")
if okIPC and IPC.available then
    print("[BloodTrail ModMenu] desktop app bridge ready.\n")
else
    print("[BloodTrail ModMenu] desktop app bridge unavailable (no io library).\n")
end
