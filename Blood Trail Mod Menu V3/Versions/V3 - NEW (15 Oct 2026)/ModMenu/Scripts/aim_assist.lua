-- Blood Trail Mod Menu - AIM tab: Silent Aim + Aim Assist + the Aim Cone
--
-- ========================================================================
-- WHY IT STILL DID NOTHING, AND WHAT CHANGED (your 2026-09-18 status.txt)
-- ========================================================================
--
--   aim=bound=true calls=314 mine=314 aimed=253 notarget=61 chance=0
--       spread0=558 writefail=0 postcalls=0 hit=0 miss=0 nopost=26
--
-- Read that again: 253 bullets had their EndLocation rewritten, and every
-- single write was read straight back and matched (writefail=0). The numbers
-- in the bullet were ours. The shots still went where the barrel pointed.
--
-- So the bullet does not decide. By the time BP_InstantHit's
-- EVENT_OnPoolBeginPlay runs, the line has already been drawn - which is also
-- why its POST hook never fires once in 314 shots (postcalls=0) while the
-- gun's own POST hooks fire every shot (Full Auto's rechamber, No Recoil).
-- We were editing the receipt, not the order.
--
-- SkeletalGun_C carries the thing that writes the order:
--
--     class UArrowComponent* FireDirection;   <- the line the shot is built on
--     float Distance;                         <- how far it reaches
--     float CurrentSpread;                    <- how far off it may wander
--     class UObjectPool* ObjectPool_instanthits;
--
-- The gun aims that arrow, traces along it out to Distance, takes a bullet out
-- of its pool and fills the bullet's StartLocation/EndLocation in from what it
-- already worked out. Turn the arrow BEFORE the gun reads it, and the game
-- aims itself: its own trace, its own hit result, its own headshot, crit zone,
-- gore, dismemberment and kill credit. Nothing downstream is faked, because
-- nothing downstream knows anything happened.
--
-- The arrow is put back in the POST hook of the very same call, so the gun is
-- never left crooked, and a tick-level sweep puts back anything a missed POST
-- left behind.
--
-- ========================================================================
-- HOW WE WILL KNOW, WITHOUT A HEADSET
-- ========================================================================
--
-- The bullet hook still runs, and it now runs as a WITNESS. It reads the
-- StartLocation/EndLocation the gun just wrote and compares that direction
-- with the direction we just told the gun to use:
--
--     follow=  bullets that came out along the line we set   <- it works
--     stray=   bullets that ignored it                       <- it does not
--
-- That is a full end-to-end proof of the redirect, from one line of
-- status.txt, with no POST hook and nothing held on to.
--
-- ========================================================================
-- WHERE THE TARGETS COME FROM
-- ========================================================================
--
-- PlayerMods.espTargets: plain numbers copied straight after the one enemy
-- sweep proven to hand back only live actors (see player_mods.lua ScanESP),
-- including the world offset of each body part. Nothing in this file ever
-- holds, receives or touches an enemy object - the 0x268 round-end crash is a
-- read off an enemy the round just destroyed, and a number cannot be
-- destroyed.
--
-- The hooks only ever touch the GUN in your hands or the BULLET that is
-- running them, both alive by construction while their own function runs.

local AA = {
    bound = false, bindTries = 0,
    calls = 0, mine = 0, redirected = 0, noTarget = 0, spreadZeroed = 0,
    chanceSkipped = 0, writeFail = 0,
    postCalls = 0, confirmed = 0, missed = 0, unknown = 0, noPost = 0,
    forced = 0, lastMissCm = nil,
    lastPart = nil, lastName = nil, lastDist = nil, lastAddr = nil, lastAt = nil,
    stickyAddr = nil,
}

-- Everything about aiming the gun itself lives in here.
AA.gun = {
    bound = false, tries = 0, calls = 0, mine = 0, aimed = 0, noTarget = 0,
    noArrow = 0, setOk = 0, setFail = 0, restored = 0, lateRestore = 0,
    aimedAt = -99, reaimed = 0, noRel = 0, worldRestores = 0, restoreFail = 0,
    muzzleOk = 0, muzzleFail = 0, madeHit = 0, beamAimed = 0, turned = 0,
    heldGuns = 0, nearGuns = 0, noFlag = 0, notHeld = 0, byAttach = 0,
    follow = 0, stray = 0, shape = 0, relShape = 0, strayDeg = nil,
    strayOrig = nil, ignored = 0,
    dir = nil, was = nil, dirAt = -99, beamOn = false, beamCalls = 0,
    beamGuns = 0, beamSkip = 0,
}

-- The live cone read-out, refreshed a few times a second by AA.ConeTick.
AA.cone = { locked = false, name = nil, part = nil, dist = nil, ang = nil,
            inCone = 0, seen = 0, at = -99, src = "none" }

local PlayerMods, ESP = nil, nil

function AA.Init(pm, esp) PlayerMods, ESP = pm, esp end

local EVENT = "/Game/WeaponMaster/Blueprints/Basic/BP_InstantHit.BP_InstantHit_C:EVENT_OnPoolBeginPlay"
local SHRAPNEL = "/Game/WeaponMaster/Blueprints/SpawnedBulletsAndProjectiles/BP_Shrapnel_InstantHit.BP_Shrapnel_InstantHit_C"
local BUCKSHOT = "/Game/WeaponMaster/Blueprints/SpawnedBulletsAndProjectiles/BP_Buckshot_InstantHit.BP_Buckshot_InstantHit_C"

-- The gun. SkeletalGun_C is where FireDirection, Distance and the fire
-- functions live; the concrete guns inherit them, so hooking the base class
-- function object covers every gun in the game (proven: shothooks=314).
local GUN_PATH = "/Game/VRExpansion/Guns/skeletalguns/SkeletalGun.SkeletalGun_C"
local GUN_CLASS = "SkeletalGun_C"
-- FindAllOf returns instances of the EXACT class only, so the beam sweep has
-- to name every concrete gun, same as player_mods' gun sweep does.
local GUN_SUBCLASSES = {
    "SkeletalGun_C",
    "bp_Skel_shotgun_C", "bp_Skel_ak_C", "bp_skel_glock_C", "bp_skel_92fs_C",
}
-- PreFireFunction first: it is the one named for "just before the shot".
-- The rest are hooked too because we cannot see the graph, and a shot that
-- reaches any of them gets aimed exactly once (guarded by a per-gun stamp).
local GUN_FNS = { "PreFireFunction", "FireGun", "Firebulletauto",
                  "FireBulletsingle", "FIREEVENT" }
-- ...and the gun's own "the shot has happened" events, which is where the
-- arrow is put straight again. UE4SS POST callbacks do not run in this build
-- (status.txt: restored=0 late=189, and the bullet's postcalls=0 over 314
-- shots), so the blueprint's own after-the-shot functions are used instead.
local GUN_RESTORE_FNS = { "PostFireFunction", "PostFireEvent" }

local shrapnelAddr, buckshotAddr = nil, nil
-- fire functions already hooked, so a retry never double-registers one
local gunBoundTargets = {}

-- The body-part picker. Indices 0..6 are the parts the game's own damage code
-- groups bones into (ALS_Player_CharacterBPai: BonesHead, BonesNeck, BonesChest,
-- BonesStomach, BonesPelvis, BonesRight/LeftArm, BonesRight/LeftLeg).
AA.PART_NAMES = { "HEAD", "NECK", "CHEST", "STOMACH", "PELVIS", "ARMS", "LEGS",
                  "NEAREST PART", "RANDOM PART" }
AA.PART_KEYS  = { "head", "neck", "chest", "stomach", "pelvis", "arms", "legs" }
AA.PRIORITY_NAMES = { "CLOSEST TO AIM", "CLOSEST TO ME", "LOWEST HEALTH", "HIGHEST HEALTH" }
AA.BEAM_COLOURS = {
    { 40, 255, 80 },  { 255, 40, 40 }, { 60, 140, 255 }, { 255, 230, 40 },
    { 40, 240, 255 }, { 255, 60, 255 }, { 255, 255, 255 }, { 255, 140, 0 },
}
AA.BEAM_COLOUR_NAMES = { "GREEN", "RED", "BLUE", "YELLOW", "CYAN", "PINK",
                         "WHITE", "ORANGE" }

-- Offsets from the actor origin (the capsule centre) for a standing body, used
-- only when the scan could not read the real bone for an enemy.
AA.FALLBACK = {
    head = { 0, 0, 68 }, neck = { 0, 0, 55 }, chest = { 0, 0, 38 },
    stomach = { 0, 0, 18 }, pelvis = { 0, 0, 2 }, arms = { 0, 0, 30 },
    legs = { 0, 0, -45 },
}

local function alive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- IS IT ACTUALLY IN YOUR HAND?
--
-- "the beam is going onto the npcs guns too when they died" - and that report
-- is also the crash. 20 September, 8 minutes in, kills=25:
--
--   lastop.txt   beam-aim
--   CrashContext EXCEPTION_ACCESS_VIOLATION reading 0x268, GameThread
--   status.txt   dropped=0 gen=5
--
-- dropped=0 is the important number. The world-change guard never fired, so
-- this was not a stale world - it was a gun that died while the round carried
-- on. "Near you" picks up an enemy's gun when he walks into you and keeps it
-- for the full second the cache holds, and when he dies the game takes that
-- gun away underneath us. Touching its arrow is a struct copy off a dead
-- actor, which is 0x268 exactly.
--
-- A gun you are HOLDING cannot be destroyed out from under you. VRExpansion
-- records that directly: AGrippableSkeletalMeshActor carries
-- FBPInterfaceProperties VRGripInterfaceSettings, whose bIsHeld is true for
-- exactly as long as a hand has it. Proximity alone is not ownership.
-- A SECOND OPINION, BECAUSE EVERYTHING NOW HANGS ON ONE BOOLEAN.
--
-- If bIsHeld were ever wrong or absent on this build, the beam and Silent Aim
-- would both go quiet with nothing to point at. So there is a second, equally
-- exact answer to the same question: a gun in your hand is ATTACHED to you,
-- and an enemy's is attached to him. AActor::GetAttachParentActor is in
-- Engine.hpp and is an object read, not a struct copy.
--
-- It is only consulted when the grip flag says no - the flag is cheaper and
-- comes first - and only for guns already near you, so it costs nothing on
-- the hundreds of guns lying around a level.
local function attachedToMe(gun)
    local okP, parent = pcall(function() return gun:GetAttachParentActor() end)
    if not (okP and parent) then return false end
    local okV, valid = pcall(function() return parent:IsValid() end)
    if not (okV and valid) then return false end
    local pawn = PlayerMods.GetPawn and PlayerMods.GetPawn()
    if not pawn then return false end
    local okA, a = pcall(function() return parent:GetAddress() end)
    local okB, b = pcall(function() return pawn:GetAddress() end)
    return okA and okB and a == b
end

-- `near` lets the caller say "this one is close enough to be worth a second
-- look"; without it only the cheap flag is consulted.
local function isHeld(gun, near)
    local ok, v = pcall(function() return gun.VRGripInterfaceSettings.bIsHeld end)
    if ok and type(v) == "boolean" then
        if v then return true, true end
        -- A READABLE "no" IS TAKEN AT ITS WORD (measured 2026-09-20 21:26).
        --
        -- The first version also asked the attachment when the flag said no,
        -- as insurance against a build that reported it wrongly. A live
        -- session settled that: `gunwho=yours=2 noflag=0` - the flag does go
        -- true when you pick a gun up, so the insurance is not needed for a
        -- held gun. What it WAS catching, 184 times in forty seconds, is guns
        -- HOLSTERED on your body: attached to you, yours, and not being
        -- aimed. Painting a beam down your own hip is not the job.
        --
        -- So the attachment is consulted only when the flag cannot be read at
        -- all, which is the case it was really for.
        --
        -- 21 September: TRIED AND REVERTED - do not put this back without
        -- reading this first. A session reported held=0 all the way through
        -- while the ammo side found your gun 1324 times, 773 of them by
        -- attachment, so "ask the attachment when the flag says no" looked
        -- like the fix. It is not: in VRExpansion a GRIPPED gun is held by a
        -- physics constraint and is attached to nothing, so attachment is
        -- precisely what a HOLSTERED gun has. That rescue paints the gun on
        -- your hip - and with your arms down your hand is at your hip, so
        -- "only when it is at a hand" does not save it either. The fake
        -- caught it immediately.
        return false, true
    end
    -- the flag could not be read at all
    if near and attachedToMe(gun) then
        AA.gun.byAttach = (AA.gun.byAttach or 0) + 1
        return true, false
    end
    return false, false        -- second value: was the flag readable at all
