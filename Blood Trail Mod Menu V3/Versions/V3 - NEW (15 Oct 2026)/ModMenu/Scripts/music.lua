-- Blood Trail Mod Menu - MUSIC tab (in-game side)
--
-- The player itself lives in the desktop app (BloodTrailModMenu.py), and that
-- is deliberate.
--
--   * Unreal cannot load an MP3 from disk at runtime without a plugin this
--     game does not ship, so "play your own music" is impossible from Lua.
--   * Playing the game's own sound assets would mean LoadAsset, and a
--     LoadAsset that misses throws a C++ exception pcall cannot catch.
--   * The PC's audio already reaches the headset through Link / Air Link, so
--     music played by the app is heard in VR anyway.
--
-- So this file is a remote control:
--
--   game -> app   musiccmd=<seq>|<command>   in status.txt
--   app  -> game  music_now / music_state / music_pos / music_len / app_hb
--                 music_folder / music_browse / music_dirs   in control.txt
--
-- "IT KEEPS SAYING NO DESKTOP APP RUNNING" (2026-09-17)
--
-- It was right: nothing had started the app. The auto-open watcher was not
-- installed, and control.txt had not been written once during that session.
-- Asking the player to alt-tab out of VR to open a window is not a fix, so the
-- MUSIC tab now starts the app itself (minimised) the first time you press a
-- button, and replays that press once the app is up.
--
-- Starting it means os.execute, which blocks for as long as cmd.exe takes to
-- hand over (~50 ms). A button press arrives from the trigger hook ON THE GAME
-- THREAD, so the press only raises a flag; the launch happens in Music.Tick on
-- the loop thread, where a short block costs no frames.

local Music = {
    seq   = 0,
    cmd   = "",
    now   = "",
    state = "stopped",
    pos   = 0,
    len   = 0,
    hb    = 0,
    count = 0,
    index = 0,
    -- folder picker, as reported by the app
    folder = "",
    songs = 0,
    browse = "",
    browseSongs = 0,
    dirs = {},
    dirCount = 0,
    -- starting the app
    pending = nil,
    wantLaunch = false,
    lastLaunch = -1000,
    launches = 0,
    launchNote = "",
    wasAlive = false,
}

-- The mod folder. main.lua points this at IPC.DIR.
Music.DIR = "D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/"
Music.LAUNCHER = "Start Music Player.bat"

-- Quick folders on the picker page; the app resolves the same indices.
Music.PRESETS = { "D:\\music", "My Music", "Downloads", "Desktop" }

local PlayerMods = nil
function Music.Init(pm) PlayerMods = pm end

---------------------------------------------------------------------------
-- commands to the app
---------------------------------------------------------------------------

-- The app acts on a CHANGE of seq, so pressing Next twice sends two nexts.
function Music.Send(cmd)
    Music.seq = Music.seq + 1
    Music.cmd = cmd
end

function Music.StatusField()
    return tostring(Music.seq) .. "|" .. Music.cmd
end

-- What every MUSIC button calls. If the app is up the command goes straight
-- out; if not, it is kept and the app is started.
function Music.Command(cmd)
    if Music.AppAlive() then
        Music.Send(cmd)
        return
    end
    Music.pending = cmd
    if not PlayerMods or PlayerMods.state.MusicAutoStart ~= false then
        Music.wantLaunch = true
        Music.launchNote = "starting the music player..."
    else
        Music.launchNote = "open the desktop app (auto-start is off)"
    end
end

-- START MUSIC PLAYER NOW: a launch even with auto-start off.
function Music.StartApp()
    if Music.AppAlive() then
        Music.launchNote = "already running"
        return
    end
    Music.wantLaunch = true
    Music.lastLaunch = -1000
    Music.launchNote = "starting the music player..."
end

