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

-- Which build is actually loaded. After an update the first question is
-- always "did it take?", and comparing file dates is a poor way to answer
-- it - especially when the game was running while the files were copied.
MOD_BUILD = "2026-09-27"

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

-- A HOOK IS ONLY ASKED FOR WHEN ITS FUNCTION EXISTS (2026-10-11).
--
-- UE4SS's RegisterHook makes a new Lua state BEFORE it looks the function up
-- (UE4SS.dll+0x37338c, then the lookup at +0x373493), and keeps it for good:
-- an attempt on a blueprint that is not loaded yet returns nothing - and still
-- adds to the table of Lua states that every call into the game looks itself
-- up in. The mod retries its missing hooks every half second; each retry grew
-- that table, and when it outgrows its buckets it rebuilds them while other
-- threads read it (11 October 05:44 and 05:56, process_lua_function).
-- StaticFindObject makes nothing. Hooks are bound on the game thread (the
-- bind-hooks job) and at start-up, before the loop runs.
if RegisterHook and StaticFindObject then
    local realRegisterHook = RegisterHook
    RegisterHook = function(target, ...)
        local ok, fn = pcall(StaticFindObject, target)
        local there = false
        if ok and fn then
            local okV, v = pcall(function() return fn:IsValid() end)
            there = okV and v == true
        end
        if not there then
            if okPlayer then PlayerMods.hookSkips = (PlayerMods.hookSkips or 0) + 1 end
            return nil
        end
        if okPlayer then PlayerMods.hookCalls = (PlayerMods.hookCalls or 0) + 1 end
        return realRegisterHook(target, ...)
    end
end

-- Added 2026-09-17. Each is optional: a module that fails to load leaves its
-- tab reading "not loaded" and the rest of the mod exactly as it was.
local okOpt,     Opt         = pcall(require, "optimizer")
local okMusic,   Music       = pcall(require, "music")
local okESP,     ESPPlus     = pcall(require, "esp_plus")
local okAim,     AimAssist   = pcall(require, "aim_assist")
bc("01b-new-modules opt=" .. tostring(okOpt) .. " music=" .. tostring(okMusic) ..
   " esp=" .. tostring(okESP) .. " aim=" .. tostring(okAim))
for name, pair in pairs({ optimizer = { okOpt, Opt }, music = { okMusic, Music },
                          esp_plus = { okESP, ESPPlus }, aim_assist = { okAim, AimAssist } }) do
    if not pair[1] then
        print("[BloodTrail ModMenu] module " .. name .. " failed to load: " .. tostring(pair[2]) .. "\n")
    end
end

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

if okOpt   then Opt.Init(PlayerMods)          PlayerMods.OptMod   = Opt       end
-- the optimizer's engine objects are found on the game thread, never the loop's
if okOpt and Opt.Warm then pcall(Opt.Warm) end
if okMusic then Music.Init(PlayerMods)        PlayerMods.MusicMod = Music     end
if okESP   then ESPPlus.Init(PlayerMods)      PlayerMods.ESPMod   = ESPPlus   end
if okAim and okESP then AimAssist.Init(PlayerMods, ESPPlus) PlayerMods.AimMod = AimAssist end
-- AFTER Init, because that is what hands aim_assist its PlayerMods - reading
-- the saved alignments before it just threw, silently, inside a pcall.
if okAim and AimAssist.LoadAlign then pcall(AimAssist.LoadAlign) end
okAim = okAim and okESP      -- aim assist predicts positions with esp_plus
PlayerMods.DIR = okIPC and IPC.DIR or nil