end


local function addrOf(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

-- alive() for a gun REMEMBERED from an earlier moment: the engine's name
-- table is asked first, so a gun the game has freed is never read - see
-- PlayerMods.Remember. Falls back to alive() when that cannot tell.
local function stillAlive(o)
    if not o then return false end
    if PlayerMods and PlayerMods.StillThere and PlayerMods.StillThere(o) == false then
        return false
    end
    return alive(o)
end

---------------------------------------------------------------------------
-- vector maths (pure Lua; nothing here calls the engine)
---------------------------------------------------------------------------

local function rotToDir(pitch, yaw)
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp = math.cos(p)
    return cp * math.cos(y), cp * math.sin(y), math.sin(p)
end

local function dirToRot(x, y, z)
    local yaw = math.deg(math.atan(y, x))
    local pitch = math.deg(math.atan(z, math.sqrt(x * x + y * y)))
    return pitch, yaw
end

local function norm(x, y, z)
    local l = math.sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 0, 0, 0 end
    return x / l, y / l, z / l, l
end

local function angleDeg(ax, ay, az, bx, by, bz)
    local d = ax * bx + ay * by + az * bz
    if d > 1 then d = 1 end
    if d < -1 then d = -1 end
    return math.deg(math.acos(d))
end

AA.rotToDir, AA.dirToRot, AA.angleDeg, AA.norm = rotToDir, dirToRot, angleDeg, norm

local function vec3(v)
    if v and type(v.X) == "number" and type(v.Y) == "number" and type(v.Z) == "number" then
        return v.X, v.Y, v.Z
    end
    return nil
end

---------------------------------------------------------------------------
-- choosing a target and a body part
---------------------------------------------------------------------------

-- World point of one body part of a target, predicted to now.
function AA.PartPoint(t, key, x, y, z)
    local off = (t.parts and t.parts[key]) or AA.FALLBACK[key] or AA.FALLBACK.chest
    return x + off[1], y + off[2], z + off[3]
end

-- Which part to aim at for this target. `ox..fz` is the shot (origin + unit
-- direction), needed for NEAREST PART.
local function choosePart(t, s, x, y, z, ox, oy, oz, fx, fy, fz)
    local pick = math.floor((s.AimBone or 0) + 0.5)
    if pick >= 0 and pick <= 6 then
        local key = AA.PART_KEYS[pick + 1]
        local px, py, pz = AA.PartPoint(t, key, x, y, z)
        return key, px, py, pz
    end
    if pick == 8 then
        local key = AA.PART_KEYS[math.random(1, #AA.PART_KEYS)]
        local px, py, pz = AA.PartPoint(t, key, x, y, z)
        return key, px, py, pz
    end
    -- NEAREST PART: the one the shot is already closest to
    local bestKey, bx, by, bz, bestAng = "chest", nil, nil, nil, math.huge
    for _, key in ipairs(AA.PART_KEYS) do
        local px, py, pz = AA.PartPoint(t, key, x, y, z)
        local dx, dy, dz = norm(px - ox, py - oy, pz - oz)
        local ang = angleDeg(fx, fy, fz, dx, dy, dz)
        if ang < bestAng then bestKey, bx, by, bz, bestAng = key, px, py, pz, ang end
    end
    return bestKey, bx, by, bz
end

-- The half-angle of the aim cone right now, in degrees. 180 or more means
-- "anywhere around you". Silent Aim and Aim Assist each have their own.
function AA.ConeAngle(s)
    if s.SilentAim then return s.SilentFov or 90 end
    return s.AimFov or 15
end

-- The best target for a shot from (ox,oy,oz) heading (fx,fy,fz). Exposed for
-- the tests. Returns a table of numbers, or nil.
function AA.PickTarget(ox, oy, oz, fx, fy, fz, targets, s, now)
    local fov = AA.ConeAngle(s)
    local range = (s.AimRange or 60) * 100.0
    local prio = math.floor((s.AimPriority or 0) + 0.5)
    local best, bestScore = nil, math.huge
    local inCone, seen = 0, 0

    for _, t in ipairs(targets or {}) do
        local x, y, z = ESP.Predict(t, now)
        local key, px, py, pz = choosePart(t, s, x, y, z, ox, oy, oz, fx, fy, fz)
        local dx, dy, dz, dist = norm(px - ox, py - oy, pz - oz)
        if dist > 30 and dist <= range then
            seen = seen + 1
            local ang = angleDeg(fx, fy, fz, dx, dy, dz)
            -- 180 or more means "anywhere around you"
            if fov >= 180 or ang <= fov then
                inCone = inCone + 1
                local score
                if prio == 1 then
                    score = dist
                elseif prio == 2 then
                    score = (type(t.hp) == "number") and t.hp or 1e9
                elseif prio == 3 then
                    score = (type(t.hp) == "number") and -t.hp or 1e9
                else
                    score = ang + (dist / 100.0) * 0.05
                end
                -- Stay On One Target: whoever we shot last wins while still valid
                if s.AimSticky and t.addr and t.addr == AA.stickyAddr then
                    score = -math.huge
                end
                if score < bestScore then
                    bestScore = score
                    best = { x = px, y = py, z = pz, dist = dist, ang = ang,
                             part = key, addr = t.addr, cls = t.cls }
                end
            end
        end
    end
    AA.lastInCone, AA.lastSeen = inCone, seen
    return best
end

-- Blend the shot's own direction toward the target by `strength` (0..1).
function AA.Bend(fx, fy, fz, tx, ty, tz, strength)
    local k = strength
    if k < 0 then k = 0 end
    if k > 1 then k = 1 end
    local x, y, z = norm(fx * (1 - k) + tx * k, fy * (1 - k) + ty * k, fz * (1 - k) + tz * k)
    return x, y, z
end

---------------------------------------------------------------------------
-- the player position the "is this mine" test compares against
---------------------------------------------------------------------------
-- Refreshed from the loop, a few times a second, as numbers.

AA.origin = nil

local function anyOn(s)
    return s.SilentAim or s.AimAssist or s.NoSpread or s.AimForceDamage
        or s.AimOneShot or s.AimBeam
end
AA.AnyOn = anyOn

local function aimOn(s)
    return s.SilentAim or s.AimAssist
end

function AA.OriginTick()
    local s = PlayerMods.state
    if not anyOn(s) then return end
    local pawn = PlayerMods.GetPawn()
    if not alive(pawn) then AA.origin = nil return end
    local ok, p = pcall(function() return pawn:K2_GetActorLocation() end)
    if ok and p and type(p.X) == "number" then
        AA.origin = { x = p.X, y = p.Y, z = p.Z, addr = addrOf(pawn) }
    end
end

-- IN MY HAND, WHICH IS NOT THE SAME AS ON MY PERSON (2026-09-21).
--
-- A whole session reported held=0 near=0 with the beam switched on: the beam
-- found no gun of yours at all, and fell back to pointing out of your head.
-- Meanwhile the ammo side of the mod found your gun 1324 times in the same
-- session - 773 of those by noticing it was ATTACHED to you rather than by
-- the grip flag, which is to say the grip flag reads false a great deal of
-- the time on this build.
--
-- The beam cannot simply copy that, because "attached to you" is also true of
-- every gun holstered on your body, and painting a beam down your own hip is
-- what this file spent last session learning not to do.
--
-- So ask a better question: is the gun AT A HAND? A gun you are holding sits
-- in the palm; a holstered one sits on your hip, which is nowhere near either
-- controller unless you are reaching for it. That separates the two cases
-- without relying on a flag this build will not answer honestly.
local HAND_CM = 25.0
-- Tighter than HAND_CM, and this is the one ownership uses. A gun you are
-- GRIPPING sits in the palm; one holstered on your hip is further off even
-- with your arms down. athand= (25 cm) is still reported beside ingrip=
-- (20 cm) so the two can be compared from a session file if this ever needs
-- moving again.
local GRIP_CM = 20.0
local handPos, handAt = nil, -99

local function hands()
    local now = os.clock()
    if handPos and (now - handAt) < 0.25 then return handPos end
    local out = nil
    if PlayerMods.GetHand then
        for _, left in ipairs({ true, false }) do
            local c = PlayerMods.GetHand(left)
            if c then
                local ok, p = pcall(function() return c:K2_GetComponentLocation() end)
                if ok and p and type(p.X) == "number" then
                    out = out or {}
                    out[#out + 1] = { x = p.X, y = p.Y, z = p.Z }
                end
            end
        end
    end
    handPos, handAt = out, now
    return out
end

-- How far this is from the nearer hand, or nil when the controllers cannot
-- be read at all. nil and 0 are very different answers and the caller needs
-- to tell them apart.
local function handDistance(x, y, z)
    local hs = hands()
    if not hs then return nil end          -- nil = "could not ask"
    local best = nil
    for _, h in ipairs(hs) do
        local dx, dy, dz = x - h.x, y - h.y, z - h.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if best == nil or d < best then best = d end
    end
    return best
end

local function atHand(x, y, z)
    local d = handDistance(x, y, z)
    if d == nil then return nil end
    return d <= HAND_CM
end

-- Near enough to my body to be my gun / my bullet. Enemies carry guns too.
local function nearMe(x, y, z, cm)
    local O = AA.origin
    if not O then return false end
    local dx, dy, dz = x - O.x, y - O.y, z - O.z
    return (dx * dx + dy * dy + dz * dz) <= (cm * cm)
end

---------------------------------------------------------------------------
-- AIMING THE GUN
---------------------------------------------------------------------------
-- USceneComponent::K2_SetWorldRotation takes an FHitResult by reference, and
-- how UE4SS wants that passed from Lua is not something we can look up from
-- here. So try the shapes in order on the first shot, keep whichever one the
-- component actually reads back, and report the winner in status.txt. This is
-- the same "write it, read it back, believe the read" rule the bullet writes
-- already follow.
local SET_SHAPES = {
    function(c, r) c:K2_SetWorldRotation(r, false, {}, false) end,
    function(c, r) c:K2_SetWorldRotation(r, false, nil, false) end,
    function(c, r) c:K2_SetWorldRotation(r, false) end,
    function(c, r) c:K2_SetWorldRotation(r) end,
}
local SET_REL_SHAPES = {
    function(c, r) c:K2_SetRelativeRotation(r, false, {}, false) end,
    function(c, r) c:K2_SetRelativeRotation(r, false, nil, false) end,
    function(c, r) c:K2_SetRelativeRotation(r, false) end,
    function(c, r) c:K2_SetRelativeRotation(r) end,
}

---------------------------------------------------------------------------
-- TURNING THE GUN ITSELF
---------------------------------------------------------------------------
-- The arrow was the wrong lever, and status.txt proved it beyond argument:
--
--   aimgun=... aimed=376 setok=376 setfail=0 follow=20 stray=291
--           ignored=275 straydeg=102.6 strayorig=0.3
--
-- `ignored=275` counts bullets that came out along the direction the gun was
-- pointing BEFORE the arrow was turned, and `strayorig=0.3` says they matched
-- it to within a third of a degree. 376 arrow turns, every one verified by
-- reading it back, and the shot never once noticed. `FireDirection` is not
-- what the shot is built from.
--
-- SkeletalGun_C also carries `FName MuzzleSocket`, and a socket lives on the
-- MESH - which follows the ACTOR. So turn the actor, by exactly the angle the
-- shot needs to move. Working in DELTAS rather than absolutes is what makes
-- that safe: we measure the direction the shot actually leaves along, work
-- out how far that is from the target, and turn the whole gun by that much.
-- It lands right whether the game reads the socket, the actor's own forward,
-- or anything else rigidly attached to the gun.
--
-- The arrow is left alone now, which frees it to be the beam.
local function actorRot(gun)
    local ok, r = pcall(function() return gun:K2_GetActorRotation() end)
    if ok and r and type(r.Yaw) == "number" then return r.Pitch, r.Yaw, r.Roll end
    return nil
end

-- There is deliberately no setActorRot any more. Writing a rotation onto the
-- gun ACTOR is what threw it at the enemy: ASkeletalGun_C derives from
-- AGrippableSkeletalMeshActor, so it is a simulating body held by a
-- VRExpansion grip constraint, and teleporting it mid-shot makes that
-- constraint fire the gun across the room. Reading the rotation (above) is
-- free and the witness needs it; writing it is off the table.

local function readRot(comp)
    local ok, r = pcall(function() return comp:K2_GetComponentRotation() end)
    if ok and r and type(r.Yaw) == "number" then
        return r.Pitch, r.Yaw, r.Roll
    end
    return nil
end

-- The arrow's rotation RELATIVE TO THE GUN. This is the number that has to be
-- put back after a shot, and it is the whole reason the last version made a
-- mess of the beam: it saved the arrow's WORLD rotation, and by the time the
-- restore ran (up to 0.3 s later, because the POST hook never fires - see
-- restored=0 late=189 in your status.txt) you had moved the gun. Forcing the
-- old world rotation onto a component that has moved leaves it skewed against
-- its parent, and every shot skewed it further. Relative rotation does not
-- care where the gun has been pointed since.
local function readRel(comp)
    local ok, r = pcall(function() return comp.RelativeRotation end)
    if ok and r and type(r.Yaw) == "number" then
        return r.Pitch, r.Yaw, r.Roll
    end
    return nil
end

local function angClose(a, b)
    return math.abs((a - b + 540) % 360 - 180) < 1.5
end

local function rotClose(comp, pitch, yaw)
    local p, y = readRot(comp)
    if not p then return false end
    return angClose(p, pitch) and angClose(y, yaw)
end

local function relClose(comp, pitch, yaw)
    local p, y = readRel(comp)
    if not p then return false end
    return angClose(p, pitch) and angClose(y, yaw)
end

-- Returns true only if the component genuinely turned.
local function setWorldRot(comp, pitch, yaw, roll)
    local r = { Pitch = pitch, Yaw = yaw, Roll = roll or 0.0 }
    local first = AA.gun.shape
    if first > 0 then
        pcall(SET_SHAPES[first], comp, r)
        if rotClose(comp, pitch, yaw) then return true end
        AA.gun.shape = 0   -- it stopped working; find the shape again
    end
    for i = 1, #SET_SHAPES do
        pcall(SET_SHAPES[i], comp, r)
        if rotClose(comp, pitch, yaw) then
            AA.gun.shape = i
            return true
        end
    end
    return false
end

-- Put the arrow back where it sits on the gun. Same probe as the world
-- setter: which call shape UE4SS wants is not knowable from a header.
local function setRelRot(comp, pitch, yaw, roll)
    local r = { Pitch = pitch, Yaw = yaw, Roll = roll or 0.0 }
    local first = AA.gun.relShape
    if first > 0 then
        pcall(SET_REL_SHAPES[first], comp, r)
        if relClose(comp, pitch, yaw) then return true end
        AA.gun.relShape = 0
    end
    for i = 1, #SET_REL_SHAPES do
        pcall(SET_REL_SHAPES[i], comp, r)
        if relClose(comp, pitch, yaw) then
            AA.gun.relShape = i
            return true
        end
    end
    return false
end

-- Guns we have turned and not yet turned back. Keyed by address, holding only
-- numbers plus the component we were handed this call - never across a round.
local pending = {}

-- Put one gun back exactly as it was. `gun` may be nil when only the arrow is
-- reachable (the loop backstop), and the arrow is the part that matters.
-- Put one gun back exactly as it was. `onGameThread` says whether we are
-- already there; from the loop we are NOT, and turning an actor from the loop
-- thread is the mistake that has crashed this game before - this time inside
-- UE4SS itself, reading 0x54 after 73 of these went out from the loop.
local function restoreGun(gun, st, onGameThread)
    if not st then return false end
    if not (gun and stillAlive(gun)) then
        AA.gun.restoreFail = AA.gun.restoreFail + 1
        return false
    end
    -- nothing was borrowed: no work, no engine calls. There is no rotation to
    -- put back any more - the gun is never turned - so this is two numbers the
    -- gun lent us for one shot: its trace length and its spread.
    if not (st.dist or st.spread) then return true end

    local function put()
        if not stillAlive(gun) then return end
        if st.dist then pcall(function() gun.Distance = st.dist end) end
        if st.spread then pcall(function() gun.CurrentSpread = st.spread end) end
    end

    if onGameThread then
        put()
    else
        PlayerMods.InGameThread("gun-restore", function()
            if PlayerMods.dormant then return end
            put()
        end)
    end
    return true
end

-- PRE on the gun's own fire call: turn the arrow the shot is built from.
local function gunPre(self)
    local s = PlayerMods.state
    if not aimOn(s) then return end
    if PlayerMods.dormant then return end

    local okG, gun = pcall(function() return self:get() end)
    gun = (okG and gun) or self
    local addr = addrOf(gun)
    if not addr then return end

    -- ONE TRIGGER PULL, ONE AIM - but every trigger pull gets one.
    --
    -- Five fire functions are hooked, in two path forms each, and a single
    -- shot runs several of them inside the same frame. Anything inside 10 ms
    -- is that same shot. Anything later is a NEW shot, and the last version
    -- threw those away (aimed=189 of calls=521) because the entry was still
    -- sitting there waiting for a POST hook that never comes. Put the arrow
    -- back and aim again.
    local held = pending[addr]
    if held then
        if (os.clock() - (held.at or 0)) < 0.010 then return end
        pending[addr] = nil
        restoreGun(gun, held, true)   -- we are inside a hook: game thread
        AA.gun.reaimed = AA.gun.reaimed + 1
    end

    AA.gun.calls = AA.gun.calls + 1

    local okA, arrow = pcall(function() return gun.FireDirection end)
    if not (okA and alive(arrow)) then
        AA.gun.noArrow = AA.gun.noArrow + 1
        return
    end

    local okL, loc = pcall(function() return arrow:K2_GetComponentLocation() end)
    local ox, oy, oz = vec3(okL and loc or nil)
    if not ox then AA.gun.noArrow = AA.gun.noArrow + 1 return end

    -- MY GUN, NOT AN ENEMY'S - and "within three metres" was never that test.
    --
    -- 20 September: calls=462 mine=462. Every single fire call in the session
    -- was taken as yours, because anybody shooting inside 3 m counted. That is
    -- not just miscounting: this hook BORROWS the gun's reach and spread and
    -- hands them back up to 0.3 s later (late=60 that session). Borrowing from
    -- an enemy's gun and giving it back after he has died is a write to an
    -- actor the game has taken away.
    --
    -- Held, and close. The same test the beam uses, for the same reason.
    local closeEnough = nearMe(ox, oy, oz, 110.0)
    if not isHeld(gun, closeEnough) then
        AA.gun.notHeld = (AA.gun.notHeld or 0) + 1
        return
    end
    if not closeEnough then return end
    AA.gun.mine = AA.gun.mine + 1

    local pitch0, yaw0, roll0 = readRot(arrow)
    if not pitch0 then AA.gun.noArrow = AA.gun.noArrow + 1 return end
    local fx, fy, fz = rotToDir(pitch0, yaw0)

    -- Hit Chance: a skipped shot leaves the gun exactly as you held it.
    local chance = s.AimHitChance or 100
    if chance < 100 and math.random(1, 100) > chance then
        AA.chanceSkipped = AA.chanceSkipped + 1
        return
    end

    local target = AA.PickTarget(ox, oy, oz, fx, fy, fz, PlayerMods.espTargets,
                                 s, os.clock())
    if not target then
        AA.gun.noTarget = AA.gun.noTarget + 1
        return
    end

    local tx, ty, tz = norm(target.x - ox, target.y - oy, target.z - oz)
    local nx, ny, nz
    if s.SilentAim then
        nx, ny, nz = tx, ty, tz
    else
        nx, ny, nz = AA.Bend(fx, fy, fz, tx, ty, tz, (s.AimStrength or 100) / 100.0)
    end

    local aP, aY, aR = actorRot(gun)
    if not aP then
        AA.gun.noArrow = AA.gun.noArrow + 1
        return
    end
    local st = { aPitch = aP, aYaw = aY, aRoll = aR, at = os.clock() }

    -- Reach: the gun's own trace length has to cover the target, or the line
    -- stops short of them and nothing is hit.
    local okD, d0 = pcall(function() return gun.Distance end)
    if okD and type(d0) == "number" then
        local want = target.dist + 500.0
        if d0 < want then
            if pcall(function() gun.Distance = want end) then st.dist = d0 end
        end
    end

    -- Silent Aim means the shot goes where it is sent, not scattered round it.
    local keepSpread = (PlayerMods.state.AimKeepShotgunSpread ~= false)
        and AA.gunIsShotgun(gun)
    if s.SilentAim and not keepSpread then
        local okS, sp = pcall(function() return gun.CurrentSpread end)
        if okS and type(sp) == "number" and sp ~= 0 then
            if pcall(function() gun.CurrentSpread = 0.0 end) then st.spread = sp end
        end
        AA.spreadZeroed = AA.spreadZeroed + 1
    end

    -- BENDING THE SHOT IS NOW OPTIONAL, AND OFF BY DEFAULT.
    --
    -- Turning the gun does move the shot - a 19 September session proved it,
    -- ignored=0 where the previous build read ignored=275. But it only moved
    -- it PART of the way: follow=9, stray=93, straydeg=34.8. The gun is held
    -- by VRExpansion's grip, which drives its transform every frame, and a
    -- rotation pushed in underneath that is both fought over and, on a gun
    -- held at any roll at all, not the rotation the shot needs.
    --
    -- It is also the most invasive thing this mod has ever done: moving a
    -- gripped, simulating physics actor 117 times in four minutes, sometimes
    -- leaving it turned for a tenth of a second when the post-fire event did
    -- not arrive (late=20). That session ended with the game stopping dead,
    -- no crash file and nothing in the log.
    --
    -- So it is an experiment you can switch on, not something that happens to
    -- you. What makes Silent Aim WORK is below: the shot is measured, and if
    -- it was not going to hit the enemy it was sent at, that enemy takes it
    -- anyway through the game's own damage - the same path the fists use.
    --
    -- AND NOW IT DOES NOT TURN THE GUN AT ALL (2026-09-20).
    --
    -- "the gun goes in the npc not the bullets". That is not a bug in the
    -- maths, it is what this was always going to do, and CXXHeaderDump says
    -- why in one line:
    --
    --     class ASkeletalGun_C : public AGrippableSkeletalMeshActor
    --
    -- The gun is a VRExpansion GRIPPED actor: a simulating rigid body held to
    -- your hand by a constraint the plugin solves every frame. K2_SetActorRotation
    -- with bTeleportPhysics teleports that body. The constraint wakes up to
    -- find its target metres of angle away from where it left it and does the
    -- only thing a constraint can do about that - it throws the gun at the
    -- error. So the gun flew, and it flew towards whoever we had just aimed
    -- it at.
    --
    -- There is no version of "shove a gripped physics body mid-shot" that is
    -- safe, so the gun is not touched any more. The bend moves to the one
    -- place that can carry it without physics: the bullet.
    --
    -- BP_BulletBase.hpp has a field nothing has ever written -
    --
    --     FRotator MuzzleRotation;
    --
    -- - sitting beside the StartLocation/EndLocation pair that was rewritten
    -- 253 times last time with no effect. A bullet that ignores both its own
    -- actor rotation AND Start->End, but is built from a MuzzleRotation the
    -- gun handed it at spawn, explains every measurement taken so far: it is
    -- also why turning the whole gun moved SOME shots (follow=69) - the gun
    -- computes that rotation from itself.
    --
    -- So Bend The Shot now sets MuzzleRotation on the bullet, costs one struct
    -- write on a pooled actor the game is about to use anyway, and cannot move
    -- anything you are holding. The witness below still measures whether the
    -- shot followed, so next session says plainly whether that field is the
    -- one.
    if s.AimGun == true then
        AA.gun.turned = AA.gun.turned + 1
    end

    st.gun = gun          -- for the loop backstop, which has no `self`
    if PlayerMods.Remember then PlayerMods.Remember(gun) end
    pending[addr] = st
    AA.gun.aimed = AA.gun.aimed + 1
    AA.gun.dir = { nx, ny, nz }
    -- where the gun was pointing BEFORE we turned it, so a bullet that ignores
    -- us can be told apart from one that never saw the change at all
    AA.gun.was = { fx, fy, fz }
    -- and WHO it was meant for, so a shot that goes somewhere else can still
    -- be made to count (see "MAKE SURE IT HITS")
    AA.gun.tgtAddr, AA.gun.tgtCls = target.addr, target.cls
    -- ...and where on him, so the impact his hit shows lands there too
    AA.gun.tgtX, AA.gun.tgtY, AA.gun.tgtZ = target.x, target.y, target.z
    AA.gun.dirAt = os.clock()
    AA.gun.aimedAt = AA.gun.dirAt

    AA.lastPart, AA.lastDist, AA.lastAddr, AA.lastAt = target.part, target.dist,
        target.addr, os.clock()
    AA.lastName = (ESP and ESP.NAMES and ESP.NAMES[target.cls]) or "ENEMY"
    if s.AimSticky then AA.stickyAddr = target.addr end
    AA.redirected = AA.redirected + 1

    -- Extra damage is applied whether or not the trace lands, so queue it now.
    if (s.AimForceDamage or s.AimOneShot) and target.addr and PlayerMods.QueueShotDamage then
        local amount = s.AimOneShot and 100000.0 or (s.AimForceAmount or 100)
        -- where it hits and which way the shot travels, so the enemy's own
        -- BulletDamage gets the same picture a real bullet would give it
        local hit = nil
        if target.x and ox then
            local hx, hy, hz = norm(target.x - ox, target.y - oy, target.z - oz)
            hit = { target.x, target.y, target.z, hx, hy, hz }
        elseif target.x then
            hit = { target.x, target.y, target.z }
        end
        PlayerMods.QueueShotDamage(target.addr, target.cls, amount, hit)
        AA.forced = AA.forced + 1
    end
end

-- A shotgun keeps its spread unless you say otherwise. `shotgun` is a plain
-- bool on SkeletalGun_C.
function AA.gunIsShotgun(gun)
    local ok, v = pcall(function() return gun.shotgun end)
    return ok and v == true
end

-- PUTTING THE GUN BACK.
--
-- This is a PRE hook, on the gun's own PostFireFunction / PostFireEvent -
-- functions the blueprint runs straight after the shot, on the game thread, in
-- the same frame. It is here because UE4SS's POST callbacks never run in this
-- build: status.txt read restored=0 late=189, i.e. not one of 189 shots was
-- put back by the POST hook and every single one was cleaned up by the loop a
-- third of a second later. The same line explains the bullet's postcalls=0.
local function gunRestoreHook(self)
    local okG, gun = pcall(function() return self:get() end)
    gun = (okG and gun) or self
    local addr = addrOf(gun)
    if not addr then return end
    local st = pending[addr]
    if not st then return end
    pending[addr] = nil
    restoreGun(gun, st, true)     -- a hook callback: already the game thread
    AA.gun.restored = AA.gun.restored + 1
end

-- Still registered as the POST callback, so the day UE4SS does deliver one it
-- is used and `restored=` says so.
local gunPost = gunRestoreHook

-- Belt and braces: if a POST never came, put the arrow back from the loop.
-- Nothing here reaches for a gun; it only uses the component we were handed
-- inside the hook, and only while it is still valid.
-- The backstop, for a shot whose post-fire event never came.
--
-- THIS RUNS ON THE LOOP THREAD, so it may not touch the gun itself - it hands
-- the work to the game thread. Doing it here directly is what faulted inside
-- UE4SS at 0x54 after 73 late restores in one session; it is the same mistake
-- as the old 0x268, in a new place.
function AA.GunRestoreTick()
    local now = os.clock()
    for addr, st in pairs(pending) do
        if now - (st.at or 0) > 0.12 then
            pending[addr] = nil
            if st.gun then
                restoreGun(st.gun, st, false)
                AA.gun.lateRestore = AA.gun.lateRestore + 1
            end
        end
    end
end

---------------------------------------------------------------------------
-- THE AIM BEAM - the cone you can actually see
---------------------------------------------------------------------------
-- FireDirection is a UArrowComponent, and an arrow component draws itself as a
-- coloured arrow whenever it is not hidden - like the ESP body boxes, and
-- unlike DrawDebugLine, that is not compiled out of a Shipping build. Un-hide
-- it and the line your bullet is about to take is drawn from your muzzle, in
-- the world, moving with the gun, at no per-frame cost to us.
--
-- DepthPriorityGroup = SDPG_Foreground (1) puts it in front of walls.
--
-- Colour says whether the cone has anyone in it: your colour when it is
-- locked on, dim grey when it is not.

local beamState = {}   -- [gun address] = { key, at }
-- Where each gun's arrow sits when it is not being pointed at anybody, so it
-- can always be put back. Read once per gun, the first time we see it.
local beamHome = {}
-- Where each gun's beam was last pointed, so a beam that is already where it
-- belongs is not shoved there again several times a second.
local beamAim = {}
local gunCache, gunCacheAt, gunCacheGen = nil, -99, -1
-- which blueprint each gun is; filled by sweepGuns, which walks the
-- classes one at a time and therefore knows without having to ask
local gunClassOf = {}

-- THE GUN CACHE IS AN ACTOR CACHE, AND ACTOR CACHES GO STALE (2026-09-20).
--
-- This held a gun for a whole second on nothing but alive(), and player_mods
-- says in as many words that IsValid() returns true for a half-destroyed
-- actor. Change map and this kept handing the cone guns from the level that
-- had just been torn down, which then had K2_GetComponentLocation called on
-- their arrows - an FVector struct copy off a dead actor, which is the 0x268
-- fault exactly.
--
-- So the cache carries the world it was filled in, and a world change throws
-- it away whole rather than filtering it. The hold is unchanged; what changed
-- is that it can no longer outlive its world.
local function sweepGuns()
    local now = os.clock()
    local gen = (PlayerMods and PlayerMods.gen) or 0
    if gunCacheGen ~= gen then
        gunCache, gunCacheAt, gunCacheGen = nil, -99, gen
    end
    -- Hold a found gun for a second (it is the same gun frame after frame),
    -- but when the list is EMPTY come back sooner: that is the moment you have
    -- just picked a gun up, and waiting a whole second to notice would leave
    -- the beam and the cone dead in your hand.
    --
    -- Not shorter than half a second, though. Empty is the LOBBY case, and
    -- this walks the object array once per gun class - the same work ScanESP
    -- does per enemy class. Half a second caps it at ten of those a second
    -- with nothing in your hands, and it shows up in status.txt under
    -- cost=... esp= like everything else that walks the array.
    local hold = (gunCache and #gunCache > 0) and 1.0 or 0.5
    if gunCache and (now - gunCacheAt) < hold then
        local kept = {}
        for _, g in ipairs(gunCache) do
            if stillAlive(g) then kept[#kept + 1] = g end
        end
        gunCache = kept
        if #kept > 0 then return kept end
    end
    local found = {}
    -- address -> which blueprint, learned from the loop below for free
    gunClassOf = {}
    -- THE ONE PLACE THIS SWEEP DIFFERS FROM THE AMMO SIDE'S. That one walks
    -- the same classes but does not ask IsValid(), and it finds your gun
    -- constantly while this one found none at all. If found= is high and
    -- swept= is zero, this filter is the reason and nothing else needs
    -- looking at.
    local rawFound = 0
    for _, cls in ipairs(GUN_SUBCLASSES) do
        local ok, list = pcall(FindAllOf, cls)
        if ok and list then
            for _, g in ipairs(list) do
                rawFound = rawFound + 1
                if alive(g) then
                    found[#found + 1] = g
                    -- fresh from the object array: learn where to find it
                    if PlayerMods and PlayerMods.Remember then PlayerMods.Remember(g) end
                    local a = addrOf(g)
                    if a then gunClassOf[a] = cls end
                end
            end
        end
    end
    gunCache, gunCacheAt, gunCacheGen = found, now, gen
    AA.gun.foundGuns = rawFound
    return found
end

-- One gun's beam, on the game thread. Render state only ever changes there -
-- doing it from the loop thread is the documented 0x268 cause.
-- About 5 s at the cone's ~3 Hz. A new round hands out the SAME addresses to
-- new guns, so a beam that was only ever painted once quietly stops appearing
-- after the first round - which is exactly what happened. Re-assert.
local BEAM_REASSERT = 15
local beamSweep = 0


-- WHERE EACH GUN'S BEAM SITS, REMEMBERED PER GUN.
--
-- Every gun blueprint carries its fire arrow differently, so one pair of
-- sliders cannot line them all up: straightening the ak bends the shotgun.
-- The sliders are a LIVE nudge; pressing SAVE folds the current nudge into
-- the gun you are holding and zeroes the sliders again, so the next gun
-- starts from its own saved value rather than the last one's.
local beamAlign = {}            -- class name -> { pitch, yaw }
local alignFile = nil

local function alignPath()
    if alignFile then return alignFile end
    alignFile = (PlayerMods.DIR or "") .. "beamalign.txt"
    return alignFile
end

function AA.LoadAlign()
    beamAlign = {}
    pcall(function()
        local f = io.open(alignPath(), "r")
        if not f then return end
        for line in f:lines() do
            local cls, p, y = string.match(line, "^([%w_]+)%s+(-?[%d%.]+)%s+(-?[%d%.]+)")
            if cls then beamAlign[cls] = { tonumber(p) or 0.0, tonumber(y) or 0.0 } end
        end
        f:close()
    end)
end

local function saveAlign()
    pcall(function()
        local f = io.open(alignPath(), "w")
        if not f then return end
        for cls, v in pairs(beamAlign) do
            f:write(string.format("%s %.2f %.2f\n", cls, v[1] or 0.0, v[2] or 0.0))
        end
        f:close()
    end)
end

-- The saved nudge for one gun, plus whatever the sliders are showing now.
local function alignFor(cls)
    local s = PlayerMods.state
    local livePitch = tonumber(s.AimBeamPitch) or 0.0
    local liveYaw   = tonumber(s.AimBeamYaw) or 0.0
    local saved = cls and beamAlign[cls] or nil
    return (saved and saved[1] or 0.0) + livePitch,
           (saved and saved[2] or 0.0) + liveYaw
end

-- LINE IT UP WITH WHERE THE BULLETS GO, measured off the gun in your hand.
--
-- The shot leaves along the ACTOR's forward - measured in this game, 376
-- arrow turns moved nothing and the bullets matched the actor to within a
-- third of a degree. So the beam is lined up when the arrow points the same
-- way the actor does, and the nudge needed is just the angle between them.
--
-- Measured, not assumed to be zero: the arrow hangs off the mesh, and what
-- sits between mesh and actor is not ours to guess.
local function angleDelta(a, b)
    return ((a - b + 540.0) % 360.0) - 180.0
end

function AA.AutoAlignForGun()
    local cls = AA.gun.alignCls
    local gun, arrow = AA.gun.alignGun, AA.gun.alignArrow
    if not cls or cls == "" or cls == "?" then return false end
    if not (alive(gun) and alive(arrow)) then return false end
    local ap, ay, _ar = actorRot(gun)
    local bp, by, _br = readRot(arrow)
    if not (ap and bp) then return false end
    local dPitch = angleDelta(ap, bp)
    local dYaw = angleDelta(ay, by)
    local curP, curY = alignFor(cls)
    beamAlign[cls] = { curP + dPitch, curY + dYaw }
    saveAlign()
    -- the sliders go back to zero: the value lives with the gun now
    PlayerMods.state.AimBeamPitch = 0.0
    PlayerMods.state.AimBeamYaw = 0.0
    AA.gun.autoAligned = (AA.gun.autoAligned or 0) + 1
    return true
end

-- "keep what I have just dialled in for the gun in my hand"
function AA.SaveAlignForGun()
    local cls = AA.gun.alignCls
    if not cls or cls == "" or cls == "?" then return false end
    local p, y = alignFor(cls)
    beamAlign[cls] = { p, y }
    saveAlign()
    -- the sliders go back to zero: the value now lives with the gun, and the
    -- next gun you pick up must not inherit this one's nudge
    PlayerMods.state.AimBeamPitch = 0.0
    PlayerMods.state.AimBeamYaw = 0.0
    if PlayerMods.SaveSettings then pcall(PlayerMods.SaveSettings) end
    return true
end

function AA.ResetAlignForGun()
    local cls = AA.gun.alignCls
    if cls and beamAlign[cls] then beamAlign[cls] = nil saveAlign() end
    PlayerMods.state.AimBeamPitch = 0.0
    PlayerMods.state.AimBeamYaw = 0.0
    return true
end

-- "bp_Skel_ak_C:1.5/-2.0 bp_Skel_shotgun_C:0.0/3.5"
function AA.AlignLine()
    local parts = {}
    for cls, v in pairs(beamAlign) do
        parts[#parts + 1] = string.format("%s:%.1f/%.1f", cls, v[1] or 0, v[2] or 0)
    end
    if #parts == 0 then return "none saved" end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- POINT THE BEAM AT HIM.
--
-- The arrow is not what the shot is built from - 376 turns of it changed
-- nothing - which is exactly what makes this safe: aiming the arrow at the
-- enemy the cone is holding cannot move your bullets, it can only show you
-- who has been picked. So while the cone is locked the beam swings onto the
-- target, and the moment it is not, the beam goes back to lying along the gun.
--
-- Runs on the game thread with everything else that moves a component.
-- THE ARROW IS LOOKED UP INSIDE THE JOB, FROM A GUN STILL KNOWN TO BE LIVE.
--
-- beam-paint and beam-aim used to carry the arrow component into the job and
-- touch it when the job ran. Between the two, a round can end and free it -
-- and InGameThread's generation check cannot help yet, because the loop only
-- notices the round ended a tick later. alive() still says yes for a
-- half-destroyed object and pcall cannot catch the native fault: that is the
-- 0x268 both crashes since the last install died on, with beam-paint named
-- as the job in flight each time.
--
-- gunClassOf is rebuilt by every fresh gun sweep, so "is this address still
-- in it" is the same question liveObj answers for enemies in esp-boxes.
AA.gun.beamStale = 0
local function liveArrow(gun, addr)
    if addr and gunClassOf[addr] == nil then
        AA.gun.beamStale = AA.gun.beamStale + 1
        return nil
    end
    if not stillAlive(gun) then return nil end
    local ok, arrow = pcall(function() return gun.FireDirection end)
    if not (ok and alive(arrow)) then return nil end
    return arrow
end

local function aimBeam(gun, arrow, tx, ty, tz)
    local addr = addrOf(gun)
    if not addr then return end
    -- NEVER BEND WHAT WE CANNOT UNBEND (2026-09-21).
    --
    -- "the beam is showing up not going straight like before."
    --
    -- Home is where this arrow sits when nothing is locked on, and it is read
    -- once, before the beam has moved anything. The old code wrote `false`
    -- when that read failed - and `false` is remembered exactly like a real
    -- answer, so the `== nil` test never tried again. From then on this gun
    -- could still be AIMED, but the going-home branch is `if home then`, so
    -- it was never straightened again: the beam stayed bent at whatever it
    -- last pointed at, for the rest of the round. One unlucky read, one
    -- permanently crooked beam.
    --
    -- Two changes. A failed read is not cached, so it is retried; and a gun
    -- whose home we do not know is not bent at all, because we would have no
    -- way to put it back.
    if beamHome[addr] == nil then
        local p, y, r = readRel(arrow)
        if p then beamHome[addr] = { p, y, r } end
    end
    if not beamHome[addr] then
        AA.gun.noHome = (AA.gun.noHome or 0) + 1
        return
    end

    -- DOING NOTHING WAS THE EXPENSIVE CASE (2026-09-20).
    --
    -- From the session that froze: `beam-aim:1968` out of 2247 game-thread
    -- jobs - and `beamaimed=0`. Not one of those 1968 aimed anything. The cone
    -- was never locked, so every single one took the "put it back" branch
    -- below and wrote a relative rotation onto the arrow of a gripped,
    -- SIMULATING actor that was already at exactly that rotation. Six times a
    -- second, for the whole round, for nothing.
    --
    -- That is the one thing this mod was doing to the engine in volume, on the
    -- kind of actor that has already thrown a gun across the room when it was
    -- pushed, and both bad endings named beam-aim. It does not get to be free
    -- any more: the beam remembers where it last pointed each gun and only
    -- speaks when that changes - with the same periodic re-assert the paint
    -- uses, because a new round recycles addresses and the arrow can be moved
    -- by something that is not us.
    local acls = gunClassOf[addr] or "?"
    local ap, ay = alignFor(acls)
    local key = tx and string.format("%.0f,%.0f,%.0f", tx * 0.1, ty * 0.1, tz * 0.1)
                    or string.format("home %.2f %.2f", ap, ay)
    local wasAim = beamAim[addr]
    if wasAim and wasAim.key == key and (beamSweep - wasAim.at) < BEAM_REASSERT then
        AA.gun.beamSkip = (AA.gun.beamSkip or 0) + 1
        return
    end
    beamAim[addr] = { key = key, at = beamSweep }

    -- the arrow is not carried in: see liveArrow
    PlayerMods.InGameThread("beam-aim", function()
        if PlayerMods.dormant then return end
        local arrow = liveArrow(gun, addr)
        if not arrow then return end
        if tx then
            local okL, loc = pcall(function() return arrow:K2_GetComponentLocation() end)
            local ax, ay, az = vec3(okL and loc or nil)
            if not ax then return end
            local dx, dy, dz = norm(tx - ax, ty - ay, tz - az)
            if dx == 0 and dy == 0 and dz == 0 then return end
            local p, y = dirToRot(dx, dy, dz)
            setWorldRot(arrow, p, y, 0.0)
            AA.gun.beamAimed = AA.gun.beamAimed + 1
        else
            local home = beamHome[addr]
            if home then
                -- LINING IT UP, PER GUN. Home is where this gun's own fire
                -- arrow sits - the right starting point, but not always along
                -- the barrel you can see. The nudge is this gun's saved one
                -- plus whatever the sliders are showing right now.
                setRelRot(arrow, home[1] + ap, home[2] + ay, home[3])
            end
        end
    end)
end

local function applyBeam(gun, arrow, want, ci, len, walls, size, dim, rgb, step)
    local addr = addrOf(gun)
    if not addr then return end
    local was = beamState[addr]
    -- step is in the key so an RGB beam actually repaints when its colour
    -- moves on - and, just as importantly, only then.
    local key = want and string.format("%d|%d|%s|%.1f|%s|%d", ci, math.floor(len),
                                       tostring(walls), size or 1.0,
                                       tostring(dim and true or false),
                                       step or 0) or "off"
    if was and was.key == key and (beamSweep - was.at) < BEAM_REASSERT then
        return
    end
    beamState[addr] = { key = key, at = beamSweep }

    local base = rgb or AA.BEAM_COLOURS[ci] or AA.BEAM_COLOURS[1]
    -- Nothing locked: the same colour, at about a third. It still shows you
    -- the line your shot takes, and it does not pretend to be a different
    -- setting than the one you chose.
    local mul = dim and 0.35 or 1.0
    local colour = { math.floor(base[1] * mul + 0.5),
                     math.floor(base[2] * mul + 0.5),
                     math.floor(base[3] * mul + 0.5) }
    -- the arrow is not carried in: see liveArrow
    arrow = nil
    PlayerMods.InGameThread("beam-paint", function()
        if PlayerMods.dormant then return end
        local arrow = liveArrow(gun, addr)
        if not arrow then return end
        AA.gun.beamCalls = AA.gun.beamCalls + 1
        if not want then
            pcall(function() arrow:SetHiddenInGame(true, false) end)
            return
        end
        pcall(function()
            local c = arrow.ArrowColor
            c.R, c.G, c.B, c.A = colour[1], colour[2], colour[3], 255
        end)
        -- AND THROUGH THE COMPONENT'S OWN SETTER.
        --
        -- ArrowColor is an FColor field; writing R/G/B into the struct the
        -- property read handed back is not guaranteed to land back in the
        -- component, and it never tells the renderer anything. Engine.hpp has
        -- UArrowComponent::SetArrowColor(FLinearColor) - the real API, which
        -- stores the colour AND marks the render state dirty so the proxy is
        -- rebuilt with it. FLinearColor is 0..1, not 0..255.
        pcall(function()
            arrow:SetArrowColor({ R = colour[1] / 255.0, G = colour[2] / 255.0,
                                  B = colour[3] / 255.0, A = 1.0 })
        end)
        pcall(function() arrow.ArrowLength = len end)
        pcall(function() arrow.ArrowSize = size end)
        pcall(function() arrow.bIsScreenSizeScaled = false end)
        pcall(function() arrow.DepthPriorityGroup = walls and 1 or 0 end)
        -- the proxy caches colour and depth group when it is built, so bounce
        -- it: exactly what the ESP box colour swap does
        pcall(function() arrow:SetHiddenInGame(true, false) end)
        pcall(function() arrow:SetHiddenInGame(false, false) end)
    end)
end

---------------------------------------------------------------------------
-- THE ACTIVE CONE
---------------------------------------------------------------------------
-- Runs from the loop a few times a second. It answers one question - is there
-- anyone in the cone right now - and paints the beam to match. It is what
-- makes the cone "active": you can see the lock before you pull the trigger,
-- instead of finding out afterwards.

function AA.ConeTick()
    local s = PlayerMods.state
    local beamWanted = (s.AimBeam == true) and aimOn(s)
    local coneWanted = (s.AimCone ~= false) and aimOn(s)
    beamSweep = beamSweep + 1
    if not (beamWanted or coneWanted) then
        if next(beamState) ~= nil then
            -- Only guns that are still in a hand. This used to walk every gun
            -- in the world to un-paint it, which is the same reach-for-a-dead-
            -- actor that crashed the 14:40 session - just on the way out
            -- rather than on the way in.
            for _, g in ipairs(sweepGuns()) do
                if isHeld(g, true) then
                    local okA, arrow = pcall(function() return g.FireDirection end)
                    if okA and alive(arrow) then applyBeam(g, arrow, false, 1, 0, false) end
                end
            end
            beamState = {}
            beamAim = {}
            AA.gun.beamOn = false
            AA.gun.beamGuns = 0
        end
        AA.cone.locked, AA.cone.src = false, "off"
        return
    end
    if PlayerMods.dormant then return end

    -- EVERY gun in your hands, not just the first one found.
    --
    -- The last version stopped at the first gun it saw, so with a pistol in
    -- each hand only one of them ever got a beam - "it only puts on one gun".
    -- The cone's axis is still a single line, and that is the gun nearest your
    -- hands; the beam is painted on all of them.
    local ox, oy, oz, fx, fy, fz, src = nil, nil, nil, nil, nil, nil, "none"
    local mine, bestD = {}, math.huge
    local nearCount, heldCount, noFlag, noHands = 0, 0, 0, 0
    local sweptGuns, atHandCount, inGripCount = 0, 0, 0
    for _, g in ipairs(sweepGuns()) do
        sweptGuns = sweptGuns + 1
        -- CHECKED BEFORE THE ARROW IS EVEN READ. The whole point is to touch
        -- nothing on a gun that is not yours, so the ownership test comes
        -- first and reads one boolean off the gun itself.
        -- NEAR FIRST, OWNERSHIP SECOND.
        --
        -- near= is counted for every gun beside you whether or not the game
        -- says you hold it, so "held=0 near=0" (nothing there) reads
        -- differently from "held=0 near=2" (a gun right in front of you the
        -- game does not call yours) - those want opposite fixes and used to
        -- look identical. The gun ACTOR's location is a cheap read and does
        -- not touch the arrow, so it is safe even on a gun we then refuse.
        --
        -- It also decides whether the attachment check is worth running.
        local okP, gloc = pcall(function() return g:K2_GetActorLocation() end)
        local gx, gy, gz = vec3(okP and gloc or nil)
        local isNear = gx ~= nil and nearMe(gx, gy, gz, 110.0)
        if isNear then nearCount = nearCount + 1 end

        -- IS IT IN YOUR HAND? This is the ownership test now. near= above is
        -- kept only as a diagnostic: it measures from the pawn's ROOT actor,
        -- which in room-scale VR is wherever the play space is pinned and can
        -- be metres from where you are standing. A session read near=0 with
        -- athand=4 - four guns at the hands that the old test called nobody's.
        local handD = nil
        if gx ~= nil then
            handD = handDistance(gx, gy, gz)
            if handD == nil then noHands = noHands + 1
            else
                if handD <= HAND_CM then atHandCount = atHandCount + 1 end
                if handD <= GRIP_CM then inGripCount = inGripCount + 1 end
            end
        end
        -- ...AND NOT ATTACHED TO YOU, WHICH IS WHAT A HOLSTER IS.
        --
        -- With your arms down your hand is AT your hip, so "near a hand"
        -- alone cannot tell the gun you are gripping from the one holstered
        -- on you. VRExpansion can: a GRIPPED gun is held by a physics
        -- constraint and is attached to nothing, while a holstered one hangs
        -- off your body. So the two together are unambiguous - at a hand, and
        -- hanging off nothing.
        local inGrip = (handD ~= nil and handD <= GRIP_CM) and not attachedToMe(g)

        local held, readable = isHeld(g, isNear)
        if not readable then noFlag = noFlag + 1 end
        if held then heldCount = heldCount + 1 end
        -- In your hand, OR the game says you hold it AND it is somewhere on
        -- your person. The flag is still worth something on a build that keeps
        -- it honestly; it is simply no longer the only way to be believed.
        -- The distance test stays on that path, because a gun lying across the
        -- room whose flag reads true is still not the one you are aiming.
        local ours = inGrip or (held and isNear)

        -- LET GO OF WHAT IS NO LONGER YOURS.
        --
        -- Nothing ever un-painted a gun that stopped being yours, so the first
        -- one the old test happened to accept kept its beam for the rest of
        -- the round - "mostly loads on the ak first". We are holding the gun
        -- right here, so this is the cheap place to take it back off.
        if not ours then
            local a = addrOf(g)
            if a and beamState[a] then
                local okD, darrow = pcall(function() return g.FireDirection end)
                if okD and alive(darrow) then
                    applyBeam(g, darrow, false, 1, 0, false)
                end
                beamState[a] = nil
                beamAim[a] = nil
                AA.gun.beamDropped = (AA.gun.beamDropped or 0) + 1
            end
        end

        local okA, arrow = nil, nil
        if ours then okA, arrow = pcall(function() return g.FireDirection end) end
        if ours and okA and alive(arrow) then
            local okL, loc = pcall(function() return arrow:K2_GetComponentLocation() end)
            local x, y, z = vec3(okL and loc or nil)
            if x then
                local p, yw = readRot(arrow)
                if p then
                    -- Ranked by how close it is to a HAND, so the gun you are
                    -- actually holding wins the cone rather than whichever one
                    -- the sweep happened to reach first.
                    local d = handDistance(x, y, z)
                    if d == nil then
                        local O = AA.origin
                        d = O and math.sqrt((x - O.x) ^ 2 + (y - O.y) ^ 2
                                            + (z - O.z) ^ 2) or 0
                    end
                    mine[#mine + 1] = { gun = g, arrow = arrow, d = d }
                    if d < bestD then
                        bestD = d
                        ox, oy, oz = x, y, z
                        fx, fy, fz = rotToDir(p, yw)
                        src = "gun"
                    end
                end
            end
        end
    end
    table.sort(mine, function(a, b) return (a.d or 0) < (b.d or 0) end)
    -- Published so "the beam stopped showing up" is answerable at a glance:
    -- held=0 near=0 with guns in the world means the ownership flag is not
    -- what we think it is, and noflag= says whether it could be read at all.
    -- swept= IS THE NUMBER THAT WAS MISSING. held=0 near=0 noflag=0 reads
    -- identically whether the sweep saw no guns at all or saw plenty and
    -- refused them, and those two want opposite fixes. It cost a session to
    -- not know which. nohands= says whether the controllers could be read.
    AA.gun.heldGuns, AA.gun.nearGuns, AA.gun.noFlag = heldCount, nearCount, noFlag
    AA.gun.sweptGuns, AA.gun.noHands = sweptGuns, noHands
    AA.gun.atHand = atHandCount
    AA.gun.inGrip = inGripCount

    if not ox and PlayerMods.AimEye then
        local e = PlayerMods.AimEye()
        if e then
            ox, oy, oz, fx, fy, fz, src = e.x, e.y, e.z, e.fx, e.fy, e.fz, "head"
        end
    end
    AA.cone.src = src
    if not ox then
        AA.cone.locked = false
        return
    end

    local target = AA.PickTarget(ox, oy, oz, fx, fy, fz, PlayerMods.espTargets,
                                 s, os.clock())
    AA.cone.inCone = AA.lastInCone or 0
    AA.cone.seen = AA.lastSeen or 0
    AA.cone.at = os.clock()
    if target then
        AA.cone.locked = true
        AA.cone.name = (ESP and ESP.NAMES and ESP.NAMES[target.cls]) or "ENEMY"
        AA.cone.part = target.part
        AA.cone.dist = target.dist
        AA.cone.ang = target.ang
        AA.coneAddr = target.addr
        AA.coneX, AA.coneY, AA.coneZ = target.x, target.y, target.z
    else
        AA.cone.locked = false
        AA.cone.name, AA.cone.part, AA.cone.dist, AA.cone.ang = nil, nil, nil, nil
        AA.coneAddr = nil
        AA.coneX, AA.coneY, AA.coneZ = nil, nil, nil
    end

    if beamWanted and #mine > 0 then
        -- THE COLOUR YOU PICKED, AND ONLY THE COLOUR YOU PICKED.
        --
        -- Two bugs met here and made the picker look dead. The menu's choice
        -- rows count from zero - Mark Color one page up converts with "+ 1"
        -- and this one did not - so GREEN and RED both came out GREEN and
        -- every name below them was off by one. Then, whenever the cone was
        -- not locked onto somebody, the whole thing was overwritten with
        -- white. Between them, picking a colour almost never changed what you
        -- saw.
        --
        -- The lock still shows, because it is worth seeing: the beam runs at
        -- full strength when it is holding someone and dimmed when it is not.
        -- Same colour either way, so the picker always does something.
        local ci = math.floor((s.AimBeamColor or 0) + 0.5) + 1
        if ci < 1 or ci > #AA.BEAM_COLOURS then ci = 1 end
        local rgbCol, rgbStep = nil, 0
        if s.AimBeamRGB == true and PlayerMods.RgbStep then
            rgbStep, rgbCol = PlayerMods.RgbStep()
        end
        local dim = not AA.cone.locked
        local len = (s.AimBeamLength or 20) * 100.0
        local size = s.AimBeamSize or 1.0
        if size < 0.1 then size = 0.1 end
        -- LASER SIGHT MODE. A real laser sight does one thing: it shows you
        -- where the barrel is pointing. So it never swings onto a target, it
        -- never dims, and it is thin. Everything else about the beam - your
        -- colour, RGB, the length, through-walls - still applies.
        local laser = (s.AimBeamLaser == true)
        if laser then
            dim = false
            if size > 0.35 then size = 0.35 end
        end
        -- two hands, two guns; anything past that is scenery
        local n = math.min(#mine, 2)
        for i = 1, n do
            local m = mine[i]
            applyBeam(m.gun, m.arrow, true, ci, len, s.AimBeamWalls ~= false,
                      size, dim, rgbCol, rgbStep)
            -- Tracking a target is the ONLY case that bends the beam off
            -- the barrel. Everything else - laser sight, tracking switched
            -- off, nothing locked - lays it straight, which is also where
            -- this gun's saved alignment is applied. It used to do nothing at
            -- all with tracking off, so the alignment was ignored exactly
            -- when it was most wanted.
            if (not laser) and s.AimBeamTrack ~= false
               and AA.cone.locked and AA.coneX then
                aimBeam(m.gun, m.arrow, AA.coneX, AA.coneY, AA.coneZ)
            else
                aimBeam(m.gun, m.arrow, nil)
            end
        end
        -- WHICH GUNS. "line it up for my loadout guns" cannot be answered
        -- without knowing which ones the beam is actually on. The class comes
        -- from the sweep below, which walks the classes one at a time anyway,
        -- so it is a table lookup rather than GetClass():GetFName():ToString()
        -- a few times a second - which this project already knows crashes
        -- these games.
        local seen = {}
        for i = 1, n do
            seen[#seen + 1] = gunClassOf[addrOf(mine[i].gun) or 0] or "?"
        end
        AA.gun.beamClasses = table.concat(seen, ",")
        -- the gun the sliders are lining up: the one nearest your hand
        AA.gun.alignCls = seen[1] or "?"
        AA.gun.alignGun = mine[1] and mine[1].gun or nil
        AA.gun.alignArrow = mine[1] and mine[1].arrow or nil
        AA.gun.beamOn = true
        AA.gun.beamGuns = n
    elseif beamWanted then
        -- THE BEAM IS ON AND YOUR HANDS ARE EMPTY.
        --
        -- This case had no branch at all, so beamguns= kept whatever it said
        -- when you last held something, and the beam's bookkeeping went on
        -- describing a gun that was no longer yours. Forget it - and forget it
        -- WITHOUT touching it: a gun that has just left your hand is exactly
        -- the object this whole section exists to stop us reaching for.
        --
        -- That does mean a gun you drop keeps its beam drawn until the game
        -- tidies the actor up. A stripe left on a gun on the floor is a fair
        -- price for never touching one that is being destroyed.
        if AA.gun.beamOn or next(beamState) ~= nil then
            beamState = {}
            beamAim = {}
            AA.gun.beamOn = false
            AA.gun.beamGuns = 0
        end
    elseif AA.gun.beamOn then
        -- Switched OFF while you are still holding it: here we may tidy up,
        -- because these are guns the sweep just handed back as yours.
        for _, m in ipairs(mine) do
            if alive(m.arrow) then applyBeam(m.gun, m.arrow, false, 1, 0, false) end
        end
        beamState = {}
        beamAim = {}
        AA.gun.beamOn = false
        AA.gun.beamGuns = 0
    end

    -- THE CONE, MADE VISIBLE.
    --
    -- A wireframe cone cannot be drawn: this game's debug drawing is compiled
    -- out, and spawning a component of our own has hard-crashed it before. So
    -- the cone shows itself the only way it can - by marking the enemy it is
    -- holding. player_mods paints that one's body box in the cone colour, so
    -- you can see the lock on the enemy himself, not just read about it.
    PlayerMods.coneTarget = AA.cone.locked and AA.coneAddr or nil
end

---------------------------------------------------------------------------
-- THE BULLET HOOK - now a witness, and a second layer
---------------------------------------------------------------------------

local shots = {}      -- [bullet address] = what we aimed it at, for the POST check

local function isMine(b, lx, ly, lz)
    local O = AA.origin
    if not O then return false end
    -- the pawn that fired it, when the gun sets one
    local okI, inst = pcall(function() return b.Instigator end)
    if okI and inst and alive(inst) then
        local a = addrOf(inst)
        if a and O.addr and a ~= O.addr then return false end
        if a and O.addr and a == O.addr then return true end
    end
    -- otherwise: fired from within reach of your body
    return nearMe(lx, ly, lz, 300.0)
end

-- Write an FVector property on the bullet. A plain table assignment silently
-- does nothing in UE4SS; writing the components of the live struct does, and
-- reading it back proves it.
local function writeVec(b, name, x, y, z)
    local ok = pcall(function()
        local v = b[name]
        v.X, v.Y, v.Z = x, y, z
    end)
    if not ok then return false end
    local okR, v = pcall(function() return b[name] end)
    local rx, ry, rz = vec3(okR and v or nil)
    return rx ~= nil and math.abs(rx - x) < 1 and math.abs(ry - y) < 1 and math.abs(rz - z) < 1
end

-- Same shape for an FRotator, and it reads the field back the same way: a
-- write that does not stick is worth knowing about, because this is exactly
-- the kind of field a pooled actor can reset under you.
local function writeRot(b, name, pitch, yaw, roll)
    local ok = pcall(function()
        local r = b[name]
        r.Pitch, r.Yaw, r.Roll = pitch, yaw, roll or 0.0
    end)
    if not ok then return false end
    local okR, r = pcall(function() return b[name] end)
    if not (okR and r and type(r.Yaw) == "number") then return false end
    return math.abs((r.Yaw - yaw + 540) % 360 - 180) < 1.0
       and math.abs((r.Pitch - pitch + 540) % 360 - 180) < 1.0
end

local function pre(self)
    AA.calls = AA.calls + 1
    local s = PlayerMods.state
    if not anyOn(s) then return end
    if PlayerMods.dormant then return end

    local okG, b = pcall(function() return self:get() end)
    b = (okG and b) or self

    local okL, loc = pcall(function() return b:K2_GetActorLocation() end)
    local lx, ly, lz = vec3(okL and loc or nil)
    if not lx then return end
    if not isMine(b, lx, ly, lz) then return end

    local okC, cls = pcall(function() return b:GetClass() end)
    local cAddr = okC and cls and addrOf(cls) or nil
    if cAddr and shrapnelAddr and cAddr == shrapnelAddr then return end
    local isBuckshot = cAddr and buckshotAddr and cAddr == buckshotAddr
    AA.mine = AA.mine + 1

    local keepSpread = isBuckshot and s.AimKeepShotgunSpread ~= false
    if s.NoSpread and not keepSpread then
        if pcall(function() b.ShotSpread = 0.0 end) then
            AA.spreadZeroed = AA.spreadZeroed + 1
        end
    end

    if not aimOn(s) then return end
    if isBuckshot and s.AimShotgun == false then return end

    -- Where the gun sent it: StartLocation -> EndLocation, the pair the bullet
    -- carries. Fall back to its rotation if they are unreadable.
    local okS, sv = pcall(function() return b.StartLocation end)
    local okE, ev = pcall(function() return b.EndLocation end)
    local sx, sy, sz = vec3(okS and sv or nil)
    local ex, ey, ez = vec3(okE and ev or nil)
    local ox, oy, oz, fx, fy, fz, len
    if sx and ex then
        fx, fy, fz, len = norm(ex - sx, ey - sy, ez - sz)
        ox, oy, oz = sx, sy, sz
    end
    if not len or len < 50 then
        local okR, r = pcall(function() return b:K2_GetActorRotation() end)
        if not (okR and r and type(r.Yaw) == "number") then return end
        fx, fy, fz = rotToDir(r.Pitch, r.Yaw)
        ox, oy, oz, len = lx, ly, lz, 20000.0
    end

    -- THE WITNESS. We turned the gun a moment ago; did the shot come out along
    -- the line we set? This is the proof that the gun aiming works, and it
    -- needs no POST hook - which is just as well, since the bullet's never
    -- fires (postcalls=0 across 314 shots).
    local g = AA.gun
    if g.dir and (os.clock() - g.dirAt) < 0.20 and len and len >= 50 then
        local off = angleDeg(fx, fy, fz, g.dir[1], g.dir[2], g.dir[3])
        if off <= 3.0 then
            g.follow = g.follow + 1
        else
            g.stray = g.stray + 1
            g.strayDeg = off
            -- TELLING THE TWO FAILURES APART.
            --
            -- If a stray bullet came out along where the gun was pointing
            -- BEFORE we turned it, then whatever we turned is not what the
            -- shot is built from. If it matches neither, something else moved
            -- it. `ignored=` counts the first case.
            if g.was then
                local back = angleDeg(fx, fy, fz, g.was[1], g.was[2], g.was[3])
                g.strayOrig = back
                if back <= 3.0 then g.ignored = g.ignored + 1 end
            end

            -- MAKE SURE IT HITS.
            --
            -- This shot was sent at someone and went somewhere else. Rather
            -- than let that be the end of it, the enemy it was meant for
            -- takes the hit - through the game's own damage call, applied by
            -- the next sweep that proves he is still alive, exactly like the
            -- fists do.
            --
            -- Decided PER SHOT, here, after the fact: a shot that DID follow
            -- the line is left completely alone, so you are never charged
            -- twice for a shot you had already lined up yourself, and the day
            -- the bend starts landing this quietly stops doing anything.
            --
            -- THIS is what makes Silent Aim work. Three goes at physically
            -- bending a shot have each been measured and each come up short;
            -- the game's own damage call has worked since the day the fists
            -- used it.
            if s.AimMakeItHit ~= false and not (s.AimForceDamage or s.AimOneShot)
               and g.tgtAddr and PlayerMods.QueueShotDamage then
                local amount = s.AimForceAmount or 100
                local hit = g.tgtX and { g.tgtX, g.tgtY, g.tgtZ } or nil
                if PlayerMods.QueueShotDamage(g.tgtAddr, g.tgtCls, amount, hit) then
                    g.madeHit = g.madeHit + 1
                else
                    g.madeMiss = (g.madeMiss or 0) + 1
                end
            end
        end
        g.dir = nil
        g.tgtAddr = nil
    end

    -- Second layer: rewrite the bullet's own numbers too. On its own this did
    -- nothing (2026-09-18: 253 verified writes, no effect), but it costs one
    -- struct write and it is free insurance if some weapon builds its shot the
    -- other way round.
    if s.AimBullet == false then return end

    -- Did the gun hook already deal with THIS shot? Not "is AimGun on" - a
    -- weapon whose fire call we never get to see would leave the bullet layer
    -- silently doing half a job: rewriting the numbers but never counting the
    -- shot, never naming the target, never applying extra damage.
    local gunHandled = (os.clock() - (AA.gun.aimedAt or -99)) < 0.20

    -- Hit Chance was already rolled at the gun for a shot it handled; rolling
    -- again here would put the same shot through the dice twice.
    if not gunHandled then
        local chance = s.AimHitChance or 100
        if chance < 100 and math.random(1, 100) > chance then
            AA.chanceSkipped = AA.chanceSkipped + 1
            return
        end
    end

    local target = AA.PickTarget(ox, oy, oz, fx, fy, fz, PlayerMods.espTargets, s, os.clock())
    if not target then
        AA.noTarget = AA.noTarget + 1
        return
    end

    local tx, ty, tz = norm(target.x - ox, target.y - oy, target.z - oz)
    local nx, ny, nz
    if s.SilentAim then
        nx, ny, nz = tx, ty, tz
    else
        nx, ny, nz = AA.Bend(fx, fy, fz, tx, ty, tz, (s.AimStrength or 100) / 100.0)
    end

    -- bUseForwardVector picks which of the two the bullet believes: its own
    -- rotation, or StartLocation -> EndLocation. Make it the pair we just
    -- wrote, and set the rotation to match anyway so both branches agree.
    pcall(function() b.bUseForwardVector = false end)

    -- far enough to pass straight through the body, and never shorter than the
    -- gun's own trace
    local reach = math.max(len, target.dist + 250.0)
    local okEnd = writeVec(b, "EndLocation", ox + nx * reach, oy + ny * reach, oz + nz * reach)
    if s.SilentAim and s.AimThroughWalls then
        -- start the trace just in front of them, so nothing in between counts
        local back = 70.0
        writeVec(b, "StartLocation", target.x - nx * back, target.y - ny * back, target.z - nz * back)
    end
    if not okEnd then AA.writeFail = AA.writeFail + 1 end

    if s.SilentAim and not keepSpread then
        if pcall(function() b.ShotSpread = 0.0 end) then
            AA.spreadZeroed = AA.spreadZeroed + 1
        end
    end
    local pitch, yaw = dirToRot(nx, ny, nz)
    pcall(function() b:K2_SetActorRotation({ Pitch = pitch, Yaw = yaw, Roll = 0.0 }, false) end)

    -- BEND THE SHOT, WHERE IT CAN ACTUALLY BE BENT.
    --
    -- This is what the switch does now that it no longer shoves the gun.
    -- BP_BulletBase carries its own FRotator MuzzleRotation, handed to it by
    -- the gun at spawn, and nothing this mod has ever done has written it -
    -- which fits every measurement: the shot ignored its actor rotation, it
    -- ignored StartLocation->EndLocation, and it partly followed the gun
    -- itself, because the gun is where that rotation comes from.
    --
    -- It is one struct write on a pooled bullet that has not been fired yet.
    -- Nothing is holding it, nothing is simulating it, and it is the same
    -- kind of write as the EndLocation one two lines up that has run for
    -- sessions without incident.
    if s.AimGun == true then
        if writeRot(b, "MuzzleRotation", pitch, yaw, 0.0) then
            AA.gun.muzzleOk = (AA.gun.muzzleOk or 0) + 1
            AA.gun.muzzleLastOk = true
        else
            AA.gun.muzzleFail = (AA.gun.muzzleFail or 0) + 1
            AA.gun.muzzleLastOk = false
        end
    end

    -- Only count and credit this shot here when the gun path did not already.
    if not gunHandled then
        AA.redirected = AA.redirected + 1
        AA.lastPart, AA.lastDist, AA.lastAddr, AA.lastAt = target.part, target.dist, target.addr, os.clock()
        AA.lastName = (ESP and ESP.NAMES and ESP.NAMES[target.cls]) or "ENEMY"
        if s.AimSticky then AA.stickyAddr = target.addr end
        if (s.AimForceDamage or s.AimOneShot) and target.addr and PlayerMods.QueueShotDamage then
            local amount = s.AimOneShot and 100000.0 or (s.AimForceAmount or 100)
            PlayerMods.QueueShotDamage(target.addr, target.cls, amount,
                target.x and { target.x, target.y, target.z } or nil)
            AA.forced = AA.forced + 1
        end
    end

    local a = addrOf(b)
    if a then
        shots[a] = { t = os.clock(), x = target.x, y = target.y, z = target.z,
                     addr = target.addr, cls = target.cls, part = target.part }
    end
end

-- Did it land? LocalLocation is where the bullet's trace hit. Near the point we
-- sent it at = the redirect worked. All of this is the bullet's own memory.
-- (It has never once been called in this build - see postcalls= - which is why
-- `follow=` above exists. Left in place: it costs nothing and it is free proof
-- the day it does fire.)
local function post(self)
    AA.postCalls = AA.postCalls + 1
    local okG, b = pcall(function() return self:get() end)
    b = (okG and b) or self
    local a = addrOf(b)
    local shot = a and shots[a]
    if not shot then return end
    shots[a] = nil

    local okH, hv = pcall(function() return b.LocalLocation end)
    local hx, hy, hz = vec3(okH and hv or nil)
    if not hx or (hx == 0 and hy == 0 and hz == 0) then
        AA.unknown = AA.unknown + 1
        return
    end
    local dx, dy, dz = hx - shot.x, hy - shot.y, hz - shot.z
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    AA.lastMissCm = d
    -- a body is ~60 cm across; the prediction can be a little behind a runner
    if d <= 90 then AA.confirmed = AA.confirmed + 1 else AA.missed = AA.missed + 1 end
end

-- Shots whose POST never came are counted and forgotten, so the table cannot
-- grow.
function AA.PendingTick()
    local now = os.clock()
    for a, shot in pairs(shots) do
        if now - shot.t > 0.5 then
            shots[a] = nil
            AA.noPost = AA.noPost + 1
        end
    end
    AA.GunRestoreTick()
    -- a sticky target that has left the scan is let go
    if AA.stickyAddr then
        local found = false
        for _, t in ipairs(PlayerMods.espTargets or {}) do
            if t.addr == AA.stickyAddr then found = true break end
        end
        if not found then AA.stickyAddr = nil end
    end
end

-- Bind lazily, and only once the player has asked for it. RegisterHook on a
-- class that is not loaded quietly binds nothing and pcall still reports
-- success, so require a real callback id before calling it bound.
-- The same conditions EnsureBound works through, as a question: is there
-- anything left for it to bind? (The loop asks; the game thread binds.)
function AA.BindPending()
    if not anyOn(PlayerMods.state) then return false end
    if not AA.bound then return true end
    return (not AA.gun.bound) or AA.gun.tries < (AA.gun.boundAt or 0) + 60
end

function AA.EnsureBound()
    local s = PlayerMods.state
    if not anyOn(s) then return end

    if not shrapnelAddr then
        local c = StaticFindObject(SHRAPNEL)
        if alive(c) then shrapnelAddr = addrOf(c) end
    end
    if not buckshotAddr then
        local c = StaticFindObject(BUCKSHOT)
        if alive(c) then buckshotAddr = addrOf(c) end
    end

    if not RegisterHook then return end

    if not AA.bound then
        local fnObj = StaticFindObject(EVENT)
        if alive(fnObj) then
            AA.bindTries = AA.bindTries + 1
            local okR, preId = pcall(function() return RegisterHook(EVENT, pre, post) end)
            if okR and type(preId) == "number" and preId > 0 then
                AA.bound = true
                print("[ModMenu] aim: bullet hook bound (witness + fallback)\n")
            end
        end
    end

    -- NEVER stop trying while nothing is bound: the gun blueprint loads
    -- lazily and you may not pick a gun up for several minutes. Once one fire
    -- function has taken, keep going for another ~30 s so a late sibling is
    -- still caught - PreFireFunction, the one named for "just before the
    -- shot", must not be skipped because FireGun happened to bind first - and
    -- then stop, so this is not a pcall every half second forever.
    if (not AA.gun.bound) or AA.gun.tries < (AA.gun.boundAt or 0) + 60 then
        AA.gun.tries = AA.gun.tries + 1
        local n = 0
        local function bind(fn, cb, post)
            for _, target in ipairs({ GUN_PATH .. ":" .. fn, GUN_CLASS .. ":" .. fn }) do
                if not gunBoundTargets[target] then
                    local okR, preId = pcall(function()
                        if post then return RegisterHook(target, cb, post) end
                        return RegisterHook(target, cb)
                    end)
                    if okR and type(preId) == "number" and preId > 0 then
                        gunBoundTargets[target] = true
                        n = n + 1
                    end
                end
            end
        end
        for _, fn in ipairs(GUN_FNS) do bind(fn, gunPre, gunPost) end
        for _, fn in ipairs(GUN_RESTORE_FNS) do bind(fn, gunRestoreHook) end
        if n > 0 and not AA.gun.bound then
            AA.gun.bound = true
            AA.gun.boundAt = AA.gun.tries
            print("[ModMenu] aim: GUN hook bound on " .. n ..
                  " fire functions - the gun itself is aimed now\n")
        end
    end
end

-- A new world recycles bullet, gun and enemy addresses; forget all of them.
function AA.OnWorldChange()
    -- the saved nudges belong to gun BLUEPRINTS, not to a world, so they
    -- survive a map change; only the per-address caches are dropped

    shots = {}
    pending = {}
    beamState = {}
    beamHome = {}
    beamAim = {}
    gunCache, gunCacheAt, gunCacheGen = nil, -99, -1
    AA.origin = nil
    AA.stickyAddr = nil
    AA.gun.dir = nil
    AA.gun.was = nil
    AA.gun.beamOn = false
    AA.gun.beamGuns = 0
    AA.cone.locked = false
    AA.coneAddr = nil
    if PlayerMods then PlayerMods.coneTarget = nil end
end

---------------------------------------------------------------------------
-- read-outs
---------------------------------------------------------------------------

function AA.PartName(i)
    return AA.PART_NAMES[math.floor((i or 0) + 0.5) + 1] or "?"
end

-- The line shown in the headset ESP and on the AIM tab.
function AA.TargetText()
    local s = PlayerMods.state
    if not aimOn(s) then return "aim off" end
    if not AA.lastAt or (os.clock() - AA.lastAt) > 3 then
        return "no target yet - fire at an enemy"
    end
    return string.format("%s  %s  %.1f m", AA.lastName or "ENEMY",
                         string.upper(AA.lastPart or "?"), (AA.lastDist or 0) / 100.0)
end

-- The LIVE cone read-out: what the cone is holding right now, before you fire.
-- The bar fills the closer the target is to the middle of the cone.
function AA.ConeText()
    local s = PlayerMods.state
    if not aimOn(s) then return "aim off" end
    if s.AimCone == false then return "cone off - shots still aim" end
    if (os.clock() - (AA.cone.at or -99)) > 2 then return "starting up..." end
    local fov = AA.ConeAngle(s)
    if not AA.cone.locked then
        if (AA.cone.seen or 0) == 0 then return "empty - no enemy in range" end
        return string.format("empty - %d in range, none in the %.0f deg cone",
                             AA.cone.seen or 0, fov)
    end
    local ang = AA.cone.ang or 0
    local fill = 1.0 - (fov > 0 and math.min(ang / fov, 1.0) or 0)
    local n = math.floor(fill * 10 + 0.5)
    local bar = string.rep("=", n) .. string.rep("-", 10 - n)
    return string.format("LOCKED [%s] %s %s %.1f m", bar, AA.cone.name or "ENEMY",
                         string.upper(AA.cone.part or "?"), (AA.cone.dist or 0) / 100.0)
end

function AA.BeamText()
    local s = PlayerMods.state
    if s.AimBeam ~= true then return "off" end
    if not aimOn(s) then return "needs Silent Aim on" end
    -- IF THE OWNERSHIP FLAG CANNOT BE READ, SAY SO.
    --
    -- The beam now only touches a gun the game says is in your hand. That is
    -- what stopped it reaching for a dead enemy's gun - but it also means a
    -- flag this build will not hand over would leave the beam silently dead
    -- with no explanation. noflag= counts guns whose grip state could not be
    -- read at all, so the difference between "no gun" and "cannot tell" is on
    -- the page instead of being something to guess at.
    if (AA.gun.noFlag or 0) > 0 and (AA.gun.heldGuns or 0) == 0 then
        return "cannot tell which gun is yours - tell me this"
    end
    if not AA.gun.beamOn then return "no gun in your hand" end
    -- Name the colour it is actually painting. The picker was off by one for
    -- a while and nothing on screen would have told you.
    local ci = math.floor((s.AimBeamColor or 0) + 0.5) + 1
    if ci < 1 or ci > #AA.BEAM_COLOURS then ci = 1 end
    return string.format("%s %s %.0fm x%.1f",
        AA.BEAM_COLOUR_NAMES[ci] or "?",
        AA.cone.locked and "LOCKED" or "dimmed - no target",
        (s.AimBeamLength or 20), s.AimBeamSize or 1.0)
end

-- Plain words for the AIM CONE page: is the gun actually being aimed, and
-- are the shots following it.
function AA.GunText()
    local s = PlayerMods.state
    local g = AA.gun
    -- FIRST, because it means none of the rest is running. A tally of shots
    -- made to hit is a comforting number to show while the feature is not
    -- working at all.
    if (g.noFlag or 0) > 0 and (g.heldGuns or 0) == 0 then
        return "cannot tell which gun is yours - tell me this"
    end
    -- Bending the shot is the experiment; making it hit is the mechanism. The
    -- read-out leads with whichever one is actually doing the work.
    if s.AimMakeItHit ~= false and (g.madeHit > 0 or (g.madeMiss or 0) > 0) then
        if (g.madeMiss or 0) > g.madeHit then
            return string.format("%d could not be applied - tell me this",
                                 g.madeMiss)
        end
        return string.format("%d shots made to hit", g.madeHit)
    end
    if not g.bound then return "waiting for a gun - fire once" end
    if g.aimed == 0 then
        if g.calls == 0 then return "ready - fire a shot" end
        if g.mine == 0 then return string.format("%d shots seen, none of them yours", g.calls) end
        if g.noArrow > 0 then return string.format("gun found, no fire arrow (%d)", g.noArrow) end
        return string.format("%d shots, no target in the cone", g.calls)
    end
    -- The bend writes the bullet's own muzzle rotation now. If that field
    -- refuses the write, say so plainly rather than reporting the shot count
    -- as though the bend were happening.
    if s.AimGun == true and g.muzzleLastOk == false then
        return string.format("the bullet will not take a new heading (%d tries)",
                             g.muzzleFail)
    end
    local judged = g.follow + g.stray
    if judged == 0 then
        return string.format("%d shots aimed", g.aimed)
    end
    if g.madeHit > 0 then
        return string.format("%d of %d shots made to hit", g.madeHit, judged)
    end
    if (g.madeMiss or 0) > 0 then
        return string.format("%d could not be applied - tell me this",
                             g.madeMiss)
    end
    return string.format("%d of %d shots went where they were sent",
                         g.follow, judged)
end

function AA.StatusText()
    local s = PlayerMods.state
    if not (AA.bound or AA.gun.bound) then
        return anyOn(s) and "waiting for a gun - fire once" or "off"
    end
    local g = AA.gun
    if g.aimed == 0 and AA.redirected == 0 then
        return string.format("ready - %d shots, no target in range", AA.mine + g.mine)
    end
    local judged = g.follow + g.stray
    if judged > 0 then
        return string.format("aimed %d, %d of %d went where they were sent",
                             AA.redirected, g.follow, judged)
    end
    return string.format("aimed %d shots", AA.redirected)
end

function AA.StatusLine()
    local s = PlayerMods.state
    return string.format(
        "bound=%s tries=%d calls=%d mine=%d aimed=%d notarget=%d chance=%d spread0=%d " ..
        "writefail=%d postcalls=%d hit=%d miss=%d unknown=%d nopost=%d extra=%d misscm=%s " ..
        "mode=%s part=%s",
        tostring(AA.bound), AA.bindTries, AA.calls, AA.mine, AA.redirected, AA.noTarget,
        AA.chanceSkipped, AA.spreadZeroed, AA.writeFail, AA.postCalls, AA.confirmed,
        AA.missed, AA.unknown, AA.noPost, AA.forced,
        AA.lastMissCm and string.format("%.0f", AA.lastMissCm) or "n/a",
        s.SilentAim and "silent" or (s.AimAssist and "assist" or "off"),
        AA.PartName(s.AimBone))
end

-- The one line that answers "does aiming the gun work". follow/stray is the
-- whole answer: follow counts bullets that came out along the line we set.
function AA.GunLine()
    local g = AA.gun
    return string.format(
        "bound=%s tries=%d calls=%d mine=%d aimed=%d reaimed=%d notarget=%d " ..
        "noarrow=%d setok=%d setfail=%d shape=%d relshape=%d norel=%d " ..
        "restored=%d late=%d worldback=%d restorefail=%d " ..
        "turned=%d muzzleok=%d muzzlefail=%d madehit=%d madefail=%d " ..
        "follow=%d stray=%d ignored=%d straydeg=%s strayorig=%s " ..
        "beam=%s beamguns=%d beamcalls=%d beamaimed=%d beamskip=%d " ..
        "held=%d near=%d noflag=%d notheld=%d byattach=%d " ..
        "swept=%d found=%d athand=%d ingrip=%d nohands=%d nohome=%d " ..
        "dropped=%d",
        tostring(g.bound), g.tries, g.calls, g.mine, g.aimed, g.reaimed,
        g.noTarget, g.noArrow, g.setOk, g.setFail, g.shape, g.relShape, g.noRel,
        g.restored, g.lateRestore, g.worldRestores, g.restoreFail,
        g.turned, g.muzzleOk or 0, g.muzzleFail or 0, g.madeHit, g.madeMiss or 0,
        g.follow, g.stray, g.ignored,
        g.strayDeg and string.format("%.1f", g.strayDeg) or "n/a",
        g.strayOrig and string.format("%.1f", g.strayOrig) or "n/a",
        tostring(g.beamOn), g.beamGuns, g.beamCalls, g.beamAimed, g.beamSkip or 0,
        g.heldGuns or 0, g.nearGuns or 0, g.noFlag or 0, g.notHeld or 0,
        g.byAttach or 0, g.sweptGuns or 0, g.foundGuns or 0,
        g.atHand or 0, g.inGrip or 0, g.noHands or 0, g.noHome or 0,
        g.beamDropped or 0)
end

function AA.ConeLine()
    local s = PlayerMods.state
    local c = AA.cone
    return string.format("on=%s fov=%.0f src=%s locked=%s incone=%d seen=%d " ..
                         "name=%s part=%s dist=%s",
        tostring(s.AimCone ~= false), AA.ConeAngle(s), c.src or "none",
        tostring(c.locked), c.inCone or 0, c.seen or 0,
        c.name or "-", c.part or "-",
        c.dist and string.format("%.0f", c.dist) or "n/a")
end

return AA