local function launch()
    if not (os and type(os.execute) == "function") then
        Music.launchNote = "this game cannot start programs - open the desktop app"
        return false
    end
    local path = (Music.DIR .. Music.LAUNCHER):gsub("/", "\\")
    -- `start` returns at once; /min keeps the window out of the way
    local ok = pcall(os.execute, 'start "" /min "' .. path .. '"')
    Music.launches = Music.launches + 1
    if not ok then Music.launchNote = "could not start the player" end
    return ok
end

-- Called from the main loop about once a second (the loop thread, never the
-- game thread).
function Music.Tick()
    local alive = Music.AppAlive()

    if Music.wantLaunch then
        Music.wantLaunch = false
        local now = os.clock()
        -- one try per 25 s: the app needs a few seconds to write its first
        -- heartbeat, and a second copy would only close itself again
        if not alive and (now - Music.lastLaunch) >= 25 then
            Music.lastLaunch = now
            launch()
        end
    end

    -- The app just came up: replay the press that started it. The app ignores
    -- the first musiccmd it ever sees (so an old press is not replayed when it
    -- opens), which is why this goes out as a NEW command now.
    if alive and Music.pending then
        Music.Send(Music.pending)
        Music.pending = nil
    end
    if alive and not Music.wasAlive then
        Music.launchNote = ""
    end
    -- nobody answered: stop saying "starting..."
    if not alive and Music.pending and (os.clock() - Music.lastLaunch) > 30
       and Music.lastLaunch > 0 then
        Music.launchNote = "the player did not start - open Blood Trail Mod Menu"
    end
    Music.wasAlive = alive
end

---------------------------------------------------------------------------
-- what the app reports back (called by ipc.lua with the parsed control.txt)
---------------------------------------------------------------------------

-- The title is shown on a TextRender in the headset. Non-ASCII has come out as
-- mojibake before, and '=' or a newline would corrupt the key=value file, so
-- the app already sanitises - this is the second line of defence.
local function clean(s, limit)
    s = tostring(s or "")
    s = s:gsub("[^\32-\126]", "?")
    limit = limit or 40
    if #s > limit then s = s:sub(1, limit - 1) .. "~" end
    return s
end

