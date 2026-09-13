-- Blood Trail Mod Menu - the in-game menu
--
-- Rendering approach: this is a VR game, and in UE4 a screen-space UMG widget
-- added with AddToViewport is composited into the spectator window only - it is
-- NOT drawn inside the headset. Blood Trail's own VR menu (BP_DugVrMenu) is
-- built entirely out of UTextRenderComponents in world space, so this menu does
-- the same thing: it drives a UTextRenderComponent that already exists on the
-- player pawn and is therefore already registered and positioned near the player.
--
--   WendigoVrChar_C  -> CameraText
--   BP_VRCharacter_C -> TextRender
--
-- The same text also goes to the UE4SS console window, so the menu is readable
-- on the desktop with the headset off. The full desktop app is separate
-- (BloodTrailModMenu.py, talking over ipc.lua).

local GUI = {
    IsOpen   = false,
    page     = 1,
    row      = 1,
    spawnCat = nil,   -- nil = category list, otherwise index into the catalogue
    spawnCount = 1,
    dirty    = true,
    WIDTH    = 50,
    VISIBLE_ROWS = 12,
}

local PlayerMods, SpawnerMods

---------------------------------------------------------------------------
-- row constructors
---------------------------------------------------------------------------

local function toggle(label, key)
    return { kind = "toggle", label = label, key = key }
end

-- `needs` names a toggle key this row belongs to, so a multiplier disappears
-- along with the toggle it adjusts when the live pawn cannot use it.
local function number(label, key, step, min, max, fmt, needs)
    return { kind = "number", label = label, key = key, needs = needs,
             step = step, min = min, max = max, fmt = fmt or "%.1f" }
end

local function action(label, run)
    return { kind = "action", label = label, run = run }
end

local function info(label, valueFn)
    return { kind = "info", label = label, valueFn = valueFn }
end

local pages = {}

function GUI.Build(playerMods, spawnerMods)
    PlayerMods, SpawnerMods = playerMods, spawnerMods

    pages = {
        {
            name = "PLAYER",
            rows = {
                toggle("SAFE MODE (no crashes)","SafeMode"),
                toggle("God Mode",             "GodMode"),
                toggle("Infinite Bullet Time", "InfiniteBulletTime"),
                toggle("Infinite Courage",     "InfiniteCourage"),
                number("God Mode Max HP",      "GodHP", 1000, 1000, 100000, "%.0f"),
                toggle("Instant Crack Regen",  "InstantCrackRegen"),
                toggle("Infinite Mana",        "InfiniteMana"),
                toggle("Infinite Arrows",      "InfiniteArrows"),
                action("Heal To Full Now",     function() PlayerMods.HealNow() end),
                info  ("Health", function()
                    return string.format("%d/%d",
                        math.floor(PlayerMods.info.health or 0),
                        math.floor(PlayerMods.info.healthmax or 0))
                end),
            },
        },
        {
            -- Melee here, guns and gear on COMBAT V2. All of it on one page ran
            -- past VISIBLE_ROWS, so the last rows were never on screen.
            name = "COMBAT",
            rows = {
                toggle("Melee Weapon DMG",      "MeleeWeaponDamage"),
                number("  Weapon Damage",       "MeleeDamage", 25, 25, 1000, "%.0f", "MeleeWeaponDamage"),
                number("  Weapon Weight",       "MeleeWeightClass", 1, 1, 50, "%.0f", "MeleeWeaponDamage"),
                number("  Weapon Knockback",    "MeleeKnockback", 5, 2, 100, "%.0fx", "MeleeWeaponDamage"),
                action("  Test Weapon Damage",  function() PlayerMods.StartMeleeTest() end),
                toggle("Melee Always Hits",     "MeleeAlwaysHits"),
                number("  Melee Reach",         "MeleeReach", 10, 10, 250, "%.0f", "MeleeAlwaysHits"),
            },
        },
        {
            -- Bare hands and body handling. These were the back half of COMBAT,
            -- which ran to 18 rows and pushed the grab settings off the panel.
            name = "HAND & GRAB",
            rows = {
                toggle("Strength Fists",        "StrengthFists"),
                number("  Fist Power",          "FistStrikePower", 1, 1, 50, "%.0f", "StrengthFists"),
                number("  Fist Damage",         "FistDamage", 25, 25, 1000, "%.0f", "StrengthFists"),
                toggle("  Knock Them Down",     "FistRagdoll"),
                toggle("  Send Them Flying",    "FistLaunch"),
                number("  Launch Force",        "FistLaunchForce", 150, 0, 4000, "%.0f", "FistLaunch"),
                action("  Test Fist Damage",    function() PlayerMods.StartFistTest() end),
                toggle("Grab & Throw Bodies",   "GrabEnemies"),
                number("  Grab Range",          "GrabRange", 10, 30, 250, "%.0f", "GrabEnemies"),
                number("  Throw Force",         "ThrowForce", 200, 200, 6000, "%.0f", "GrabEnemies"),
                action("  Test Grab & Throw",   function() PlayerMods.StartGrabTest() end),
            },
        },
        {
            name = "COMBAT V2",
            rows = {
                toggle("Infinite Ammo",         "InfiniteAmmo"),
                toggle("No Recoil",             "NoRecoil"),
                toggle("Full Auto (all guns)",  "FullAuto"),
                number("  Fire Rate (sec/shot)","FireRateValue", 0.02, 0.02, 0.5, "%.2f", "FullAuto"),
                number("  Fire Mode Index",     "FireModeIndex", 1, 0, 3, "%.0f", "FullAuto"),
                action("Refill Everything Now", function() PlayerMods.RefillNow() end),
                action("Toggle Headlamp",       function() PlayerMods.ToggleHeadlamp() end),
                action("Toggle Night Vision",   function() PlayerMods.ToggleNightVision() end),
                toggle("No Accidental Lamp/NVG","NoAccidentalLamp"),
                action("  Test Lamp Lock",      function() PlayerMods.StartLampTest() end),
            },
        },
        {
            name = "ENEMIES",
            rows = {
                toggle("Enemy ESP (in headset)", "EnemyESP"),
                action("Restart ESP  (or END key)", function()
                    PlayerMods.RestartESP(GUI)
                end),
                toggle("Freeze Enemies",        "FreezeEnemies"),
                toggle("Stop Enemy Spawns",     "StopEnemySpawns"),
                action("Delete All Enemies",    function() PlayerMods.KillAllEnemies() end),
                info  ("Enemies Loaded", function()
                    return tostring(PlayerMods.info.enemies or 0)
                end),
                info  ("Your Kills", function()
                    return tostring(PlayerMods.info.kills or 0)
                end),
            },
        },
        {
            name = "MOVEMENT",
            rows = {
                toggle("Super Speed",          "SuperSpeed"),
                number("  Speed Multiplier",   "SpeedMultiplier", 0.5, 1.0, 10.0, "%.1fx", "SuperSpeed"),
                toggle("Virtual Jump (A button)","VirtualJump"),
                action("  Test Jump",           function() PlayerMods.StartJumpTest() end),
                toggle("High Jump",            "HighJump"),
                number("  Jump Multiplier",    "JumpMultiplier",  0.5, 1.0, 10.0, "%.1fx", "HighJump"),
                toggle("Long Teleport",        "TeleportBoost"),
                toggle("Fly (look to steer)",  "FlyMode"),
                toggle("NoClip (fly + ghost)", "NoClip"),
                number("  Fly Speed",          "FlySpeed", 100, 100, 4000, "%.0f"),
                toggle("  Stick Controls Fly",  "FlyNeedsStick"),
                number("  Level = Hover",      "FlyDeadzone", 0.05, 0.05, 0.6, "%.2f"),
                toggle("Crouch Down",          "CrouchDown"),
                toggle("  R-Stick Toggles It",  "CrouchOnStick"),
                number("  Crouch Height",      "CrouchHeight", 5, 20, 90, "%.0f", "CrouchDown"),
                number("  Crouch Drop",        "CrouchDrop", 10, 0, 150, "%.0f", "CrouchDown"),
            },
        },
        {
            name = "WORLD",
            rows = {
                number("Time Scale",           "TimeScale", 0.1, 0.1, 3.0, "%.1fx"),
                action("Apply Time Scale",     function()
                    PlayerMods.SetTimeScale(PlayerMods.state.TimeScale)
                end),
                action("Slow Motion (0.2x)",   function() PlayerMods.SetTimeScale(0.2) end),
                action("Normal Speed (1.0x)",  function() PlayerMods.SetTimeScale(1.0) end),
                toggle("Brighten The World",   "BrightWorld"),
                number("  Brightness",         "Brightness", 0.25, 1.0, 5.0, "%.2f", "BrightWorld"),
                toggle("Gore Never Despawns",  "GoreForever"),
                action("Unlock All Progress",  function() PlayerMods.UnlockAll() end),
            },
        },
        {
            name = "SPAWN",
            rowsFn = function() return GUI.SpawnRows() end,
        },
        {
            name = "MAPS",
            rowsFn = function() return GUI.MapRows() end,
        },
        {
            -- Menu and audio plumbing. These are not player cheats and were
            -- crowding the PLAYER tab off the bottom of the panel.
            name = "SETTINGS",
            rows = {
                action("FIX AUDIO (restore volume)", function() PlayerMods.FixAudio() end),
                number("Master Volume",        "MasterVolume", 0.05, 0, 1, "%.2f"),
                info  ("Audio", function() return PlayerMods.AudioReport() end),
                number("Panel Size",           "PanelSize", 0.2, 0.6, 6, "%.1f"),
                number("Panel Height trim",    "PanelLift", 1, -20, 20, "%.0f"),
                toggle("Panel Draws Over World", "PanelOnTop"),
                toggle("Panel Hides Behind Hands", "PanelDepthFix"),
                toggle("Panel Solid Background", "PanelSolidBg"),
                -- the laser defaults to the left hand because the right one is
                -- usually holding a gun on the same trigger that clicks
                action("CALIBRATE POINTER (aim at me, press)", function()
                    GUI.CalibratePointer(GUI.pointer.hand)
                end),
                number("Pointer Aim Pitch",    "PointerPitch", 5, -90, 90, "%.0f deg"),
                number("Pointer Aim Yaw",      "PointerYaw", 5, -90, 90, "%.0f deg"),
                toggle("Aim From Hand Rig (automatic)", "AimFromSocket"),
                toggle("Touch Mode (reach out, no aiming)", "TouchPointer"),
                number("  Touch Reach",       "TouchRange", 5, 5, 200, "%.0f cm"),
                toggle("Two Pointers (both hands)", "TwoPointers"),
                info  ("Laser L/R", function()
                    if GUI.calibReject then return GUI.calibReject end
                    return string.format("%s / %s",
                        GUI.pointerL.hit and "ON PANEL" or GUI.pointerL.why,
                        GUI.pointerR.hit and "ON PANEL" or GUI.pointerR.why)
                end),
                action("Pointer Hand: swap L/R", function()
                    GUI.pointer.hand = not GUI.pointer.hand
                    PlayerMods.beamOn = { [true] = nil, [false] = nil }  -- re-arm both beams
                end),
                info  ("Pointer", function()
                    return (GUI.pointer.hand and "left hand" or "right hand")
                end),
                info  ("Panel",   function() return GUI.PanelStyleReport() end),
            },
        },
    }
end

-- Look a page up by name. Page order changes whenever one is added or split,
-- so nothing should hardcode an index.
function GUI.Pages() return pages end

function GUI.PageIndex(name)
    for i, p in ipairs(pages) do
        if p.name == name then return i end
    end
    return 1
end

---------------------------------------------------------------------------
-- the maps page: groups, then the maps inside a group
---------------------------------------------------------------------------