---------------------------------------------------------------------------
-- KEEP THE LAST SESSION'S EVIDENCE (2026-09-20)
---------------------------------------------------------------------------
-- 20 September, and this cost a real answer. The game crashed changing map at
-- 00:28. The next session started at 00:29 and froze at 00:35 for a DIFFERENT
-- reason. By the time anyone looked, status.txt and lastop.txt held the second
-- session's story and the first one's was gone - so the crash's own note, the
-- one thing written specifically to answer "what was in flight", had to be
-- inferred instead of read.
--
-- Both files are rewritten from scratch every launch. So copy them aside once,
-- at boot, before anything touches them, and append one line per launch to a
-- log that is never truncated. Next time there are two bad sessions in a row,
-- both are still on disk.
local function keepLastSession(dir)
    if not dir then return end
    local function carry(from, to)
        local f = io.open(dir .. from, "r")
        if not f then return nil end
        local body = f:read("*a")
        f:close()
        local g = io.open(dir .. to, "w")
        if g then g:write(body) g:close() end
        return body
    end
    local st = carry("status.txt", "status-prev.txt")
    local op = carry("lastop.txt", "lastop-prev.txt")
    -- ...and say it out loud, so the previous session's ending is the first
    -- thing on the page rather than something to go and find on disk.
    if st or op then
        PlayerMods.prevSession = string.format("tick=%s lastop=%s",
            st and (st:match("tick=(%d+)") or "?") or "?",
            op and (op:match("^([^\r\n]*)") or "?") or "?")
    else
        PlayerMods.prevSession = "none - this is a first run"
    end
    -- saves.lua calls os.date through a pcall in both the places it uses it,
    -- which is a fair warning. The copies above have already happened by the
    -- time we get here, but the log line is worth keeping even when the clock
    -- will not format.
    local okDate, when = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if not (okDate and type(when) == "string") then when = "time unknown" end
    local g = io.open(dir .. "sessions.txt", "a")
    if g then
        g:write(string.format(
            "%s  started.  previous session: tick=%s lastop=%s\n", when,
            st and (st:match("tick=(%d+)") or "?") or "none",
            op and (op:match("^([^\r\n]*)") or "?") or "none"))
        g:close()
    end
end
pcall(keepLastSession, PlayerMods.DIR)
if okIPC and okMusic then
    IPC.onControl = function(kv)
        Music.FromControl(kv)
        -- The app looks the graphics card up in Windows and sends the name.
        -- The game cannot ask Windows itself without shelling out, and the
        -- OPT GPU page only needs it to tell you which upscaler to pick.
        if okOpt and kv.gpu ~= nil then
            local g = tostring(kv.gpu):gsub("[%c]", ""):sub(1, 48)
            if #g > 0 then Opt.gpuName = g end
        end
    end
    -- the launcher .bat sits next to control.txt
    Music.DIR = IPC.DIR
end

-- SAVES (2026-09-18): put your saved settings back BEFORE anything reads the
-- state, so every feature comes up already set. Init first - it remembers the
-- defaults for RESET.
local okSaves, Saves = pcall(require, "saves")
if okSaves then
    if okIPC then Saves.DIR = IPC.DIR end
    local okInit = pcall(Saves.Init, PlayerMods)
    local okLoad, savedAt = false, nil
    if okInit then okLoad, savedAt = pcall(Saves.LoadAtStart) end
    -- tells ipc.lua not to let a leftover control.txt undo the load
    if okLoad and savedAt and okIPC then IPC.startupSavedAt = savedAt end
    PlayerMods.SavesMod = Saves
    print("[BloodTrail ModMenu] saves: " .. tostring(Saves.loadNote) .. "\n")
else
    print("[BloodTrail ModMenu] module saves failed to load: " .. tostring(Saves) .. "\n")
