-- Blood Trail Mod Menu - ESP tab
--
-- Two layers, each behind its own switch so a crash bisects to one call.
--
-- 1. HEADSET ESP TEXT (safe, proven path)
--    Names, health bars, distance, direction, height and a four-way radar,
--    drawn into the one UTextRenderComponent the pawn already owns.
--
-- 2. BODY BOXES - a box drawn ON each enemy, moving with them
--    (the work is in player_mods.lua, "ESP BODY BOXES"; this file only chooses
--    colours and reports)
--
--    The September build drew boxes with DrawDebugBox. That can never work
--    here: UKismetSystemLibrary::DrawDebugBox forwards to ::DrawDebugBox, which
--    is an empty inline in any build with UE_BUILD_SHIPPING, and this game is
--    BTVR-Win64-Shipping.exe. The call "succeeds" and draws nothing.
--
--    What DOES render in a shipping build is a shape component that is not
--    hidden in game. Every enemy is an ACharacter, and ACharacter's root is a
--    UCapsuleComponent wrapped around the whole body - the engine already moves
--    it with the enemy every frame, and its scene proxy draws a wireframe when
--    bHiddenInGame is false. So a body box is: colour the enemy's own capsule
--    (ShapeColor) and un-hide it. Nothing is spawned, attached or moved, and
--    there is no per-frame work at all - which is why it stays glued to them.
--
--    Human NPCs (BP_NPC_Man_C) also carry real hitbox shapes on their bones -
--    CritZone_Head (sphere), CritZone_Neck, _Heart, _Lung_L/R, _Femoral_L/R,
--    _PelvisFront (boxes). Un-hiding those draws their hit zones on the body.
--
--    WHY STILL NO FLOATING TEXT LABELS OVER EACH ENEMY?
--    Moving or spawning a text component has killed this game three times. The
--    names stay on the headset text.
--
-- WHERE THE ENEMY DATA COMES FROM
--
-- PlayerMods.ScanESP copies each live enemy into plain numbers
-- (PlayerMods.espTargets). This file never holds, receives or touches an enemy.

local ESP = {}
local PlayerMods = nil

function ESP.Init(pm) PlayerMods = pm end

ESP.NAMES = {
    ALS_Player_CharacterBPai_C = "CULTIST",
    BP_MeleeAI_Character_C     = "ZOMBIE",
    BP_NPC_Man_C               = "NPC",
}

ESP.COLOUR_NAMES = { "BY TYPE", "RED", "GREEN", "BLUE", "YELLOW", "CYAN", "PINK", "WHITE", "ORANGE" }

---------------------------------------------------------------------------
-- helpers shared with aim
---------------------------------------------------------------------------

-- Where an enemy is NOW, from the last scan plus its measured velocity.
-- Extrapolation is capped so a stale entry cannot fly off.
function ESP.Predict(t, now)
    local age = now - (t.t or now)
    if age < 0 then age = 0 end
    if age > 0.6 then age = 0.6 end
    return t.x + (t.vx or 0) * age, t.y + (t.vy or 0) * age, t.z + (t.vz or 0) * age
end

local function sectorOf(clock)
    if clock == 11 or clock == 12 or clock == 1 then return "front" end
    if clock >= 2 and clock <= 4 then return "right" end
    if clock >= 5 and clock <= 7 then return "behind" end
    return "left"
end

local ARROW = { front = "^", right = ">", behind = "v", left = "<" }

local function bar(frac, cells)
    if type(frac) ~= "number" then return nil end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end
    local n = math.floor((frac * cells) + 0.5)
    return "[" .. string.rep("#", n) .. string.rep("-", cells - n) .. "]"
end

---------------------------------------------------------------------------
-- 1. headset text
---------------------------------------------------------------------------

