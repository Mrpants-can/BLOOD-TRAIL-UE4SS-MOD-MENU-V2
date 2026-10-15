-- Blood Trail Mod Menu - SAVES: your settings, kept for next time
--
-- Every module switch and slider (PlayerMods.state) is written to
--
--     Mods/ModMenu/saved_settings.txt        (key=value, same format as control.txt)
--
-- and put back when the game starts. Three profiles sit beside it
-- (saved_profile1.txt .. 3) for set-ups you want to swap between.
--
--   * AUTO-SAVE (on by default): about every 2 s the state is compared with
--     what was last written, and saved only if something changed - flipping a
--     switch in VR or in the desktop app both count. Nothing is written while
--     nothing changes.
--   * LOAD ON START (on by default): read before the main loop starts, so
--     every feature comes up already set.
--   * The two switches live in the file too, so turning Load On Start off is
--     remembered.
--
-- NOT saved - momentary things you would not want to start a round with:
--   CrouchDown, FlyMode, NoClip (button toggles), and the laser calibration
--   PointerPitch/PointerYaw (that already has its own pointercal.txt).
--
-- WHY THE LEFTOVER control.txt DOES NOT UNDO A LOAD
--
-- ipc.lua applies the first value it sees for every key in control.txt, which
-- is how settings chosen in the desktop app before the game started get in.
-- But control.txt is just whatever the app last wrote - often a copy of an old
-- session - and applied blindly it would stomp the save a moment after
-- loading it. So the app stamps app_edit=<time> with its last REAL edit (a
-- click, not a heartbeat), and on the first poll ipc.lua only applies the file
-- when that edit is newer than the save. Otherwise the file is noted as
-- already seen, and only later changes count - which is the normal rule.
--
-- FIRST RUN AFTER THIS UPDATE
--
-- There is no save yet, but status.txt still holds the last session's
-- st_<key> values (the mod writes it every second, and nothing has overwritten
-- it yet when this runs). Those are carried over, so the settings you played
-- with last time are the ones you start with.
--
-- The write goes to a .tmp file first and is renamed into place, so a crash
-- mid-write cannot leave half a save; a load falls back to the .tmp if the
-- rename never happened.

local Saves = {
    DIR = "D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/",
    FILE = "saved_settings.txt",
    PROFILES = 3,
    lastWritten = nil,      -- the body last written by auto-save
    lastSaveAt = nil,       -- os.time() of the last write
    loadedCount = 0,
    source = "none",        -- "save", "last session", "none", "off"
    loadNote = "",
    note = nil, noteAt = nil,
    saves = 0, writeErrors = 0,
    autoWasOn = true,
    resetArmedAt = nil,
    profileInfo = {},
}

local PlayerMods = nil
local defaults = {}

Saves.SKIP = {
    PointerPitch = true, PointerYaw = true,
    CrouchDown = true, FlyMode = true, NoClip = true,
    GammaDefault = true,
}

local META = { version = true, saved = true, note = true }

local function nowClock()
    local ok, t = pcall(os.clock)
    return ok and t or 0
end

local function setNote(text)
    Saves.note = text
    Saves.noteAt = nowClock()
end

local function path(name) return Saves.DIR .. name end
local function profileFile(n) return "saved_profile" .. tostring(n) .. ".txt" end

local function stamp(t)
    local ok, s = pcall(os.date, "%d %b %H:%M", t)
    return ok and s or tostring(t)
end

local function clockText(t)
    local ok, s = pcall(os.date, "%H:%M:%S", t)
    return ok and s or tostring(t)
end

---------------------------------------------------------------------------
-- files
---------------------------------------------------------------------------

local function slurp(p)
    local ok, data = pcall(function()
        local f = io.open(p, "r")
        if not f then return nil end
        local d = f:read("*a")
        f:close()
        return d
    end)
    return ok and data or nil
end

local function parse(data)
    local kv = {}
    for line in string.gmatch(data or "", "[^\r\n]+") do
        if not string.match(line, "^%s*#") then
            local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k then kv[k] = v end
        end
    end
    return kv
end

-- The save, or nil. A leftover .tmp means a write never got renamed into
-- place; it is complete (it is only renamed after closing), so use it.
local function readSave(name)
    local data = slurp(path(name))
    if not data or data == "" then data = slurp(path(name .. ".tmp")) end
    if not data or data == "" then return nil end
    local kv = parse(data)
    if next(kv) == nil then return nil end
    return kv
end