local okMaps, MAPS = pcall(require, "map_list")
if not okMaps or type(MAPS) ~= "table" then MAPS = {} end
GUI.mapGroup = nil

function GUI.MapRows()
    local rows = {}

    if GUI.mapGroup == nil then
        for i, grp in ipairs(MAPS) do
            local idx = i
            rows[#rows + 1] = action(
                string.format("%-16s (%d)", grp.name, #grp.items),
                function() GUI.mapGroup = idx; GUI.row = 1 end)
        end
        if #rows == 0 then
            rows[#rows + 1] = info("map_list.lua missing", function() return "-" end)
        end
        return rows
    end

    local grp = MAPS[GUI.mapGroup]
    if not grp then GUI.mapGroup = nil; return GUI.MapRows() end

    rows[#rows + 1] = action("< Back to map groups",
        function() GUI.mapGroup = nil; GUI.row = 1 end)

    for _, entry in ipairs(grp.items) do
        local name, path = entry[1], entry[2]
        rows[#rows + 1] = action(name, function()
            PlayerMods.LoadMap(path)
        end)
    end
    return rows
end

---------------------------------------------------------------------------
-- the spawn page: categories, then items inside a category
---------------------------------------------------------------------------

function GUI.SpawnRows()
    local rows = {}

    if GUI.spawnCat == nil then
        for i = 1, SpawnerMods.CategoryCount() do
            local cat = SpawnerMods.Category(i)
            local avail = SpawnerMods.AvailableCount(i)
            -- a category with nothing spawnable left in it is not worth a row
            if avail > 0 then
                local idx = i
                rows[#rows + 1] = action(
                    string.format("%-22s (%d)", cat.name, avail),
                    function() GUI.spawnCat = idx; GUI.row = 1 end)
            end
        end
        return rows
    end

    local cat = SpawnerMods.Category(GUI.spawnCat)
    if not cat then GUI.spawnCat = nil; return GUI.SpawnRows() end

    rows[#rows + 1] = action("< Back to categories",
        function() GUI.spawnCat = nil; GUI.row = 1 end)
    rows[#rows + 1] = number("How many per spawn", "__spawnCount", 1, 1, 25, "%d")
    rows[#rows + 1] = action("** SPAWN ONE OF EVERYTHING **", function()
        SpawnerMods.SpawnWholeCategory(GUI.spawnCat, PlayerMods.GetPawn, 40)
    end)

    -- Only things that will actually appear in the world. Engine classes and
    -- unresolvable blueprints are left out entirely rather than listed and then
    -- failing when you press Enter.
    for _, entry in ipairs(cat.items) do
        if SpawnerMods.IsSpawnable(entry) then
            local pretty, className = entry[1], entry[2]
            rows[#rows + 1] = action(pretty, function()
                SpawnerMods.SpawnByClassName(className, PlayerMods.GetPawn, GUI.spawnCount)
            end)
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- navigation
---------------------------------------------------------------------------

local function currentPage()
    return pages[GUI.page]
end

-- Rows for mods the live pawn physically cannot do are removed, not greyed:
-- Blood Trail's two player classes have different abilities, and a row you can
-- highlight and toggle but that does nothing is worse than no row at all.
local function currentRows()
    local p = currentPage()
    if not p then return {} end

    local rows = p.rowsFn and p.rowsFn() or p.rows
    if not PlayerMods.Applies then return rows end

    local out = {}
    for _, r in ipairs(rows) do
        local gate = r.needs or ((r.kind == "toggle") and r.key or nil)
        if gate == nil or PlayerMods.Applies(gate) then
            out[#out + 1] = r
        end
    end
    return out
end

-- The spawn-count row lives on the GUI rather than PlayerMods.state, so give it
-- its own accessors.
local function readKey(key)
    if key == "__spawnCount" then return GUI.spawnCount end
    return PlayerMods.state[key]
end

local function writeKey(key, value)
    if key == "__spawnCount" then GUI.spawnCount = value return end
    PlayerMods.state[key] = value
end

function GUI.Toggle()
    GUI.IsOpen = not GUI.IsOpen
    GUI.dirty = true
    GUI.UnlockLift()   -- re-centre once for this opening, then hold still
end

function GUI.Nav(delta)
    if not GUI.IsOpen then return end
    local n = #currentRows()
    if n == 0 then GUI.row = 1 GUI.dirty = true return end
    GUI.row = GUI.row + delta
    if GUI.row < 1 then GUI.row = n end
    if GUI.row > n then GUI.row = 1 end
    GUI.dirty = true
end

function GUI.PageChange(delta)
    if not GUI.IsOpen then return end
    GUI.page = GUI.page + delta
    if GUI.page < 1 then GUI.page = #pages end
    if GUI.page > #pages then GUI.page = 1 end
    GUI.row = 1
    GUI.spawnCat = nil
    GUI.mapGroup = nil
    GUI.dirty = true
end

function GUI.Adjust(delta)
    if not GUI.IsOpen then return end
    local r = currentRows()[GUI.row]
    if not r then return end

    if r.kind == "toggle" then
        -- SAFE MODE pins a handful of combat keys to false every tick, so
        -- toggling one while it is on flips for a tenth of a second and snaps
        -- back - which reads as "the click does nothing, it keeps resetting".
        -- Turning the feature on is a clear statement of intent, so drop SAFE
        -- MODE rather than silently fight it.
        if PlayerMods.SafeModeSuppresses and PlayerMods.SafeModeSuppresses(r.key)
           and not readKey(r.key) then
            writeKey("SafeMode", false)
            writeKey(r.key, true)
            GUI.dirty = true
            return
        end
        writeKey(r.key, not readKey(r.key))
    elseif r.kind == "number" then
        local v = (readKey(r.key) or r.min) + (r.step * delta)
        v = math.floor((v / r.step) + 0.5) * r.step   -- keep it on the step
        if v < r.min then v = r.min end
        if v > r.max then v = r.max end
        writeKey(r.key, v)
    end
    GUI.dirty = true
end

function GUI.Activate()
    if not GUI.IsOpen then return end
    local r = currentRows()[GUI.row]
    if not r then return end

    if r.kind == "action" then
        pcall(r.run)
    elseif r.kind ~= "info" then
        GUI.Adjust(1)
    end
    GUI.dirty = true
end

-- Backspace: leave a spawn category without hunting for the Back row.
function GUI.Back()
    if not GUI.IsOpen then return end
    if GUI.spawnCat ~= nil then
        GUI.spawnCat = nil
        GUI.row = 1
        GUI.dirty = true
    elseif GUI.mapGroup ~= nil then
        GUI.mapGroup = nil
        GUI.row = 1
        GUI.dirty = true
    end
end

---------------------------------------------------------------------------
-- text building
---------------------------------------------------------------------------

local function rule(ch)
    return string.rep(ch or "=", GUI.WIDTH)
end

local function valueOf(r)
    if r.kind == "toggle" then
        return readKey(r.key) and "[ON]" or "[OFF]"
    elseif r.kind == "number" then
        return string.format(r.fmt, readKey(r.key) or 0)
    elseif r.kind == "info" then
        local ok, v = pcall(r.valueFn)
        return ok and tostring(v) or "?"
    end
    return "[GO]"
end

local function windowBounds(total)
    local vis = GUI.VISIBLE_ROWS
    if total <= vis then return 1, total end
    local first = GUI.row - math.floor(vis / 2)
    if first < 1 then first = 1 end
    if first + vis - 1 > total then first = total - vis + 1 end
    return first, first + vis - 1
end

-- Laid out after the BONELAB "Ultimate 3D HMD" menu, which is built from a
-- title bar, a row of tab buttons, a bordered content panel of labelled
-- toggles, and a status line pinned to the bottom. That menu is a Unity
-- world-space Canvas; here the only thing that can draw in the headset is the
-- pawn's UTextRenderComponent, so the same layout is drawn with box-glyphs.
-- Every attempt to spawn or re-parent a real panel component has hard-crashed
-- the game, so this deliberately stays inside the component the pawn owns.

local BOX = { tl = "+", tr = "+", bl = "+", br = "+", h = "-", v = "|" }

local function frameTop()    return BOX.tl .. string.rep(BOX.h, GUI.WIDTH - 2) .. BOX.tr end
local function frameBottom() return BOX.bl .. string.rep(BOX.h, GUI.WIDTH - 2) .. BOX.br end
local function frameSplit()  return BOX.v  .. string.rep(BOX.h, GUI.WIDTH - 2) .. BOX.v  end

-- one content line inside the border, clipped so a long label cannot push the
-- right-hand edge out and make the panel look ragged
local function frameLine(text)
    local inner = GUI.WIDTH - 4
    if #text > inner then text = string.sub(text, 1, inner) end
    return BOX.v .. " " .. text .. string.rep(" ", inner - #text) .. " " .. BOX.v
end

local function centred(text)
    local inner = GUI.WIDTH - 4
    if #text >= inner then return frameLine(text) end
    local pad = math.floor((inner - #text) / 2)
    return frameLine(string.rep(" ", pad) .. text)
end

-- The tab strip. BONELAB shows every tab at once with the active one boxed;
-- with this many pages that would overflow 50 columns, so window it around the
-- current page the same way the rows are windowed.
-- Which tab sits under a hit, as a fraction across the panel. Shared by the
-- hover highlight and the click, so what lights up is exactly what activates.
local function tabAtFrac(L, frac)
    if not L then return nil end
    local col = math.floor(frac * GUI.WIDTH)
    if L.tabRanges then
        for _, r in ipairs(L.tabRanges) do
            if col >= r.lo and col <= r.hi then return r.idx end
        end
        if #L.tabRanges > 0 then
            return (col < L.tabRanges[1].lo) and L.tabRanges[1].idx
                                             or L.tabRanges[#L.tabRanges].idx
        end
    end
    if L.tabLo and L.tabHi then
        local span = (L.tabHi - L.tabLo) + 1
        return L.tabLo + math.floor(frac * span)
    end
    return nil
end

local function tabStrip()
    local names, width = {}, GUI.WIDTH - 4
    for i, pg in ipairs(pages) do
        if i == GUI.page then
            names[i] = "[" .. pg.name .. "]"          -- the tab you are on
        elseif i == GUI.hoverTab then
            names[i] = ">" .. pg.name .. "<"          -- the tab under the pointer
        else
            names[i] = " " .. pg.name .. " "
        end
    end

    -- grow outwards from the active tab until the strip fills the panel
    local lo, hi = GUI.page, GUI.page
    local len = #names[GUI.page]
    while true do
        local grew = false
        if hi < #names and (len + #names[hi + 1]) <= width then
            hi = hi + 1; len = len + #names[hi]; grew = true
        end
        if lo > 1 and (len + #names[lo - 1]) <= width then
            lo = lo - 1; len = len + #names[lo]; grew = true
        end
        if not grew then break end
    end

    local strip = table.concat(names, "", lo, hi)
    if lo > 1  then strip = "<" .. string.sub(strip, 2) end
    if hi < #names then strip = string.sub(strip, 1, #strip - 1) .. ">" end

    -- WHERE EACH TAB ACTUALLY SITS, in characters.
    --
    -- Dividing the strip into equal slices assumes every tab name is the same
    -- width. They are not - "SPAWN" and "HAND & GRAB" differ by six characters -
    -- so an even split sends clicks to the neighbouring tab, which is what made
    -- tab clicking feel glitchy and made one tab seem stuck. frameLine puts the
    -- strip two characters in, after "| ".
    local ranges, col = {}, 2
    for i = lo, hi do
        local w = #names[i]
        ranges[#ranges + 1] = { idx = i, lo = col, hi = col + w - 1 }
        col = col + w
    end
    return strip, lo, hi, ranges
end

-- Row rendering, mirroring the desktop app (BloodTrailModMenu.py):
--   toggles  a checkbox on the LEFT, not an [ON]/[OFF] tag on the right
--   numbers  indented under their toggle, with a filled track and the value
--   actions  a centred button bar
--   info     a label with its reading right-aligned
-- One line per row: the desktop app can afford a caption line above each
-- slider, a headset showing twelve rows cannot.
local function trackBar(v, lo, hi, cells)
    cells = cells or 10
    if type(v) ~= "number" then v = 0 end
    if type(lo) ~= "number" or type(hi) ~= "number" or hi <= lo then
        return string.rep("-", cells)
    end
    local f = (v - lo) / (hi - lo)
    if f < 0 then f = 0 end
    if f > 1 then f = 1 end
    local n = math.floor((f * cells) + 0.5)
    return string.rep("#", n) .. string.rep("-", cells - n)
end

local function clip(t, n)
    t = tostring(t)
    if #t > n then return string.sub(t, 1, n) end
    return t .. string.rep(" ", n - #t)
end

local function rowText(r, selected)
    local mark = selected and ">" or " "
    local inner = GUI.WIDTH - 4
    local body

    if r.kind == "toggle" then
        local mk = readKey(r.key) and "x" or " "
        if PlayerMods.SafeModeSuppresses and PlayerMods.SafeModeSuppresses(r.key) then
            mk = "~"          -- held off by SAFE MODE; clicking releases it
        end
        body = string.format("[%s] %s", mk, r.label)

    elseif r.kind == "number" then
        local v = readKey(r.key) or 0
        -- 16 for the label leaves 11 for the value, which is what the widest
        -- of them ("1800 force") needs; at 20 it clipped to "900 for"
        body = string.format("   %s [%s] %s",
                             clip(r.label, 16), trackBar(v, r.min, r.max),
                             string.format(r.fmt, v))

    elseif r.kind == "action" then
        local t = "[ " .. r.label .. " ]"
        local room = inner - 2
        if #t < room then
            t = string.rep(" ", math.floor((room - #t) / 2)) .. t
        end
        body = t

    else -- info
        local ok, val = pcall(r.valueFn)
        body = string.format("   %s %s", clip(r.label, 20), ok and tostring(val) or "?")
    end

    return frameLine(mark .. " " .. body)
end

function GUI.BuildText()
    local p = currentPage()
    if not p then return "" end
    local rows = currentRows()

    -- sub-pages (a spawn category, a map group) read as a breadcrumb
    local title = p.name
    if p.name == "SPAWN" and GUI.spawnCat then
        local cat = SpawnerMods.Category(GUI.spawnCat)
        if cat then title = "SPAWN / " .. cat.name end
    elseif p.name == "MAPS" and GUI.mapGroup then
        local grp = MAPS[GUI.mapGroup]
        if grp then title = "MAPS / " .. grp.name end
    end

    -- The pointer has to turn a laser hit into a row, so record which printed
    -- line each part of the panel ended up on. Doing it here, while the text is
    -- being built, is the only way the two can never disagree.
    local L = { tabLine = 0, tabLo = 1, tabHi = 1, rowLine = 0,
                rowFirst = 1, rowCount = 0, lines = 0 }

    local out = {}
    out[#out + 1] = frameTop()
    out[#out + 1] = frameLine(string.format("%s%s",
                        clip("BLOOD TRAIL  .  MOD MENU", GUI.WIDTH - 4 - 12),
                        clip(PlayerMods.info.pawn or "-", 12)))
    out[#out + 1] = frameSplit()
    local strip, tlo, thi, tranges = tabStrip()
    L.tabLine, L.tabLo, L.tabHi, L.tabRanges = #out + 1, tlo, thi, tranges
    out[#out + 1] = frameLine(strip)
    out[#out + 1] = frameSplit()

    -- No "--- PLAYER ---" line: the tab strip already boxes the active tab, so
    -- repeating it just costs a row of headset space. Sub-pages DO get one,
    -- because the strip cannot show a breadcrumb.
    if title ~= p.name then
        out[#out + 1] = centred("--- " .. string.upper(title) .. " ---")
    end

    local total = #rows
    local first, last = windowBounds(total)
    if first > 1 then out[#out + 1] = frameLine("   ^ more above") end

    L.rowLine, L.rowFirst, L.rowCount = #out + 1, first, (last - first + 1)
    for i = first, last do
        out[#out + 1] = rowText(rows[i], i == GUI.row)
    end

    if last < total then out[#out + 1] = frameLine("   v more below") end

    -- StatusText, pinned to the bottom exactly like the reference menu
    out[#out + 1] = frameSplit()
    out[#out + 1] = frameLine(string.format("Playing as %s.  enemies:%s  tab %d/%d",
                                            PlayerMods.info.pawn or "nobody",
                                            tostring(PlayerMods.info.enemies or 0),
                                            GUI.page, #pages))
    out[#out + 1] = frameLine("Move your hand over a row  |  B close  Y fly  X noclip")
    out[#out + 1] = frameBottom()

    -- A BACKING PLATE, AS FAR AS ONE TEXT SURFACE ALLOWS.
    --
    -- A real filled background needs a SECOND render surface behind this one.
    -- There is no way to get one: spawning our own text actor killed the game
    -- twice (see the note further up), and the pawn's other text components are
    -- all 66-96 cm away from this one, so none can be used as a backing plate
    -- without moving it - the one operation that has never survived.
    --
    -- What a single-colour text surface CAN do is draw the panel inside out:
    -- fill every blank cell and blank every drawn cell, so the panel becomes a
    -- solid slab with the text punched through it as holes. Off by default
    -- because whether it reads better than plain text depends on the font, and
    -- that can only be judged in the headset.
    if PlayerMods.state.PanelSolidBg then
        for i = 1, #out do
            local line, sw = out[i], {}
            for c = 1, #line do
                local ch = string.sub(line, c, c)
                sw[c] = (ch == " ") and "#" or " "
            end
            -- pad to the full width so the slab has no ragged right edge
            local row = table.concat(sw)
            if #row < GUI.WIDTH then
                row = row .. string.rep("#", GUI.WIDTH - #row)
            end
            out[i] = row
        end
    end

    -- RAISING THE PANEL WITHOUT MOVING THE COMPONENT.
    --
    -- CameraText sits about 23 cm BELOW eye level, so the menu hangs low in the
    -- view. The component cannot be moved - K2_SetRelativeLocation on it has
    -- killed the game - but the text is CENTRE-anchored (VerticalAlignment=1),
    -- which means the block is centred on the component's origin. Padding the
    -- bottom with blank lines therefore pushes the visible content UP by half a
    -- line each, with no transform touched at all.
    --
    -- The pointer maths is unaffected: it divides the measured block height by
    -- the real line count, and both grow together.
    L.framed = #out          -- before any padding, so the probe can tell them apart

    local trim = PlayerMods.state.PanelLift
    if type(trim) ~= "number" then trim = 0 end
    local lift = (GUI.autoLift or 0) + trim
    if lift > 0 then
        for _ = 1, math.floor(lift) do
            out[#out + 1] = " "   -- a space, not "", so the line is really rendered
        end
    end

    L.lines = #out
    GUI.layout = L

    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- rendering to the pawn's world-space text component
---------------------------------------------------------------------------

local lastText = nil
local lastPrinted = nil
local styledComponent = nil
local hadVisibility = nil

local function isValid(obj)
    if not obj then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function getTextComponent(pawn)
    for _, name in ipairs({ "CameraText", "TextRender", "AmmoProxyText" }) do
        local ok, c = pcall(function() return pawn[name] end)
        if ok and isValid(c) then return c end
    end
    return nil
end

---------------------------------------------------------------------------
-- Putting the text where the player is actually looking
---------------------------------------------------------------------------
-- The menu and ESP were being written to the pawn's own CameraText component,
-- and whether that is in front of your face is the game's business, not ours -
-- which is why the ESP never appeared in the headset. Drive the component's
-- placement explicitly instead, off the real VR camera.
--
-- AVRCharacter (the Wendigo pawn's base) exposes VRReplicatedCamera, a
-- UReplicatedVRCameraComponent. K2_GetComponentLocation/Rotation take no
-- arguments and return values, so they are safe to call; K2_TeleportTo takes
-- exactly two and returns a bool, avoiding the out-parameter arity traps.

GUI.textDistance = 90.0     -- cm in front of the eyes
GUI.textDrop     = 25.0     -- cm below eye line, so it does not cover the sights
GUI.textSize     = 4.0

local panelActor = nil      -- our own ATextRenderActor
local panelComp  = nil

local function getCamera(pawn)
    for _, name in ipairs({ "VRReplicatedCamera", "Camera", "VRCamera" }) do
        local ok, c = pcall(function() return pawn[name] end)
        if ok and isValid(c) then return c end
    end
    return nil
end

-- ==========================================================================
-- WHY THIS DRIVES THE PAWN'S OWN COMPONENT AND NOTHING ELSE
--
-- Two attempts at a dedicated text actor both killed the game:
--   * teleporting it into place from the LoopAsync thread ->
--     access violation in VCRUNTIME140.dll writing at 0x17C (actor transforms
--     are game-thread-only, and a struct copy raced the engine)
--   * spawning + K2_AttachToComponent on the game thread ->
--     silent death during creation, no log line, no dump
--
-- The pawn already owns a UTextRenderComponent that is registered, parented and
-- positioned by the game (CameraText on Wendigo, TextRender on the legacy pawn).
-- Writing text to it ran for many sessions without a single crash. So: use it,
-- and touch nothing but the safe scalar setters.
--
-- The reason the ESP never appeared is almost certainly bHiddenInGame: a
-- component can be "visible" and still not render. SetVisibility alone does not
-- clear it, which is why the menu never showed either.
-- ==========================================================================

-- One place decides how the panel is sized and anchored, so the two styling
-- paths below cannot drift apart.
--
-- HORIZONTAL ALIGNMENT IS THE BIG ONE. It was EHTA_Left, which anchors the text
-- block's LEFT EDGE to the component origin - and the origin sits dead ahead of
-- the player, so the whole panel hung off to the right and ran out of the view.
-- EHTA_Center (1) centres the block on the origin, putting it in front of both
-- eyes.
--
-- SIZE stands in for distance. The component cannot be moved (that has killed
-- the game every time), but a text block half the size subtends half the angle,
-- which is exactly what moving it further away would look like.
-- WHY THE PANEL DRAWS THROUGH YOUR HANDS.
--
-- Not DepthPriorityGroup. The game assigns CameraText the material
--   /Game/WeaponMaster/DemoRoom/Materials/M_GlowingText_NoDepth
-- whose bDisableDepthTest is TRUE - it is deliberately a HUD material that
-- shows through geometry, which is right for an ammo counter and wrong for a
-- menu the size of a door. No component flag can override a material that has
-- opted out of the depth test.
--
-- The replacement is taken from UTextRenderComponent's own class default
-- rather than by guessing an asset path: LoadAsset throws a C++ exception that
-- pcall cannot catch when a path is wrong, and StaticFindObject on the CDO is
-- a plain hash lookup that cannot fail badly. Whatever the engine ships as the
-- default text material is depth-tested and, being the default, is guaranteed
-- to render text correctly.
local depthMat, depthMatTried = nil, false
local originalMat = nil

local function engineTextMaterial()
    if depthMatTried then return depthMat end
    depthMatTried = true
    pcall(function()
        local cdo = StaticFindObject("/Script/Engine.Default__TextRenderComponent")
        if not cdo then return end
        local m = cdo.TextMaterial
        if m then depthMat = m end
    end)
    return depthMat
end

local function applyMaterial(comp)
    -- remember what the game had, so turning the fix off puts it back
    if originalMat == nil then
        pcall(function() originalMat = comp.TextMaterial end)
    end
    -- Swapping a material rebuilds the render state too; same rule.
    local want = nil
    if PlayerMods.state.PanelDepthFix then
        want = engineTextMaterial()
    else
        want = originalMat
    end
    if want then
        ExecuteInGameThread(function()
            if not isValid(comp) then return end
            pcall(function() comp:SetTextMaterial(want) end)
        end)
    end
end

-- Depth, applied by BOTH styling paths - it previously lived on only one of
-- them, so whichever ran first decided the outcome.
--
-- NOTE: DepthPriorityGroup is only half the story. Whether the panel draws
-- through a hand is finally decided by the MATERIAL: UMaterial carries a
-- bDisableDepthTest flag, and a HUD text material with that set draws over
-- everything no matter what the component asks for. GUI.MaterialReport()
-- reads it so this stops being guesswork.
local function applyDepth(comp)
    local want = PlayerMods.state.PanelOnTop and 1 or 0
    pcall(function() comp.DepthPriorityGroup = want end)
    -- A property write alone does not refresh the render proxy; bouncing
    -- visibility forces the component to rebuild it. Rebuilding a render state
    -- is game-thread work - doing it from the async loop is what the 0x268
    -- access violation looked like - so hand it over.
    ExecuteInGameThread(function()
        if not isValid(comp) then return end
        pcall(function() comp:SetVisibility(false, false) end)
        pcall(function() comp:SetVisibility(true, false) end)
    end)
end

local appliedSize = { nil, nil }

local function panelSize()
    local v = PlayerMods.state and PlayerMods.state.PanelSize
    if type(v) ~= "number" or v <= 0 then v = 2.2 end
    return v
end

-- returns true when the size changed and the cached "already styled" key must
-- be ignored so the new size actually gets applied
local function sizeChanged(slot)
    local want = panelSize()
    if appliedSize[slot] ~= want then
        appliedSize[slot] = want
        GUI.liftLocked = false      -- new line height, so the centring must be redone
        return true
    end
    return false
end

local styleDone = nil       -- address of the component we already configured
local lastCompAddr = nil    -- so a new pawn's component is picked up
local reassertIn = 0        -- countdown to re-applying visibility + text

-- Why the periodic re-assert exists:
--
-- Caching "already styled" and "text unchanged" forever means that if the GAME
-- re-hides the component or writes its own text over ours, the mod never notices
-- and the ESP silently dies - staying dead until a world change resets the
-- caches, which is exactly the reported "stops working until the round ends".
-- Re-applying every couple of seconds recovers automatically, while staying far
-- below the per-tick spam that crashes these games.
local REASSERT_TICKS = 20   -- ~2 s at the 10 Hz refresh

-- The cheap half: just the two render flags. Safe to repeat, and the only thing
-- the periodic re-assert is allowed to do.
--
-- The first version of the re-assert cleared styleDone, so the FULL styling
-- below - camera lookup, two component transform reads, a string build and a log
-- line - re-ran every 2 seconds forever. In Raid Mode, where levels stream in and
-- out, that repeatedly touched components while they were being destroyed and
-- crashed the game at UE4SS.dll+0x4BAAAF, the same property-resolution fault as
-- the very first crash in this project.
local function assertVisible(comp)
    pcall(function() comp:SetVisibility(true, true) end)
    pcall(function() comp:SetHiddenInGame(false, true) end)
end

-- Pin the text to the camera, once per component.
--
-- This is the real cause of "the ESP unlinks and stays in one spot": CameraText
-- is NOT parented to the VR camera - it hangs off the pawn, which in roomscale
-- stays put while your head moves. So the text ends up lying on the floor
-- wherever the pawn origin happens to be, exactly as in the screenshot.
--
-- Attaching it to the camera with SnapToTarget (EAttachmentRule 2) makes it take
-- the camera's transform, after which a relative offset puts it in front of your
-- face and it follows the head for free - no per-tick transform work, which is
-- what crashed earlier attempts.
--
-- The relative setters take a trailing FHitResult out-parameter. Passing all
-- four arguments is required; omitting the out-param is the arity mistake that
-- corrupts memory.
-- DO NOT re-parent or move this component. Attempted three times, fatal every
-- time: spawning a text actor and teleporting it, spawning one and attaching it,
-- and now K2_AttachToComponent + K2_SetRelativeLocation/Rotation on the pawn's
-- own CameraText. All three killed the game outright.
--
-- The component is left exactly where the game puts it. Measured across many
-- sessions it sits 68 cm ahead and 23 cm below the eyes, which is correct - the
-- "text on the floor" case is a separate problem (see the pawn lookup in
-- player_mods.lua), not the component's placement.
local function attachToCamera(pawn, comp)
    return false
end

-- The expensive half: ONCE per component, never on a timer.
local function styleComponent(comp)
    local ok, addr = pcall(function() return comp:GetAddress() end)
    local key = ok and addr or nil
    local resize = sizeChanged(1)
    if key and styleDone == key and not resize then return end

    pcall(function() comp:SetWorldSize(panelSize()) end)
    pcall(function() comp:SetHorizontalAlignment(1) end)   -- EHTA_Center
    pcall(function() comp:SetTextRenderColor({ R = 60, G = 255, B = 120, A = 255 }) end)
    applyDepth(comp)
    applyMaterial(comp)
    -- Both of these, and both arguments each. A component that is visible but
    -- hidden-in-game draws nothing, which is exactly what we were seeing.
    assertVisible(comp)
    styleDone = key

    GUI.panelReady = true

    -- make it ride the head instead of sitting wherever the pawn is
    GUI.panelAttached = false
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if pawn then GUI.panelAttached = attachToCamera(pawn, comp) end
    end)

    -- Measure where the text actually sits relative to the eyes. Without this
    -- "it isn't showing in the headset" is unfalsifiable: text 6 m behind you is
    -- indistinguishable from text that never rendered.
    GUI.panelGeom = "unknown"
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then return end
        local cam = getCamera(pawn)
        if not cam then return end

        local tl = comp:K2_GetComponentLocation()
        local cl = cam:K2_GetComponentLocation()
        local cr = cam:K2_GetComponentRotation()
        if not (tl and cl and cr) then return end

        local dx, dy, dz = tl.X - cl.X, tl.Y - cl.Y, tl.Z - cl.Z
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

        -- positive = in front of the camera, negative = behind you
        local yaw = math.rad(cr.Yaw or 0)
        local ahead = (math.cos(yaw) * dx) + (math.sin(yaw) * dy)

        -- Read the render flags BACK after setting them. If bVisible is true and
        -- bHiddenInGame is false, the component is in a drawable state - which,
        -- with the placement above, is as far as this can be proven without
        -- wearing the headset (the game renders black to the desktop mirror when
        -- the HMD is idle, even with -nohmd).
        local vis, hid = "?", "?"
        local okV, v = pcall(function() return comp.bVisible end)
        if okV then vis = tostring(v) end
        local okH, hgi = pcall(function() return comp.bHiddenInGame end)
        if okH then hid = tostring(hgi) end

        GUI.panelGeom = string.format(
            "dist=%.0fcm ahead=%.0fcm up=%.0fcm size=%.1f visible=%s hidden=%s attached=%s",
            dist, ahead, dz, panelSize(), vis, hid, tostring(GUI.panelAttached))
    end)

    print("[ModMenu] display component ready: " .. tostring(GUI.panelGeom) .. "\n")
end

-- Style once per component, not per refresh: repeatedly pushing identical
-- structs at the engine is a known way to take these games down.
local function styleOnce(comp)
    local ok, addr = pcall(function() return comp:GetAddress() end)
    local key = ok and addr or nil
    local resize = sizeChanged(2)
    if key and styledComponent == key and not resize then return end

    pcall(function() comp:SetWorldSize(panelSize()) end)
    pcall(function() comp:SetHorizontalAlignment(1) end)   -- EHTA_Center
    pcall(function() comp:SetTextRenderColor({ R = 60, G = 255, B = 120, A = 255 }) end)

    -- Without this the menu is depth-sorted against the world, so a gun, a hand
    -- or a wall in front of it slices the text apart. SDPG_Foreground (1) draws
    -- the component after the main pass, so the panel stays whole and readable.
    -- A plain scalar property write on the component - the same class of touch
    -- as the setters above, and nothing to do with the transform.
    applyDepth(comp)
    applyMaterial(comp)

    styledComponent = key
end

-- The ESP shares the one head-locked text component with the menu. The menu
-- wins whenever it is open; the ESP takes over as soon as it closes.
function GUI.BuildESPText()
    local esp = PlayerMods.esp or {}
    local out = { "-- ENEMY ESP --" }
    if #esp == 0 then
        out[#out + 1] = "  no enemies nearby"
    else
        for i = 1, #esp do
            local e = esp[i]
            out[#out + 1] = string.format("  %2d o'clock   %5.1f m", e.clock, e.dist)
        end
    end
    return table.concat(out, "\n")
end

function GUI.Render()
    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then return end

    -- what should be on screen right now: the menu wins, then the ESP
    local text = nil
    if GUI.IsOpen then
        text = GUI.BuildText()
    elseif PlayerMods.state.EnemyESP then
        text = GUI.BuildESPText()
    end

    local comp = getTextComponent(pawn)
    if not comp then return end

    -- The pawn can be replaced (respawn, round restart) and with it the text
    -- component. Without this the cached text still "matches" and nothing is
    -- ever pushed to the new component - the ESP appears to unlink itself.
    local okA, addr = pcall(function() return comp:GetAddress() end)
    local nowAddr = okA and addr or nil
    if nowAddr ~= lastCompAddr then
        lastCompAddr = nowAddr
        lastText = nil
        styleDone = nil
    end

    -- Periodically re-apply, in case the game hid it or overwrote the text.
    -- ONLY the two cheap flags plus a text re-push - styleDone is deliberately
    -- left alone so the geometry measurement and its log line stay one-per-
    -- component. Re-running those on a timer is what crashed Raid Mode.
    reassertIn = reassertIn - 1
    if reassertIn <= 0 then
        reassertIn = REASSERT_TICKS
        assertVisible(comp)
        lastText = nil
    end

    if text == nil then
        if lastText ~= nil then
            pcall(function() comp:SetText("") end)
            lastText = nil
        end
        return
    end

    -- Only push new text, and only when it has actually changed - re-sending
    -- identical strings several times a second is a known way to crash these
    -- games.
    if text ~= lastText then
        styleComponent(comp)
        pcall(function() comp:SetText(text) end)
        -- only log genuinely new content: the periodic re-assert clears lastText
        -- on purpose, and echoing the same menu every 2 s would flood the log
        -- The whole panel used to be printed whenever it changed. With a
        -- pointer hovering, the cursor moves the selection constantly, so a
        -- 22-line block went into the UE4SS console - which renders through
        -- the DX11 overlay - many times a second. The menu is visible in the
        -- headset; logging it serves nobody. Off unless GUI.debugPrint is set.
        if GUI.debugPrint and GUI.IsOpen and text ~= lastPrinted then
            print("\n" .. text .. "\n")
            lastPrinted = text
        end
        lastText = text
    end
end

-- Test hooks: simulate the game interfering with our text component, and read
-- back its true state. Used by the ESP self-test to prove the display recovers
-- on its own instead of staying dead until the round ends.
function GUI.SabotageDisplay()
    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then return false end
    local comp = getTextComponent(pawn)
    if not comp then return false end
    local ok = pcall(function()
        comp:SetHiddenInGame(true, true)
        comp:SetText("")
    end)
    return ok
end

-- returns hiddenInGame, textLooksSet
function GUI.DisplayState()
    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then return nil, nil end
    local comp = getTextComponent(pawn)
    if not comp then return nil, nil end
    local hidden, hasText = nil, nil
    pcall(function() hidden = comp.bHiddenInGame end)
    -- lastText is what we last pushed; if it is set the mod has re-asserted
    hasText = (lastText ~= nil and lastText ~= "")
    return hidden, hasText
end

function GUI.DropCaches()
    lastText = nil
    styledComponent = nil
    hadVisibility = nil
    -- the component died with the old world
    panelActor, panelComp = nil, nil
    styleDone = nil
    lastCompAddr = nil
    reassertIn = 0
    GUI.panelReady = false
end

---------------------------------------------------------------------------
-- does the panel actually follow the head?
---------------------------------------------------------------------------
-- CameraText is named for the camera and measures ~65 cm directly ahead of it,
-- which says it is parented to the VR camera and therefore already turns with
-- the head. That is a claim about the attachment hierarchy, which the header
-- dump does not expose, so measure it instead of asserting it.
--
-- The test is the LATERAL offset - the part of the camera->text vector that is
-- perpendicular to where the camera is looking. Parented to the camera, that
-- stays ~0 no matter how far the head turns. Parented to the pawn body, it
-- swings out to the full 65 cm as soon as the head turns 90 degrees off the
-- body. Track the yaw range covered so a verdict is only offered once the
-- player has actually looked around.
--
-- Strictly read-only. Moving or re-parenting this component has hard-crashed
-- the game three times, so nothing here writes to it.

---------------------------------------------------------------------------
-- laser pointer: aim a controller at the panel and click a row
---------------------------------------------------------------------------
-- Turns the controller into a mouse. The panel is a flat text plane, so the
-- hit is a ray/plane intersection, and the row is the hit height divided by the
-- line height. GetTextWorldSize() reports the rendered block's real size, so
-- the line height is measured rather than guessed - no calibration constants.
--
-- The only awkward part is which way the text plane's axes point. Rather than
-- assume, take the panel's own right/up vectors and FLIP EITHER ONE that
-- disagrees with the camera's: the text is readable to the player, so its
-- horizontal axis must lie within 90 degrees of the camera's right, and its
-- vertical within 90 degrees of the camera's up. That settles the signs
-- without knowing how the component happens to be oriented.

-- One pointer state PER HAND, so both lasers can be live at once. GUI.pointer
-- stays as the primary hand's state, which every report and the hand-swap row
-- already refer to.
local function newPointer(isLeft)
    return { hand = isLeft, active = false, line = 0, x = 0, frac = 0,
             hit = false, why = "off" }
end

GUI.pointerL = newPointer(true)
GUI.pointerR = newPointer(false)

function GUI.PointerFor(useLeft)
    return useLeft and GUI.pointerL or GUI.pointerR
end

GUI.pointer = {
    hand      = true,     -- true = left hand (the one not holding a gun)
    active    = false,
    line      = 0,        -- printed line under the laser, 1-based
    x         = 0,        -- across the panel, 0 = left edge
    frac      = 0,        -- 0..1 across the panel width
    hit       = false,
    why       = "off",
}

local function vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function vdot(a, b) return (a.X * b.X) + (a.Y * b.Y) + (a.Z * b.Z) end
local function vneg(a)    return { X = -a.X, Y = -a.Y, Z = -a.Z } end

-- Component basis. Prefer the engine's own accessors; fall back to building it
-- from the rotator, because the sign fix below makes the handedness moot.
local function basisOf(comp)
    local function tryVec(fn)
        local ok, v = pcall(function() return comp[fn](comp) end)
        if ok and v and type(v.X) == "number" then return v end
        return nil
    end
    local f, r, u = tryVec("GetForwardVector"), tryVec("GetRightVector"), tryVec("GetUpVector")
    if f and r and u then return f, r, u end

    local okR, rot = pcall(function() return comp:K2_GetComponentRotation() end)
    if not okR or not rot then return nil end
    local y, pch = math.rad(rot.Yaw or 0), math.rad(rot.Pitch or 0)
    f = { X = math.cos(pch) * math.cos(y), Y = math.cos(pch) * math.sin(y), Z = math.sin(pch) }
    r = { X = -math.sin(y), Y = math.cos(y), Z = 0 }
    u = { X = (r.Y * f.Z) - (r.Z * f.Y),
          Y = (r.Z * f.X) - (r.X * f.Z),
          Z = (r.X * f.Y) - (r.Y * f.X) }
    return f, r, u
end

-- These are defined ABOVE tickHand deliberately. They are local functions,
-- so a call from tickHand to one declared later resolves as a GLOBAL - nil -
-- and the pcall around tickHand turns that into a silent pointer=error with
-- no aim at all. Touch mode hid it, because that branch calls none of them.
-- Rotate a direction by the saved pitch/yaw correction.
--
-- The correction used to be applied only in the grip/socket path, which meant
-- that when the widget ray was selected there was no way to correct it at all -
-- if the game's own ray were even slightly off, the player was stuck. Building
-- the basis around whatever direction was chosen makes one calibration correct
-- ANY source, so the pointer can always be made right.
local function applyAimOffset(D, pitchDeg, yawDeg)
    if (math.abs(pitchDeg) < 0.01) and (math.abs(yawDeg) < 0.01) then return D end
    -- right = D x worldUp, up = right x D  (degenerate only if D is vertical)
    local up0 = { X = 0, Y = 0, Z = 1 }
    local r = { X = (D.Y * up0.Z) - (D.Z * up0.Y),
                Y = (D.Z * up0.X) - (D.X * up0.Z),
                Z = (D.X * up0.Y) - (D.Y * up0.X) }
    local rl = math.sqrt((r.X * r.X) + (r.Y * r.Y) + (r.Z * r.Z))
    if rl < 0.0001 then return D end
    r = { X = r.X / rl, Y = r.Y / rl, Z = r.Z / rl }
    local u = { X = (r.Y * D.Z) - (r.Z * D.Y),
                Y = (r.Z * D.X) - (r.X * D.Z),
                Z = (r.X * D.Y) - (r.Y * D.X) }
    local cp, sp = math.cos(math.rad(pitchDeg)), math.sin(math.rad(pitchDeg))
    local cy, sy = math.cos(math.rad(yawDeg)),  math.sin(math.rad(yawDeg))
    return { X = (D.X * cp * cy) + (r.X * cp * sy) + (u.X * sp),
             Y = (D.Y * cp * cy) + (r.Y * cp * sy) + (u.Y * sp),
             Z = (D.Z * cp * cy) + (r.Z * cp * sy) + (u.Z * sp) }
end

-- THE GAME'S OWN POINTING RAY.
--
-- WendigoVrChar owns TeleportControllerLeft/Right (ABP_Teleport_Controller_C),
-- and each carries a UWidgetInteractionComponent - the component Unreal uses to
-- point at UI - next to the LaserBeam spline mesh that draws the visible line.
-- That component's transform IS where the game thinks the hand is pointing, so
-- reading it removes the guesswork entirely: no constant, no calibration, no
-- socket heuristics. It supplies the ORIGIN as well as the direction, which
-- matters - a wrong origin is a miss that grows with distance, which is exactly
-- what "better when my hand is close to it" described.
local function aimFromWidget(pawn, kind, isLeft)
    if PlayerMods.state.AimFromWidget == false then return nil end
    local name = isLeft and "TeleportControllerLeft" or "TeleportControllerRight"
    if not PlayerMods.hasProp(kind, name) then return nil end
    local okC, tc = pcall(function() return pawn[name] end)
    if not okC or not isValid(tc) then return nil end
    -- WidgetInteraction lives on the teleport controller, a class the pawn
    -- schema does not cover; the header confirms it (BP_Teleport_Controller.hpp)
    local okW, wi = pcall(function() return tc.WidgetInteraction end)
    if not okW or not isValid(wi) then return nil end
    local okL, O = pcall(function() return wi:K2_GetComponentLocation() end)
    if not okL or not O then return nil end
    local f = basisOf(wi)
    if not f then return nil end
    return O, f
end

-- AUTOMATIC AIM DIRECTION, FROM THE HAND RIG.
--
-- The controller reports only its grip pose, so the ray needs to know how far
-- the visual "pointing" direction sits off that. Rather than a constant (wrong)
-- or a calibration the player has to perform (fragile), look for a socket on
-- the hand mesh that represents pointing - a rigged hand carries dozens, and an
-- aim/muzzle/index socket rotates with the finger, which is where a laser is
-- drawn from. Resolve it once and cache it.
--
-- Falls back to the solved calibration, then to the raw grip forward, so a rig
-- without a suitable socket is no worse off than before.
-- Deliberately NOT "index": on a rigged hand most sockets are bone names, and a
-- finger bone points along a segment that curls with the pose - it would make
-- aiming worse, not better. Only sockets explicitly named for aiming qualify.
local AIM_SOCKET_RANK = { "aim", "muzzle", "laser", "beam", "point" }

local aimSocket = {}      -- [isLeft] = name | false  (false = looked, found none)

local function handMesh(pawn, kind, isLeft)
    local name = isLeft and "HandMesh-Left" or "HandMesh-Right"
    if not PlayerMods.hasProp(kind, name) then return nil end
    local ok, m = pcall(function() return pawn[name] end)
    if ok and isValid(m) then return m end
    return nil
end

local function resolveAimSocket(mesh, isLeft)
    if aimSocket[isLeft] ~= nil then return aimSocket[isLeft] end
    aimSocket[isLeft] = false
    pcall(function()
        local ok, socks = pcall(function() return mesh:GetAllSocketNames() end)
        if not ok or not socks then return end
        local n = 0
        pcall(function() n = #socks end)
        local best, bestRank = nil, 99
        for i = 1, n do
            local sn = socks[i]
            pcall(function()
                if type(sn) == "userdata" and sn.get then sn = sn:get() end
            end)
            sn = tostring(sn)
            local low = string.lower(sn)
            for rank, want in ipairs(AIM_SOCKET_RANK) do
                if string.find(low, want, 1, true) and rank < bestRank then
                    best, bestRank = sn, rank
                end
            end
        end
        if best then aimSocket[isLeft] = best end
    end)
    GUI.aimSocketName = tostring(aimSocket[isLeft])
    return aimSocket[isLeft]
end

-- The rig's pointing direction, or nil if this hand has no usable socket.
local function socketForward(pawn, kind, isLeft)
    if PlayerMods.state.AimFromSocket == false then return nil end
    local mesh = handMesh(pawn, kind, isLeft)
    if not mesh then return nil end
    local name = resolveAimSocket(mesh, isLeft)
    if not name then return nil end
    local okR, rot = pcall(function() return mesh:GetSocketRotation(name) end)
    if not okR or not rot then return nil end
    local y, pch = math.rad(rot.Yaw or 0), math.rad(rot.Pitch or 0)
    return { X = math.cos(pch) * math.cos(y),
             Y = math.cos(pch) * math.sin(y),
             Z = math.sin(pch) }
end

-- The ray BEFORE correction: origin, direction and which source won. Shared by
-- the tick and the calibration so the two can never disagree about what is
-- being corrected - solving an offset against a different ray than the one that
-- actually gets used is silently wrong.
local function chooseRay(pawn, kind, useLeft, hf, handO)
    local wO, wF = aimFromWidget(pawn, kind, useLeft)
    if wO and wF then return wO, wF, "widget" end

    -- SANITY CHECK the rig: a socket more than ~80 degrees off the grip is a
    -- bone across the hand, not an aim direction, and is worse than the grip.
    local sf = socketForward(pawn, kind, useLeft)
    if sf and hf then
        local dp = (sf.X * hf.X) + (sf.Y * hf.Y) + (sf.Z * hf.Z)
        if dp < 0.17 then sf = nil end
    end
    if sf then return handO, sf, "socket" end
    return handO, hf, "grip"
end

local function tickHand(pt, useLeft)
    pt.hit = false

    if not GUI.IsOpen or not GUI.layout then pt.why = "closed" return end

    local ok = pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then pt.why = "no pawn" return end

        -- getTextComponent, NOT styledComponent: the latter is the address key
        -- the styling de-dupe compares against, not the component itself.
        local comp = getTextComponent(pawn)
        if not isValid(comp) then pt.why = "no panel" return end
        local cam = getCamera(pawn)
        if not cam then pt.why = "no camera" return end

        local hand = PlayerMods.GetHand(useLeft)
        if not hand then pt.why = "no hand" return end

        local P0 = comp:K2_GetComponentLocation()
        local O  = hand:K2_GetComponentLocation()
        if not (P0 and O) then pt.why = "no transform" return end

        local N, R, U = basisOf(comp)
        local hf, hr, hu = basisOf(hand)
        if not (N and R and U and hf and hu) then pt.why = "no basis" return end

        -- AIM, NOT GRIP.
        --
        -- The motion controller reports its grip pose: forward runs down the
        -- handle, which is tens of degrees away from where the hand is actually
        -- pointing. Casting the ray along it is why the panel had to be
        -- approached at odd angles to register. Pitch the ray about the
        -- controller's own right axis to recover the aim direction.
        local pa = math.rad(PlayerMods.state.PointerPitch or 0)
        -- Touch controllers are mirror images, so the grip-to-aim twist is the
        -- same size on both hands and opposite in sign. Calibrating one hand
        -- therefore fixes the other for free - the pitch carries over as-is and
        -- the yaw flips.
        local yawDeg = PlayerMods.state.PointerYaw or 0
        if useLeft ~= GUI.pointer.hand then yawDeg = -yawDeg end
        local ya = math.rad(yawDeg)
        local cp, sp, cy, sy = math.cos(pa), math.sin(pa), math.cos(ya), math.sin(ya)
        local D = {
            X = (hf.X * cp * cy) + ((hr and hr.X or 0) * cp * sy) + (hu.X * sp),
            Y = (hf.Y * cp * cy) + ((hr and hr.Y or 0) * cp * sy) + (hu.Y * sp),
            Z = (hf.Z * cp * cy) + ((hr and hr.Z or 0) * cp * sy) + (hu.Z * sp),
        }

        local _, camR, camU = basisOf(cam)
        if not (camR and camU) then pt.why = "no cam basis" return end
        if vdot(R, camR) < 0 then R = vneg(R) end
        if vdot(U, camU) < 0 then U = vneg(U) end

        -- ray / plane
        -- TOUCH BEATS AIM.
        --
        -- Ray aiming depends on knowing the angle between the controller's grip
        -- pose and where it visually points, and the game exposes no way to read
        -- that. Every attempt to pin it down - a constant, then a solved
        -- calibration - works on paper and then misses in the headset, which is
        -- why "it is a little bit better when my hand is close to it": an
        -- angular error times a shorter throw is a smaller miss.
        --
        -- So when the hand is near the panel, stop aiming entirely and project
        -- the hand straight onto it. There is no direction in that calculation,
        -- so there is no offset left to get wrong - reach out and touch the row.
        -- The ray is still there for pointing from across the room.
        local H, d
        local along = vdot(vsub(O, P0), N)      -- signed distance to the plane
        local reach = PlayerMods.state.TouchRange or 35
        if PlayerMods.state.TouchPointer ~= false and math.abs(along) <= reach then
            H = { X = O.X - (N.X * along), Y = O.Y - (N.Y * along), Z = O.Z - (N.Z * along) }
            d = vsub(H, P0)
            pt.mode = "touch"
        else
            local _, kind2 = PlayerMods.GetPawn()
            local rO, rD, rSrc = chooseRay(pawn, kind2, useLeft, hf, O)
            O, D, pt.src = rO, rD, rSrc

            -- one correction, applied to whatever source was chosen
            local yawDeg = PlayerMods.state.PointerYaw or 0
            if useLeft ~= GUI.pointer.hand then yawDeg = -yawDeg end
            D = applyAimOffset(D, PlayerMods.state.PointerPitch or 0, yawDeg)

            local denom = vdot(D, N)
            if math.abs(denom) < 0.0001 then pt.why = "parallel" return end
            local t = vdot(vsub(P0, O), N) / denom
            if t <= 0 then pt.why = "behind" return end
            H = { X = O.X + (D.X * t), Y = O.Y + (D.Y * t), Z = O.Z + (D.Z * t) }
            d = vsub(H, P0)
            pt.mode = "aim"
        end

        -- The rendered block's real extents, so the line height is measured.
        local okS, size = pcall(function() return comp:GetTextWorldSize() end)
        if not okS or not size then pt.why = "no text size" return end
        local width  = math.max(math.abs(size.Y), math.abs(size.X))
        local height = math.abs(size.Z)
        local lines  = GUI.layout.lines
        if lines < 1 or height <= 0 or width <= 0 then pt.why = "empty" return end

        -- Horizontal is pinned to Left by the styling above, so "across" is
        -- measured straight from the origin. VERTICAL IS NOT SET by us, and
        -- forcing it to Top would shove the whole panel down by its own height
        -- (~80 world units) and out of view. So read where the engine anchors
        -- it and shift the origin accordingly: Top puts the origin at the top
        -- edge, Center in the middle, Bottom at the bottom.
        local vAlign = 2
        local okA, va = pcall(function() return comp.VerticalAlignment end)
        if okA and type(va) == "number" then vAlign = va end
        pt.valign = vAlign

        local topOffset = height          -- EVRTA_TextBottom
        if     vAlign == 0 then topOffset = 0             -- EVRTA_TextTop
        elseif vAlign == 1 then topOffset = height / 2    -- EVRTA_TextCenter
        end

        -- Horizontal is now EHTA_Center, so the origin is the MIDDLE of the
        -- block, not its left edge. Read it rather than assume, exactly as
        -- above, so the click mapping survives an alignment change.
        local hAlign = 1
        local okH, ha = pcall(function() return comp.HorizontalAlignment end)
        if okH and type(ha) == "number" then hAlign = ha end
        pt.halign = hAlign

        local leftOffset = 0                       -- EHTA_Left
        if     hAlign == 1 then leftOffset = width / 2   -- EHTA_Center
        elseif hAlign == 2 then leftOffset = width       -- EHTA_Right
        end

        local across = vdot(d, R) + leftOffset
        local down   = topOffset - vdot(d, U)

        if across < 0 or across > width or down < 0 or down > height then
            pt.why = "off panel"
            pt.x, pt.frac = across, across / width
            return
        end

        local lineH = height / lines
        local line  = math.floor(down / lineH) + 1
        if line < 1 then line = 1 end
        if line > lines then line = lines end

        pt.line, pt.x, pt.frac = line, across, across / width
        pt.hit, pt.why = true, "ok"

        -- hovering a data row moves the selection, so the bullet IS the cursor
        local L = GUI.layout
        if useLeft ~= GUI.pointer.hand and GUI.PointerFor(GUI.pointer.hand).hit then
            return   -- primary hand is on the panel; it owns the cursor
        end
        if L.rowCount > 0 and line >= L.rowLine and line < (L.rowLine + L.rowCount) then
            local target = L.rowFirst + (line - L.rowLine)
            if target ~= GUI.row then
                GUI.row = target
                GUI.MarkDirty()
            end
            if GUI.hoverTab ~= nil then GUI.hoverTab = nil GUI.MarkDirty() end

        -- A row shows a cursor when you point at it; the tab strip showed
        -- nothing, so there was no way to tell whether a tab was clickable or
        -- which one you were about to hit. Mark it the same way.
        elseif line == L.tabLine then
            local t = tabAtFrac(L, pt.frac)
            if t ~= GUI.hoverTab then GUI.hoverTab = t GUI.MarkDirty() end
        elseif GUI.hoverTab ~= nil then
            GUI.hoverTab = nil
            GUI.MarkDirty()
        end
    end)
    if not ok then pt.why = "error" end
end

-- ONE-PRESS AIM CALIBRATION.
--
-- The controller only exposes its GRIP pose, and nothing in the game exposes
-- the direction its laser is drawn along (the procedural meshes and grab
-- spheres all measured 0 degrees off the grip). So the offset cannot be read
-- and guessing it does not converge - which is why aiming stayed wrong and got
-- worse with distance, an angular error growing over the throw.
--
-- Instead, solve it. Point the laser at the middle of the panel, press once,
-- and this works out the pitch and yaw that would have put the ray exactly
-- there. Decompose the hand->panel vector in the controller's own basis and
-- read the two angles straight off it.
function GUI.CalibratePointer(useLeft)
    local okAll = false
    pcall(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        local comp = getTextComponent(pawn)
        if not isValid(comp) then return end
        local hand = PlayerMods.GetHand(useLeft)
        if not hand then return end

        local hf = basisOf(hand)
        local handO = hand:K2_GetComponentLocation()
        local P0 = comp:K2_GetComponentLocation()
        if not (hf and handO and P0) then return end

        -- the SAME ray the tick will use, before correction
        local O, D0 = chooseRay(pawn, kind, useLeft, hf, handO)
        if not (O and D0) then return end

        -- where it should point: the content centre, which the padding lifts
        -- above the component origin
        local pad  = (GUI.autoLift or 0) + (PlayerMods.state.PanelLift or 0)
        local rise = (pad * (GUI.lineH or 0)) / 2
        local vx, vy, vz = P0.X - O.X, P0.Y - O.Y, (P0.Z + rise) - O.Z
        local len = math.sqrt((vx * vx) + (vy * vy) + (vz * vz))
        if len < 1 then return end
        vx, vy, vz = vx / len, vy / len, vz / len

        -- solve in the basis built around D0, matching applyAimOffset exactly
        local up0 = { X = 0, Y = 0, Z = 1 }
        local r = { X = (D0.Y * up0.Z) - (D0.Z * up0.Y),
                    Y = (D0.Z * up0.X) - (D0.X * up0.Z),
                    Z = (D0.X * up0.Y) - (D0.Y * up0.X) }
        local rl = math.sqrt((r.X * r.X) + (r.Y * r.Y) + (r.Z * r.Z))
        if rl < 0.0001 then return end
        r = { X = r.X / rl, Y = r.Y / rl, Z = r.Z / rl }
        local u = { X = (r.Y * D0.Z) - (r.Z * D0.Y),
                    Y = (r.Z * D0.X) - (r.X * D0.Z),
                    Z = (r.X * D0.Y) - (r.Y * D0.X) }

        local vd = (D0.X * vx) + (D0.Y * vy) + (D0.Z * vz)
        local vr = (r.X * vx) + (r.Y * vy) + (r.Z * vz)
        local vu = (u.X * vx) + (u.Y * vy) + (u.Z * vz)

        -- math.atan2 in 5.1, two-arg math.atan in 5.3+
        local function atan2(y, x)
            if math.atan2 then return math.atan2(y, x) end
            return math.atan(y, x)
        end
        local yaw   = math.deg(atan2(vr, vd))
        local pitch = math.deg(atan2(vu, math.sqrt((vd * vd) + (vr * vr))))

        -- REFUSE AN IMPLAUSIBLE SOLUTION.
        --
        -- The solver happily returns whatever angle points at the panel, so
        -- pressing calibrate while the laser is somewhere else bakes that in
        -- and saves it. A live scan found pitch=49.8 yaw=-129.3 stored - a yaw
        -- of -129 degrees is pointing backwards, not a grip-to-aim offset. Any
        -- real offset is small; anything beyond 60 degrees means the player was
        -- not pointing at the panel, so keep the old value and say so.
        if math.abs(yaw) > 60 or math.abs(pitch) > 60 then
            GUI.calibReject = string.format("refused p=%.0f y=%.0f (aim at the panel first)",
                                            pitch, yaw)
            return
        end
        GUI.calibReject = nil
        -- the tick negates yaw for the off hand; undo that here so a
        -- calibration performed with either hand stores the same convention
        if useLeft ~= GUI.pointer.hand then yaw = -yaw end

        PlayerMods.state.PointerYaw   = yaw
        PlayerMods.state.PointerPitch = pitch
        GUI.calibCount = (GUI.calibCount or 0) + 1
        if PlayerMods.SavePointerCal then PlayerMods.SavePointerCal() end
        GUI.MarkDirty()
        okAll = true
    end)
    return okAll
end

function GUI.PointerTick()
    -- primary hand first, so it wins the cursor when both are on the panel
    local primary = GUI.pointer.hand
    tickHand(GUI.PointerFor(primary), primary)
    if PlayerMods.state.TwoPointers then
        tickHand(GUI.PointerFor(not primary), not primary)
    else
        local other = GUI.PointerFor(not primary)
        other.hit, other.why = false, "off"
    end
    -- the reports read GUI.pointer, so mirror the primary hand into it
    local src = GUI.PointerFor(primary)
    GUI.pointer.line, GUI.pointer.x, GUI.pointer.frac = src.line, src.x, src.frac
    GUI.pointer.hit,  GUI.pointer.why = src.hit, src.why
    GUI.pointer.valign, GUI.pointer.halign = src.valign, src.halign
end

-- A click does what the thing under the laser deserves: a tab switches page, a
-- slider takes the left or right half as down/up, anything else is ENTER.
function GUI.PointerClick(useLeft)
    if not GUI.IsOpen then return false end

    -- The trigger fires a press/release PAIR and the alternation can slip if an
    -- event is missed, which turns one pull into two actions - tabs flicking
    -- past, toggles flipping back. Debounce on the tick counter as well.
    local now = PlayerMods.tickStamp or 0
    if (now - (GUI.lastClickTick or -99)) < 3 then return false end
    GUI.lastClickTick = now
    -- each hand clicks what ITS OWN laser is on, so two pointers really are two
    -- pointers rather than one that only answers to one trigger
    local pt = GUI.PointerFor(useLeft)
    if not PlayerMods.state.TwoPointers and useLeft ~= GUI.pointer.hand then
        return false
    end
    if not GUI.layout then return false end

    -- A MISS DOES NOTHING.
    --
    -- This used to fall back to activating whatever row was selected, on the
    -- theory that a trigger pull should always do something. With the aim off,
    -- that was worse than nothing: every pull fired the same selected row, so
    -- the tab strip could never be reached (the tab appeared "locked") and
    -- random toggles flipped (the "glitchy" clicks). Guessing at intent when
    -- the ray is not on the panel is not helpful - miss quietly, and let
    -- CALIBRATE fix the aim.
    if not pt.hit then
        GUI.misses = (GUI.misses or 0) + 1
        return false
    end

    local L = GUI.layout

    if pt.line == L.tabLine then
        local idx = tabAtFrac(L, pt.frac)
        if not idx then return false end
        if idx < 1 then idx = 1 end
        if idx > #pages then idx = #pages end
        GUI.page = idx
        GUI.row  = 1
        -- match PageChange: leaving a tab must also leave any sub-page, or
        -- SPAWN/MAPS come back still inside the category you were in
        GUI.spawnCat  = nil
        GUI.mapGroup  = nil
        GUI.MarkDirty()
        GUI.clicks = (GUI.clicks or 0) + 1
        return true
    end

    if L.rowCount > 0 and pt.line >= L.rowLine and pt.line < (L.rowLine + L.rowCount) then
        local rows = currentRows()
        local r = rows[L.rowFirst + (pt.line - L.rowLine)]
        GUI.clicks = (GUI.clicks or 0) + 1
        if r and r.kind == "number" then
            GUI.Adjust(pt.frac < 0.5 and -1 or 1)
        else
            GUI.Activate()
        end
        return true
    end

    return false
end

-- Is a real background even possible? A filled backdrop needs a SECOND render
-- surface, and spawning one has killed the game twice (see the note above). The
-- only other candidates are the text components the pawn already owns. If one
-- of them happens to sit on top of CameraText it could be filled with block
-- glyphs and used as a backing plate; if they are all somewhere else, it cannot.
-- Read-only survey - nothing here moves or writes anything.
function GUI.MaterialReport()
    local out = "?"
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then return end
        local comp = getTextComponent(pawn)
        if not isValid(comp) then return end
        local okM, mat = pcall(function() return comp.TextMaterial end)
        if not okM or not mat then out = "no material" return end
        local name = "?"
        pcall(function() name = mat:GetFullName() end)
        local dd = "?"
        pcall(function() dd = tostring(mat.bDisableDepthTest) end)
        -- the material may be an instance; the flag lives on the parent UMaterial
        local pd = "?"
        pcall(function()
            local base = mat.Parent
            if base then pd = tostring(base.bDisableDepthTest) end
        end)
        out = string.format("%s nodepth=%s parentnodepth=%s", tostring(name), dd, pd)
    end)
    return out
end

function GUI.PanelStyleReport()
    local out = "?"
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then return end
        local comp = getTextComponent(pawn)
        if not isValid(comp) then return end
        local function rd(n)
            local ok, v = pcall(function() return comp[n] end)
            return (ok and v ~= nil) and tostring(v) or "?"
        end
        out = string.format("size=%s h=%s v=%s depth=%s want=%.1f",
            rd("WorldSize"), rd("HorizontalAlignment"), rd("VerticalAlignment"),
            rd("DepthPriorityGroup"), panelSize())
    end)
    return out
end

-- Is the panel actually square-on to the player? Report the component's
-- rotation next to the camera's: a difference in Pitch or Roll is exactly the
-- "weird angle, not flat facing me" look.
-- What Activate/Adjust will actually act on. "The click does nothing" is
-- usually the selection sitting on a row that has nothing to toggle.
-- WHERE DOES THE VISIBLE BEAM ACTUALLY POINT?
--
-- The player aims with the game's own laser, so if our ray does not run along
-- the same axis the hit lands somewhere else - and the error grows with
-- distance, which is exactly "better when my hand is close to it". The beam is
-- most likely one of the procedural meshes. Measure the angle between the
-- controller's grip forward and each candidate, so the aim offset is read off
-- the game rather than guessed.
function GUI.BeamProbeReport()
    local out = {}
    pcall(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then out[1] = "no pawn" return end
        local hand = PlayerMods.GetHand(true)
        if not hand then out[1] = "no hand" return end
        local hf = basisOf(hand)
        if not hf then out[1] = "no basis" return end

        local function ang(v)
            local d = (hf.X * v.X) + (hf.Y * v.Y) + (hf.Z * v.Z)
            if d > 1 then d = 1 elseif d < -1 then d = -1 end
            return math.deg(math.acos(d))
        end

        for _, name in ipairs({ "ProceduralMeshLeft", "GrabSphereLeft" }) do
            if PlayerMods.hasProp(kind, name) then
                local okC, c = pcall(function() return pawn[name] end)
                if okC and isValid(c) then
                    local f = basisOf(c)
                    local okL, l = pcall(function() return c:K2_GetComponentLocation() end)
                    local hl = hand:K2_GetComponentLocation()
                    local dist = "?"
                    if okL and l and hl then
                        dist = string.format("%.0f", math.sqrt((l.X-hl.X)^2 + (l.Y-hl.Y)^2 + (l.Z-hl.Z)^2))
                    end
                    out[#out + 1] = string.format("%s:off=%.0f d=%s", name,
                                                  f and ang(f) or -1, dist)
                end
            end
        end

        -- and the camera, as a sanity reference
        local cam = getCamera(pawn)
        if cam then
            local cf = basisOf(cam)
            if cf then out[#out + 1] = string.format("camfwd:off=%.0f", ang(cf)) end
        end
    end)
    if #out == 0 then return "none" end
    return table.concat(out, " ")
end

-- WHAT DOES THE HAND ACTUALLY POINT ALONG?
--
-- The controller only reports its grip pose. But the hand MESH is skinned to
-- that controller and the game rigs it, so if the rig carries an aim/muzzle/
-- point socket, that socket's rotation IS the direction the hand visually
-- points - readable, no calibration, no guessing. Enumerate every socket and
-- report how far each sits off the grip forward.
function GUI.SocketProbeReport()
    local out = {}
    pcall(function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then out[1] = "no pawn" return end
        local hand = PlayerMods.GetHand(true)
        if not hand then out[1] = "no hand" return end
        local hf = basisOf(hand)
        if not hf then out[1] = "no basis" return end

        local name = "HandMesh-Left"
        if not PlayerMods.hasProp(kind, name) then out[1] = "no prop" return end
        local okM, mesh = pcall(function() return pawn[name] end)
        if not okM or not isValid(mesh) then out[1] = "no mesh" return end

        local okS, socks = pcall(function() return mesh:GetAllSocketNames() end)
        if not okS or not socks then out[1] = "no sockets" return end

        local n = 0
        pcall(function() n = #socks end)
        out[#out + 1] = "n=" .. tostring(n)

        for i = 1, math.min(n, 40) do
            -- TArray entries arrive as RemoteUnrealParam wrappers, not strings;
            -- :get() unwraps them, and the same wrapper cannot be handed back
            -- to GetSocketRotation - it needs the plain name.
            local sn = socks[i]
            pcall(function()
                if type(sn) == "userdata" and sn.get then sn = sn:get() end
            end)
            if type(sn) ~= "string" then sn = tostring(sn) end
            local okR, rot = pcall(function() return mesh:GetSocketRotation(sn) end)
            if okR and rot then
                local y, pch = math.rad(rot.Yaw or 0), math.rad(rot.Pitch or 0)
                local f = { X = math.cos(pch) * math.cos(y),
                            Y = math.cos(pch) * math.sin(y),
                            Z = math.sin(pch) }
                local dp = (hf.X * f.X) + (hf.Y * f.Y) + (hf.Z * f.Z)
                if dp > 1 then dp = 1 elseif dp < -1 then dp = -1 end
                local off = math.deg(math.acos(dp))
                -- an identity rotation means the lookup failed; skip the noise
                if not (math.abs(rot.Pitch or 0) < 0.01 and math.abs(rot.Yaw or 0) < 0.01
                        and math.abs(rot.Roll or 0) < 0.01) then
                    out[#out + 1] = string.format("%s:%.0f", tostring(sn), off)
                end
            end
        end
    end)
    if #out == 0 then return "none" end
    return table.concat(out, " ")
end

function GUI.SelectionReport()
    local out = "?"
    pcall(function()
        local pg = pages[GUI.page]
        local rows = currentRows()
        local r = rows and rows[GUI.row]
        out = string.format("page=%d(%s) row=%d/%d kind=%s key=%s",
            GUI.page, pg and pg.name or "?", GUI.row, rows and #rows or 0,
            r and tostring(r.kind) or "nil", r and tostring(r.key) or "-")
    end)
    return out
end

function GUI.PanelAngleReport()
    local out = "?"
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then return end
        local comp = getTextComponent(pawn)
        local cam  = getCamera(pawn)
        if not isValid(comp) or not cam then return end
        local cr = comp:K2_GetComponentRotation()
        local kr = cam:K2_GetComponentRotation()
        if not (cr and kr) then return end

        -- how far off square-on the panel is, as seen from the camera
        local N = basisOf(comp)
        local cl = cam:K2_GetComponentLocation()
        local tl = comp:K2_GetComponentLocation()
        local face = "?"
        if N and cl and tl then
            -- Measure to where the TEXT actually is, not to the component
            -- origin. The content is pushed up inside the block by the padding,
            -- so the origin is not the thing the player looks at, and measuring
            -- there reports a tilt that is not the one being seen.
            local pad = (GUI.autoLift or 0) + (PlayerMods.state.PanelLift or 0)
            local rise = (pad * (GUI.lineH or 0)) / 2
            local dx, dy, dz = tl.X - cl.X, tl.Y - cl.Y, (tl.Z + rise) - cl.Z
            local len = math.sqrt(dx*dx + dy*dy + dz*dz)
            if len > 0.01 then
                local d = math.abs(((N.X*dx) + (N.Y*dy) + (N.Z*dz)) / len)
                if d > 1 then d = 1 end
                face = string.format("%.0f", math.deg(math.acos(d)))
            end
        end
        out = string.format("panel P=%.0f Y=%.0f R=%.0f | cam P=%.0f Y=%.0f R=%.0f | offsquare(at text)=%s deg",
            cr.Pitch or 0, cr.Yaw or 0, cr.Roll or 0,
            kr.Pitch or 0, kr.Yaw or 0, kr.Roll or 0, face)
    end)
    return out
end

function GUI.TextCompsReport()
    local out = {}
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then out[1] = "no pawn" return end
        local base = getTextComponent(pawn)
        if not isValid(base) then out[1] = "no base" return end
        local bl = base:K2_GetComponentLocation()

        for _, name in ipairs({ "CameraText", "AmmoCount", "PlayerNameDisplay",
                                "ThrowerCountSidearm", "ThrowerCountLongB",
                                "AmmoProxyText" }) do
            local okC, c = pcall(function() return pawn[name] end)
            if okC and isValid(c) then
                local okL, l = pcall(function() return c:K2_GetComponentLocation() end)
                if okL and l and bl then
                    -- right/up/ahead relative to the MENU panel, so a component
                    -- that merely sits further along the view axis (a usable
                    -- backing plate) is distinguishable from one off to the side
                    local dx, dy, dz = l.X - bl.X, l.Y - bl.Y, l.Z - bl.Z
                    local F, R, U = basisOf(base)
                    if F and R and U then
                        out[#out + 1] = string.format("%s:a%.0f r%.0f u%.0f", name,
                            (F.X*dx)+(F.Y*dy)+(F.Z*dz),
                            (R.X*dx)+(R.Y*dy)+(R.Z*dz),
                            (U.X*dx)+(U.Y*dy)+(U.Z*dz))
                    else
                        out[#out + 1] = string.format("%s:%.0f", name,
                            math.sqrt(dx*dx + dy*dy + dz*dz))
                    end
                else
                    out[#out + 1] = name .. ":?"
                end
            end
        end
    end)
    if #out == 0 then return "none" end
    return table.concat(out, " ")
end

function GUI.PointerReport()
    local pt = GUI.pointer
    local L = GUI.layout
    return string.format(
        "%s line=%d/%d frac=%.2f valign=%s halign=%s lift=%s aim=%s h=%s w=%s lineH=%s pad=%s rows=%s-%s tab=%s row=%d hand=%s beam=%s clicks=%d",
        pt.why, pt.line, (L and L.lines) or 0, pt.frac, tostring(pt.valign),
        tostring(pt.halign), tostring(GUI.autoLift),
        GUI.aimedBelow and string.format('%.0f', GUI.aimedBelow) or '?',
        GUI.measH and string.format('%.1f', GUI.measH) or '?',
        GUI.measW and string.format('%.1f', GUI.measW) or '?',
        GUI.lineH and string.format('%.2f', GUI.lineH) or '?',
        tostring(GUI.padCounts),
        tostring(L and L.rowLine), tostring(L and L.rowCount),
        tostring(L and L.tabLine), GUI.row or 0,
        pt.hand and "L" or "R", tostring(PlayerMods.beamOk), GUI.clicks or 0)
        .. string.format(" miss=%d mode=%s/%s src=%s sock=%s", GUI.misses or 0,
            tostring(GUI.pointerL.mode), tostring(GUI.pointerR.mode),
            tostring(GUI.pointerL.src), tostring(GUI.aimSocketName))
        .. string.format(" | L:%s@%d R:%s@%d pitch=%s",
            GUI.pointerL.why, GUI.pointerL.line,
            GUI.pointerR.why, GUI.pointerR.line,
            tostring(PlayerMods.state.PointerPitch))
        .. (GUI.calibReject and (" CAL:" .. GUI.calibReject) or "")
end

local trackTick = 0

GUI.track = { yawMin = nil, yawMax = nil, latMax = 0, aheadMin = nil, samples = 0 }

-- Re-solve the vertical centring. Called when the geometry genuinely changes,
-- never on a timer - see the note in TrackProbe.
function GUI.UnlockLift()
    GUI.liftLocked = false
end

function GUI.TrackProbe()
    pcall(function()
        local pawn = PlayerMods.GetPawn()
        if not pawn then return end
        local comp = getTextComponent(pawn)
        if not isValid(comp) then return end
        local cam = getCamera(pawn)
        if not cam then return end

        local tl = comp:K2_GetComponentLocation()
        local cl = cam:K2_GetComponentLocation()
        local cr = cam:K2_GetComponentRotation()
        if not (tl and cl and cr) then return end

        local dx, dy = tl.X - cl.X, tl.Y - cl.Y
        local yaw    = cr.Yaw or 0
        local r      = math.rad(yaw)
        local ahead  =  (math.cos(r) * dx) + (math.sin(r) * dy)
        local lat    = -(math.sin(r) * dx) + (math.cos(r) * dy)

        -- AUTO-CENTRE THE PANEL VERTICALLY.
        --
        -- The component hangs ~20 cm below the eyes and cannot be moved, but the
        -- text is centre-anchored, so N blank lines under the menu raise the
        -- visible content by N/2 line heights. Measure the drop and the real
        -- line height and solve for N, instead of hard-coding a number that
        -- silently goes wrong the moment the text size changes.
        --
        -- No feedback loop: line height is height/lines, and padding grows both
        -- together, so it is a property of the font size alone.
        local okS, size = pcall(function() return comp:GetTextWorldSize() end)
        local nlines = GUI.layout and GUI.layout.lines or 0
        local framed = (GUI.layout and GUI.layout.framed) or nlines
        if okS and size and nlines > 0 then
            local h = math.abs(size.Z)
            GUI.measH, GUI.measLines = h, nlines
            GUI.measW = math.max(math.abs(size.Y), math.abs(size.X))

            -- LEARN the real per-line height instead of assuming.
            --
            -- Dividing the measured height by the TOTAL line count assumes the
            -- blank padding lines are measured too. If they are not, that makes
            -- the line height shrink as padding grows, which makes the estimate
            -- ask for more padding - a runaway that pinned the lift at 40.
            -- Watching how the height responds when the line count changes
            -- settles it: the slope IS the line height, and a zero slope proves
            -- the padding is not measured at all.
            local last = GUI.lastMeas
            if h > 0.01 and last and last.lines ~= nlines then
                local dh = h - last.h
                local dl = nlines - last.lines
                local slope = dh / dl
                if slope > 0.05 then
                    GUI.lineH, GUI.padCounts = slope, true
                elseif math.abs(dh) < 0.01 then
                    GUI.padCounts = false
                end
            end
            if h > 0.01 then GUI.lastMeas = { lines = nlines, h = h } end

            local lineH = GUI.lineH
            if not lineH or lineH <= 0.01 then
                -- Until the slope is known, divide by the FRAMED lines only.
                -- That errs towards too little padding, which merely
                -- under-centres; the other way round runs away.
                lineH = h / math.max(framed, 1)
            end

            -- SOLVE ONCE, THEN FREEZE.
            --
            -- `drop` is measured against the CAMERA, which moves every time the
            -- player's head does, so the answer drifts by a line or two with
            -- every breath. Slewing towards it meant the panel chased the head
            -- for ever - visibly sliding up and down and never settling.
            --
            -- The panel only needs to be centred once. Latch the first good
            -- solution and leave it alone; GUI.UnlockLift() re-solves when
            -- something that genuinely changes the geometry happens (the menu
            -- is reopened, the text size changes, the pawn is replaced).
            if not GUI.liftLocked and h > 0.01 and lineH > 0.01
               and GUI.padCounts ~= false then
                local drop = cl.Z - tl.Z          -- positive when the panel is low

                -- AIM THE PANEL BY CHOOSING ITS HEIGHT.
                --
                -- The component is pitched ~13 deg upward and that cannot be
                -- changed - writing a rotation to it has killed the game. But a
                -- panel pitched 13 deg is exactly square-on to a viewer sitting
                -- tan(13) * distance BELOW it. So instead of centring on the
                -- eyes (which leaves it 7 deg off square and reads as "tilted,
                -- not flat facing me"), put the content where the panel is
                -- actually aimed. Same one safe lever - blank padding lines.
                local pitch = 0
                local okR, cr = pcall(function() return comp:K2_GetComponentRotation() end)
                if okR and cr and type(cr.Pitch) == "number" then pitch = cr.Pitch end
                local dx, dy, dz = tl.X - cl.X, tl.Y - cl.Y, tl.Z - cl.Z
                local dist = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
                if dist < 1 then dist = 68 end
                local aimedBelow = math.tan(math.rad(pitch)) * dist
                if aimedBelow < 0 then aimedBelow = 0 end
                GUI.aimedBelow = aimedBelow

                local want = math.floor(((2 * (drop - aimedBelow)) / lineH) + 0.5)
                if want < 0  then want = 0  end
                if want > 60 then want = 60 end
                GUI.autoLift  = want
                GUI.liftLocked = true
            end
        end

        local t = GUI.track
        t.samples = t.samples + 1
        if t.yawMin == nil or yaw < t.yawMin then t.yawMin = yaw end
        if t.yawMax == nil or yaw > t.yawMax then t.yawMax = yaw end
        if math.abs(lat) > t.latMax then t.latMax = math.abs(lat) end
        if t.aheadMin == nil or ahead < t.aheadMin then t.aheadMin = ahead end
    end)
end

function GUI.TrackReport()
    local t = GUI.track
    if t.samples == 0 then return "no samples" end
    local span = (t.yawMax or 0) - (t.yawMin or 0)
    local verdict
    if span < 40 then
        verdict = "look around to test"
    elseif t.latMax < 15 and (t.aheadMin or 0) > 30 then
        verdict = "FOLLOWS HEAD"
    else
        verdict = "DOES NOT FOLLOW"
    end
    return string.format("%s yawspan=%.0f lat=%.0fcm ahead=%.0fcm n=%d",
                         verdict, span, t.latMax, t.aheadMin or 0, t.samples)
end

function GUI.Tick()
    -- Sample the head-tracking geometry first, and do it whether or not the
    -- menu is drawn: the component sits in the same place either way, so this
    -- collects the yaw span passively instead of needing the menu held open.
    -- Every third tick is plenty at 10 Hz and keeps the reads off the budget.
    trackTick = (trackTick or 0) + 1
    if (trackTick % 3) == 0 then GUI.TrackProbe() end

    -- the laser only exists while the menu does
    pcall(function()
        if PlayerMods.SetPointerBeam then
            local on = GUI.IsOpen and true or false
            PlayerMods.SetPointerBeam(GUI.pointer.hand, on)
            PlayerMods.SetPointerBeam(not GUI.pointer.hand,
                                      on and (PlayerMods.state.TwoPointers == true))
        end
    end)
    GUI.PointerTick()

    -- the ESP updates on its own, so it needs the render path even with the
    -- menu closed and nothing marked dirty
    if not GUI.dirty and not GUI.IsOpen and not PlayerMods.state.EnemyESP then
        return
    end
    pcall(GUI.Render)
    GUI.dirty = false
end

-- The live read-outs change without any keypress, so refresh periodically while
-- the menu is open. Render() still only pushes when the text actually differs.
function GUI.MarkDirty()
    if GUI.IsOpen then GUI.dirty = true end
end

return GUI
