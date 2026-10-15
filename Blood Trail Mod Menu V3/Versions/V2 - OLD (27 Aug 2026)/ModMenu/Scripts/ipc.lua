-- Blood Trail Mod Menu - bridge to the desktop app
--
-- The desktop app (BloodTrailModMenu.py) and this mod talk through two plain
-- text files in the mod folder. No sockets, no dependencies, and if the app is
-- not running the mod simply carries on with its in-game menu.
--
--   control.txt  written by the app, read here  - every toggle/value + a
--                one-shot action slot guarded by a sequence number
--   status.txt   written here, read by the app  - so the app can show health,
--                pawn type, enemy count and whether the game is even running
--
-- The app writes control.txt atomically (write temp, os.replace), so a partial
-- read is not possible on that side. Malformed lines are ignored regardless.

local IPC = {}

-- Adjust this if the game is installed somewhere else. Paths are resolved on
-- every call rather than captured here, so overriding IPC.DIR after require()
-- actually takes effect.
IPC.DIR = "D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/"

local function controlPath() return IPC.DIR .. "control.txt" end
local function statusPath()  return IPC.DIR .. "status.txt"  end
local function statusTmp()   return IPC.DIR .. "status.tmp"  end

IPC.available = (type(io) == "table" and type(io.open) == "function")
IPC.lastSeq = -1

---------------------------------------------------------------------------
-- reading control.txt
---------------------------------------------------------------------------

local function readAll(path)
    local ok, res = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if ok then return res end
    return nil
end

local function parse(text)
    local t = {}
    for line in string.gmatch(text, "[^\r\n]+") do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then t[k] = v end
    end
    return t
end

-- state    : PlayerMods.state, whose existing value types drive the parsing
-- dispatch : function(action, arg) for one-shot commands
-- Toggles the player can flip from inside VR; see the edge-trigger note below.
-- kept only so the desktop app and this file agree on the concept; the
-- edge rule below now applies to every key, not just these
IPC.MOD_OWNED = { CrouchDown = true, FlyMode = true, NoClip = true }
IPC.NEVER_SEED = { PointerPitch = true, PointerYaw = true }
IPC.lastControl = {}

function IPC.Poll(state, dispatch)
    if not IPC.available then return end

    local text = readAll(controlPath())
    if not text or text == "" then return end

    local kv = parse(text)

    for key, current in pairs(state) do
        local raw = kv[key]
        if raw ~= nil then
            -- EVERY KEY IS EDGE-TRIGGERED.
            --
            -- control.txt is rewritten five times a second whether or not the
            -- human touched anything. Applying it on every poll means the file
            -- is the only thing that can ever set state: a toggle flipped from
            -- inside VR is stamped back 200 ms later, which looks exactly like
            -- "clicking the module does nothing and the sliders reset".
            --
            -- This used to be limited to a MOD_OWNED list (crouch, fly,
            -- noclip), so those three worked from the controller and the other
            -- sixty-odd did not. The rule belongs on all of them: apply the
            -- file only when its value actually CHANGES - which is precisely
            -- when a human moved a control in the desktop app - and otherwise
            -- leave the mod's own state alone.
            --
            -- First sighting still counts, so settings chosen before the mod
            -- loaded are honoured.
            local apply = (IPC.lastControl[key] == nil)
                          or (IPC.lastControl[key] ~= raw)

            -- SOME KEYS MUST NOT BE SEEDED FROM THE FILE.
            --
            -- The pointer calibration is solved in VR and saved by the mod. If
            -- the "first sighting counts" rule applies to it, every launch
            -- stamps whatever stale number is sitting in control.txt over the
            -- top - which is exactly what happened: the file still held
            -- PointerPitch=-45 and no PointerYaw at all, so each restart threw
            -- the calibration away and aiming was wrong again. Genuine CHANGES
            -- still apply, so the desktop sliders keep working.
            if IPC.NEVER_SEED[key] and IPC.lastControl[key] == nil then
                apply = false
            end
            IPC.lastControl[key] = raw

            if apply then
                if type(current) == "boolean" then
                    state[key] = (raw == "1" or raw == "true")
                elseif type(current) == "number" then
                    local n = tonumber(raw)
                    if n then state[key] = n end
                end
            end
        end
    end

    -- One-shot actions. The app bumps seq on every button press, including a
    -- repeat of the same action, so holding "spawn" works.
    local seq = tonumber(kv.seq or "")
    IPC.seenSeq = tostring(kv.seq) .. "/" .. tostring(IPC.lastSeq)
    if seq and seq ~= IPC.lastSeq then
        IPC.lastSeq = seq
        local action = kv.action
        IPC.lastAction = "[" .. tostring(action) .. "]"
        if action and action ~= "" and dispatch then
            -- Report the failure. A bare pcall here hid a dispatch error
            -- completely: the button did nothing, nothing was logged, and the
            -- status field just stayed at its default, which looks identical to
            -- "the action never arrived".
            local ok, err = pcall(dispatch, action, kv.arg or "")
            if not ok then
                IPC.lastError = tostring(action) .. ": " .. tostring(err)
                print("[ModMenu] action '" .. tostring(action) ..
                      "' FAILED: " .. tostring(err) .. "\n")
            end
        end
    end
end

---------------------------------------------------------------------------
-- writing status.txt
---------------------------------------------------------------------------

function IPC.WriteStatus(fields)
    if not IPC.available then return end

    -- Written straight to the file, in one buffered go.
    --
    -- This used to write a temp file, os.remove the target and os.rename over
    -- it, for atomicity. Measured at 1.6% of wall time - two filesystem metadata
    -- operations twice a second, which on a drive with antivirus watching it is
    -- exactly the kind of background hitch you feel in a headset. The reader
    -- already tolerates a partial read (it try/excepts and re-reads twice a
    -- second), so the atomicity was not buying anything.
    pcall(function()
        local f = io.open(statusPath(), "w")
        if not f then return end
        local parts = {}
        for _, pair in ipairs(fields) do
            parts[#parts + 1] = pair[1] .. "=" .. tostring(pair[2])
        end
        f:write(table.concat(parts, "\n"), "\n")
        f:close()
    end)
end

return IPC