local function fmtNum(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", math.floor(v))
    end
    return string.format("%.6g", v)
end

function Saves.Serialize()
    local keys = {}
    for k, v in pairs(PlayerMods.state) do
        if not Saves.SKIP[k] and (type(v) == "boolean" or type(v) == "number") then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do
        local v = PlayerMods.state[k]
        lines[#lines + 1] = k .. "=" .. ((type(v) == "boolean") and (v and "1" or "0") or fmtNum(v))
    end
    return table.concat(lines, "\n"), #keys
end

local function writeSave(name, body, note)
    local okT, now = pcall(os.time)
    if not okT then now = 0 end
    local target, tmp = path(name), path(name .. ".tmp")
    local ok = pcall(function()
        local f = io.open(tmp, "w")
        if not f then error("cannot open " .. tmp) end
        f:write("# Blood Trail Mod Menu - saved settings. Written by the mod;\n",
                "# the desktop app reads it too. Delete this file to start fresh.\n",
                "version=1\n",
                "saved=", tostring(now), "\n",
                "note=", tostring(note or ""), "\n",
                body, "\n")
        f:close()
    end)
    if not ok then
        Saves.writeErrors = Saves.writeErrors + 1
        return false
    end
    pcall(os.remove, target)
    local okR, res = pcall(os.rename, tmp, target)
    if not (okR and res) then
        Saves.writeErrors = Saves.writeErrors + 1
        return false
    end
    return true, now
end

local function refreshProfile(n)
    local kv = readSave(profileFile(n))
    if not kv then
        Saves.profileInfo[n] = "empty"
    else
        local t = tonumber(kv.saved or "")
        Saves.profileInfo[n] = t and ("saved " .. stamp(t)) or "saved"
    end
end

---------------------------------------------------------------------------
-- applying
---------------------------------------------------------------------------

-- Put saved values into the state. Unknown keys (a setting that was removed)
-- and wrong types are ignored, so an old save never breaks a new build.
-- ONE-TIME NUDGES for values that shipped wrong.
--
-- A default nobody chose is not a setting worth defending. The head-touch
-- reach went out at 28 cm and measured hands sit 82 and 89 cm away at rest,
-- so a real reach beside your head only just gets inside 35 - it fired ONCE
-- in a whole session. Anyone still sitting on exactly the old number never
-- picked it, so move them on. A value they have changed themselves is left
-- alone, and so is anything that matches the new default already.
--
-- `under` is the same argument one step further. The slider used to go down
-- to 12 cm, which is a button no controller can get inside - your ear is
-- further from the middle of your head than that - and a saved profile spent
-- a whole session sitting on it, reading on=true live=true fires=0. The
-- runtime clamps it anyway, but a saved file that still says 12 would go on
-- disagreeing with the menu forever, so move it too.
local MIGRATE = {
    HeadTouchRange = { from = 28, to = 38, under = 20 },
    -- 3 was the old default and it is the SHOTGUN's own non-automatic mode,
    -- so Full Auto was setting the gun to what it already was. The ak - which
    -- does run while you hold the trigger - ships with 0. Anybody still
    -- carrying the old default gets the working one.
    FireModeIndex = { from = 3, to = 0 },
}

local function migrate(kv)
    local moved = 0
    for key, m in pairs(MIGRATE) do
        local v = tonumber(kv[key] or "")
        if v and (v == m.from or (m.under and v < m.under)) then
            kv[key] = tostring(m.to)
            moved = moved + 1
        end
    end
    Saves.migrated = (Saves.migrated or 0) + moved
    return moved
end

function Saves.Apply(kv, onlySwitches)
    local n = 0
    if not onlySwitches then migrate(kv) end
    for k, raw in pairs(kv) do
        if not META[k] and not Saves.SKIP[k] then
            if (not onlySwitches) or k == "SaveAuto" or k == "SaveLoadOnStart" then
                local cur = PlayerMods.state[k]
                if type(cur) == "boolean" then
                    PlayerMods.state[k] = (raw == "1" or raw == "true")
                    n = n + 1
                elseif type(cur) == "number" then
                    local v = tonumber(raw)
                    if v then
                        PlayerMods.state[k] = v
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- First run after the update: the last session's st_ values from status.txt.
local function importFromStatus()
    local data = slurp(path("status.txt"))
    if not data then return nil end
    local lower = {}
    for k in pairs(PlayerMods.state) do lower[string.lower(k)] = k end
    local kv, n = {}, 0
    for line in string.gmatch(data, "[^\r\n]+") do
        local k, v = string.match(line, "^st_([%w_]+)=(.-)%s*$")
        local real = k and lower[k]
        if real and not Saves.SKIP[real] then
            kv[real] = v
            n = n + 1
        end
    end
    if n < 10 then return nil end      -- not a real status file
    return kv
end

---------------------------------------------------------------------------
-- entry points
---------------------------------------------------------------------------

-- Before the settings are touched: remember the defaults, for RESET.
function Saves.Init(pm)
    PlayerMods = pm
    defaults = {}
    for k, v in pairs(pm.state) do
        if type(v) == "boolean" or type(v) == "number" then defaults[k] = v end
    end
    for n = 1, Saves.PROFILES do refreshProfile(n) end
end

-- Called once at mod start. Returns the time the loaded settings were saved
-- (for ipc.lua's control.txt rule), or nil if nothing was loaded.
function Saves.LoadAtStart()
    local kv = readSave(Saves.FILE)
    local source = "save"
    if not kv then
        kv = importFromStatus()
        source = "last session"
    end
    if not kv then
        Saves.source = "none"
        Saves.loadNote = "nothing saved yet - your settings save by themselves"
        return nil
    end

    -- the two switches first: Load On Start may be off
    Saves.Apply(kv, true)
    if PlayerMods.state.SaveLoadOnStart == false then
        Saves.source = "off"
        Saves.loadNote = "saved settings not loaded (Load On Start is off)"
        return nil
    end

    local n = Saves.Apply(kv, false)
    Saves.loadedCount = n
    Saves.source = source
    local okT, now = pcall(os.time)
    if source == "save" then
        local t = tonumber(kv.saved or "")
        Saves.loadNote = string.format("loaded %d settings (saved %s)", n, t and stamp(t) or "earlier")
        -- already on disk; do not rewrite an identical file straight away
        Saves.lastWritten = Saves.Serialize()
        return t or (okT and now) or 0
    end
    Saves.loadNote = string.format("carried over %d settings from your last session", n)
    -- not written yet: the first auto-save turns it into a real save
    Saves.lastWritten = nil
    -- 0, not "now": status.txt's real age is unknown here, and "now" would
    -- make ANY click in the desktop app before this launch look older and be
    -- thrown away. With 0, an app that was edited (app_edit > 0) wins, and an
    -- untouched leftover control.txt (app_edit 0 or missing) does not.
    return 0
end

-- From the main loop, about every 2 s.
function Saves.AutoSaveTick()
    if not PlayerMods then return end
    local body = Saves.Serialize()
    if PlayerMods.state.SaveAuto == false then
        -- write once more so "auto-save off" itself is remembered
        if Saves.autoWasOn then
            Saves.autoWasOn = false
            local ok, at = writeSave(Saves.FILE, body, "auto-save switched off")
            if ok then Saves.lastWritten, Saves.lastSaveAt = body, at end
        end
        return
    end
    Saves.autoWasOn = true
    if body == Saves.lastWritten then return end
    local ok, at = writeSave(Saves.FILE, body, "auto")
    if ok then
        Saves.lastWritten, Saves.lastSaveAt = body, at
        Saves.saves = Saves.saves + 1
    end
end

function Saves.SaveNow()
    local body = Saves.Serialize()
    local ok, at = writeSave(Saves.FILE, body, "saved from the menu")
    if ok then
        Saves.lastWritten, Saves.lastSaveAt = body, at
        Saves.saves = Saves.saves + 1
        setNote("SAVED at " .. clockText(at))
    else
        setNote("could not save - is the ModMenu folder read-only?")
    end
end

function Saves.LoadSaved()
    local kv = readSave(Saves.FILE)
    if not kv then setNote("nothing saved yet") return end
    local n = Saves.Apply(kv, false)
    Saves.lastWritten = Saves.Serialize()
    setNote(string.format("LOADED %d settings", n))
end

local function slot(n)
    n = math.floor(tonumber(n) or 0)
    if n < 1 or n > Saves.PROFILES then return nil end
    return n
end

function Saves.SaveProfile(n)
    n = slot(n)
    if not n then return end
    local ok = writeSave(profileFile(n), (Saves.Serialize()), "profile " .. n)
    refreshProfile(n)
    setNote(ok and ("SAVED to profile " .. n) or ("could not save profile " .. n))
end

function Saves.LoadProfile(n)
    n = slot(n)
    if not n then return end
    local kv = readSave(profileFile(n))
    if not kv then setNote("profile " .. n .. " is empty - save to it first") return end
    local n2 = Saves.Apply(kv, false)
    setNote(string.format("LOADED profile %d (%d settings)", n, n2))
    -- auto-save picks the change up and makes it the settings for next time
end

-- One press arms it, a second press within 4 s does it: a pointer that
-- slides over the row by accident cannot wipe everything.
function Saves.ResetDefaults()
    local t = nowClock()
    if not Saves.resetArmedAt or (t - Saves.resetArmedAt) > 4 then
        Saves.resetArmedAt = t
        setNote("press RESET again to put EVERYTHING back to default")
        return false
    end
    Saves.resetArmedAt = nil
    for k, v in pairs(defaults) do
        if not Saves.SKIP[k] then PlayerMods.state[k] = v end
    end
    setNote("everything is back to default")
    return true
end

---------------------------------------------------------------------------
-- read-outs
---------------------------------------------------------------------------

function Saves.ProfileText(n)
    return Saves.profileInfo[n] or "empty"
end

function Saves.StatusText()
    if Saves.note and (nowClock() - (Saves.noteAt or 0)) < 8 then return Saves.note end
    local s = PlayerMods and PlayerMods.state or {}
    if s.SaveAuto == false then return "auto-save is OFF - use SAVE NOW" end
    if Saves.lastSaveAt then return "your settings saved at " .. clockText(Saves.lastSaveAt) end
    if Saves.loadNote ~= "" then return Saves.loadNote end
    return "your settings save by themselves"
end

function Saves.StatusLine()
    local s = PlayerMods and PlayerMods.state or {}
    return string.format("auto=%s loadonstart=%s source=%s loaded=%d saves=%d lastsave=%s errors=%d",
        tostring(s.SaveAuto ~= false), tostring(s.SaveLoadOnStart ~= false),
        (Saves.source:gsub(" ", "_")), Saves.loadedCount, Saves.saves,
        tostring(Saves.lastSaveAt or 0), Saves.writeErrors)
end

return Saves