end
bc("01c-saves ok=" .. tostring(okSaves) .. " source=" .. tostring(okSaves and Saves.source or "n/a"))

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
    elseif action == "beamsave"    then if okAim then pcall(AimAssist.SaveAlignForGun) end
    elseif action == "beamauto"    then if okAim then pcall(AimAssist.AutoAlignForGun) end
    elseif action == "beamreset"   then if okAim then pcall(AimAssist.ResetAlignForGun) end
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
    -- optimizer / ESP (2026-09-17)
    elseif action == "opt_apply"   then if okOpt then Opt.ApplyNow() end
    elseif action == "opt_reset"   then if okOpt then Opt.ResetNow() end
    -- the September DRAW TEST is gone (debug drawing is compiled out of this
    -- build); an old desktop app asking for it gets the screenshot instead
    elseif action == "drawtest" or action == "espshot" then
        if okESP then ESPPlus.Screenshot() else PlayerMods.Screenshot() end
    elseif action == "music_start" then if okMusic then Music.StartApp() end
    -- saves (the desktop app's Saves tab while the game is running)
    elseif action == "save_now"       then if okSaves then Saves.SaveNow() end
    elseif action == "load_saved"     then if okSaves then Saves.LoadSaved() end
    elseif action == "save_profile"   then if okSaves then Saves.SaveProfile(tonumber(arg)) end
    elseif action == "load_profile"   then if okSaves then Saves.LoadProfile(tonumber(arg)) end
    -- the app asks "are you sure" itself, so it arms and fires in one go
    elseif action == "reset_defaults" then
        if okSaves then Saves.ResetDefaults() Saves.ResetDefaults() end
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

-- A KEY PRESS ONLY COUNTS ITSELF (2026-10-11). UE4SS runs key callbacks on
-- a thread of its own; the menu work they used to do there put jobs in the
-- loop's outbox from outside the loop. Now the callback bumps a counter made
-- up front - one write, one writer - and the loop does the work on its next
-- tick, like everything else it does.
local keyPressed, keyDone, keyActions = {}, {}, {}

local function bind(vk, name, fn, minTicks)
    if not RegisterKeyBind then return end
    keyPressed[name] = 0
    keyDone[name] = 0
    keyActions[#keyActions + 1] = { name = name, fn = fn, minTicks = minTicks or 2 }
    pcall(function()
        RegisterKeyBind(vk, function()
            keyPressed[name] = keyPressed[name] + 1
        end)
    end)
end

-- ON THE LOOP THREAD: the keys pressed since the last tick, each once.
local function runKeys()
    for _, k in ipairs(keyActions) do
        local p = keyPressed[k.name]
        if p ~= keyDone[k.name] then
            keyDone[k.name] = p
            local last = lastFire[k.name]
            if not (last and (tickCount - last) < k.minTicks) then
                lastFire[k.name] = tickCount
                pcall(k.fn)
            end
        end
    end
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
-- NEVER RegisterLoadMapPreHook / RegisterLoadMapPostHook. In this UE4SS
-- (3.0.1) they crash the game at the very first map load, whatever the
-- callback does: UE4SS's LoadMap handler gets an error back from calling it
-- and throws a C++ exception nothing catches (0xe06d7363, std::runtime_error,
-- thrown from the function holding "A callback for 'LoadMap' must return
-- bool or nil") - twice in a row on 6 October, the second one a second
-- after the mod started.
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
-- consecutive checks where the pawn could not be reached; see the note
-- at the world check below for why one of them means nothing
local missingWorld = 0

local function worldAddress()
    local pawn = PlayerMods.GetPawn()
    if not pawn then return nil end
    -- The nil world is checked rather than thrown through. This used to be
    -- pawn:GetWorld():GetAddress() in one go, so a moment when the world is
    -- not answerable raised inside the pcall and was swallowed - harmless,
    -- but it filled the error record with something that is a normal state,
    -- and a real fault would have been lost in the noise.
    local ok, addr = pcall(function()
        local w = pawn:GetWorld()
        if not w then return nil end
        return w:GetAddress()
    end)
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
-- EVERY TICK, not every fifth (2026-09-20).
--
-- This number is how long the mod can keep working on a world that is already
-- gone, and 500 ms of that is what the map-change crash was made of: the beam
-- kept being aimed at guns from the old level. cost=...world= has measured
-- this check at 0.0% since it was added - it is one GetWorld() on the one
-- cached pawn, no object sweep - so there is nothing to buy by doing it less.
--
-- settledTicks still advances by WORLD_EVERY per check, so the "wait for the
-- world to settle" gate is unchanged at ~2 s either way.
local WORLD_EVERY  = 1    -- ~100 ms   world-change check
local IPC_EVERY    = 3    -- ~300 ms
-- 1 Hz is plenty for a status read-out and halves the file-write cost.
local STATUS_EVERY = 10   -- ~1 s

if LoopAsync then
    local function loopTick()
        tickCount = tickCount + 1
        -- lets the enemy sweep be shared by everything running on this tick
        PlayerMods.tickStamp = tickCount
        -- the keys pressed since the last tick
        runKeys()

        -- god mode and friends: every tick, no gate
        -- must run before anything reads the toggles
        timed("fast", PlayerMods.SafeModeTick)
        timed("fast", PlayerMods.FastTick)
        -- pawn-only: flight, noclip and crouch
        timed("fast", PlayerMods.FlightTick)
        -- console gamma, only re-issued when the value changes
        timed("fast", PlayerMods.BrightnessTick)
        -- FPS meter every tick; console settings only when something changed,
        -- and only once the world has settled
        if okOpt then timed("fast", Opt.Tick, settledTicks > 20) end
        if okAim then
            -- your position for "is this bullet mine", as numbers
            if tickCount % 2 == 0 then timed("fast", AimAssist.OriginTick) end
            -- (binds lazily, only once an aim feature is on - from the
            -- game thread, with the other hooks, below)
            -- forget shots whose POST never came, and put back any gun whose
            -- POST hook never arrived to straighten it
            pcall(AimAssist.PendingTick)
        end
        -- Reach beside your head to switch the lamp / night vision. Three
        -- position reads; no object-array work, so it needs no settle gate.
        if tickCount % 2 == 0 then timed("fast", PlayerMods.HeadTouchTick) end
        -- your settings, saved about every 2 s if (and only if) something changed
        if okSaves and (tickCount % 20 == 0) then pcall(Saves.AutoSaveTick) end
        if okMusic and (tickCount % 10 == 0) then
            -- starts the desktop player when the MUSIC tab needs it (this is
            -- the loop thread, so the short os.execute block costs no frames)
            pcall(Music.Tick)
            pcall(Music.DuckTick)
        end
        pcall(function() PlayerMods.ESPTestTick(GUI) end)

        -- HOOKS ARE BOUND FROM THE GAME THREAD (2026-10-05).
        --
        -- UE4SS's own crash dumps (27 and 28 September, 0xC0000264) have this
        -- loop thread inside RegisterHook while the game thread was inside a
        -- fire hook: two threads in UE4SS's hook table at once, and a lock
        -- released by the wrong one. So the retries - the mod's hooks twice a
        -- second until they take, the aim hooks likewise, the enemy watch
        -- every 3 s because the zombie blueprints load lazily - run as one
        -- job on the game thread, and only while something is left to bind.
        local watchDue = (tickCount % 30 == 0)
        local hooksDue = (tickCount % 5 == 0)
            and (PlayerMods.HooksPending() or (okAim and AimAssist.BindPending()))
        if watchDue or hooksDue then
            PlayerMods.InGameThread("bind-hooks", function()
                if hooksDue then
                    pcall(PlayerMods.EnsureHooks)
                    if okAim then pcall(AimAssist.EnsureBound) end
                end
                if watchDue then pcall(PlayerMods.EnsureEnemyWatch) end
            end)
        end

        -- Checking the world means calling GetWorld() on the pawn; no need to
        -- do that 10 times a second.
        if tickCount % WORLD_EVERY == 0 then
            local wt0 = os.clock()
            local addr = worldAddress()
            cost.world = cost.world + (os.clock() - wt0)
            -- every job made from here on is for this level
            if addr then PlayerMods.worldAddr = addr end
            if addr == nil then
                -- Round end: the pawn is destroyed before the next world
                -- exists. Slam the gate shut and drop every cached actor NOW,
                -- rather than waiting for a new world to appear - the ticks in
                -- between are what were touching dead actors and crashing.
                --
                -- BUT A SINGLE NIL IS NOT A ROUND END (2026-09-20).
                --
                -- worldAddress() returns nil whenever GetPawn() misses or
                -- GetWorld() throws, and the note at the top of this file
                -- records that the address FLICKERS - it is what broke God
                -- Mode when the per-pawn work was gated on it. This check
                -- moved from every fifth tick to every tick, which catches
                -- five times as many of those blips, and each one used to cost
                -- every cache plus two seconds of gate.
                --
                -- A real round end leaves the pawn missing for a long time; a
                -- blip is one tick. So a nil has to hold for three checks
                -- (~300 ms) before it counts. A world CHANGE is unambiguous -
                -- a different address - and is still acted on immediately.
                --
                -- (Written as a nested if rather than a goto. UE4SS 3.0.1
                -- ships Lua 5.4.4, so goto would be legal - but there is not
                -- one anywhere else in these 20,000 lines, and a construct
                -- whose first use is in the startup path of a mod that has to
                -- LOAD to report anything is not worth the saved indent.)
                missingWorld = missingWorld + 1
                if missingWorld >= 3 then
                    settledTicks = 0
                    if lastWorldAddr ~= nil then
                        lastWorldAddr = nil
                        PlayerMods.DropCaches()
                        SpawnerMods.DropCaches()
                        GUI.DropCaches()
                        if okOpt   then pcall(Opt.OnWorldChange) end
                        if okMusic then pcall(Music.OnWorldChange) end
                        if okAim   then pcall(AimAssist.OnWorldChange) end
                    end
                end
            elseif addr ~= lastWorldAddr then
                missingWorld = 0
                lastWorldAddr = addr
                -- WHICH MAP. Resolving a name means GetFName():ToString(),
                -- which allocates - so it happens exactly here, once per
                -- level, and never in a sweep. Without it "which guns did I
                -- shoot in the basement map" cannot be answered at all,
                -- because nothing wrote down where you were.
                pcall(function()
                    local pawn = PlayerMods.GetPawn()
                    if not pawn then return end
                    local w = pawn:GetWorld()
                    if not w then return end
                    local n = w:GetFName():ToString()
                    if n and n ~= "" then PlayerMods.mapName = n end
                end)
                settledTicks = 0
                PlayerMods.DropCaches()
                SpawnerMods.DropCaches()
                GUI.DropCaches()
                if okOpt   then pcall(Opt.OnWorldChange) end
                if okMusic then pcall(Music.OnWorldChange) end
                if okAim   then pcall(AimAssist.OnWorldChange) end
            else
                missingWorld = 0
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
                -- what the enemies' own AI is doing (see NpcAiSample)
                timed("enemy", PlayerMods.NpcAiTick)
            end
            -- ESP needs to be fresher than the 2 s enemy tick, but it still
            -- walks the object array, so 3 Hz is the compromise.
            -- 2 Hz: this now walks the object array once per enemy class, so it
            -- must not run as often as it used to
            -- Aim reads the same numbers-only target list, so the scan runs
            -- for either feature. Aiming needs fresher positions than the text
            -- does (a running zombie covers 2 m in half a second), so it goes
            -- to 5 Hz while Silent Aim or Aim Assist is on - on even ticks, so
            -- every other one shares the hit watch's sweep instead of adding one.
            local st = PlayerMods.state
            local aimOn = st.SilentAim or st.AimAssist
            if (st.EnemyESP or aimOn)
               and (tickCount % (aimOn and 2 or 5) == 0) then
                timed("esp", PlayerMods.ScanESP)
                GUI.MarkDirty()
            end
            -- Body boxes need nothing here: they are applied inside the hit
            -- watch's sweep, and the engine keeps them on the bodies.
            --
            -- The AIM CONE, on the other hand, has to be live: it tells you
            -- whether the shot you are about to take has a target BEFORE you
            -- take it, and it paints the muzzle beam to match. It sweeps for
            -- the gun in your hands, so it waits for a settled world like
            -- everything else that walks the object array.
            if okAim and (tickCount % 3 == 0) then
                timed("esp", AimAssist.ConeTick)
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
                -- STATUS.TXT MUST ALWAYS BE WRITTEN.
                --
                -- This whole block used to be one pcall around ninety values,
                -- and building the table is what ran inside it. One value
                -- throwing therefore skipped the write - silently, and for the
                -- rest of the session. That is exactly what a 19 September
                -- session looked like: the file froze at tick 2350 with no
                -- crash, no log line and no way to see which value did it.
                --
                -- Now the BUILD is what is protected, and the write always
                -- happens. If the build throws, the file still appears with
                -- `statuserr=` naming the file and line, and `tick=` still
                -- advances - so "the loop died" and "one value is broken"
                -- stop looking the same.
                local okBuild, fields = pcall(function()
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
                        { "headtouch",   PlayerMods.HeadTouchLine and PlayerMods.HeadTouchLine() or "n/a" },
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
                        -- did the hooks No Recoil / Full Auto depend on
                        -- actually BIND? recoilhooks=0 means No Recoil cannot
                        -- work however many times the weapon scan runs.
                        { "gunhooks",  PlayerMods.gunHooksBound or 0 },
                        -- which gun classes the per-shot hook actually ran
                        -- for, so "the shotgun is still not automatic" can be
                        -- told from "its hook never fired"
                        -- how often the gun in your hand was made ready
                        -- again: if this is 0 while Full Auto is on, the
                        -- per-tick path is not running
                        { "readied",   PlayerMods.rechamberFast or 0 },
                        -- how fast it is firing at this moment
                        -- whether the monitor is being drawn at all: a
                        -- switched-off mirror looks exactly like a frozen
                        -- game, and nothing said which it was
                        -- the game's own impact switch, on your guns
                        { "impactfx", PlayerMods.ImpactFxLine and
                                      PlayerMods.ImpactFxLine() or "full" },
                        { "mirror", PlayerMods.state.OptNoSpectator
                                    and "off" or "on" },
                        { "shotnow", PlayerMods.ShotNow and
                                     PlayerMods.ShotNow() or 0 },
                        -- the mod pulling the trigger for you: the rate,
                        -- which fire function it settled on, and whether
                        -- the gun says you are holding the trigger
                        { "autofire", PlayerMods.AutoFireLine and
                                      PlayerMods.AutoFireLine() or "none" },
                        -- the most shots each gun got off in a second:
                        -- the measured answer to "is it automatic yet"
                        { "shotrate", PlayerMods.ShotRateLine and
                                      PlayerMods.ShotRateLine() or "none" },
                        -- every call of each fire function, uncapped: the rate shotrate=
                        -- cannot show past 10 a second
                        { "firefn", PlayerMods.FireFnLine and PlayerMods.FireFnLine() or "none" },
                        { "gunclasses", PlayerMods.GunClassLine and
                                        PlayerMods.GunClassLine() or "none" },
                        -- named beamcls, not beamguns: the aimgun line already
                        -- carries a beamguns= COUNT and two fields with one
                        -- name is how a readout starts lying
                        { "beamcls",   (AimAssist and AimAssist.gun and
                                        AimAssist.gun.beamClasses) or "none" },
                        { "map",       PlayerMods.mapName or "unknown" },
                        { "beamnow",   (AimAssist and AimAssist.gun and
                                        AimAssist.gun.alignCls) or "none" },
                        { "beamalign", (AimAssist and AimAssist.AlignLine and
                                        AimAssist.AlignLine()) or "none saved" },
                        { "recoilhooks", PlayerMods.recoilHooksBound or 0 },
                        -- ...and the same four numbers as ONE line, which the
                        -- app turns into a plain-English answer to "is No
                        -- Recoil actually on?". The switch has always said
                        -- yes; a 25-kill session said events=0.
                        { "norecoil", string.format(
                              "hooks=%d events=%d killed=%d zeroed=%d",
                              PlayerMods.recoilHooksBound or 0,
                              PlayerMods.recoilEvents or 0,
                              PlayerMods.recoilArgKilled or 0,
                              PlayerMods.recoilZeroed or 0) },
                        -- whose gun the fire hooks were actually working on
                        { "gunwho",    PlayerMods.GunWhoLine and PlayerMods.GunWhoLine() or "n/a" },
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
                        -- 2026-09-17 features. aim= carries took=/good=/bad=,
                        -- which is the only proof aim assist works: it compares
                        -- where each bent bullet was sent with where it went.
                        { "aim",      okAim and AimAssist.StatusLine() or "not loaded" },
                        -- THE line that answers "does aiming work": follow= counts
                        -- bullets that came out along the direction we turned the
                        -- gun to, stray= counts the ones that ignored it.
                        { "aimgun",   okAim and AimAssist.GunLine() or "not loaded" },
                        { "aimcone",  okAim and AimAssist.ConeLine() or "not loaded" },
                        { "aimtarget", okAim and AimAssist.TargetText() or "n/a" },
                        { "shotdamage", PlayerMods.shotDamage or 0 },
                        -- where every "make sure it hits" shot ended up
                        { "shotwhy", PlayerMods.ShotWhyLine and PlayerMods.ShotWhyLine() or "n/a" },
                        -- why the last Silent Aim damage routine that failed,
                        -- failed - in the game's own words
                        { "shoterr", PlayerMods.damageErr or "none" },
                        -- your gun's impact on Silent Aim hits, and why not
                        { "impact", PlayerMods.ImpactLine and PlayerMods.ImpactLine() or "none" },
                        { "impacterr", PlayerMods.impactErr or "none" },
                        -- queued vs ran: if these drift apart the GAME has
                        -- stopped taking our work, which is a different
                        -- problem from the mod being wrong
                        { "gamethread", PlayerMods.GameThreadLine and PlayerMods.GameThreadLine() or "n/a" },
                        -- the job pump, and hook attempts skipped because the
                        -- function was not there (each would have made a Lua state)
                        { "pump", PlayerMods.PumpLine and PlayerMods.PumpLine() or "n/a" },
                        { "hookasks", string.format("made=%d skipped=%d",
                            PlayerMods.hookCalls or 0, PlayerMods.hookSkips or 0) },
                        -- remembered guns found gone through the engine's name table, so never
                        -- touched after being freed (the UE4SS.dll+0x4baaaf crash)
                        { "goneuntouched", tostring(PlayerMods.goneUntouched or 0) },
                        -- how the LAST session ended, carried over at boot
                        { "prevsession", PlayerMods.prevSession or "unknown" },
                        -- so "am I actually running the new build?" is
                        -- answerable without comparing file dates
                        { "build", MOD_BUILD },
                        { "espplus",  okESP and ESPPlus.StatusLine() or "not loaded" },
                        { "npcai",    PlayerMods.NpcAiLine and PlayerMods.NpcAiLine() or "n/a" },
                        { "opt",      okOpt and Opt.StatusLine() or "not loaded" },
                        { "optfps",   okOpt and Opt.FpsText() or "n/a" },
                        { "optpreset", okOpt and Opt.PresetName(PlayerMods.state.OptPreset) or "n/a" },
                        -- memory / CPU / audio / loading: what the OPT SYSTEM
                        -- page currently has switched on
                        { "optsystem", okOpt and Opt.SystemText and Opt.SystemText() or "n/a" },
                        { "music",    okMusic and Music.StatusLine() or "not loaded" },
                        -- the desktop app acts on a change of the number before |
                        { "musiccmd", okMusic and Music.StatusField() or "0|" },
                        { "saves",    okSaves and Saves.StatusLine() or "not loaded" },
                        { "savenote", okSaves and Saves.StatusText() or "not loaded" },
                        { "savestart", okIPC and IPC.startupRule or "n/a" },
                        { "modules",  string.format("opt=%s music=%s esp=%s aim=%s",
                                      tostring(okOpt), tostring(okMusic), tostring(okESP), tostring(okAim)) },
                    }
                    for k, v in pairs(PlayerMods.state) do
                        local t = type(v)
                        if t == "boolean" then
                            fields[#fields + 1] = { "st_" .. string.lower(k), v and "1" or "0" }
                        elseif t == "number" then
                            fields[#fields + 1] = { "st_" .. string.lower(k), tostring(v) }
                        end
                    end
                    return fields
                end)
                if not okBuild or type(fields) ~= "table" then
                    local why = tostring(fields):gsub("[\r\n]", " "):sub(1, 160)
                    fields = { { "alive", 1 }, { "tick", tickCount },
                               { "statuserr", why } }
                end
                pcall(IPC.WriteStatus, fields)
                cost.status = cost.status + (os.clock() - st0)
            end
        end

        timed("gui", GUI.Tick)

        -- publish the cost breakdown once every 10 s
        if tickCount % 100 == 0 then reportCost() end

        return false -- keep looping
    end

    -- THE LOOP THREAD. Jobs made in here are only collected, and go to the
    -- game thread after it - see PlayerMods.SendOutbox for the freeze that
    -- made this necessary. The flag is cleared even if the tick throws.
    LoopAsync(TICK_MS, function()
        PlayerMods.loopCo = coroutine.running()
        -- the game thread is stalled (a load, a round change): touch nothing
        local okH, hold = pcall(PlayerMods.HoldLoop)
        if okH and hold then return false end
        PlayerMods.loopBodyActive = true
        local ok, err = pcall(loopTick)
        PlayerMods.loopBodyActive = false
        PlayerMods.SendOutbox()
        if not ok then
            PlayerMods.loopErr = tostring(err)
            print("[ModMenu] loop tick failed: " .. tostring(err) .. "\n")
        end
        return false
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