function Music.FromControl(kv)
    if kv.music_now   ~= nil then Music.now   = clean(kv.music_now) end
    if kv.music_state ~= nil then Music.state = tostring(kv.music_state) end
    Music.pos   = tonumber(kv.music_pos or "")   or Music.pos
    Music.len   = tonumber(kv.music_len or "")   or Music.len
    Music.hb    = tonumber(kv.app_hb or "")      or Music.hb
    Music.count = tonumber(kv.music_count or "") or Music.count
    Music.index = tonumber(kv.music_index or "") or Music.index

    if kv.music_folder ~= nil then Music.folder = clean(kv.music_folder, 44) end
    Music.songs = tonumber(kv.music_songs or "") or Music.songs
    if kv.music_browse ~= nil then Music.browse = clean(kv.music_browse, 44) end
    Music.browseSongs = tonumber(kv.music_browse_songs or "") or Music.browseSongs
    Music.dirCount = tonumber(kv.music_dircount or "") or Music.dirCount
    if kv.music_dirs ~= nil then
        local list = {}
        for name in string.gmatch(tostring(kv.music_dirs), "[^|]+") do
            list[#list + 1] = clean(name, 34)
        end
        Music.dirs = list
    end
end

-- The app stamps app_hb with the wall clock every couple of seconds. If that
-- stops moving, the app is closed and the buttons here would do nothing.
function Music.AppAlive()
    if not Music.hb or Music.hb <= 0 then return false end
    local ok, now = pcall(os.time)
    if not ok or type(now) ~= "number" then return true end
    return (now - Music.hb) < 8
end

local function mmss(sec)
    sec = math.floor(tonumber(sec) or 0)
    if sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

function Music.NowText()
    if not Music.AppAlive() then
        if Music.launchNote ~= "" then return Music.launchNote end
        return "press PLAY - the player starts by itself"
    end
    if Music.now == "" then return "nothing loaded" end
    return Music.now
end

function Music.StateText()
    if not Music.AppAlive() then
        if Music.launchNote ~= "" then return "waiting for the player" end
        return "player not started yet"
    end
    local st = string.upper(Music.state or "?")
    if Music.len and Music.len > 0 then
        return string.format("%s %s / %s", st, mmss(Music.pos), mmss(Music.len))
    end
    return st
end

function Music.TrackText()
    if not Music.AppAlive() or (Music.count or 0) == 0 then return "-" end
    return string.format("%d of %d", Music.index or 0, Music.count or 0)
end

function Music.FolderText()
    if not Music.AppAlive() or Music.folder == "" then return "-" end
    return string.format("%s  (%d songs)", Music.folder, Music.songs or 0)
end

function Music.BrowseText()
    if not Music.AppAlive() then return "starting the player..." end
    if Music.browse == "" then return "-" end
    return Music.browse
end

function Music.BrowseSongsText()
    if not Music.AppAlive() then return "-" end
    return string.format("%d songs, %d folders", Music.browseSongs or 0, Music.dirCount or 0)
end

---------------------------------------------------------------------------
-- duck the game's own soundtrack while your music plays
---------------------------------------------------------------------------
-- Edge-triggered: the pawn is written only when "should be ducked" changes,
-- never per tick. The value it had is captured first and put back afterwards,
-- so this cannot fight FIX AUDIO or the master volume slider.

local ducked = false
local savedMusicVol = nil

local function writeGameMusic(vol)
    -- Through the door like everything else. It was the last one going round
    -- it, and it writes to the PAWN - which is exactly the kind of thing a
    -- level change takes away underneath a job that is already in flight.
    PlayerMods.InGameThread("music-duck", function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        local okV, valid = pcall(function() return pawn:IsValid() end)
        if not (okV and valid) then return end
        -- fail closed: no schema check, no touch
        if not (PlayerMods.hasProp and PlayerMods.hasProp(kind, "MusicVolume")) then return end
        pcall(function() pawn.MusicVolume = vol end)
        -- RefreshAllVolumeMulties is WendigoVrChar_C only; the other pawn has
        -- no such function, so it is only called where the schema lists it
        if PlayerMods.hasFunc and PlayerMods.hasFunc(kind, "RefreshAllVolumeMulties") then
            pcall(function() pawn:RefreshAllVolumeMulties() end)
        end
    end)
end

function Music.DuckTick()
    if not PlayerMods then return end
    local s = PlayerMods.state
    local want = s.MusicDuckGame and Music.AppAlive() and Music.state == "playing"

    if want and not ducked then
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        if not (PlayerMods.hasProp and PlayerMods.hasProp(kind, "MusicVolume")) then return end
        local ok, v = pcall(function() return pawn.MusicVolume end)
        savedMusicVol = (ok and type(v) == "number") and v or 1.0
        writeGameMusic(s.MusicDuckLevel or 0.1)
        ducked = true
    elseif (not want) and ducked then
        writeGameMusic(savedMusicVol or 1.0)
        ducked = false
    elseif want and ducked then
        -- the level slider moved while ducked
        if Music.lastDuckLevel ~= s.MusicDuckLevel then
            writeGameMusic(s.MusicDuckLevel or 0.1)
        end
    end
    Music.lastDuckLevel = s.MusicDuckLevel
end

-- A new world is a new pawn with its own volumes; do not restore stale ones.
function Music.OnWorldChange()
    ducked = false
    savedMusicVol = nil
end

function Music.StatusLine()
    return string.format("alive=%s state=%s idx=%s/%s ducked=%s seq=%d launches=%d pending=%s folder=%s",
        tostring(Music.AppAlive()), tostring(Music.state), tostring(Music.index),
        tostring(Music.count), tostring(ducked), Music.seq, Music.launches,
        tostring(Music.pending or "none"), Music.folder ~= "" and Music.folder or "-")
end

return Music