function ESP.BuildText()
    local s = PlayerMods.state
    local all = PlayerMods.espTargets or {}
    local maxRange = s.ESPMaxRange or 100
    local maxRows = math.floor((s.ESPMaxRows or 6) + 0.5)

    local inRange = {}
    for _, t in ipairs(all) do
        if t.dist <= maxRange then inRange[#inRange + 1] = t end
    end

    local out = {}
    if PlayerMods.dormant then
        out[1] = "-- ENEMY ESP --  (round ending)"
        return table.concat(out, "\n")
    end
    if #inRange == 0 then
        out[1] = "-- ENEMY ESP --  clear"
        return table.concat(out, "\n")
    end

    local head = string.format("-- ENEMY ESP --  %d hostile", #inRange)
    if s.ESPDistance ~= false then
        head = head .. string.format("   nearest %.1f m", inRange[1].dist)
    end
    out[#out + 1] = head

    -- Four-way radar. Each line is centred on the panel on its own, which is
    -- why it holds its shape in the headset's proportional font.
    if s.ESPRadar ~= false then
        local c = { front = 0, right = 0, behind = 0, left = 0 }
        local near = { front = false, right = false, behind = false, left = false }
        for _, t in ipairs(inRange) do
            local sec = sectorOf(t.clock)
            c[sec] = c[sec] + 1
            if t.dist < 5 then near[sec] = true end
        end
        local function cell(sec)
            return string.format("[ %d%s ]", c[sec], near[sec] and "!" or "")
        end
        out[#out + 1] = cell("front")
        out[#out + 1] = cell("left") .. "   YOU   " .. cell("right")
        out[#out + 1] = cell("behind")
    end

    -- the enemy aim is locked on to gets a star
    local AA = PlayerMods.AimMod
    local aimAddr = nil
    if AA and (s.SilentAim or s.AimAssist) and AA.lastAt and (os.clock() - AA.lastAt) < 3 then
        aimAddr = AA.lastAddr
    end

    for i = 1, math.min(maxRows, #inRange) do
        local t = inRange[i]
        local parts = {}
        if aimAddr and t.addr == aimAddr then parts[#parts + 1] = "*" end
        if s.ESPDirection ~= false then
            parts[#parts + 1] = string.format("%s%2d", ARROW[sectorOf(t.clock)], t.clock)
        end
        if s.ESPNames ~= false then
            parts[#parts + 1] = ESP.NAMES[t.cls] or "ENEMY"
        end
        if s.ESPDistance ~= false then
            parts[#parts + 1] = string.format("%.1f m", t.dist)
        end
        if s.ESPHealth ~= false and t.hp and t.hpmax and t.hpmax > 0 then
            local b = bar(t.hp / t.hpmax, 8)
            if b then parts[#parts + 1] = b end
        end
        if s.ESPHeight ~= false and t.dz and math.abs(t.dz) >= 1.5 then
            parts[#parts + 1] = string.format("%s%.0fm", t.dz > 0 and "+" or "-", math.abs(t.dz))
        end
        if t.dist < 5 then parts[#parts + 1] = "!" end
        out[#out + 1] = table.concat(parts, "  ")
    end

    if #inRange > maxRows then
        out[#out + 1] = string.format("+%d more", #inRange - maxRows)
    end
    if AA and (s.SilentAim or s.AimAssist) and s.AimShowTarget ~= false then
        local mode = s.SilentAim and "SILENT AIM" or "AIM ASSIST"
        out[#out + 1] = string.format("%s > %s  [%s]", mode, AA.TargetText(), AA.PartName(s.AimBone))
        -- The cone, live: what it is holding NOW, before the shot. The bar
        -- fills as the target moves toward the middle of the cone.
        if s.AimCone ~= false and AA.ConeText then
            out[#out + 1] = "CONE  " .. AA.ConeText()
        end
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- 2. body boxes: read-outs (the work is in player_mods.lua)
---------------------------------------------------------------------------

function ESP.ColourName(i)
    return ESP.COLOUR_NAMES[math.floor((i or 0) + 0.5) + 1] or "?"
end

-- Short line for the ESP tab
function ESP.BoxText()
    local s = PlayerMods.state
    local st = PlayerMods.boxStats or {}
    if not (s.ESPBoxes or s.ESPHitboxes) then return "off" end
    if (st.live or 0) == 0 then return "on - no enemies yet" end
    return string.format("on %d enemies", st.live or 0)
end

-- A screenshot of exactly what the headset shows, a second after asking, so
-- the boxes can be checked without taking the headset off:
--   %LOCALAPPDATA%\BTVR\Saved\Screenshots\WindowsNoEditor
function ESP.Screenshot()
    ESP.shotNote = "screenshot saved (Saved\\Screenshots)"
    if PlayerMods.Screenshot then PlayerMods.Screenshot() end
end

function ESP.StatusLine()
    local s = PlayerMods.state
    local st = PlayerMods.boxStats or {}
    -- the app splits this line on spaces, so "BY TYPE" goes out as BY_TYPE
    local colour = (ESP.ColourName(s.ESPBoxColor):gsub(" ", "_"))
    return string.format("targets=%d boxes=%s hitboxes=%s colour=%s live=%d " ..
        "shown=%d hidden=%d corpses=%d calls=%d skipped=%d stale=%d",
        #(PlayerMods.espTargets or {}), tostring(s.ESPBoxes == true), tostring(s.ESPHitboxes == true),
        colour, st.live or 0, st.shown or 0, st.hidden or 0,
        st.corpses or 0, st.calls or 0, st.skipped or 0, st.stale or 0)
end

-- The honest answer about walls, on the ESP tab.
function ESP.WallText()
    return "boxes cannot - text does"
end

return ESP
