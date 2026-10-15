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
-- IS THIS GUN IN YOUR HAND?
--
-- 20 September: the fire hooks below run on EVERY SkeletalGun_C shot in the
-- world - including an enemy's, a foot away, firing at you. So No Recoil and
-- Infinite Ammo have been quietly arming the people shooting at you: refilling
-- their magazines, chambering their next round, and zeroing their kick. That
-- is a gameplay bug on its own, and ZeroRecoil writes FVectors, which on a gun
-- the game is destroying is the 0x268 fault this file already documents.
--
-- ASkeletalGun_C derives from AGrippableSkeletalMeshActor, which carries
-- FBPInterfaceProperties VRGripInterfaceSettings; bIsHeld is true for exactly
-- as long as a hand has it. Enemies do not grip their weapons through
-- VRExpansion, so this is also the line between your gun and theirs.
-- Readable proof of the line above: how many shots were somebody else's, and
-- whether the grip flag could be read at all. If notyours climbs while yours
-- stays at zero, the test is wrong - not the guns.
-- "shotgun:120 ak:88" - which guns the per-shot hook ran for.
function PlayerMods.GunClassLine()
    local by = PlayerMods.gunByClass
    if not by or next(by) == nil then return "none" end
    local parts = {}
    for cls, n in pairs(by) do
        parts[#parts + 1] = string.format("%s:%d", tostring(cls), n)
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

function PlayerMods.GunWhoLine()
    return string.format("yours=%d notyours=%d noflag=%d byattach=%d",
        PlayerMods.gunYours or 0, PlayerMods.gunNotYours or 0,
        PlayerMods.gunNoFlag or 0, PlayerMods.gunByAttach or 0)
end

-- "the no recoil is not working & full auto is not working like it used to."
--
-- That was this function, and it was my mistake. Requiring the gun to be HELD
-- is the right test for the BEAM, which is about which gun you are aiming.
-- Arming is a different question. The weapon scan exists to get your guns
-- ready BEFORE you draw them, and a gun on your hip never reports held - so it
-- never got no-recoil and never had its fire mode set, and the first shot
-- after every draw kicked. Measured: recoilzeroed fell from 1619 in a session
-- to 118, with yours=118 against notyours=1382.
--
-- What arming needs to ask is "is this MINE", not "is it in my hand this
-- instant". A gun attached to you is yours whether held or holstered - and
-- either way an enemy dying cannot take it away, which is the entire reason
-- this test exists.
local function attachedToPawn(gun)
    local okP, parent = pcall(function() return gun:GetAttachParentActor() end)
    if not (okP and parent) then return false end
    local okV, valid = pcall(function() return parent:IsValid() end)
    if not (okV and valid) then return false end
    local pawn = PlayerMods.GetPawn()
    if not pawn then return false end
    local okA, a = pcall(function() return parent:GetAddress() end)
    local okB, b = pcall(function() return pawn:GetAddress() end)
    return okA and okB and a == b
end

function PlayerMods.IsGunHeld(gun)
    local ok, v = pcall(function() return gun.VRGripInterfaceSettings.bIsHeld end)
    if ok and type(v) == "boolean" then
        if v then return true, true end
        if attachedToPawn(gun) then
            PlayerMods.gunByAttach = (PlayerMods.gunByAttach or 0) + 1
            return true, true
        end
        return false, true
    end
    -- Unreadable: fail OPEN here rather than closed. These are the features
    -- that have always worked, and silently disabling somebody's infinite ammo
    -- is worse than the old behaviour. gunwho= in status.txt counts it.
    PlayerMods.gunNoFlag = (PlayerMods.gunNoFlag or 0) + 1
    return true, false
end

local GUN_PHYS    = "BP_PhysicalMagazineFirearm_C"
local MAG_SKEL    = "BP_SkeletalMag_C"
local MAG_STD     = "BP_Magazine_C"

---------------------------------------------------------------------------
-- WHAT WE WERE ABOUT TO TOUCH (2026-09-19)
---------------------------------------------------------------------------
-- The game deadlocked: all 173 threads Waiting, the world still loaded, no
-- crash file, nothing in the log - and status.txt had stopped, so there was
-- no record of what the mod had last asked the engine to do.
--
-- Everything this mod does to the engine goes through one door now. It names
-- the job, writes that name to lastop.txt BEFORE handing it over, and counts
-- what goes in against what comes back. After a freeze:
--
--   lastop.txt  - the job that was in flight when everything stopped
--   gamethread= in status.txt - queued vs ran. If queued keeps climbing and
--                 ran does not, the game thread has stopped taking our work,
--                 which is a very different thing from the mod being wrong.
--
-- AND WHICH WORLD IT WAS FOR (2026-09-20)
--
-- It answered its first question. The game crashed changing map late in a
-- round - EXCEPTION_ACCESS_VIOLATION reading 0x268, GameThread, UE4SS in the
-- stack - and lastop.txt said: beam-aim. queued=2250 ran=2250, so the game
-- thread was healthy; it took every job we sent it, including the one that
-- killed it.
--
-- 0x268 is the fault this file already documents under "A ROUND ENDING IS NOT
-- A WORLD CHANGE": a struct copy off an actor whose guts are gone. beam-aim
-- does two of them - K2_GetComponentLocation reads an FVector, the turn
-- writes an FRotator - on a gun's arrow picked up on the loop thread and
-- touched later on the game thread. It was 1968 of that session's 2247 jobs:
-- far and away the likeliest thing to be in flight when a map changes.
--
-- The enemy code has had the rule for months: never touch an actor the
-- CURRENT sweep did not hand back. Handing work to another thread breaks that
-- rule by construction, because "current" expires while the job waits. So the
-- door now stamps every job with the world it was queued for and refuses to
-- run one whose world has since gone. That covers beam-aim, beam-paint,
-- esp-boxes, gun-restore and shot-damage in one place - which is the whole
-- point of having a door.
PlayerMods.gt = { queued = 0, ran = 0, op = "none", ops = {}, dropped = 0, bounced = 0 }

-- Bumped whenever the world changes or a round ends. DropCaches() is already
-- called at both, and both destroy every actor a queued job could be holding.
PlayerMods.gen = 1

local lastOpWritten = nil

-- WHICH JOB WAS RUNNING, NOT WHICH WAS SENT (2026-09-21).
--
-- lastop.txt was written when a job was HANDED OVER, so after a crash it
-- named whatever was queued last - not the one the game thread was actually
-- inside when it died. Those are usually different, and the crash is in the
-- second one. MarkRunning is called from inside the job; it still only writes
-- when the name changes, so a run of identical jobs costs one write.
function PlayerMods.MarkRunning(name)
    if PlayerMods.gt.running == name then return end
    PlayerMods.gt.running = name
    PlayerMods.MarkOp(name)
end

function PlayerMods.MarkOp(name)
    PlayerMods.gt.op = name
    if name == lastOpWritten then return end
    lastOpWritten = name
    pcall(function()
        local path = (PlayerMods.DIR or "") .. "lastop.txt"
        local f = io.open(path, "w")
        if f then
            -- ...and what the game thread is RUNNING: after a freeze, the
            -- job last sent and the job stuck are usually not the same one
            f:write(string.format("%s\nqueued=%d ran=%d running=%s\n", tostring(name),
                                  PlayerMods.gt.queued, PlayerMods.gt.ran,
                                  tostring(PlayerMods.gt.running or "none")))
            f:close()
        end
    end)
end

-- The one door. `op` is a short name that ends up in lastop.txt.
--
-- The generation is read HERE, on the loop thread, at the moment the job is
-- made - not inside the job, where it would always agree with itself. When
-- the world goes, the job that was already in flight finds the number moved
-- and does nothing at all.
-- NO JOB EVER RUNS ON THE LOOP THREAD (2026-10-07).
--
-- UE4SS runs its ExecuteInGameThread queue inside its ProcessEvent hook - on
-- WHATEVER thread calls ProcessEvent. Every engine function the loop calls
-- (K2_GetActorLocation, anything) is such a call. The freeze of 7 October,
-- caught in a full dump: Grab Enemies asked a hand where it was, UE4SS ran
-- the queued shot-damage job right there on the loop thread, the damage made
-- the NPC's blueprint build objects, that wanted the physics scene lock - held
-- by the game thread, which was waiting in the same hook for the lock the
-- loop thread held. Neither could move again.
--
-- So while the loop is running (main.lua sets loopBodyActive), jobs are only
-- COLLECTED; they are handed to UE4SS the moment it finishes, when the loop is
-- asleep and only the game thread can pick them up. And a job that still
-- finds itself running while the loop is busy - one left over from a slow
-- frame, picked up by one of the loop's engine calls - does nothing and goes
-- back in the box for the next send.
PlayerMods.outbox = {}
PlayerMods.loopBodyActive = false

-- THE GAME THREAD COMES TO FETCH THE WORK (2026-10-11).
--
-- Two crashes of 11 October (05:44 and 05:56) died inside UE4SS itself, at
-- UE4SS.dll+0x87e772 in process_lua_function - the door every call from Lua
-- into the game goes through. It looks the calling Lua state up in a table
-- UE4SS keeps of every Lua state it has ever made, and it found one bucket
-- null and another garbage: the table was being rebuilt under it. That table
-- only GROWS - nothing in UE4SS.dll ever removes from it - and every
-- ExecuteInGameThread call adds one entry. The mod made one call per job,
-- about twenty a second, from the loop thread, which runs its Lua outside
-- UE4SS's lock (the lock's owner in the 04:34 freeze dump proves it). Each
-- time the table outgrew its buckets it rebuilt them, and a lookup on any
-- other thread at that moment read freed memory. And the 05:44 job was not
-- even on the game thread: UE4SS drains its queue inside ProcessEvent, on any
-- thread - and the animation graph calls ProcessEvent from worker threads
-- (TaskGraphThreadHP 14 ran our job).
--
-- So nothing is handed to UE4SS any more. The loop drops each tick's jobs in
-- a ring, and the game thread takes them from the player pawn's own
-- ReceiveTick: one hook, bound once, firing every frame on the game thread
-- and on no other. No Lua state made per job, nothing left in UE4SS's queue
-- for a worker thread to find.
--
-- The ring's slots are made up front and each counter has one writer - ringW
-- the loop (the only one that publishes), ringR the pump - so the two threads
-- never grow or shrink the same table.
--
-- While the pump is not running (no pawn yet, a map loading, the hook not yet
-- bound) one ExecuteInGameThread per tick - not one per job - asks the game
-- thread to run the same pump.
do -- (its own scope: the file is at Lua's 200-local limit)
local RING = 64
PlayerMods.ring = {}
for i = 1, RING do PlayerMods.ring[i] = false end
PlayerMods.ringW, PlayerMods.ringR = 0, 0
-- jobs made ON the game thread (a hook, a job, start-up): only the game
-- thread touches this table
PlayerMods.gtJobs = {}
PlayerMods.gtJobsN = 0
-- the pump's heartbeat (written by the pump, read by the loop)
PlayerMods.pumpRuns = 0
PlayerMods.pumpSeen = -1
PlayerMods.pumpQuiet = 99
PlayerMods.loopCo = nil

-- Is this the LOOP's own Lua thread? Every UE4SS entry point - the loop, each
-- hook, each queued call - runs in a Lua thread of its own, so this is exact,
-- where loopBodyActive only says "the loop is busy somewhere right now".
function PlayerMods.OnLoop()
    local co = coroutine.running()
    return co ~= nil and co == PlayerMods.loopCo
end

-- what each kind of job costs the game thread, in ms (os.clock), per window
PlayerMods.jobMs = {}
local function runJob(j, world)
    PlayerMods.gt.ran = PlayerMods.gt.ran + 1
    -- the world this job was for is gone; everything it is holding is a
    -- corpse pointer now, and IsValid() would not tell us so
    if j[3] ~= PlayerMods.gen then
        PlayerMods.gt.dropped = PlayerMods.gt.dropped + 1
        return
    end
    -- ...and the game thread can see that for itself: the level its own
    -- player is ticking in is not the one the job was made for. (After a load
    -- the pump runs before the loop has looked, so the generation alone would
    -- let the old level's jobs through.)
    if world and j[4] and j[4] ~= world then
        PlayerMods.gt.dropped = PlayerMods.gt.dropped + 1
        return
    end
    -- named BEFORE the work, so a crash inside it leaves its name behind
    PlayerMods.MarkRunning(j[1])
    -- one job failing must not stop the ones queued behind it
    local t0 = os.clock()
    local ok, err = pcall(j[2])
    PlayerMods.jobMs[j[1]] = (PlayerMods.jobMs[j[1]] or 0) + (os.clock() - t0) * 1000
    if not ok then PlayerMods.jobErr = tostring(err) end
end

-- ON THE GAME THREAD: everything handed over, in the order it was made.
--
-- A FRAME'S WORTH AT A TIME (2026-10-15, "the lagging in rounds"). A loop
-- tick's whole batch used to run in the one frame the pump met it - ESP
-- bones and boxes, the beam, the gun - ten times a second. With a budget
-- (seconds) the pump stops when it is spent and carries the rest to the next
-- frame, in order; every job still checks its world when it finally runs.
-- (A queued call without the pump passes none: it comes round too rarely.)
PlayerMods.carry, PlayerMods.carryAt = nil, 1
function PlayerMods.RunPending(world, budget)
    if PlayerMods.pumping then return 0 end
    PlayerMods.pumping = true
    local n = 0
    local t0 = os.clock()
    local function spent() return budget and (os.clock() - t0) > budget end
    -- runs list[from..]; returns where to pick up again if the budget ran out
    local function runFrom(list, from)
        for k = from, #list do
            runJob(list[k], world)
            n = n + 1
            if k < #list and spent() then return k + 1 end
        end
        return nil
    end
    if PlayerMods.carry then
        local at = runFrom(PlayerMods.carry, PlayerMods.carryAt)
        if at then
            PlayerMods.carryAt = at
            PlayerMods.pumping = false
            return n
        end
        PlayerMods.carry = nil
    end
    local r, w = PlayerMods.ringR, PlayerMods.ringW
    while r < w do
        if spent() then break end
        local i = r % RING + 1
        local batch = PlayerMods.ring[i]
        PlayerMods.ring[i] = false
        r = r + 1
        PlayerMods.ringR = r
        if batch then
            local at = runFrom(batch, 1)
            if at then
                PlayerMods.carry, PlayerMods.carryAt = batch, at
                PlayerMods.pumping = false
                return n
            end
        end
    end
    -- ...and the ones made on this thread, including any these jobs made
    local rounds = 0
    while #PlayerMods.gtJobs > 0 and rounds < 8 do
        local list = PlayerMods.gtJobs
        PlayerMods.gtJobs = {}
        PlayerMods.gtJobsN = 0
        for _, j in ipairs(list) do
            runJob(j, world)
            n = n + 1
        end
        rounds = rounds + 1
    end
    PlayerMods.pumping = false
    return n
end

-- The pawn's tick, every frame, on the game thread.
--
-- BACK FROM A PAUSE FIRST (2026-10-11 07:07). After a stall - a load, a round
-- change - or on a new body, or while the loop is waiting for it, the first
-- thing done is to ask the engine about everything the loop remembers and
-- mark what it has freed. Only then does the count move that lets the loop go
-- on. The level the player is ticking in is noted too, so a job made for the
-- level before does not run in this one.
PlayerMods.checkRuns = 0
PlayerMods.holdTicks = 0
-- the most the mod's own jobs may take of one frame (s); VR has ~11 ms
PlayerMods.PUMP_BUDGET = 0.0015
PlayerMods.pumpWin = { at = os.clock(), n = 0, sum = 0, max = 0, slow = 0 }
PlayerMods.pumpStats = "measuring..."
function PlayerMods.Pump(pawn)
    PlayerMods.inPump = true
    local now = os.clock()
    local a = nil
    if pawn then
        local okA, v = pcall(function() return pawn:GetAddress() end)
        if okA then a = v end
        local okW, wa = pcall(function()
            local w = pawn:GetWorld()
            return w and w:GetAddress() or nil
        end)
        PlayerMods.pumpWorld = okW and wa or nil
    end
    if PlayerMods.holdTicks > 0 or a ~= PlayerMods.pumpPawn
       or (PlayerMods.pumpAt and now - PlayerMods.pumpAt > 0.05) then
        PlayerMods.pumpPawn = a
        if PlayerMods.CheckRemembered then pcall(PlayerMods.CheckRemembered) end
    end
    PlayerMods.pumpAt = now
    PlayerMods.pumpRuns = PlayerMods.pumpRuns + 1
    pcall(PlayerMods.RunPending, PlayerMods.pumpWorld, PlayerMods.PUMP_BUDGET)
    -- what the mod costs the game thread, a window at a time
    local ms = (os.clock() - now) * 1000
    local wdw = PlayerMods.pumpWin
    wdw.n, wdw.sum = wdw.n + 1, wdw.sum + ms
    if ms > wdw.max then wdw.max = ms end
    if ms >= 4 then wdw.slow = wdw.slow + 1 end
    if now - wdw.at >= 10 then
        local top, best = "-", 0
        for op, v in pairs(PlayerMods.jobMs) do
            if v > best then top, best = op, v end
        end
        PlayerMods.pumpStats = string.format("avg=%.2fms max=%.0fms slow=%d top=%s:%.0fms",
            wdw.sum / math.max(1, wdw.n), wdw.max, wdw.slow, top, best)
        PlayerMods.pumpWin = { at = now, n = 0, sum = 0, max = 0, slow = 0 }
        PlayerMods.jobMs = {}
    end
    PlayerMods.inPump = false
end

-- THE LOOP WAITS WHILE THE GAME THREAD IS STALLED (2026-10-11 07:07).
--
-- The crash: the loop's aim cone asked IsValid() of a gun it had listed a
-- moment before, and the game had freed it - a round change, when the game
-- destroys the old level and collects it straight away. During a load the
-- game thread is not ticking the player, so the pump is not running; the loop
-- went on touching what it remembered all the way through.
--
-- So, at the top of each tick: if the player has not ticked since the last
-- one, the loop does nothing at all. When the player ticks again, the pump
-- has already re-checked everything remembered (above), and the loop goes on.
-- Five seconds with no player at all - a menu with no body, a lost hook - and
-- one queued call has the game thread re-check, after which the loop runs
-- without the pump.
PlayerMods.holds = 0
local holdRunsSeen, holdFrom, holdFree = -1, 0, false
function PlayerMods.HoldLoop()
    local runs = PlayerMods.pumpRuns
    local moved = runs ~= holdRunsSeen
    holdRunsSeen = runs
    -- never run yet: there is nothing to wait for (start-up binds it)
    if runs == 0 then return false end
    if moved then
        holdFree = false
        if PlayerMods.holdTicks == 0 then return false end
        -- back - once the game thread has re-checked what the loop remembers
        if PlayerMods.checkRuns ~= holdFrom then
            PlayerMods.holdTicks = 0
            return false
        end
        PlayerMods.holdTicks = PlayerMods.holdTicks + 1
        return true
    end
    if holdFree then return false end
    if PlayerMods.holdTicks == 0 then
        holdFrom = PlayerMods.checkRuns
        PlayerMods.holds = PlayerMods.holds + 1
    end
    PlayerMods.holdTicks = PlayerMods.holdTicks + 1
    if PlayerMods.holdTicks >= 50 then
        if PlayerMods.checkRuns ~= holdFrom then
            PlayerMods.holdTicks = 0
            holdFree = true
            return false
        end
        if PlayerMods.holdTicks % 10 == 0 then PlayerMods.Kick(true) end
    end
    return true
end

-- No pump: ONE queued call for the whole backlog. (checkOnly: just the
-- re-check of what the loop remembers, which the loop waits on after a stall.)
function PlayerMods.Kick(checkOnly)
    PlayerMods.gt.kicks = (PlayerMods.gt.kicks or 0) + 1
    ExecuteInGameThread(function()
        -- picked up by one of the loop's own engine calls (UE4SS drains its
        -- queue on whatever thread calls ProcessEvent): not here. The work is
        -- still in the ring, and the next tick asks again.
        if PlayerMods.loopBodyActive then
            PlayerMods.gt.bounced = PlayerMods.gt.bounced + 1
            return
        end
        if checkOnly then
            if PlayerMods.CheckRemembered then pcall(PlayerMods.CheckRemembered) end
            return
        end
        -- (no level check: without the pump nothing here knows the level)
        PlayerMods.RunPending(nil)
    end)
end

-- Is the pump running? Its count moved since the last tick.
local function watchPump()
    local runs = PlayerMods.pumpRuns
    if runs ~= PlayerMods.pumpSeen then
        PlayerMods.pumpSeen = runs
        PlayerMods.pumpQuiet = 0
    else
        PlayerMods.pumpQuiet = PlayerMods.pumpQuiet + 1
    end
end

function PlayerMods.PumpAlive()
    return PlayerMods.pumpQuiet < 3
end

-- ON THE LOOP THREAD, after each tick: this tick's jobs go into the ring.
function PlayerMods.SendOutbox()
    local box = PlayerMods.outbox
    if #box > 0 then
        if PlayerMods.ringW - PlayerMods.ringR < RING then
            PlayerMods.outbox = {}
            local w = PlayerMods.ringW + 1
            PlayerMods.ring[(w - 1) % RING + 1] = box
            PlayerMods.ringW = w
        elseif #box > 4000 then
            -- nothing taken for RING ticks: keep collecting, but not forever
            local keep = {}
            for i = #box - 1999, #box do keep[#keep + 1] = box[i] end
            PlayerMods.gt.overflow = (PlayerMods.gt.overflow or 0) + (#box - #keep)
            PlayerMods.outbox = keep
        end
    end
    watchPump()
    -- No pump: one queued call for the whole backlog, and at most one every
    -- half second - each is a Lua state UE4SS keeps for good, and a map load
    -- or a menu with no pawn can last minutes.
    if not PlayerMods.PumpAlive()
       and (PlayerMods.ringW > PlayerMods.ringR or PlayerMods.gtJobsN > 0) then
        local t = PlayerMods.tickStamp or 0
        if not PlayerMods.kickAt or t - PlayerMods.kickAt >= 5 then
            PlayerMods.kickAt = t
            PlayerMods.Kick()
        end
    end
end

function PlayerMods.InGameThread(op, fn)
    PlayerMods.MarkOp(op)
    PlayerMods.gt.queued = PlayerMods.gt.queued + 1
    -- per job, so "which kinds of work are we sending over" survives the next
    -- job overwriting the name
    PlayerMods.gt.ops[op] = (PlayerMods.gt.ops[op] or 0) + 1
    -- the generation is read HERE, when the job is made
    local j = { op, fn, PlayerMods.gen, PlayerMods.worldAddr }
    if PlayerMods.OnLoop() then
        local box = PlayerMods.outbox
        box[#box + 1] = j
    else
        -- made on the game thread - a hook, a job, start-up: the pump takes
        -- it. (Never into the loop's outbox: a hook firing while the loop is
        -- mid-tick would be adding to a table the loop is using.)
        local l = PlayerMods.gtJobs
        l[#l + 1] = j
        PlayerMods.gtJobsN = PlayerMods.gtJobsN + 1
    end
end
end

-- The world changed, or a round ended. Every job still in flight was built for
-- the world that has just gone, so none of them may run.
function PlayerMods.NewGeneration()
    PlayerMods.gen = PlayerMods.gen + 1
    -- the gun you were holding belongs to the world that has just gone
    PlayerMods.heldGun = nil
    PlayerMods.yourGuns = {}
end

function PlayerMods.GameThreadLine()
    local g = PlayerMods.gt
    local jobs = {}
    for name, n in pairs(g.ops or {}) do jobs[#jobs + 1] = name .. ":" .. n end
    table.sort(jobs)
    return string.format(
        "queued=%d ran=%d behind=%d dropped=%d bounced=%d gen=%d pump=%s lastop=%s jobs=%s",
        -- behind: handed to the game thread and not yet run. This tick's own
        -- jobs, still in the box until the loop finishes, are not "behind".
        g.queued, g.ran, g.queued - g.ran - #(PlayerMods.outbox or {}), g.dropped or 0,
        g.bounced or 0, PlayerMods.gen, PlayerMods.PumpAlive() and "on" or "OFF",
        g.op or "none", #jobs > 0 and table.concat(jobs, ",") or "none")
end

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
    -- Keep the game's own self-lit text material, so the menu reads the same
    -- in a pitch-black basement as in the open and no brightness, gamma or
    -- optimizer setting can dim it. It draws over your hands, because a
    -- material that has opted out of the depth test cannot be talked back
    -- into it - and being able to read the menu matters more than that.
    PanelGlow          = true,
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
    -- 0, READ OUT OF THE PAK, NOT GUESSED. bp_Skel_ak - the gun that
    -- already runs while you hold the trigger - ships with
    -- Firingmode = Enum_FireStates::NewEnumerator0, and the shotgun with
    -- NewEnumerator5 (= 3). This defaulted to 3, so Full Auto was writing
    -- the shotgun's own non-automatic mode back over itself.
    FireModeIndex      = 0,      -- the value the ak uses: automatic
    FireRateValue      = 0.06,   -- seconds between shots; lower is faster
    -- the MOD fires while you hold the trigger, one bullet every this many
    -- seconds - 0.10 fastest, 0.50 slowest (clamped in AutoFireGap)
    AutoFireOn         = true,
    AutoFireGap        = 0.25,
    -- the gun that ships automatic (the AK): how fast its automatic runs,
    -- 1.0 being its own speed
    AkSpeed            = 1.0,
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

    -- ESP tab (esp_plus.lua). The text options default ON so switching the
    -- ESP on shows everything; the 3D layer is experimental and defaults OFF.
    ESPNames           = true,
    ESPHealth          = true,
    ESPDistance        = true,
    ESPDirection       = true,
    ESPHeight          = true,
    ESPRadar           = true,
    ESPMaxRange        = 100,     -- metres
    ESPMaxRows         = 6,
    -- Body boxes: each enemy's own capsule, coloured and un-hidden, so the
    -- engine draws it on them and moves it with them (see "ESP BODY BOXES").
    -- The September DrawDebug boxes are gone: debug drawing is compiled out of
    -- this Shipping build and could never have shown.
    ESPBoxes           = false,
    ESPHitboxes        = false,   -- human NPCs' hit zones (head, neck, heart...)
    ESPBoxColor        = 0,       -- 0 by type, 1 red .. 8 orange
    ESPRgb             = false,   -- ...or cycle the whole rainbow
    -- SEE THEM THROUGH WALLS IS GONE, AND SO IS THE GLOW.
    --
    -- ESPBoxWalls asked the box to draw in the foreground depth group; the
    -- engine's own wireframe never reads that, so it was a no-op that cost
    -- 12,951 native writes a session. ESPGlow replaced the enemy's MATERIALS
    -- with the game's no-depth HUD material - and the first session it ever
    -- actually worked, the game deadlocked while shooting one of the three
    -- enemies wearing it.
    --
    -- Swapping materials on a live skinned mesh makes the RENDER thread
    -- rebuild that mesh's proxies, and this game does heavy per-mesh work of
    -- its own the moment you shoot someone (gore, dismemberment). Two things
    -- rebuilding the same mesh is the shape of what we saw: every thread
    -- waiting, world still loaded, nothing spinning.
    --
    -- Nothing else this mod does touches materials. It is not worth a frozen
    -- game for a box you can see through a wall, so it is out.

    -- AIM tab (aim_assist.lua). Both modes rewrite the bullet's own
    -- Start/EndLocation, which is what it actually traces along.
    SilentAim          = false,   -- every shot goes to the target
    SilentFov          = 90,      -- degrees either side; 180+ = all around
    AimBone            = 0,       -- 0 head 1 neck 2 chest 3 stomach 4 pelvis
                                  -- 5 arms 6 legs 7 nearest part 8 random
    AimPriority        = 0,       -- 0 closest to aim 1 closest to me
                                  -- 2 lowest health 3 highest health
    AimThroughWalls    = false,   -- start the trace just in front of them
    AimSticky          = false,   -- stay on one target until it is gone
    AimHitChance       = 100,     -- percent of shots aimed (humaniser)
    AimShowTarget      = true,    -- target line in the headset ESP
    AimForceDamage     = false,   -- extra damage on every aimed shot
    AimForceAmount     = 100,
    AimOneShot         = false,   -- aimed shots kill
    AimAssist          = false,   -- only nudge shots that were already close
    AimFov             = 15,      -- degrees either side of where you point
    AimStrength        = 100,     -- percent of the way to the target
    AimRange           = 60,      -- metres
    AimShotgun         = true,    -- shotgun pellets follow too
    NoSpread           = false,   -- Perfect Accuracy: bullets ignore spread
    AimKeepShotgunSpread = true,  -- ...but let a shotgun still spread
    -- WHICH END OF THE SHOT IS AIMED.
    -- AimGun turns the gun's own FireDirection arrow just before it
    -- builds the shot, so the GAME aims: its trace, its hit, its
    -- headshot. AimBullet is the old bullet-level rewrite, kept as a
    -- free second layer. See the header of aim_assist.lua.
    -- BENDING THE SHOT IS AN EXPERIMENT, NOT THE MECHANISM.
    --
    -- Turning the gun does move a shot (proven: ignored went 275 -> 0), but
    -- only part of the way (follow=9 stray=93), and it means shoving a
    -- rotation under VRExpansion's grip on a simulating physics actor over a
    -- hundred times a minute. The session that did it stopped dead after four
    -- minutes with no crash file at all. Off unless you want to try it.
    AimGun             = false,
    AimBullet          = true,
    -- The active cone: what it is holding right now, before you fire.
    AimCone            = true,
    AimBeam            = true,    -- draw the line out of the muzzle
    AimBeamColor       = 0,       -- 0/1 green, 2 red .. 8 orange
    AimBeamRGB         = false,   -- ...or cycle the whole rainbow
    AimBeamLaser       = false,   -- straight down the barrel, never onto a target
    AimBeamPitch       = 0.0,     -- nudge the beam up/down to match the barrel
    AimBeamYaw         = 0.0,     -- ...and left/right
    AimBeamLength      = 20,      -- metres
    AimBeamWalls       = true,    -- beam drawn over walls too
    AimBeamSize        = 1.0,     -- how thick the beam draws (0.2 .. 5)
    -- The cone cannot be drawn as a wireframe (debug drawing is compiled out
    -- and spawning our own component has hard-crashed this game), so it shows
    -- itself by marking the enemy it is holding, in his own body box.
    AimConeMark        = true,
    AimConeColor       = 6,       -- 0 red, 1 green ... 6 white, 7 orange
    -- The beam swings onto whoever the cone is holding. It cannot move your
    -- shots (the arrow is not what they are built from), so this is purely
    -- "show me who is picked", and it is the clearest way to see it.
    AimBeamTrack       = true,
    -- A shot that was sent at someone and went somewhere else still counts:
    -- the enemy it was meant for takes the hit, through the game's own damage
    -- call. Decided per shot, only when the bend did not land.
    AimMakeItHit       = true,

    -- Touch beside your head to switch the lamp / night vision.
    HeadTouch          = true,
    HeadTouchLeft      = 0,       -- 0 flashlight 1 night vision 2 nothing
    HeadTouchRight     = 1,
    -- 38 cm, not 28. Measured live: with your arms down the controllers sit
    -- 82 and 89 cm from the camera, and reaching up beside your head with a
    -- gun in that hand only gets the GRIP to about 30-35 cm. 28 fired once in
    -- a whole session.
    HeadTouchRange     = 38,      -- cm from the middle of your head

    -- OPTIMIZER tab (optimizer.lua). Off until used: nothing is issued to the
    -- console on a fresh launch.
    OptEnabled         = false,
    OptPreset          = 3,       -- 1 Game Default .. 5 Potato
    -- OPT GPU page: upscaling and the per-effect knobs. Every one of these
    -- means "leave the game's own value alone" at its default, so the page
    -- issues nothing until you touch it.
    OptUpscaler        = 0,       -- 0 off, 1 built-in, 2 FSR1, 3 FSR2, 4 DLSS
    OptUpscaleQuality  = 1,       -- 0 ultra quality .. 4 ultra performance
    OptSharpen         = 0,       -- 0 leave; 0.1 .. 1.0
    OptShadowDist      = 0,       -- 0 leave; 0.1 .. 2.0
    OptAnisotropy      = 0,       -- 0 leave; 1 .. 16
    OptCSMRes          = 0,       -- 0 leave; 512 .. 2048
    OptSSR             = -1,      -- -1 leave; 0 off .. 4
    OptAO              = -1,      -- -1 leave; 0 off .. 4
    OptMotionBlur      = -1,      -- -1 leave; 0 off .. 4
    OptDoF             = -1,      -- -1 leave; 0 off .. 4
    OptParticleLOD     = 0,       -- 0 leave; 1 .. 4
    OptMipBias         = 0,       -- 0 leave; 1 .. 4
    OptNoSpectator     = false,   -- stop rendering the desktop mirror
    OptRoundRobin      = false,   -- one eye's occlusion queries per frame
    OptFramePacing     = false,   -- steadier delivery, less judder
    -- OPT SYSTEM page: memory, the garbage collector, the CPU, audio and
    -- loading. Same rule - every one of these means "leave it alone".
    OptGcMode          = 0,       -- 0 game, 1 gentle, 2 smooth, 3 constant
    OptPhysThreads     = 0,       -- 0 game, 1 two .. 4 all cores
    OptFewerRagdolls   = false,   -- bodies settle and stop solving sooner
    OptAnimBudget      = false,   -- cheaper animation for distant enemies
    OptStreamBoost     = false,   -- let the texture streamer work harder
    OptTrimRam         = false,   -- hand memory back to Windows sooner
    OptRamMipBias      = 0,       -- 0 leave; 1..4 smaller textures in memory
    OptAudioVoices     = 0,       -- 0 leave; cap on sounds at once
    OptFastLoad        = false,   -- async loading on its own thread
    OptCustom          = false,
    OptResolution      = 0,       -- 0 = leave it; else r.ScreenPercentage
    OptPixelDensity    = 0,       -- 0 = leave it; else vr.PixelDensity
    OptShadows         = -1,      -- -1 = leave it; 0..3 quality groups
    OptViewDistance    = -1,
    OptFoliage         = -1,
    OptEffects         = -1,
    OptPostProcess     = -1,
    OptTextures        = -1,
    OptTexturePool     = 0,       -- MB, 0 = leave it
    OptEnemyDetail     = -1,      -- r.SkeletalMeshLODBias, -1 = leave it
    OptFpsCap          = 0,
    OptAutoRes         = false,
    OptTargetFps       = 72,
    OptAutoMin         = 0.6,
    OptAutoMax         = 1.0,
    OptNoFog           = false,
    OptNoLensFlares    = false,
    OptNoLightShafts   = false,
    OptNoBloom         = false,
    OptFastDecalFade   = false,
    OptSmoothGC        = false,
    OptSmoothStreaming = false,
    OptCorpseCleanup   = false,
    OptCorpseSeconds   = 20,
    OptBloodCleanup    = false,
    -- the game's own BulletFullFX, switched off on your guns
    OptNoImpactFX      = false,
    -- a Silent Aim hit shows the impact of the gun you are shooting with
    AimImpactFx        = true,
    OptBloodSeconds    = 45,
    OptFreezeBodies    = false,

    -- MUSIC tab (music.lua; playback lives in the desktop app)
    MyMusicVolume      = 0.6,
    MyMusicShuffle     = false,
    MyMusicRepeat      = true,
    MusicDuckGame      = true,    -- turn the game's soundtrack down while yours plays
    MusicDuckLevel     = 0.1,
    MusicAutoStart     = true,    -- the MUSIC tab starts the desktop player itself

    -- SAVES tab (saves.lua): your settings, kept for next time
    SaveAuto           = true,    -- write saved_settings.txt whenever something changes
    SaveLoadOnStart    = true,    -- and put it all back when the game starts
    SaveProfile        = 1,       -- which profile the SAVE/LOAD PROFILE rows use
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
-- for the 2026-09-17 modules, which call blueprint functions that exist on
-- only one of the two pawns (RefreshAllVolumeMulties is Wendigo-only)
PlayerMods.hasFunc = hasFunc

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

-- An actor's address, or nil. Used as a key, never dereferenced - two actors
-- can share an address across a round, which is why everything keyed on one
-- is also stamped with the sweep or the generation that saw it.
local function addrOf(o)
    if not o then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok then return a end
    return nil
end

-- A REMEMBERED OBJECT IS CHECKED WITHOUT BEING TOUCHED (2026-10-05).
--
-- UE4SS writes crash dumps of its own, and they carry the mod's Lua stack.
-- The most common crash in them is IsValid() asked of a gun the mod was
-- still remembering after the game had freed it: 27 September 16:33 in this
-- file's isValid (from YourGuns), and three more in aim_assist's alive().
-- IsValid reads the object's own index, so on freed memory the question
-- itself is the crash - UE4SS.dll+0x4baaaf, reading obj+0xC - and pcall
-- cannot catch it.
--
-- So an object is remembered together with its path, read while it was
-- certainly alive (just handed over by a hook or FindAllOf). Later the
-- ENGINE is asked whether that path still leads to that address - its name
-- table, never the object's memory - and only then is the object touched. A
-- path the engine cannot find its way back to at the start is not trusted,
-- and the old check is used for that object instead.
PlayerMods.pathOf = {}     -- (forgotten with the other caches; see onDropCaches)

-- "Looked up and found gone" is an answer too, and it is KEPT: the same gun
-- is usually remembered in more than one place (your guns, the held gun), and
-- forgetting its name after the first lookup left the second to ask the gun
-- itself. Only a live object handed over fresh at that address replaces it.
PlayerMods.GONE = {}

function PlayerMods.Remember(o)
    local a = addrOf(o)
    if not a then return end
    local cur = PlayerMods.pathOf[a]
    if cur ~= nil and cur ~= PlayerMods.GONE then return end
    local ok, full = pcall(function() return o:GetFullName() end)
    -- "ClassName /Game/Maps/Map.Map:PersistentLevel.Thing_12" -> the path
    local path = ok and type(full) == "string" and full:match("^%S+%s+(%S.*)$") or nil
    -- checked straight away on the game thread; from the loop, the game
    -- thread's own check (CheckRemembered) does it a moment later
    if path and not PlayerMods.loopBodyActive then
        local okF, back = pcall(StaticFindObject, path)
        if not (okF and back and addrOf(back) == a) then path = nil end
    end
    PlayerMods.pathOf[a] = path or false
end

-- true = still there, false = gone (and not touched), nil = cannot tell
function PlayerMods.StillThere(o)
    local a = addrOf(o)
    local path = a and PlayerMods.pathOf[a]
    if path == PlayerMods.GONE then return false end
    if not path then return nil end
    -- THE LOOP THREAD NEVER ASKS THE NAME TABLE (2026-10-07 06:43). UE4SS's
    -- StaticFindObject is its own FindObject, walking the engine's object
    -- hash with no lock - and from this thread, while the game was tearing a
    -- round down, it read a hash entry that had just been emptied: the crash
    -- at UE4SS.dll+0x4baaaf. The game thread re-checks every remembered path
    -- once a tick (CheckRemembered); here the last answer is used.
    if PlayerMods.loopBodyActive then return true end
    local ok, back = pcall(StaticFindObject, path)
    if ok and back and addrOf(back) == a then return true end
    PlayerMods.pathOf[a] = PlayerMods.GONE
    PlayerMods.goneUntouched = (PlayerMods.goneUntouched or 0) + 1
    return false
end

-- ON THE GAME THREAD, once a tick: every remembered path asked again, so
-- the loop thread can trust "not marked GONE" without asking anything itself.
-- The game thread is the one that frees objects, so the lookup here cannot
-- meet an object half-way through being torn down.
function PlayerMods.CheckRemembered()
    local gone = PlayerMods.GONE
    for a, path in pairs(PlayerMods.pathOf) do
        if path and path ~= gone then
            local ok, back = pcall(StaticFindObject, path)
            if not (ok and back and addrOf(back) == a) then
                PlayerMods.pathOf[a] = gone
                PlayerMods.goneUntouched = (PlayerMods.goneUntouched or 0) + 1
            end
        end
    end
    -- the loop waits on this count after a stall
    PlayerMods.checkRuns = PlayerMods.checkRuns + 1
end

-- isValid() for something REMEMBERED from an earlier moment
function PlayerMods.StillValid(o)
    if PlayerMods.StillThere(o) == false then return false end
    return isValid(o)
end

-- forEachSettledEnemy is defined further down, once forEachOf exists.
local forEachSettledEnemy
-- Called by the sweep for an enemy that has just been found DEAD, so its body
-- box can be hidden before the corpse lies there with a box standing over it.
-- Assigned in the ESP BODY BOXES section.
local boxCorpse

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
    -- BY NAME FIRST (2026-10-06): a map load frees the controller, and the
    -- UE4SS dumps of 5 October are a class check on exactly such an object
    -- (UE4SS.dll+0x52dbb9, 14 and 18 s into a session). See StillValid.
    if not PlayerMods.StillValid(cachedPC) then
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
                PlayerMods.Remember(pc)
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
    -- by name first: a map load frees the pawn (see possessedPawn)
    if PlayerMods.StillValid(cachedPawn) then
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
            PlayerMods.Remember(live)
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
                            PlayerMods.Remember(obj)
                            PlayerMods.pawnSource = "sweep"
                            return cachedPawn, cachedKind
                        end
                    end
                end
            end
            -- nothing possessed: better to use one than none
            if firstValid then
                cachedPawn, cachedKind = firstValid, cls
                PlayerMods.Remember(firstValid)
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
-- a new world or round: every remembered path belongs to the one just gone
onDropCaches(function() PlayerMods.pathOf = {} end)

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
    -- FIRST, before anything else: retire every job already on its way to the
    -- game thread. Clearing our own tables does nothing for a closure that is
    -- already holding the arrow off a gun in the world that just went.
    PlayerMods.NewGeneration()
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

-- Which blueprint each gun is, learned free from the sweep that walks the
-- classes one at a time. Address -> class name.
local gunClassOf = {}
-- What `separatebolt` was before Full Auto took it away, per gun.
local pumpWas = {}

-- HOW FAST EACH GUN ACTUALLY FIRES.
--
-- "the shotgun is still not automatic while holding the button" is a question
-- about a rate, and it should not have to be judged by ear. These count it.
--
-- In TICKS, not seconds: the key debounce a few hundred lines up in main.lua
-- deliberately avoids depending "on os.clock semantics inside the UE4SS Lua
-- runtime", and a rate built on that clock would inherit the same doubt. The
-- loop runs at 100 ms and already treats 10 ticks as a second.
--
-- ONE PER TICK, because four fire functions are hooked and one trigger pull
-- may run more than one of them. Counting each call would multiply a single
-- shot into several and report a single-shot gun as automatic. Capping at one
-- per tick caps the reading at 10 a second, which is enough: the question is
-- "several a second" against "about one".
local shotTicks, shotPeak, lastShotTick = {}, {}, {}
local SHOT_WINDOW = 10   -- ticks; the loop runs at 100 ms, so about a second

onDropCaches(function()
    pumpWas = {} gunClassOf = {}
    -- the window is about what is happening now, so it goes; the peak is the
    -- answer we are collecting, so it stays
    shotTicks = {} lastShotTick = {}
end)

-- Shots in the last second, right now, across whichever gun is firing.
-- Pruned as it is read rather than only when a shot lands, so a gun that has
-- stopped reads 0 instead of holding its last count.
function PlayerMods.ShotNow()
    local tick, best = PlayerMods.tickStamp or 0, 0
    for _, w in pairs(shotTicks) do
        local n = 0
        for i = 1, #w do
            if w[i] > tick - SHOT_WINDOW then n = n + 1 end
        end
        if n > best then best = n end
    end
    return best
end

-- "bp_Skel_shotgun_C:9 bp_Skel_ak_C:10" - the most shots each gun managed in
-- one second. This is the measured answer to "is it automatic yet": several a
-- second means it kept firing while the trigger was held, about one means it
-- still takes a pull each time. Reads no higher than 10 - see shotTicks.
function PlayerMods.ShotRateLine()
    local parts = {}
    for cls, n in pairs(shotPeak) do
        parts[#parts + 1] = string.format("%s:%d", tostring(cls), n)
    end
    if #parts == 0 then return "none" end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- EVERY CALL, UNCAPPED - per gun AND per fire function.
--
-- "AK speed slider still is not working" could not be settled from shotrate=:
-- it counts one shot per tick, so it stops at 10 a second, and an AK at 15 a
-- second reads exactly like one at 10. Counting each fire function on its own
-- gets round the reason for the cap (one pull can run several of the four),
-- so this one counts every call. "bp_Skel_ak_C.Firebulletauto:15" = that
-- function ran 15 times inside one second. Kept on PlayerMods: this chunk is
-- at Lua's 200-local ceiling.
PlayerMods.fnTicks, PlayerMods.fnPeak = {}, {}
onDropCaches(function() PlayerMods.fnTicks = {} end)

function PlayerMods.CountFireFn(key)
    local tick = PlayerMods.tickStamp or 0
    local w = PlayerMods.fnTicks[key] or {}
    local keep, cut = {}, tick - SHOT_WINDOW
    for i = 1, #w do
        if w[i] > cut then keep[#keep + 1] = w[i] end
    end
    keep[#keep + 1] = tick
    PlayerMods.fnTicks[key] = keep
    if #keep > (PlayerMods.fnPeak[key] or 0) then PlayerMods.fnPeak[key] = #keep end
end

function PlayerMods.FireFnLine()
    local parts = {}
    for key, n in pairs(PlayerMods.fnPeak) do
        parts[#parts + 1] = string.format("%s:%d", tostring(key), n)
    end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, " ") or "none"
end

local function RefillSkeletalGun(gun, fnName)
    if not isValid(gun) then return end
    -- Not the gun that is shooting AT you. These hooks fire for every
    -- SkeletalGun_C in the world, so without this the enemies have had
    -- infinite ammo and no recoil for as long as you have.
    if not PlayerMods.IsGunHeld(gun) then
        PlayerMods.gunNotYours = (PlayerMods.gunNotYours or 0) + 1
        return
    end
    PlayerMods.gunYours = (PlayerMods.gunYours or 0) + 1
    -- the gun in your hand, kept so the per-tick work below does not have to
    -- walk the object array to find it again
    PlayerMods.heldGun = gun
    PlayerMods.heldGunGen = PlayerMods.gen
    -- fresh from the game right now: learn where to find it again
    PlayerMods.Remember(gun)
    -- ...and into the set of EVERY gun in your hands. You often hold two
    -- (ingrip=2), and "the last one fired" is only ever one of them: while it
    -- was the other hand's gun, the shotgun was never re-loaded.
    do
        local ya = addrOf(gun)
        if ya then PlayerMods.yourGuns[ya] = { g = gun, gen = PlayerMods.gen } end
    end
    local s, C = PlayerMods.state, GUN_SKEL

    -- LIGHTER GUNSHOT IMPACTS - the game's own switch, not a new one.
    --
    -- SkeletalGun_C carries BulletFullFX (True on the base gun, inherited by
    -- all four of yours) and hands it to every bullet it fires as FullFX.
    -- Enemy guns are a different class with no such switch, so their shots
    -- already go out without it. This is written only on YOUR gun, here,
    -- inside its own pre-fire hook - after the ownership check above and
    -- before the bullet is made - so the gun is certainly alive and nothing
    -- is carried across a job gap. Its own value is handed back on the way
    -- out, and the table lives on PlayerMods rather than as a file local
    -- (this chunk is at Lua's 200-local ceiling).
    do
        local fa = addrOf(gun)
        if fa then
            local wasFx = PlayerMods.fxWas
            if s.OptEnabled and s.OptNoImpactFX then
                if wasFx[fa] == nil then
                    wasFx[fa] = (get(gun, C, "BulletFullFX") == true)
                end
                set(gun, C, "BulletFullFX", false)
            elseif wasFx[fa] ~= nil then
                set(gun, C, "BulletFullFX", wasFx[fa])
                wasFx[fa] = nil
            end
        end
    end

    if s.InfiniteAmmo then
        local maxA = get(gun, C, "AmmoMAX")
        set(gun, C, "Ammo", (type(maxA) == "number" and maxA > 0) and maxA or 999)
        -- The paced shotgun is loaded here too. A loaded gun never fires by
        -- itself: the gun's own bytecode fires on a press, or on the fire
        -- timer Auto Fire starts, and on nothing else - so a shell up is a
        -- shell ready, not a shot. The pace is the timer's.
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

    -- Full auto. Enum_FireStates' display names were lost in the header dump
    -- (NewEnumerator0/1/2/5 = 0/1/2/3), so which one meant "automatic" was a
    -- guess for a long time. It is not any more: the shipped pak says
    -- bp_Skel_ak defaults to NewEnumerator0 and bp_Skel_shotgun to
    -- NewEnumerator5, and the ak is the one that already runs while the
    -- trigger is held. So 0 is automatic. It stays adjustable in case a gun
    -- disagrees, but the default is now the right one rather than the
    -- shotgun's own. Keeping the burst counters topped up means burst mode
    -- never runs out either way.
    -- WHOSE HOOK IS THIS? shothooks= counts every gun together, so "the
    -- shotgun is still not automatic" could not be told from "the shotgun's
    -- hook never fires". Per class, it can - and the class costs nothing,
    -- because the weapon sweep already walks one class at a time and writes
    -- down what it found. Asking the gun itself would mean
    -- GetClass():GetFName():ToString() on every shot, which the ESP note in
    -- this same file calls a known way to crash these games.
    local ga = addrOf(gun)
    local gcls = ga and gunClassOf[ga] or nil
    if gcls then
        PlayerMods.gunByClass = PlayerMods.gunByClass or {}
        PlayerMods.gunByClass[gcls] = (PlayerMods.gunByClass[gcls] or 0) + 1

        -- A CALL THE MOD MADE IS NOT A SHOT. Auto Fire starts the gun's fire
        -- timer through Firebulletauto, which runs this hook as well; counting
        -- it would put the mod's own call into the meter.

        -- NOT a `return`. Everything below this block is what puts the gun
        -- into automatic, keeps it fed and gives it the self-cycling bolt,
        -- and the two-second sweep is the only thing that runs it on a gun
        -- you are not firing this instant. Returning early here silently
        -- undid the bolt fix - two tests caught it in the same run.
        --
        -- The sweep topping a gun up is not a trigger pull either, so neither
        -- it nor a driven shot goes into the rate.
        if not (PlayerMods.inAutoFire or PlayerMods.inSweepRefill) then
            -- how fast, one shot per tick. See the note by shotTicks.
            local tick = PlayerMods.tickStamp or 0
            if lastShotTick[gcls] ~= tick then
                lastShotTick[gcls] = tick
                local w = shotTicks[gcls]
                if not w then w = {} shotTicks[gcls] = w end
                w[#w + 1] = tick
                local keep, cut = {}, tick - SHOT_WINDOW
                for i = 1, #w do
                    if w[i] > cut then keep[#keep + 1] = w[i] end
                end
                shotTicks[gcls] = keep
                if #keep > (shotPeak[gcls] or 0) then shotPeak[gcls] = #keep end
            end
            -- ...and uncapped, per function (firefn=)
            if fnName then PlayerMods.CountFireFn(gcls .. "." .. fnName) end
        end
    end

    if s.FullAuto then
        -- WHAT THE GUN WAS, remembered before anything is written over it -
        -- including its own fire mode, which decides who sets the pace below
        local a0 = addrOf(gun)
        if a0 and pumpWas[a0] == nil then
            local wasRate = get(gun, C, "FireRate")
            local wasMode = get(gun, C, "Firingmode")
            -- remembered apart from pumpWas, which Full Auto off clears before
            -- the AK's speed has been handed back
            if wasMode == PlayerMods.FIRE_AUTO then PlayerMods.akShips[a0] = true end
            pumpWas[a0] = { get(gun, C, "separatebolt") == true,
                            get(gun, C, "bIsRecipricatingBolt") == true,
                            type(wasRate) == "number" and wasRate or nil,
                            type(wasMode) == "number" and wasMode or nil,
                            -- the pump shotgun's own flag (True only on it
                            -- in the shipped pak): the one gun Auto Fire paces
                            get(gun, C, "shotgun") == true }
        end
        local was0 = a0 and pumpWas[a0] or nil

        -- WHO SETS THE PACE.
        --
        -- Forcing every gun into the game's Auto mode is what turned the
        -- shotgun into an SMG: that mode fires at the gun's own FireRate, and
        -- the shotgun ships at 0.025 s. With Auto Fire on, a gun that does not
        -- ship automatic keeps its OWN mode, so the game fires one shell per
        -- pull and the mod fires the rest at the pace you set. A gun that does
        -- ship automatic is left at its own speed, and the mod leaves it be.
        -- ONLY THE PUMP SHOTGUN. Pacing the pistols made them worse ("they
        -- were great before ... like an ak ... put it back"), so every other
        -- gun goes back to the game's own automatic below.
        local modDrives = PlayerMods.AutoFireGap() ~= nil
                          and was0 ~= nil and was0[5] == true
        if modDrives then
            if was0[4] ~= nil then set(gun, C, "Firingmode", was0[4]) end
        else
            set(gun, C, "Firingmode", math.floor(s.FireModeIndex or 0))
        end
        set(gun, C, "BurstAmount", 999)
        set(gun, C, "BurstRemain", 999)
        -- THE PUMP ITSELF. `separatebolt` is the weapon-type flag for "worked
        -- by hand between shots" - a pump shotgun, a bolt rifle. Clearing
        -- weapon-type configuration is normally a bad idea and an earlier
        -- round said so; but "no pumping" is exactly what Full Auto is for,
        -- and this is the flag that decides it. Its original value is kept so
        -- turning Full Auto off puts the gun back the way the game had it.
        local a = addrOf(gun)
        if a then
            -- (what the gun was is captured at the top of this branch)
            -- READ OUT OF THE SHIPPED PAK - every default of both guns, side
            -- by side. Both subclasses are EMPTY (their CXXHeaderDump headers
            -- declare nothing), so the same code runs for both and only a
            -- value can separate them. Of the firing ones, exactly two do:
            --
            --   Firingmode            ak Auto(0)  shotgun Single(5)
            --   bIsRecipricatingBolt  ak TRUE     shotgun FALSE
            --   separatebolt          ak false    shotgun false   (same)
            --   FireRate              ak 0.1      shotgun 0.025   (faster!)
            --
            -- separatebolt is already false on every gun, so clearing it was
            -- doing nothing - that much was established last round, along
            -- with the fact that CLEARING bIsRecipricatingBolt was backwards
            -- because the ak, the gun that works, has it set. What was not
            -- drawn then is the other half: if the working gun has it and the
            -- broken one does not, then SETTING it is the lever. A
            -- reciprocating bolt is the one that cycles itself rather than
            -- being worked by hand, which is exactly the difference between
            -- "holding the trigger keeps it firing" and "pump it again".
            --
            -- Neither the shotgun nor the base class overrides it, so it sits
            -- at false on the shotgun; the ak sets it true on purpose.
            set(gun, C, "separatebolt", false)
            -- The paced shotgun keeps its OWN pump. A self-cycling bolt
            -- chambers the next shell by itself, and a loaded gun with the
            -- trigger held fires again - that was half the SMG.
            if modDrives then
                set(gun, C, "bIsRecipricatingBolt", was0[2] == true)
            else
                set(gun, C, "bIsRecipricatingBolt", true)
            end

            -- FIRE RATE, CLAMPED SO IT ONLY EVER SPEEDS A GUN UP.
            --
            -- The slider is seconds between shots. Written as-is it made the
            -- shotgun - which ships at 0.025 - nine times slower at 0.22, and
            -- that is exactly the "0.45 second delay" that got reported.
            -- Neither clamp can slow a gun: both only ever lower the number.
            -- THE GUN'S OWN FIRE RATE. The "seconds per shot" slider is
            -- gone: it was a second pace control in the opposite unit, and
            -- the old clamp overrode it anyway. FireRate holds the gun's own
            -- value, lowered only when the mod is firing it, so its cooldown
            -- can never refuse one of those shots.
            local want = pumpWas[a] and pumpWas[a][3]
            if modDrives then
                -- THE PACED SHOTGUN'S RATE IS YOUR GAP, exactly. The gun's
                -- bytecode reads FireRate in one place only: the period of the
                -- looping timer Firebulletauto starts - Auto Fire's timer. It
                -- was the shotgun's own 0.025 s under that timer that made the
                -- SMG.
                want = PlayerMods.AutoFireGap()
            elseif want and PlayerMods.akShips[a] then
                -- THE AK'S SPEED IS ITS FIRE RATE after all. Last round moved
                -- it onto the 750/1000rpm timelines - but those run at 12 and
                -- 16 a second, and the AK has measured 8 to 10 a second in
                -- every session: its own FireRate, 0.1 s (bp_Skel_ak's default
                -- in the pak). So its own rate is divided by the speed - 2.0
                -- is 0.05 s a bullet - and the timelines follow as well.
                want = want / PlayerMods.AkSpeed()
            end
            if want then set(gun, C, "FireRate", want) end
        end
        -- every gun of yours, the paced shotgun included: this is the shell
        -- the next tick of its fire timer fires
        RechamberSkeletalGun(gun)
        -- each tick of that timer runs FireBulletsingle; each press, FIREEVENT
        if modDrives and fnName == "FireBulletsingle" then PlayerMods.PacedShot(gun) end
        if modDrives and fnName == "FIREEVENT" then PlayerMods.PacedPress(gun) end
    elseif next(pumpWas) ~= nil then
        -- Full Auto is off again: hand the pump back to any gun we took it
        -- from, so the shotgun behaves like the game intends once more.
        local a = addrOf(gun)
        if a and pumpWas[a] ~= nil then
            set(gun, C, "separatebolt", pumpWas[a][1])
            -- ...and the bolt goes back to being worked by hand, so a pump
            -- shotgun is a pump shotgun again with Full Auto off
            set(gun, C, "bIsRecipricatingBolt", pumpWas[a][2])
            -- ...and its own fire rate, so the gun is exactly as the game
            -- made it once Full Auto is off
            if pumpWas[a][3] then set(gun, C, "FireRate", pumpWas[a][3]) end
            -- ...and its own fire mode, which Full Auto off never used to
            -- hand back - the gun stayed automatic after it was switched off
            if pumpWas[a][4] then set(gun, C, "Firingmode", pumpWas[a][4]) end
            pumpWas[a] = nil
        end
    end
    -- the AK's speed: set, or handed back with Full Auto off
    PlayerMods.ApplyAkSpeed(gun)
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

    -- THE GUN IN YOUR HAND, NOT WHICHEVER ONE TURNS UP FIRST.
    --
    -- This used FindAllOf on the EXACT base class, which never returns a
    -- shotgun, an ak, a glock or a 92fs - every one of those is a subclass of
    -- it. So the one readout meant to answer "why is my shotgun not
    -- automatic" could never see the shotgun. It walks the subclasses now and
    -- prefers a gun the ownership test calls yours.
    -- NOTHING IN A STATUS FIELD MAY CONTAIN A SPACE. The app splits these
    -- lines on spaces, so one value that reads back as a table - which a
    -- property the build does not have will - would print "table: 0000..."
    -- and silently corrupt every field after it.
    local function flat(v)
        if v == true then return "true" end
        if v == false then return "false" end
        if type(v) == "number" then return string.format("%g", v) end
        if type(v) == "string" and not v:find("%s") then return v end
        return "?"
    end

    local out, fallback = nil, nil
    for _, cls in ipairs(GUN_SUBCLASSES) do
        local ok, list = pcall(FindAllOf, cls)
        if ok and list then
            for _, g in ipairs(list) do
                if isValid(g) then
                    local line = string.format(
                        "gun=%s mode=%s rate=%s pump=%s recipbolt=%s shotgun=%s " ..
                        "trigger=%s chambered=%s spent=%s cocked=%s boltback=%s canfire=%s " ..
                        -- FireFunction fires NOTHING while a hand is on the
                        -- slide of a gun whose slide cannot stabilise
                        "slidegrip=%s slidestab=%s",
                        flat(cls),
                        flat(get(g, GUN_SKEL, "Firingmode")),
                        flat(get(g, GUN_SKEL, "FireRate")),
                        flat(get(g, GUN_SKEL, "separatebolt")),
                        flat(get(g, GUN_SKEL, "bIsRecipricatingBolt")),
                        flat(get(g, GUN_SKEL, "shotgun")),
                        flat(get(g, GUN_SKEL, "TriggerHeld")),
                        flat(get(g, GUN_SKEL, "RoundChambered")),
                        flat(get(g, GUN_SKEL, "HasSpentShell")),
                        flat(get(g, GUN_SKEL, "FullyCocked")),
                        flat(get(g, GUN_SKEL, "BoltLockedBack")),
                        flat(get(g, GUN_SKEL, "CanBeFired")),
                        flat(get(g, GUN_SKEL, "SliderGripActive")),
                        flat(get(g, GUN_SKEL, "bSlideCanStabilize")))
                    fallback = fallback or line
                    if PlayerMods.IsGunHeld and PlayerMods.IsGunHeld(g) then
                        out = line
                        break
                    end
                end
            end
        end
        if out then break end
    end
    out = out or fallback
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

-- EVERY GUN BLUEPRINT, NOT JUST THE BASE ONE (2026-09-21).
--
-- The per-shot hooks were registered on SkeletalGun_C alone. The shotgun, ak,
-- glock and 92fs are separate blueprints deriving from it, and a blueprint
-- that overrides the fire function does not run the base one - so for those
-- guns the hook never fired at all. The weapon sweep walks the subclasses
-- (that is why they still get infinite ammo), but a sweep every two seconds
-- cannot ready the next round between two trigger pulls. That is what made
-- the shotgun still need pumping while the rifle went full auto.
local function gunTargets(fn)
    local out = targets(PlayerMods.PATHS.SkelGun, GUN_SKEL, fn)
    for _, cls in ipairs(GUN_SUBCLASSES) do
        if cls ~= GUN_SKEL then out[#out + 1] = cls .. ":" .. fn end
    end
    return out
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

-- THE PUMP'S HOOK: the player pawns' own per-frame event. Both classes
-- override ReceiveTick (CXXHeaderDump), and whichever this map uses ticks on
-- the game thread every frame.
do -- (its own scope: the file is at Lua's 200-local limit)
local PUMP_TARGETS = {
    "/Game/VRExpansion/Vive/WendigoVrChar.WendigoVrChar_C:ReceiveTick",
    "/Game/WeaponMaster/Blueprints/Basic/BP_VRCharacter.BP_VRCharacter_C:ReceiveTick",
}
PlayerMods.pumpHooked = {}
PlayerMods.pumpBinds = 0

-- Worth a bind attempt: quiet for two seconds, a pawn to carry it, and not
-- tried in the last five (a bound pump on a pawn that is not ticking is not
-- fixed by binding it again - and every RegisterHook makes a Lua state).
function PlayerMods.PumpPending()
    if PlayerMods.pumpQuiet < 20 then return false end
    local at = PlayerMods.pumpTriedAt
    if at and (PlayerMods.tickStamp or 0) - at < 50 then return false end
    return PlayerMods.GetPawn() ~= nil
end

-- ON THE GAME THREAD (the bind-hooks job). A function already hooked is not
-- hooked again unless the class was reloaded under it (a new function object).
function PlayerMods.BindPump()
    -- never from inside the pump: that would add to the very callback list
    -- UE4SS is walking to call us
    if PlayerMods.inPump then return end
    if not (RegisterHook and StaticFindObject) then return end
    PlayerMods.pumpTriedAt = PlayerMods.tickStamp or 0
    for _, t in ipairs(PUMP_TARGETS) do
        local ok, fn = pcall(StaticFindObject, t)
        local a = ok and fn and isValid(fn) and addrOf(fn) or nil
        if a and PlayerMods.pumpHooked[t] ~= a then
            local okR, id = pcall(RegisterHook, t, function(self)
                local okG, p = pcall(function() return self:get() end)
                PlayerMods.Pump(okG and p or self)
            end)
            if okR and id ~= nil then
                PlayerMods.pumpHooked[t] = a
                PlayerMods.pumpBinds = PlayerMods.pumpBinds + 1
            end
        end
    end
end

function PlayerMods.PumpLine()
    return string.format("%s runs=%d kicks=%d binds=%d waiting=%d holds=%d %s",
        PlayerMods.PumpAlive() and "on" or "OFF", PlayerMods.pumpRuns,
        PlayerMods.gt.kicks or 0, PlayerMods.pumpBinds,
        PlayerMods.ringW - PlayerMods.ringR, PlayerMods.holds,
        PlayerMods.pumpStats or "")
end
end

PlayerMods.hooksBound = false

-- IS THERE STILL A HOOK TO BIND? The same test EnsureHooks makes before it
-- gives up, so the loop only sends binding work to the game thread while
-- there is binding work to do.
function PlayerMods.HooksPending()
    if PlayerMods.PumpPending() then return true end
    local recoilOn = (PlayerMods.recoilHooksBound or 0) > 0
    return not (PlayerMods.hooksBound and (PlayerMods.meleeHooks or 0) > 0
                and (PlayerMods.gunHooksBound or 0) > 0 and recoilOn)
end

function PlayerMods.EnsureHooks()
    -- the job pump first: until it runs, every tick's work needs a queued call
    if PlayerMods.PumpPending() then PlayerMods.BindPump() end
    -- Fist hooks live on the ENEMY classes, which are not loaded when the player
    -- pawn appears - they arrive with the first enemy. The old code stopped
    -- retrying the moment the god-mode hooks bound, so the fist hooks were
    -- attempted once, against classes that did not exist yet, and never again.
    -- That is why Strength Fists did nothing. Each group retries on its own.
    --
    -- THE GUN HOOKS NEEDED THE SAME TREATMENT (2026-09-20).
    --
    -- The ammo/recoil hooks were inside the `not hooksBound` block, and
    -- hooksBound flips true the moment the DAMAGE hooks bind - which happens
    -- as soon as the pawn exists, long before you are holding a gun. So if
    -- the gun blueprint was not loaded at that moment, Infinite Ammo, No
    -- Recoil and Full Auto never bound at all, and nothing said so: the
    -- weapon scan kept them roughly working, so it looked fine. Exactly the
    -- bug described above for the fists, one group along. They retry on their
    -- own now, like the melee hooks do.
    -- AND THE RECOIL HOOK IS ITS OWN GROUP. gunHooksBound only counts the
    -- FIRE hooks, so once those bound this gate stopped calling
    -- RegisterAmmoHooks at all - and the recoil hook, which binds separately
    -- and later, never got another attempt. No Recoil depends entirely on it.
    local recoilOn = (PlayerMods.recoilHooksBound or 0) > 0
    if PlayerMods.hooksBound and (PlayerMods.meleeHooks or 0) > 0
       and (PlayerMods.gunHooksBound or 0) > 0
       and recoilOn then return end
    -- no point trying before the pawn - and therefore its class - exists
    if not PlayerMods.GetPawn() then return end

    -- RECOIL IS RETRIED FOR AS LONG AS IT TAKES, BUT ONCE A SECOND.
    --
    -- A count of attempts was the wrong bound: the fire hooks bind in the
    -- first seconds and RecoilEvent may not appear until you actually pick a
    -- gun up, by which time any sensible attempt budget is long spent. A
    -- one-second gap costs nothing and never gives up on it.
    local nowClock = os.clock()
    local recoilDue = not recoilOn
                      and (nowClock - (PlayerMods.recoilHookAt or -99)) > 1.0
    if (PlayerMods.gunHooksBound or 0) == 0 or recoilDue then
        PlayerMods.recoilHookAt = nowClock
        PlayerMods.RegisterAmmoHooks()
    end

    if not PlayerMods.hooksBound then
        PlayerMods.RegisterDamageHooks()

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
        -- A HOOK THAT DID NOT BIND MUST NOT BE MARKED AS BOUND.
        --
        -- RegisterHook returns nothing - without raising - when the blueprint
        -- is not loaded yet, which for a gun is most of the time at startup.
        -- The old code only asked whether the pcall survived, so the first
        -- attempt marked the target done forever and these hooks never bound
        -- at all: status.txt has been reading shothooks=0 with
        -- "blueprint not loaded yet - will retry" sitting right above it, and
        -- Infinite Ammo / No Recoil / Full Auto have been getting by on the
        -- 2 s weapon scan alone. Keep the handle, or keep retrying.
        local ok, handle = pcall(function()
            -- Second callback is the POST hook. Cycle state has to be restored
            -- after the shot has been processed; doing it in the pre-hook only
            -- means the gun un-chambers itself immediately afterwards.
            if postFn then
                return RegisterHook(target, run(fn), run(postFn))
            end
            return RegisterHook(target, run(fn))
        end)
        -- Counted on its OWN line, not inside the test below. A counter that
        -- lives inside the condition it is meant to prove cannot tell you the
        -- condition was removed - which is exactly what a mutant showed.
        -- GUN targets only. This same helper binds the damage and melee
        -- hooks too, whose blueprints are loaded long before a gun is, so
        -- counting everything hid the very thing the counter is for.
        -- ...and the subclasses count as gun hooks too. They are named
        -- bp_Skel_shotgun_C / bp_skel_glock_C - different capitals, no
        -- "SkeletalGun" in the name - so the old test missed every one of
        -- them and the retry gate could call it a day with the shotgun still
        -- unhooked.
        if handle ~= nil and tostring(target):lower():find("skel", 1, true) then
            PlayerMods.gunHooksBound = (PlayerMods.gunHooksBound or 0) + 1
        end
        if ok and handle ~= nil then
            hookedTargets[target] = true
        end
    end

    -- POST-fire work: both of these have to happen after the shot, not before.
    -- NOTE: this is registered as a POST callback, and UE4SS POST hooks do not
    -- fire in this build (restored=0 late=189, measured 18 September). So in
    -- the real game this never runs, and No Recoil / Full Auto are carried
    -- entirely by the 2 s weapon scan and the recoil-event hook below. The
    -- ownership check is here anyway, for the day POST hooks start working -
    -- but no test drives it, because nothing can.
    local function afterShot(gun)
        if not (isValid(gun) and PlayerMods.IsGunHeld(gun)) then
            PlayerMods.gunNotYours = (PlayerMods.gunNotYours or 0) + 1
            return
        end
        if PlayerMods.state.NoRecoil then ZeroRecoil(gun) end
        if PlayerMods.state.FullAuto then
            RechamberSkeletalGun(gun)
            PlayerMods.rechambers = (PlayerMods.rechambers or 0) + 1
        end
    end

    for _, fn in ipairs({ "FireGun", "Firebulletauto", "FireBulletsingle", "FIREEVENT" }) do
        -- which of the four this is, for the uncapped meter
        local function pre(g) RefillSkeletalGun(g, fn) end
        for _, t in ipairs(gunTargets(fn)) do
            hook(t, pre, afterShot)
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
        for _, t in ipairs(gunTargets(fn)) do
            if not hookedTargets[t] then
                local ok, handle = pcall(function()
                    return RegisterHook(t, function(self, arg1)
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
                        if not PlayerMods.IsGunHeld(gun) then return end
                        ZeroRecoil(gun)
                        -- and the int32 lerp/decay indices, which the vectors
                        -- alone may not cover
                        set(gun, GUN_SKEL, "RecoilLERPStblz", 0)
                        set(gun, GUN_SKEL, "RecoilDECAYStblz", 0)
                        set(gun, GUN_SKEL, "RecoilLERP1hnd", 0)
                        set(gun, GUN_SKEL, "RecoilDECAY1hnd", 0)
                    end)
                end)
                -- THE SAME TRAP AS THE FIRE HOOKS, ONE LOOP ALONG (2026-09-20).
                --
                -- RegisterHook returns nothing - WITHOUT raising - when the
                -- blueprint is not loaded, which for a gun is most of the time
                -- at startup. Asking only whether the pcall survived marked
                -- this target done on the first failed attempt and it was never
                -- retried. That is why a real session with 25 kills reported
                -- recoilevents=0: RecoilEvent is the only moment No Recoil can
                -- work (the stored vectors are already 0/0/0 by then and the
                -- kick arrives as an ARGUMENT), and the hook was never on.
                -- Keep the handle, or keep retrying.
                if ok and handle ~= nil then
                    hookedTargets[t] = true
                    -- ONLY RecoilEvent COUNTS. ManualRecoil is a sibling in the
                    -- same loop that can bind while RecoilEvent is still
                    -- missing, and it was satisfying the retry gate on
                    -- RecoilEvent's behalf - so the retrying stopped with the
                    -- one hook No Recoil actually needs still unbound. A group
                    -- counter is no use when the group members arrive apart.
                    if tostring(t):find("RecoilEvent", 1, true) then
                        PlayerMods.recoilHooksBound =
                            (PlayerMods.recoilHooksBound or 0) + 1
                    end
                end
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
                -- ...and the component is LOOKED UP INSIDE the job, never
                -- carried into it. Between queueing and running, the round
                -- can end and this component can be freed; isValid() still
                -- answers true for a half-destroyed object and pcall cannot
                -- catch a native fault, which is the 0x268 read this mod has
                -- already been bitten by once in esp-boxes.
                PlayerMods.InGameThread("hand-power", function()
                    if PlayerMods.dormant then return end
                    if not isValid(hand) then return end
                    local live = get(hand, cls, "RootPhysics")
                    if not isValid(live) then return end
                    pcall(function() live:SetSphereRadius(want, true) end)
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
                    -- by name, resolved inside the job - same reason
                    PlayerMods.InGameThread("hand-power", function()
                        if PlayerMods.dormant then return end
                        if not isValid(hand) then return end
                        local live = get(hand, cls, name)
                        if not isValid(live) then return end
                        pcall(function()
                            live:SetCapsuleSize(want * 0.5, want * 0.5, true)
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
        local p = PlayerMods.EnemyPos(e, c)
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
                local hp = PlayerMods.EnemyPos(other, h.cls)
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
                PlayerMods.RagdollStartLater(e, ecls)
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
        PlayerMods.InGameThread("test-grab", function()
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
        PlayerMods.InGameThread("test-lamp", function()
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
        PlayerMods.InGameThread("test-jump", function()
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
    PlayerMods.InGameThread("audio-fix", function()
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
    PlayerMods.InGameThread("pointer-beam", function()
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
    -- Added 2026-09-17. Each of these reads enemy positions from the ESP scan,
    -- so they belong with the rest of the enemy-touching set. Perfect Accuracy
    -- (NoSpread) is deliberately NOT here: it only ever touches your own bullet.
    "AimAssist", "ESPBoxes",
    -- Added 2026-09-18: silent aim reads the same numbers; extra damage and the
    -- body/hitbox shapes are calls on live enemies (made once per enemy, on the
    -- game thread, right after the sweep - but still enemy work).
    "SilentAim", "AimForceDamage", "AimOneShot", "ESPHitboxes",
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
    local p = PlayerMods.EnemyPos(enemy, cls)
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

-- AN ENEMY'S POSITION, WITHOUT CALLING INTO THE ENGINE (2026-10-07).
--
-- K2_GetActorLocation is an engine FUNCTION: called from the loop thread it
-- goes through ProcessEvent, UE4SS's call setup reads the object's class -
-- and an enemy the round end is tearing down can be gone by then. That is the
-- crash of 7 October 05:29 (the ESP's bone read on a dying enemy), and the
-- crash message box it left behind was the "frozen right after". An
-- ACharacter's root is its capsule, attached to nothing, so the capsule's own
-- RelativeLocation IS the actor's location - and reading a property is a
-- plain memory read, no call at all.
function PlayerMods.EnemyPos(e, cls)
    local root = get(e, cls, "RootComponent")
    if not root then return nil end
    local v = get(root, "SceneComponent", "RelativeLocation")
    if v and type(v.X) == "number" then return { X = v.X, Y = v.Y, Z = v.Z } end
    return nil
end

-- RagdollStart switches the body's physics on - the very kind of work that
-- deadlocked with the game thread over the physics lock. It goes to the game
-- thread, and finds the body again there from this round's live list.
function PlayerMods.RagdollStartLater(e, cls)
    local addr = markLive(e)
    PlayerMods.InGameThread("ragdoll-start", function()
        if PlayerMods.dormant then return end
        local obj = addr and liveEnemy(addr)
        if obj then call(obj, cls, "RagdollStart") end
    end)
end

-- Bodies queued by a hit: ragdoll them, then start the fling. From the loop
-- (RagdollTick) the ragdoll itself is sent to the game thread; from a job that
-- is already ON the game thread - a punch's damage landing - it starts right
-- there, in the same moment as the hit, instead of a sweep later.
function PlayerMods.DrainRagdollQueue(onGameThread)
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
                if onGameThread then
                    call(enemy, cls, "RagdollStart")
                else
                    PlayerMods.RagdollStartLater(enemy, cls)
                end
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
end

function PlayerMods.RagdollTick()
    PlayerMods.DrainRagdollQueue(false)

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
    PlayerMods.InGameThread("hitbox-widen", function()
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
        PlayerMods.InGameThread("test-fist", function()
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
    PlayerMods.InGameThread("test-melee", function()
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

-- READY THE NEXT ROUND CONTINUOUSLY, NOT EVERY TWO SECONDS.
--
-- This is what "the shotgun is still not automatic while holding the button"
-- actually comes down to. The rechamber runs in the PRE-fire hook - before a
-- shot - so on a gun that refuses to fire until it has been worked, the hook
-- never runs again and never clears the block. The only other place it ran
-- was the weapon sweep, every two seconds, which is exactly what a shotgun
-- that fires once every couple of seconds looks like.
--
-- So while Full Auto is on, the gun in your hand is made ready every tick.
-- It is a handful of property writes on ONE object - no object-array walk -
-- and it only runs when the switch is on and a gun of yours is known.
-- AUTO FIRE: THE GUN'S OWN FIRE TIMER, AT YOUR PACE (2026-10-06).
--
-- Read out of SkeletalGun's own bytecode (research/tools/kismet4.py), not
-- guessed from session counts as the last eight rounds were:
--   * a trigger press runs OnUsed -> PreFireFunction -> FIREEVENT ->
--     FireFunction: ONE shot, if a round is chambered. Nothing in the gun or
--     in WendigoVrChar fires again while the trigger stays down - TriggerHeld
--     is written on press and release and read nowhere.
--   * Firebulletauto binds FireBulletsingle to a LOOPING timer of FireRate
--     seconds, and every tick of it is a shot if a round is chambered.
--     Letting go runs OnEndUsed -> EndFireGunLocal, which clears that timer.
--   * nothing in the game starts that timer for your gun. The old "SMG" was
--     this timer, started by the mod, at the shotgun's own 0.025 s.
-- So Auto Fire starts the timer once per hold with FireRate set to your gap,
-- the gun is kept loaded, and the game itself stops it when you let go. The
-- mod stops it as well if the gun leaves your hand with the trigger down,
-- since then no release ever reaches the gun.
--
-- NOTE THE SHAPE: all of this hangs off PlayerMods rather than file locals.
-- This chunk was already near Lua's ceiling of 200 chunk-level locals and the
-- seven a first attempt added tipped it over - which is a compile error, so
-- the entire mod stopped loading, not just this. Locals inside a function do
-- not count; chunk-level ones do.
-- Guns whose BulletFullFX the impact switch has changed, and what each had.
PlayerMods.fxWas = {}
onDropCaches(function() PlayerMods.fxWas = {} end)

-- "light guns=2" while it is on, "full" while the game has its own way.
function PlayerMods.ImpactFxLine()
    local s = PlayerMods.state
    if not (s.OptEnabled and s.OptNoImpactFX) then return "full" end
    local n = 0
    for _ in pairs(PlayerMods.fxWas) do n = n + 1 end
    return string.format("light guns=%d", n)
end

PlayerMods.autoFire = {
    held = "off", rate = 0, gap = 0,
    -- holds that started the timer, the jobs that did, the timers the mod
    -- stopped itself, and the shells the timer fired
    holds = 0, starts = 0, stops = 0, shots = 0, fireRate = "?",
    -- address -> the press count this hold was started on; every press
    -- seen (FIREEVENT runs once per press, never from the timer); and the
    -- guns whose timer the mod really did start
    started = {}, presses = {}, running = {},
    -- address -> the tick its timer last fired (or was started) on, and the
    -- timers started again after going quiet
    lastShot = {}, restarts = 0,
}

-- a world that has gone took its guns' timers with it
onDropCaches(function()
    PlayerMods.autoFire.started = {}
    PlayerMods.autoFire.presses = {}
    PlayerMods.autoFire.running = {}
    PlayerMods.autoFire.lastShot = {}
end)

-- One tick of the paced shotgun's fire timer, from its FireBulletsingle hook.
-- Never the mod's own call or the weapon sweep.
function PlayerMods.PacedShot(gun)
    if PlayerMods.inAutoFire or PlayerMods.inSweepRefill then return end
    local a = PlayerMods.autoFire
    a.shots = a.shots + 1
    local addr = addrOf(gun)
    if addr then a.lastShot[addr] = PlayerMods.tickStamp or 0 end
end

-- A press of the paced shotgun's trigger. Two clicks inside one tick read as
-- one long hold from TriggerHeld alone - and the first release has cleared
-- the timer - so a new press is what starts it again.
function PlayerMods.PacedPress(gun)
    if PlayerMods.inAutoFire or PlayerMods.inSweepRefill then return end
    local addr = addrOf(gun)
    if not addr then return end
    local p = PlayerMods.autoFire.presses
    p[addr] = (p[addr] or 0) + 1
end

-- On the game thread (keep-ready): a gun of yours that is no longer in your
-- hand. If its timer is ours, stop it - with the trigger still down when it
-- left your hand, no release will ever reach it, and the timer would run on.
function PlayerMods.AutoFireLetGo(g)
    local a = PlayerMods.autoFire
    local addr = addrOf(g)
    if not addr or not a.running[addr] then return end
    -- stopped, but the hold still counts as handled: no restart until a
    -- release or a new press
    a.running[addr] = nil
    a.stops = a.stops + 1
    pcall(function() g:EndFireGunLocal() end)
end

-- THE PACE, AS SECONDS BETWEEN BULLETS.
--
-- "fastest is 1 bullet per 0.10 sec's / slowest is 1 bullet per 0.50". It was
-- shots-a-second from 0 to 20, which let a shotgun run like an SMG and put the
-- number in the opposite unit from the way it is thought about. Now it is the
-- gap itself, held between those two limits here - whatever the settings file
-- says - with an on/off of its own, since "0 = off" cannot live inside it.
PlayerMods.AUTO_GAP_MIN, PlayerMods.AUTO_GAP_MAX = 0.10, 0.50
-- Enum_FireStates 0, "Auto" in the shipped pak - what the AK ships as
PlayerMods.FIRE_AUTO = 0

-- THE AK'S SPEED IS ITS TIMELINES' PLAY RATE.
--
-- "AK speed slider is not working." It set the AK's FireRate - but SkeletalGun_C
-- runs its automatic on fixed-rate timelines (TL_750rpm_A/b, TL_1000rpm_a/b),
-- and a UTimelineComponent has a play rate, not a fire rate. So the slider is
-- a speed: 1.0 is the AK's own, 2.0 twice as fast, 0.5 half, held between
-- these. Each is read back afterwards, so status.txt says what actually took.
PlayerMods.AK_SPEED_MIN, PlayerMods.AK_SPEED_MAX = 0.5, 3.0
PlayerMods.AK_TIMELINES = { "TL_750rpm_A", "TL_750rpm_b", "TL_1000rpm_a", "TL_1000rpm_b",
                           -- the AK's own bolt, 0.07 s each way in the pak
                           "TL_akBoltback", "TL_akboltfwd" }
PlayerMods.akShips = {}        -- address -> true for a gun that ships automatic
PlayerMods.akRateSet = {}      -- address -> play rate last applied
PlayerMods.akRead = "none"     -- what the timelines read back
onDropCaches(function() PlayerMods.akShips = {} PlayerMods.akRateSet = {} end)

function PlayerMods.AkSpeed()
    local v = tonumber(PlayerMods.state.AkSpeed) or 1.0
    if v < PlayerMods.AK_SPEED_MIN then v = PlayerMods.AK_SPEED_MIN end
    if v > PlayerMods.AK_SPEED_MAX then v = PlayerMods.AK_SPEED_MAX end
    return v
end

-- Called at the end of the gun's own fire hook - the game thread, with the gun
-- certainly alive. Never from the sweep, which runs on the loop thread: this
-- calls into the engine, not just a property write.
function PlayerMods.ApplyAkSpeed(gun)
    if PlayerMods.inSweepRefill then return end
    local a = addrOf(gun)
    if not a or not PlayerMods.akShips[a] then return end
    local want = PlayerMods.state.FullAuto and PlayerMods.AkSpeed() or 1.0
    if PlayerMods.akRateSet[a] == want then return end
    local read = nil
    for _, name in ipairs(PlayerMods.AK_TIMELINES) do
        local tl = get(gun, GUN_SKEL, name)
        if isValid(tl) then
            pcall(function() tl:SetPlayRate(want) end)
            local okR, r = pcall(function() return tl:GetPlayRate() end)
            if okR and type(r) == "number" then read = r end
        end
    end
    PlayerMods.akRateSet[a] = want
    PlayerMods.akRead = read and string.format("%.2f", read) or "none"
end

-- Is this the gun Auto Fire paces? The pump shotgun, while Auto Fire is on -
-- read from what Full Auto remembered about it, so nothing is read here.
function PlayerMods.IsPaced(gun)
    if PlayerMods.AutoFireGap() == nil then return false end
    local a = addrOf(gun)
    local w = a and pumpWas[a]
    return w ~= nil and w[5] == true
end

-- THE GUN IN YOUR HAND, but only if it is from THIS round.
--
-- It used to be set when you fired and cleared only when isValid() said no -
-- which it does not, for a half-destroyed actor. So after a round ended the
-- loop kept writing into your old gun, ten times a second, until the game
-- freed it. Those writes never went through the job door, so lastop.txt
-- could not name them and kept saying beam-paint instead.
-- EVERY GUN IN YOUR HANDS, from this round only - the same stamp and the
-- same refusal as HeldGun, for however many you are holding.
PlayerMods.yourGuns = {}
onDropCaches(function() PlayerMods.yourGuns = {} end)

function PlayerMods.YourGuns()
    local out = {}
    for a, e in pairs(PlayerMods.yourGuns) do
        if e.gen ~= PlayerMods.gen or not PlayerMods.StillValid(e.g) then
            PlayerMods.yourGuns[a] = nil
        else
            out[#out + 1] = e.g
        end
    end
    return out
end

function PlayerMods.HeldGun()
    local g = PlayerMods.heldGun
    if g == nil then return nil end
    if PlayerMods.heldGunGen ~= PlayerMods.gen or not PlayerMods.StillValid(g) then
        PlayerMods.heldGun = nil
        return nil
    end
    return g
end

function PlayerMods.AutoFireGap()
    local s = PlayerMods.state
    if not s.AutoFireOn then return nil end
    local g = tonumber(s.AutoFireGap) or 0.25
    if g < PlayerMods.AUTO_GAP_MIN then g = PlayerMods.AUTO_GAP_MIN end
    if g > PlayerMods.AUTO_GAP_MAX then g = PlayerMods.AUTO_GAP_MAX end
    return g
end

function PlayerMods.AutoFireTick()
    local s, a = PlayerMods.state, PlayerMods.autoFire
    local gap = PlayerMods.AutoFireGap()
    a.gap = gap or 0.0
    a.rate = gap and (1.0 / gap) or 0.0
    if not s.FullAuto or not gap then
        -- switched off mid-hold: stop any timer it started
        a.started = {}
        for addr in pairs(a.running) do
            a.running[addr] = nil
            a.stops = a.stops + 1
            PlayerMods.InGameThread("auto-stop", function()
                local e = PlayerMods.yourGuns[addr]
                if not e or e.gen ~= PlayerMods.gen or not PlayerMods.StillValid(e.g) then return end
                pcall(function() e.g:EndFireGunLocal() end)
            end)
        end
        a.held = "off"
        return
    end
    -- THE PACED GUN AMONG ALL OF YOURS, not "the last one fired": with the
    -- shotgun in one hand and the AK in the other, the AK firing last used to
    -- hide the shotgun's trigger from this completely.
    local mine = PlayerMods.YourGuns()
    if #mine == 0 then a.held = "nogun" return end
    local any = false
    a.held = "native"
    for _, g in ipairs(mine) do
        if PlayerMods.IsPaced(g) then
            any = true
            local addr = addrOf(g)
            -- the gun's own "you are holding the trigger" flag
            local held = get(g, GUN_SKEL, "TriggerHeld")
            if held == true or a.held ~= "true" then a.held = tostring(held) end
            if held ~= true then
                -- let go: OnEndUsed has already cleared the gun's timer
                if addr then a.started[addr] = nil a.running[addr] = nil end
            elseif addr and a.running[addr] and a.started[addr] ~= nil
                   and (PlayerMods.tickStamp or 0) - (a.lastShot[addr] or 0)
                       > math.floor(gap * 20) + 3 then
                -- QUIET FOR TWO GAPS UNDER A HELD TRIGGER. The gun cancels
                -- its own fire timer the moment a tick finds the chamber
                -- empty (FireFunction's dry path clears FireTimer); the hook
                -- loads it first, but should a tick ever get there before it,
                -- the hold would go silent. Start it again.
                a.started[addr] = nil
                a.restarts = a.restarts + 1
            elseif addr and (a.started[addr] == nil
                             or (a.presses[addr] or 0) > a.started[addr]) then
                -- A NEW HOLD: start the gun's own fire timer, once. Your press
                -- has already fired the first shell; the timer's first tick
                -- is one gap later.
                a.started[addr] = a.presses[addr] or 0
                a.holds = a.holds + 1
                PlayerMods.InGameThread("auto-start", function()
                    if PlayerMods.dormant then return end
                    -- that gun, found again from this round's list at the
                    -- moment the job runs - never carried in
                    local e = PlayerMods.yourGuns[addr]
                    if not e or e.gen ~= PlayerMods.gen or not PlayerMods.StillValid(e.g) then return end
                    local gg = e.g
                    if not PlayerMods.IsGunHeld(gg) then return end
                    -- let go before the job ran: nothing to start
                    if get(gg, GUN_SKEL, "TriggerHeld") ~= true then
                        a.started[addr] = nil
                        return
                    end
                    -- the timer's period is read as it starts
                    set(gg, GUN_SKEL, "FireRate", gap)
                    RechamberSkeletalGun(gg)
                    PlayerMods.inAutoFire = true
                    pcall(function() gg:Firebulletauto() end)
                    PlayerMods.inAutoFire = false
                    a.running[addr] = true
                    a.lastShot[addr] = PlayerMods.tickStamp or 0
                    a.starts = a.starts + 1
                    local fr = get(gg, GUN_SKEL, "FireRate")
                    a.fireRate = type(fr) == "number" and string.format("%.2f", fr) or "?"
                end)
            end
        end
    end
    -- every gun but the pump shotgun runs on the game's own automatic
    if not any then a.held = "native" end
end

-- "rate=2.0 gap=0.50 ... held=true holds=3 starts=3 stops=0 restarts=0 shots=12 firerate=0.50"
-- holds/starts: holds that started the gun's fire timer, and the jobs that
-- did. stops: timers the mod stopped itself (gun out of your hand, or Auto
-- Fire off mid-hold). restarts: timers started again after going quiet under
-- a held trigger. shots: ticks of that timer. firerate: its period, read back
-- from the gun as it started.
function PlayerMods.AutoFireLine()
    local a = PlayerMods.autoFire or {}
    return string.format(
        "rate=%.1f gap=%.2f akspeed=%.1f akread=%s held=%s holds=%d starts=%d stops=%d " ..
        "restarts=%d shots=%d firerate=%s",
        a.rate or 0, a.gap or 0, PlayerMods.AkSpeed(), tostring(PlayerMods.akRead or "none"),
        tostring(a.held or "?"), a.holds or 0, a.starts or 0, a.stops or 0,
        a.restarts or 0, a.shots or 0, tostring(a.fireRate or "?"))
end

local function keepReady()
    local s = PlayerMods.state
    if not s.FullAuto then return end
    if #PlayerMods.YourGuns() == 0 then return end
    -- ON THE GAME THREAD, and for EVERY gun in your hands - not just the last
    -- one fired. With two in hand, the shotgun used to be skipped whenever the
    -- other gun had fired last, and it had to be racked by hand. One job per
    -- tick, and every gun looked up again inside it.
    PlayerMods.InGameThread("keep-ready", function()
        if PlayerMods.dormant then return end
        for _, g in ipairs(PlayerMods.YourGuns()) do
            if PlayerMods.IsGunHeld(g) then
                -- the paced shotgun too: its timer, not its chamber, is the pace
                RechamberSkeletalGun(g)
                PlayerMods.rechamberFast = (PlayerMods.rechamberFast or 0) + 1
            else
                PlayerMods.AutoFireLetGo(g)
            end
        end
    end)
end

function PlayerMods.FastTick()
    -- the game thread re-asks every remembered path, once a tick
    if next(PlayerMods.pathOf) ~= nil then
        PlayerMods.InGameThread("still-check", PlayerMods.CheckRemembered)
    end
    keepReady()
    PlayerMods.AutoFireTick()
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
            elseif boxCorpse then
                boxCorpse(e, ENEMY_CLASS)
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
            if dead and boxCorpse then boxCorpse(entry.obj, entry.cls) end
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
                -- the class is known HERE, once every couple of seconds,
                -- because this loop is what finds the guns in the first place
                forEachOf(gunCls, function(g)
                    local a = addrOf(g)
                    if a then gunClassOf[a] = gunCls end
                    -- topping a gun up is not a trigger pull, and the
                    -- shots-per-second meter lives inside this function
                    PlayerMods.inSweepRefill = true
                    RefillSkeletalGun(g)
                    PlayerMods.inSweepRefill = false
                end)
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

-- EXPORTED AS PLAIN NUMBERS (2026-09-17).
--
-- The ESP tab, the 3D boxes and aim assist all need to know where enemies are.
-- None of them is allowed to hold an enemy: a stored reference outlives the
-- body, and a struct read off a dead one is the 0x268 crash. So this scan -
-- which already runs straight after the one sweep proven to return only live
-- enemies - copies each into a table of numbers, and that table is all anything
-- else ever sees. PlayerMods.espTargets holds no objects at all.
--
-- The health field differs by family and is read only on the class that has
-- it, like the death flags.
local ESP_HP = {
    ALS_Player_CharacterBPai_C = "hp",
    BP_NPC_Man_C               = "HealthOverall",
    BP_MeleeAI_Character_C     = "Health",
}

PlayerMods.espTargets = {}   -- nearest first; see esp_plus.lua for the fields
PlayerMods.espPlayer  = nil  -- { x, y, z, fx, fy } at scan time

-- Previous position and the most health seen, per address - both only numbers.
-- An address can be reused by a new enemy, so a class change resets the entry
-- and a velocity that is physically impossible is thrown away.
local espPrev, espHpMax = {}, {}
onDropCaches(function() espPrev = {} espHpMax = {} PlayerMods.espTargets = {} end)

-- BODY PARTS FOR THE AIM (2026-09-18)
--
-- Silent Aim needs to know where a head IS, not where a head usually is on a
-- standing body. Both enemy skeletons in the pak use the stock mannequin names
-- (skm_cultboy_IK_base_v03_Skeleton, skm_human_base_Skeleton: head, neck_01,
-- spine_03, spine_01, pelvis, lowerarm_r, calf_l), so one bone table serves
-- all three families. Human NPCs also carry hitbox components ON those bones
-- (CritZone_Head, _Neck, _Heart, _PelvisFront, _Femoral_L) - where one exists
-- it is used instead, since it is exactly what their damage code checks.
--
-- Stored as OFFSETS from the actor origin, so the aim can add them to a
-- velocity-predicted position. Read in this scan only, off the object this
-- sweep returned - never later.
local AIM_BONES = {
    head = "head", neck = "neck_01", chest = "spine_03", stomach = "spine_01",
    pelvis = "pelvis", arms = "lowerarm_r", legs = "calf_l",
}
local AIM_PART_ORDER = { "head", "neck", "chest", "stomach", "pelvis", "arms", "legs" }
local NPC_ZONES = {
    head = "CritZone_Head", neck = "CritZone_Neck", chest = "CritZone_Heart",
    pelvis = "CritZone_PelvisFront", legs = "CritZone_Femoral_L",
}
local AIM_PARTS_MAX = 8     -- nearest enemies that get bone reads per scan

local function readParts(e, cls, px, py, pz, which)
    local parts, n = {}, 0
    local mesh = get(e, cls, "Mesh")
    local meshOk = isValid(mesh)
    local mx, my, mz
    if meshOk then
        -- A missing bone makes GetSocketLocation hand back the component's own
        -- location. Compare against it so a miss falls back instead of aiming
        -- every part at the feet.
        local okM, ml = pcall(function() return mesh:K2_GetComponentLocation() end)
        if okM and ml and type(ml.X) == "number" then mx, my, mz = ml.X, ml.Y, ml.Z end
    end
    for _, key in ipairs(which) do
        local x, y, z
        local zone = (cls == "BP_NPC_Man_C") and NPC_ZONES[key] or nil
        if zone then
            local c = get(e, cls, zone)
            if isValid(c) then
                local okZ, zl = pcall(function() return c:K2_GetComponentLocation() end)
                if okZ and zl and type(zl.X) == "number" then x, y, z = zl.X, zl.Y, zl.Z end
            end
        end
        if not x and meshOk and mx then
            local okS, sl = pcall(function() return mesh:GetSocketLocation(AIM_BONES[key]) end)
            if okS and sl and type(sl.X) == "number" then
                local d = math.abs(sl.X - mx) + math.abs(sl.Y - my) + math.abs(sl.Z - mz)
                if d > 0.5 then x, y, z = sl.X, sl.Y, sl.Z end
            end
        end
        if x then
            parts[key] = { x - px, y - py, z - pz }
            n = n + 1
        end
    end
    return n > 0 and parts or nil
end

function PlayerMods.ScanESP()
    local s = PlayerMods.state
    local aimOn = s.SilentAim or s.AimAssist
    -- stand down with the rest of the mod while a round tears down, and make
    -- sure nothing keeps drawing or aiming at the wave that just died
    if PlayerMods.dormant then
        PlayerMods.espTargets = {}
        return
    end
    if not (s.EnemyESP or aimOn) then
        if #PlayerMods.esp > 0 then PlayerMods.esp = {} end
        if #PlayerMods.espTargets > 0 then PlayerMods.espTargets = {} end
        return
    end

    local pawn = PlayerMods.GetPawn()
    if not isValid(pawn) then PlayerMods.esp = {} PlayerMods.espTargets = {} return end

    local okL, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    local okF, fwd = pcall(function() return pawn:GetActorForwardVector() end)
    if not (okL and okF and loc and fwd) then
        PlayerMods.esp = {} PlayerMods.espTargets = {}
        return
    end

    local now = os.clock()
    local found = {}
    local seen = {}
    -- the objects, only for the part reads below; this table dies with the call
    local objOf = {}
    forEachSettledEnemy(function(e, cls)
        local p = PlayerMods.EnemyPos(e, cls)
        if not p then return end
        local dx, dy, dz = p.X - loc.X, p.Y - loc.Y, p.Z - loc.Z
        local d = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))

        local t = { dist = d / 100.0,           -- cm -> metres
                    clock = bearingClock(fwd.X, fwd.Y, dx, dy),
                    cls = cls, x = p.X, y = p.Y, z = p.Z, t = now,
                    dz = dz / 100.0, vx = 0, vy = 0, vz = 0 }
        objOf[t] = e

        local okA, addr = pcall(function() return e:GetAddress() end)
        if okA and addr then
            seen[addr] = true
            -- a NUMBER: lets the aim queue damage and the ESP mark its target
            t.addr = addr
            local prev = espPrev[addr]
            if prev and prev.cls == cls then
                local dtS = now - prev.t
                if dtS > 0.05 then
                    local vx, vy, vz = (p.X - prev.x) / dtS, (p.Y - prev.y) / dtS, (p.Z - prev.z) / dtS
                    -- faster than ~9 m/s is a recycled address, not a sprint
                    if (vx * vx + vy * vy + vz * vz) < (900.0 * 900.0) then
                        t.vx, t.vy, t.vz = vx, vy, vz
                    end
                end
            end
            espPrev[addr] = { x = p.X, y = p.Y, z = p.Z, t = now, cls = cls }

            local field = ESP_HP[cls]
            if field then
                local hp = get(e, cls, field)
                if type(hp) == "number" then
                    local m = espHpMax[addr]
                    if not m or m.cls ~= cls then m = { cls = cls, max = hp } end
                    if hp > m.max then m.max = hp end
                    espHpMax[addr] = m
                    t.hp, t.hpmax = hp, m.max
                end
            end
        end
        found[#found + 1] = t
    end)

    -- forget anyone the sweep did not return, so the tables cannot grow all round
    for a in pairs(espPrev) do if not seen[a] then espPrev[a] = nil end end
    for a in pairs(espHpMax) do if not seen[a] then espHpMax[a] = nil end end

    table.sort(found, function(a, b) return a.dist < b.dist end)

    -- body parts for the aim, nearest enemies in range only, and only the
    -- part that is actually selected unless NEAREST/RANDOM needs them all
    if aimOn then
        local pick = math.floor((s.AimBone or 0) + 0.5)
        local which = (pick >= 0 and pick <= 6) and { AIM_PART_ORDER[pick + 1] } or AIM_PART_ORDER
        local range = (s.AimRange or 60)
        local want = {}
        for _, t in ipairs(found) do
            if #want >= AIM_PARTS_MAX or t.dist > range then break end
            local e = objOf[t]
            if e then want[#want + 1] = { t, e } end
        end
        -- THE BONES ARE READ ON THE GAME THREAD. GetSocketLocation is an
        -- engine call, and from this loop it raced the round end destroying
        -- the very body it was asking about (7 October 05:29). The game
        -- thread is the one doing the destroying, so there it cannot happen
        -- halfway through a read. The parts land on these same target
        -- entries a moment later.
        if #want > 0 then
            PlayerMods.InGameThread("esp-parts", function()
                if PlayerMods.dormant then return end
                for _, w in ipairs(want) do
                    local t, e = w[1], w[2]
                    if isValid(e) and not isEnemyDead(e, t.cls) then
                        local okP, parts = pcall(readParts, e, t.cls, t.x, t.y, t.z, which)
                        if okP then t.parts = parts end
                    end
                end
            end)
        end
    end
    objOf = nil

    PlayerMods.espPlayer = { x = loc.X, y = loc.Y, z = loc.Z, fx = fwd.X, fy = fwd.Y }
    -- replace, never mutate: the aim hook reads this from the game thread
    PlayerMods.espTargets = found

    local rows = {}
    for i = 1, math.min(PlayerMods.ESP_ROWS, #found) do rows[i] = found[i] end
    PlayerMods.esp = rows
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
    local ep = PlayerMods.EnemyPos(e, cls)
    if pp and ep then
        local vx, vy = ep.X - pp.X, ep.Y - pp.Y
        local len = math.sqrt((vx * vx) + (vy * vy))
        if len > 1.0 then dx, dy = vx / len, vy / len end
    end

    PlayerMods.RagdollStartLater(e, cls)
    flingEnemy(e, cls, dx, dy, PlayerMods.state.FistLaunchForce or 900.0)
end

---------------------------------------------------------------------------
-- ESP BODY BOXES (2026-09-18)
---------------------------------------------------------------------------
-- "The box is connected to their body."
--
-- Every enemy is an ACharacter whose root is a UCapsuleComponent wrapped round
-- the whole body. A shape component draws itself as a wireframe whenever it is
-- not hidden in game - and unlike DrawDebugBox, that is NOT compiled out of a
-- Shipping build. The engine already moves the capsule with the enemy every
-- frame, so un-hiding it gives a box that stays locked to them with no
-- per-frame work from us at all. Human NPCs also carry hitbox shapes on their
-- bones (CritZone_*), which show where their damage zones are.
--
-- The rules this follows, all from crashes in this game:
--   * Only ever touched via the object the CURRENT sweep returned.
--   * Once per enemy (plus a slow re-assert), never per tick.
--   * Render-state changes run on the GAME THREAD - doing them from the loop
--     thread is a documented 0x268 cause.
--   * Nothing is spawned, attached or moved. Two scalar setters and a colour.
--   * A wave wipe is left alone: those bodies are about to be destroyed, and
--     touching them then is the round-end crash.

local BOX_COLOURS = {
    { 255, 40, 40 },  { 40, 255, 80 },  { 60, 140, 255 }, { 255, 230, 40 },
    { 40, 240, 255 }, { 255, 60, 255 }, { 255, 255, 255 }, { 255, 140, 0 },
}
-- BY TYPE: cultists red, zombies green, human NPCs yellow
local TYPE_COLOUR = { ALS_Player_CharacterBPai_C = 1, BP_MeleeAI_Character_C = 2, BP_NPC_Man_C = 4 }
local HITBOX_ZONES = {
    "CritZone_Head", "CritZone_Neck", "CritZone_Heart", "CritZone_Lung_L",
    "CritZone_Lung_R", "CritZone_Femoral_L", "CritZone_Femoral_R", "CritZone_PelvisFront",
}
-- about 10 s at the ~3 Hz sweep; also catches a new enemy reusing an
-- address. It reads the shape's own hidden flag first, so a re-assert that
-- has nothing to do now costs one property read and no engine calls at all.
local BOX_REASSERT_SWEEPS = 30

local boxState = {}     -- [address] = { key, body, parts, cls, seen, at }
onDropCaches(function() boxState = {} end)
PlayerMods.boxStats = { live = 0, shown = 0, hidden = 0, corpses = 0, calls = 0,
                        skipped = 0 }

local corpseStamp, corpseCount = -1, 0


-- ONE HUE FOR THE WHOLE MOD, so the beam and the boxes cycle together rather
-- than drifting apart.
--
-- STEPPED ON PURPOSE. Both consumers only repaint when their colour key
-- changes, and that is what took the beam from 1968 game-thread jobs in the
-- session that froze to 139 in the one that did not. A continuously varying
-- colour would repaint on every pass and hand the freeze straight back. At
-- RGB_PER_SEC changes a second the work stays bounded and it still looks
-- like a rainbow.
PlayerMods.RGB_STEPS = 36
PlayerMods.RGB_PER_SEC = 3

function PlayerMods.RgbStep()
    local step = math.floor(os.clock() * PlayerMods.RGB_PER_SEC)
    local h = ((step % PlayerMods.RGB_STEPS) / PlayerMods.RGB_STEPS) * 6.0
    local i = math.floor(h)
    local f = h - i
    local q, t = 1.0 - f, f
    local r, g, b
    if i == 0 then r, g, b = 1.0, t, 0.0
    elseif i == 1 then r, g, b = q, 1.0, 0.0
    elseif i == 2 then r, g, b = 0.0, 1.0, t
    elseif i == 3 then r, g, b = 0.0, q, 1.0
    elseif i == 4 then r, g, b = t, 0.0, 1.0
    else r, g, b = 1.0, 0.0, q end
    return step, { math.floor(r * 255 + 0.5),
                   math.floor(g * 255 + 0.5),
                   math.floor(b * 255 + 0.5) }
end

local function boxWant(cls, addr)
    local s = PlayerMods.state
    local body = s.ESPBoxes == true
    local parts = (s.ESPHitboxes == true) and cls == "BP_NPC_Man_C"
    if not body and not parts then return nil end
    local ci = math.floor((s.ESPBoxColor or 0) + 0.5)
    if ci < 1 or ci > #BOX_COLOURS then ci = TYPE_COLOUR[cls] or 1 end
    -- THE AIM CONE, MADE VISIBLE. The one enemy the cone is holding right now
    -- wears a different colour, so the lock is on the enemy rather than only
    -- in a line of text.
    local marked = false
    if s.AimConeMark ~= false and addr ~= nil and addr == PlayerMods.coneTarget then
        local mi = math.floor((s.AimConeColor or 6) + 0.5) + 1
        if mi >= 1 and mi <= #BOX_COLOURS then
            ci = mi
            marked = true
        end
    end
    -- RGB, unless this is the one the cone is holding: that enemy keeps his
    -- own colour, because the whole point of the mark is to stand out from
    -- the others, and a rainbow everyone is wearing cannot do that.
    if s.ESPRgb == true and not marked then
        local step, col = PlayerMods.RgbStep()
        local n = step % PlayerMods.RGB_STEPS
        -- THE STEP GOES IN `ci` AS WELL AS THE KEY. boxTick decides whether a
        -- shape needs repainting from `styleChanged`, which compares ci - not
        -- the key - so returning the user's chosen index here left the colour
        -- changing on paper and never reaching the screen. 1000+ cannot
        -- collide with a real palette index.
        return string.format("%s%sR%d", body and "B" or "-",
                             parts and "H" or "-", n),
               body, parts, col, 1000 + n
    end
    return string.format("%s%s%d%s", body and "B" or "-", parts and "H" or "-",
                         ci, marked and "T" or "-"),
           body, parts, BOX_COLOURS[ci], ci
end

-- What to do with one group of shapes (the body capsule, or the hit zones),
-- given what it was and what it should be:
--   nil     leave it alone
--   "show"  un-hide (colour first)
--   "swap"  already showing, new colour: bounce hidden->shown so the proxy
--           rebuilds with the colour
--   "hide"  hide it
local function shapeAction(was, want, colourChanged, reassert)
    if want and not was then return "show" end
    if was and not want then return "hide" end
    if want and colourChanged then return "swap" end
    if want and reassert then return "show" end
    return nil
end

-- Queue the shape changes for one live enemy, on the game thread.
-- THE POINTERS ARE NOT CARRIED ACROSS THE GAP (2026-09-21).
--
-- This used to read the CapsuleComponent and the hit zones HERE, at queue
-- time, and hold them until the game thread reached the job. An enemy
-- destroyed in between leaves those as corpse pointers, and the first thing
-- the job does with one is copy its ShapeColor struct - a read at a small
-- offset off a freed object, which is exactly the shape of the
-- EXCEPTION_ACCESS_VIOLATION reading 0x268 that has now crashed six sessions.
-- isValid() is no defence: it answers true for a half-destroyed actor.
--
-- So carry NAMES, look the components up when the job actually runs, and only
-- after checking the enemy is still in the registry the sweep rebuilds.
local function applyShapes(e, cls, bodyAct, partsAct, colour, addr, allowDead)
    local names = {}
    if bodyAct then names[#names + 1] = { "CapsuleComponent", bodyAct } end
    if partsAct and cls == "BP_NPC_Man_C" then
        for _, zone in ipairs(HITBOX_ZONES) do
            names[#names + 1] = { zone, partsAct }
        end
    end
    if #names == 0 then return false end
    if not isValid(e) then return false end

    PlayerMods.InGameThread("esp-boxes", function()
        -- a wave collapsed between the sweep and now: touch nothing
        if PlayerMods.dormant then return end
        if not isValid(e) then return end
        -- The sweep that queued this is the one that proved him alive. If a
        -- later sweep has dropped him, he is gone and his components went
        -- with him - and the box goes with them, so there is nothing to do.
        if not allowDead and addr and liveObj[addr] == nil then
            PlayerMods.boxStats.stale = (PlayerMods.boxStats.stale or 0) + 1
            return
        end
        for _, pair in ipairs(names) do
            local comp, act = get(e, cls, pair[1]), pair[2]
            if isValid(comp) then
                -- READ BEFORE YOU WRITE.
                --
                -- The slow re-assert exists to catch a new enemy handed a
                -- dead one's address, and it used to blind-fire hide+show at
                -- every shape every few seconds: 13,086 native calls in one
                -- session, almost all of them asking for what was already
                -- true. One property read tells us, and costs nothing.
                local okH, hidden = pcall(function() return comp.bHiddenInGame end)
                local known = okH and type(hidden) == "boolean"
                if act == "hide" then
                    if not (known and hidden) then
                        pcall(function() comp:SetHiddenInGame(true, false) end)
                        PlayerMods.boxStats.calls = PlayerMods.boxStats.calls + 1
                    else
                        PlayerMods.boxStats.skipped = (PlayerMods.boxStats.skipped or 0) + 1
                    end
                elseif act == "show" and known and hidden == false then
                    -- already showing, and this is not a colour change
                    PlayerMods.boxStats.skipped = (PlayerMods.boxStats.skipped or 0) + 1
                else
                    -- NOTHING TOUCHES DepthPriorityGroup HERE ANY MORE.
                    --
                    -- UCapsuleComponent's scene proxy draws its outline by
                    -- calling the engine's wireframe helper with SDPG_World
                    -- written in as a literal; the component's own value is
                    -- never consulted. Writing it was 12,951 native property
                    -- writes in one session that could not possibly do
                    -- anything. There IS no through-walls answer for a box:
                    -- the glow that used to be offered here repainted a live
                    -- skeletal mesh and deadlocked the game, and is gone. The
                    -- ESP TEXT shows through everything; a box cannot.
                    if colour then
                        pcall(function()
                            local sc = comp.ShapeColor
                            sc.R, sc.G, sc.B, sc.A = colour[1], colour[2], colour[3], 255
                        end)
                    end
                    if act == "swap" then pcall(function() comp:SetHiddenInGame(true, false) end) end
                    -- propagate=false: the enemy's mesh hangs off this capsule
                    -- and must not be hidden or shown with it
                    pcall(function() comp:SetHiddenInGame(false, false) end)
                    PlayerMods.boxStats.calls = PlayerMods.boxStats.calls + 1
                end
            end
        end
    end)
    return true
end

-- From the HitWatch sweep, for every live enemy.
local function boxTick(e, cls, addr)
    if not addr then return end
    local key, body, parts, colour, ci = boxWant(cls, addr)
    local st = boxState[addr]
    if st and st.cls ~= cls then st = nil end
    local wasBody, wasParts = st and st.body or false, st and st.parts or false

    if key == nil then
        -- off: hide what we showed, once
        if wasBody or wasParts then
            applyShapes(e, cls, wasBody and "hide" or nil, wasParts and "hide" or nil,
                        nil, addr)
            PlayerMods.boxStats.hidden = PlayerMods.boxStats.hidden + 1
            boxState[addr] = { key = "off", cls = cls, seen = liveSweep, at = liveSweep }
        elseif st then
            st.seen = liveSweep
        end
        return
    end

    -- slow re-assert: a plain "show", which the engine ignores when it is
    -- already showing - and which recovers a new enemy that was given a dead
    -- one's address
    local reassert = st ~= nil and st.key == key and (liveSweep - (st.at or 0)) >= BOX_REASSERT_SWEEPS
    if st and st.key == key and not reassert then
        st.seen = liveSweep
        return
    end

    local styleChanged = st ~= nil and st.ci ~= ci
    local bodyAct = shapeAction(wasBody, body, styleChanged, reassert)
    local partsAct = shapeAction(wasParts, parts, styleChanged, reassert)
    applyShapes(e, cls, bodyAct, partsAct, colour, addr)
    if not st or st.key ~= key then
        PlayerMods.boxStats.shown = PlayerMods.boxStats.shown + 1
    end
    boxState[addr] = { key = key, body = body, parts = parts, ci = ci,
                       cls = cls, seen = liveSweep, at = liveSweep }
end

---------------------------------------------------------------------------
-- SEEING THEM THROUGH A WALL (2026-09-18 later)
---------------------------------------------------------------------------
-- WHY THERE IS NO "SEE THEM THROUGH WALLS"
---------------------------------------------------------------------------
-- A shape component draws itself with the engine's wireframe helper, and that
-- helper is handed SDPG_World as a literal - the component's own
-- DepthPriorityGroup is never consulted. So no flag on the box will ever do
-- it, however often the box is re-applied.
--
-- What decides is the MATERIAL, and this game ships one that draws over
-- everything (M_GlowingText_NoDepth, the menu's). Putting it on the enemy's
-- own mesh DID work - and the first session it ran, the game deadlocked while
-- shooting one of the enemies wearing it. Swapping materials on a live
-- skinned mesh makes the render thread rebuild that mesh while the game is
-- already rebuilding it for gore. Not worth a frozen game, so it is gone.
--
-- The headset ESP text still draws over everything, because that component is
-- the one the game itself assigns that material to.

-- A body box over a corpse looks like a live enemy, so hide it on death - but
-- not for zombies (bDestroyOnDeath: the body is on its way out), and not when a
-- whole wave dies at once (the round is tearing those down).
boxCorpse = function(e, cls)
    if cls == "BP_MeleeAI_Character_C" then return end
    local okA, addr = pcall(function() return e:GetAddress() end)
    if not okA or not addr then return end
    local st = boxState[addr]
    if not st or not (st.body or st.parts) then return end
    local stamp = PlayerMods.tickStamp or 0
    if corpseStamp ~= stamp then corpseStamp, corpseCount = stamp, 0 end
    if corpseCount >= 3 then return end
    corpseCount = corpseCount + 1
    boxState[addr] = { key = "dead", cls = cls, seen = liveSweep, at = liveSweep }
    -- The corpse path is the one case where the enemy is MEANT to be on his
    -- way out, so the registry check is skipped - but the components are
    -- still looked up fresh inside the job rather than carried to it.
    applyShapes(e, cls, st.body and "hide" or nil, st.parts and "hide" or nil,
                nil, addr, true)
    PlayerMods.boxStats.corpses = PlayerMods.boxStats.corpses + 1
end

---------------------------------------------------------------------------
-- EXTRA DAMAGE FROM THE AIM (2026-09-18)
---------------------------------------------------------------------------
-- The aim hook queues an enemy ADDRESS; this applies the damage against the
-- object the next sweep returns, on the game thread. A body that is gone by
-- then is silently dropped.
local SHOT_HP = {
    ALS_Player_CharacterBPai_C = "hp",
    BP_NPC_Man_C               = "HealthOverall",
    BP_MeleeAI_Character_C     = "Health",
}

-- One line saying where every made-to-hit shot went.
function PlayerMods.ShotWhyLine()
    local w = PlayerMods.shotWhy or {}
    return string.format("queued=%d landed=%d noclass=%d full=%d notlive=%d " ..
                         "dead=%d nodrop=%d game=%d killed=%d gamefail=%d " ..
                         "noeffect=%d via=%s",
        w.queued or 0, PlayerMods.shotDamage or 0, w.noclass or 0, w.full or 0,
        w.notlive or 0, w.dead or 0, w.nodrop or 0, w.game or 0, w.killed or 0,
        w.gamefail or 0, w.noeffect or 0, tostring(w.via or "none"))
end
local shotQueue = {}
onDropCaches(function() shotQueue = {} end)
PlayerMods.shotDamage = 0

-- Returns true when the hit was accepted, so the aim can tell "we made him
-- take it" from "we could not". A whole session read madehit=93 shotdamage=3
-- and there was no way to see which step lost the other 90.
PlayerMods.shotWhy = { noclass = 0, full = 0, queued = 0, notlive = 0,
                       dead = 0, nodrop = 0, game = 0, killed = 0, gamefail = 0 }

function PlayerMods.QueueShotDamage(addr, cls, amount, hit)
    if not addr then return false end
    if not SHOT_HP[cls] then
        PlayerMods.shotWhy.noclass = PlayerMods.shotWhy.noclass + 1
        return false
    end
    -- 64, not 24: full auto into a crowd fills 24 in well under a second, and
    -- a dropped entry is a shot that silently did nothing.
    if #shotQueue >= 64 then
        PlayerMods.shotWhy.full = PlayerMods.shotWhy.full + 1
        return false
    end
    shotQueue[#shotQueue + 1] = { addr = addr, cls = cls, dmg = amount or 100,
                                  hit = hit }
    PlayerMods.shotWhy.queued = PlayerMods.shotWhy.queued + 1
    return true
end

-- SILENT AIM DAMAGE: THE ENEMY'S OWN ROUTINES, TRIED IN ORDER (2026-09-27).
--
-- Round one wrote health directly, which left NPCs ALIVE below zero: the one-
-- second knock-down. Round two called BulletDamage - the call a real bullet
-- makes - and in the game it failed every time (gamefail=623 of 623). Its
-- FHitResult goes BY VALUE, and nothing from here can say how this UE4SS
-- wants one of those built. So, exactly like the rotation shapes in
-- aim_assist: try the ways the enemy himself takes damage, in order; keep
-- the first that visibly hurts him; and write why any of them failed into
-- status.txt (shoterr=), so the next session names the reason instead of
-- hiding it the way the last one did.
--
-- Every way is the enemy's OWN routine. Whatever works, the game still
-- decides the death - no health number is ever written for these two.
PlayerMods.DAMAGE_WAYS = {
    BP_NPC_Man_C = {
        { "bullet", function(o, d, h)
            o:BulletDamage(d, nil, h.loc, h.nrm, h.mesh, FName("head"), h.dir,
                           nil, nil, {}, false, 0.0) end },
        { "bullet-nohit", function(o, d, h)
            o:BulletDamage(d, nil, h.loc, h.nrm, h.mesh, FName("head"), h.dir,
                           nil, nil, nil, false, 0.0) end },
        -- BP_NPC_Man.hpp:410 - the head zone's own critical damage
        { "crit-head", function(o, d, h)
            o:ApplyCriticalDamage(FName("CritZone_Head")) end },
        -- BP_NPC_Man.hpp:412 - a single float. The generated schema leaves it
        -- out only because its name has spaces in it; the header has it.
        { "brain", function(o, d, h) o["Apply Brain Damage"](o, d) end },
    },
    ALS_Player_CharacterBPai_C = {
        { "bullet", function(o, d, h)
            o:BulletDamage(d, nil, h.loc, h.nrm, h.mesh, FName("head"), h.dir,
                           nil, nil, {}, false, 0.0) end },
        { "bullet-nohit", function(o, d, h)
            o:BulletDamage(d, nil, h.loc, h.nrm, h.mesh, FName("head"), h.dir,
                           nil, nil, nil, false, 0.0) end },
        -- ALS_Player_CharacterBPai.hpp:520 - one float
        { "scream", function(o, d, h) o:RemoveHPAndScream(d) end },
    },
}
PlayerMods.damageWay = {}          -- class -> the way that worked this session
PlayerMods.damageErr = "none"      -- why the last way that failed, failed

-- A BULLET HIT WHERE A SILENT AIM HIT LANDS.
--
-- "like normal shooting bullets impacting the npcs". Last round looked for
-- the gun's own FleshEffects / FleshImpactSounds (SkeletalGun.hpp:207/217) -
-- and the session read fx=0 snd=0, because every gun ships them EMPTY: the
-- pak has SkeletalGun referencing no flesh particle and no hit sound at all.
-- A real hit's blood is the ENEMY's: BP_NPC_Man loads P_BT_BloodHit_* from
-- Blood_VFX_Pack and the bullet_body_cue hit sound. So a gun that carries its
-- own is still used first, and otherwise it is the game's own blood. Found by
-- path, never cached: an asset from the last map is not a pointer to keep.
-- GameplayStatics spawns them (Engine.hpp:11306/11336); how this UE4SS wants
-- those calls shaped is tried in order and the winner kept, and what failed
-- and why lands in status.txt (impact=, impacterr=).
PlayerMods.impact = { fx = 0, snd = 0, fxShape = 0, sndShape = 0, none = 0, src = "none" }
PlayerMods.impactErr = "none"
PlayerMods.BLOOD_FX = {
    "/Game/Blood_VFX_Pack/Particles/Systems/P_BT_BloodHit_Med.P_BT_BloodHit_Med",
    "/Game/Blood_VFX_Pack/Particles/Systems/P_BT_BloodHit_Small.P_BT_BloodHit_Small",
    "/Game/Blood_VFX_Pack/Particles/Systems/P_BT_BloodHit_Lrg.P_BT_BloodHit_Lrg",
}
PlayerMods.BODY_HIT_SND = {
    "/Game/BulletImpactSounds/Bullets/BloodTrailCues/bullet_body_cue.bullet_body_cue",
    "/Game/Audio/blood/v2/Splatter/sfx_Blood_Splatter_Cue.sfx_Blood_Splatter_Cue",
}

function PlayerMods.FindLoaded(paths)
    for _, p in ipairs(paths) do
        local ok, o = pcall(StaticFindObject, p)
        if ok and o ~= nil and isValid(o) then return o end
    end
    return nil
end

-- (on PlayerMods: this file is at Lua's 200-local ceiling)
function PlayerMods.FirstOf(arr)
    if arr == nil then return nil end
    local ok, e = pcall(function() return arr[1] end)
    if not ok or e == nil then return nil end
    if not isValid(e) then
        local okG, g = pcall(function() return e:get() end)
        if okG then e = g end
    end
    return isValid(e) and e or nil
end

function PlayerMods.ShowImpact(ctx, h)
    if not isValid(PlayerMods.gpsObj) then
        PlayerMods.gpsObj = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end
    local gs = PlayerMods.gpsObj
    if not isValid(gs) then return end
    -- facing back along the shot, towards you: where a bullet hit sprays
    local nx, ny, nz = h.nrm.X or 0, h.nrm.Y or 0, h.nrm.Z or 0
    local rot = { Pitch = math.deg(math.asin(math.max(-1, math.min(1, nz)))),
                  Yaw = math.deg(math.atan(ny, nx)), Roll = 0.0 }
    local I = PlayerMods.impact

    -- NO PARTICLE, EVER (2026-10-06).
    --
    -- Round 5 spawned the game's blood-hit particle here on every Silent Aim
    -- kill (SpawnEmitterAtLocation), and every session after it crashed: four
    -- times on 5 and 6 October at BTVR+0x153970e - inside the engine building
    -- that particle's component, with this very call in flight in every one
    -- of UE4SS's crash dumps. The hit SOUND is a different kind of call (it
    -- builds no object) and stays: the gun's own, or the game's body-hit cue.
    local gun = PlayerMods.HeldGun() or PlayerMods.YourGuns()[1]
    local snd = gun and PlayerMods.FirstOf(get(gun, GUN_SKEL, "FleshImpactSounds")) or nil
    I.src = snd and "gun" or "game"
    if not snd then snd = PlayerMods.FindLoaded(PlayerMods.BODY_HIT_SND) end
    if not snd then
        I.none = I.none + 1
        I.src = "none"
        PlayerMods.impactErr = "no hit sound loaded: no bullet_body_cue"
        return
    end

    if snd then
        local shapes = {
            function() gs:PlaySoundAtLocation(ctx, snd, h.loc, rot, 1.0, 1.0, 0.0, nil, nil, nil) end,
            function() gs:PlaySoundAtLocation(ctx, snd, h.loc, rot) end,
            function() gs:PlaySoundAtLocation(ctx, snd, h.loc) end,
        }
        for i = (I.sndShape > 0 and I.sndShape or 1), #shapes do
            local ok, err = pcall(shapes[i])
            if ok then I.sndShape = i I.snd = I.snd + 1 break end
            PlayerMods.impactErr = ("snd" .. i .. ": " .. tostring(err)):gsub("[\r\n]", " "):sub(1, 160)
        end
    end
end

function PlayerMods.ImpactLine()
    local I = PlayerMods.impact
    return string.format("fx=%d snd=%d src=%s fxshape=%d sndshape=%d none=%d",
                         I.fx, I.snd, tostring(I.src), I.fxShape, I.sndShape, I.none)
end

-- nil = no routines known for this class; true = one of them hurt him;
-- false = every one was tried and none did
local function dealGameDamage(obj, cls, dmg, hit)
    local ways = PlayerMods.DAMAGE_WAYS[cls]
    if not ways then return nil end
    local lx, ly, lz
    if hit then lx, ly, lz = hit[1], hit[2], hit[3] end
    if type(lx) ~= "number" then
        local okL, loc = pcall(function() return obj:K2_GetActorLocation() end)
        if okL and loc then lx, ly, lz = loc.X, loc.Y, loc.Z end
    end
    if type(lx) ~= "number" then
        PlayerMods.damageErr = "no hit location"
        return false
    end
    local dx, dy, dz = 0.0, 0.0, -1.0
    if hit and type(hit[4]) == "number" then dx, dy, dz = hit[4], hit[5], hit[6] end
    local mesh = get(obj, cls, "Mesh")
    if not isValid(mesh) then mesh = nil end
    local h = { loc = { X = lx, Y = ly, Z = lz }, nrm = { X = -dx, Y = -dy, Z = -dz },
                dir = { X = dx, Y = dy, Z = dz }, mesh = mesh }
    -- "hurt" means: dead now, or his health went down, or (NPC) his brain did
    local field = SHOT_HP[cls]
    local function snap()
        local br = nil
        if cls == "BP_NPC_Man_C" then br = get(obj, cls, "BrainFunctionCurrent") end
        return get(obj, cls, field), br
    end
    local function hurt(hp0, br0)
        if isEnemyDead(obj, cls) then return true end
        local hp1, br1 = snap()
        if type(hp0) == "number" and type(hp1) == "number" and hp1 < hp0 then return true end
        if type(br0) == "number" and type(br1) == "number" and br1 < br0 then return true end
        return false
    end
    for i = (PlayerMods.damageWay[cls] or 1), #ways do
        local name, fn = ways[i][1], ways[i][2]
        local hp0, br0 = snap()
        local ok, err = pcall(fn, obj, dmg, h)
        if not ok then
            PlayerMods.damageErr = (name .. ": " .. tostring(err)):gsub("[\r\n]", " "):sub(1, 160)
            if PlayerMods.damageWay[cls] == i then PlayerMods.damageWay[cls] = nil end
        elseif hurt(hp0, br0) then
            PlayerMods.damageWay[cls] = i
            PlayerMods.shotWhy.via = name
            -- the hit landed through his own routine, which makes no bullet
            -- impact: show the one YOUR gun makes, where the shot landed
            if PlayerMods.state.AimImpactFx ~= false then
                pcall(PlayerMods.ShowImpact, obj, h)
            end
            return true
        else
            PlayerMods.shotWhy.noeffect = (PlayerMods.shotWhy.noeffect or 0) + 1
        end
    end
    return false
end

local function applyShotDamage(obj, cls, dmg, hit)
    local field = SHOT_HP[cls]
    local before = get(obj, cls, field)
    local via = dealGameDamage(obj, cls, dmg, hit)
    if via ~= nil then
        if not via then
            PlayerMods.shotWhy.gamefail = PlayerMods.shotWhy.gamefail + 1
            return false
        end
        PlayerMods.shotWhy.game = PlayerMods.shotWhy.game + 1
        if isEnemyDead(obj, cls) then
            PlayerMods.shotWhy.killed = PlayerMods.shotWhy.killed + 1
        end
        return true
    end
    -- No routine to call for this class. Only the zombie family, whose death
    -- really IS health at or below zero (isEnemyDead reads it that way), ever
    -- gets its health written: doing it to anyone else is what left NPCs
    -- alive at -400.
    if type(before) ~= "number" or before <= 0 then return false end
    if cls ~= "BP_MeleeAI_Character_C" then return false end
    set(obj, cls, field, math.floor(before - dmg))
    local forced = get(obj, cls, field)
    return type(forced) == "number" and forced < before
end

local function processShotQueue()
    if #shotQueue == 0 then return end
    local q = shotQueue
    shotQueue = {}
    local jobs = {}
    for _, d in ipairs(q) do
        local obj = liveEnemy(d.addr)
        if obj then
            jobs[#jobs + 1] = { obj, d.cls, d.dmg, d.hit }
        else
            -- the sweep no longer returns him: dead, destroyed, or he was
            -- never in the list the aim picked him from
            PlayerMods.shotWhy.notlive = PlayerMods.shotWhy.notlive + 1
        end
    end
    if #jobs == 0 then return end
    PlayerMods.InGameThread("shot-damage", function()
        if PlayerMods.dormant then return end
        for _, j in ipairs(jobs) do
            if isValid(j[1]) and not isEnemyDead(j[1], j[2]) then
                if applyShotDamage(j[1], j[2], j[3], j[4]) then
                    PlayerMods.shotDamage = PlayerMods.shotDamage + 1
                else
                    PlayerMods.shotWhy.nodrop = PlayerMods.shotWhy.nodrop + 1
                end
            else
                PlayerMods.shotWhy.dead = PlayerMods.shotWhy.dead + 1
            end
        end
    end)
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
    local boxesOn = PlayerMods.state.ESPBoxes or PlayerMods.state.ESPHitboxes
    local boxesTracked = next(boxState) ~= nil
    forEachSettledEnemy(function(e, c)
        n = n + 1
        if c == ENEMY_CLASS then nAls = nAls + 1 end
        local addr = markLive(e)
        if PlayerMods.state.FistLaunch and MELEE_HP[c] then watchForHit(e, c) end
        -- body boxes: right after the sweep proved this one alive
        if boxesOn or boxesTracked then boxTick(e, c, addr) end
    end)
    PlayerMods.boxStats.live = boxesOn and n or 0
    -- forget addresses the sweep no longer returns (dead, destroyed, reused)
    if boxesTracked then
        for a, st in pairs(boxState) do
            if (liveSweep - (st.seen or 0)) > 2 then boxState[a] = nil end
        end
    end

    -- extra damage the aim queued, against the objects this sweep returned
    processShotQueue()

    -- Damage the hooks asked for, applied against the object THIS sweep
    -- returned. Anything whose body is gone is simply dropped.
    if #damageQueue > 0 then
        local q = damageQueue
        damageQueue = {}
        -- PUNCH AND MELEE DAMAGE LAND ON THE GAME THREAD. BludgeonDamage and
        -- RemoveHPAndScream are the enemy's own damage functions; a hit that
        -- kills him starts his death - physics, ragdoll, things spawned - and
        -- from this loop that is exactly the shot-damage freeze of 7 October.
        PlayerMods.InGameThread("melee-damage", function()
            if PlayerMods.dormant then return end
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
            -- the knock-down those hits queued, now, on this same thread
            PlayerMods.DrainRagdollQueue(true)
        end)
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
        shotQueue, boxState = {}, {}
        -- numbers only, but still: stop drawing boxes and aiming at the wave
        -- that just died, at the earliest moment the collapse is known
        PlayerMods.espTargets = {}
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
        PlayerMods.espTargets = {}
        shotQueue, boxState = {}, {}
    end
    lastEnemyCount = nAls
end

do -- (its own scope: the file is at Lua's 200-local limit)
-- WHAT THE ENEMIES' OWN AI THINKS (2026-10-11).
--
-- "the npc's seem dumber than normal vanilla game ones". The human enemies'
-- AI (BP_AICON_FIniteState, read from its bytecode) picks what to do from:
-- CanSeePlayer, HasCleanShot (a trace from its gun to your head actor), and
-- RecentlyRendered - WasRecentlyRendered(0.2) on the WHOLE actor, so any part
-- of it being drawn counts, the capsule the ESP box un-hides included. Its
-- Difficulty comes from YOUR body's Difficulty. This samples every one of
-- them every 2 s on the game thread and keeps the session's totals, so the
-- next game says what "dumber" is instead of guessing at it.
local NAV = { [0] = "DoNothing", "PatrolUnaware", "GetToLowCoverConstantUpdate",
    "GetToLowCoverAndWait", "RunDirectlyFromPlayer", "ChasePlayer",
    "MoveToGivenLocation", "RandomCleanShotNonEqs", "RandomCoverNonEqs",
    "DefendLocation", "OppositeSideOfCover", "FlankPlayer",
    "EyesOnLastPlayerPosition", "SearchArea", "GetToAssignedCover",
    "HighAlertSearch", "IdleUnawareAtStart", "MeleeAttack",
    "MeleeEncirclePlayer", "StationaryShooting" }
local AWARE = { [0] = "Unaware", "Suspicious", "HighAlert", "FullyAware" }
local DIFF = { [0] = "TooEasy", "Easy", "Normal", "Hard", "TooHard", "Impossible" }
PlayerMods.npcAi = { samples = 0, npcs = 0, see = 0, rendered = 0, clean = 0,
    surrendered = 0, boxOnly = 0, nav = {}, aware = {}, diff = nil, now = "" }

local function field(o, name)
    local ok, v = pcall(function() return o[name] end)
    if ok then return v end
    return nil
end

local function drawn(comp)
    if not isValid(comp) then return nil end
    local ok, v = pcall(function() return comp:WasRecentlyRendered(0.2) end)
    if ok then return v == true end
    return nil
end

-- ON THE GAME THREAD (the npc-ai job)
function PlayerMods.NpcAiSample()
    local ok, list = pcall(FindAllOf, "BP_AICON_FIniteState_C")
    if not (ok and type(list) == "table") then return end
    local t = PlayerMods.npcAi
    local n, see, ren, clean, sur, boxOnly = 0, 0, 0, 0, 0, 0
    local navNow = {}
    for _, c in ipairs(list) do
        if isValid(c) then
            n = n + 1
            local nav = field(c, "CurrentNavBehavior")
            local navName = NAV[tonumber(nav) or -1] or tostring(nav)
            navNow[navName] = (navNow[navName] or 0) + 1
            t.nav[navName] = (t.nav[navName] or 0) + 1
            local aw = AWARE[tonumber(field(c, "AwarenessState")) or -1]
            if aw then t.aware[aw] = (t.aware[aw] or 0) + 1 end
            local d = DIFF[tonumber(field(c, "Difficulty")) or -1]
            if d then t.diff = d end
            if field(c, "CanSeePlayer") == true then see = see + 1 end
            if field(c, "HasCleanShot") == true then clean = clean + 1 end
            if field(c, "Surrendered") == true then sur = sur + 1 end
            if field(c, "RecentlyRendered") == true then
                ren = ren + 1
                -- drawn ONLY because its box was: the capsule, not the body
                local pawn = field(c, "ControlledNPC")
                if isValid(pawn) then
                    local cap = drawn(field(pawn, "CapsuleComponent"))
                    local body = drawn(field(pawn, "Mesh"))
                    if cap == true and body == false then boxOnly = boxOnly + 1 end
                end
            end
        end
    end
    t.samples = t.samples + 1
    t.npcs = t.npcs + n
    t.see, t.rendered, t.clean = t.see + see, t.rendered + ren, t.clean + clean
    t.surrendered, t.boxOnly = t.surrendered + sur, t.boxOnly + boxOnly
    local parts = {}
    for k, v in pairs(navNow) do parts[#parts + 1] = k .. ":" .. v end
    table.sort(parts)
    t.now = string.format("n=%d see=%d drawn=%d boxonly=%d clean=%d surrendered=%d doing=%s",
        n, see, ren, boxOnly, clean, sur, #parts > 0 and table.concat(parts, ",") or "-")
end

-- ON THE LOOP: every 2 s, one job
function PlayerMods.NpcAiTick()
    if PlayerMods.dormant then return end
    PlayerMods.InGameThread("npc-ai", PlayerMods.NpcAiSample)
end

-- now | session: per NPC-sample, so "see=40%" means 40% of the time
function PlayerMods.NpcAiLine()
    local t = PlayerMods.npcAi
    local function pct(x) return t.npcs > 0 and math.floor(100 * x / t.npcs + 0.5) or 0 end
    local function top(map)
        local arr = {}
        for k, v in pairs(map) do arr[#arr + 1] = { k, v } end
        table.sort(arr, function(a, b) return a[2] > b[2] end)
        local out = {}
        for i = 1, math.min(5, #arr) do out[#out + 1] = arr[i][1] .. ":" .. pct(arr[i][2]) .. "%" end
        return #out > 0 and table.concat(out, ",") or "-"
    end
    return string.format(
        "now: %s | session: samples=%d difficulty=%s see=%d%% drawn=%d%% boxonly=%d%% clean=%d%% surrendered=%d%% doing=%s aware=%s",
        t.now ~= "" and t.now or "-", t.samples, t.diff or "?", pct(t.see), pct(t.rendered),
        pct(t.boxOnly), pct(t.clean), pct(t.surrendered), top(t.nav), top(t.aware))
end
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
    PlayerMods.InGameThread("ammo-refill", function()
        local pawn, kind = PlayerMods.GetPawn()
        if pawn then RefillReserveAmmo(pawn, kind) end
        PlayerMods.ScanTick()
    end)
end

function PlayerMods.HealNow()
    PlayerMods.InGameThread("heal", function()
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
    PlayerMods.InGameThread("kill-all", function()
        local n = 0
        forEachSettledEnemy(function(e)
            pcall(function() e:K2_DestroyActor() end)
            n = n + 1
        end)
        print("[ModMenu] removed " .. n .. " enemies\n")
    end)
end

function PlayerMods.UnlockAll()
    PlayerMods.InGameThread("unlock-all", function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        set(pawn, kind, "UnlockedCheckpoint", 99)
        set(pawn, kind, "Unlockedchapter", 99)
        set(pawn, kind, "UnlockedRaidLevel", 99)
        print("[ModMenu] progression unlocked\n")
    end)
end

function PlayerMods.ToggleHeadlamp()
    PlayerMods.InGameThread("lamp-toggle", function()
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
    PlayerMods.InGameThread("nvg-toggle", function()
        local pawn, kind = PlayerMods.GetPawn()
        if not pawn then return end
        call(pawn, kind, "EventCycleNightVision")
    end)
end

-- Where your head is and where it looks, as plain numbers. The aim cone falls
-- back to this when there is no gun in your hands, and the head touch below
-- measures against it.
function PlayerMods.AimEye()
    local pawn, kind = PlayerMods.GetPawn()
    if not pawn then return nil end
    local cam = get(pawn, kind, "VRReplicatedCamera")
    if not isValid(cam) then return nil end
    local okL, l = pcall(function() return cam:K2_GetComponentLocation() end)
    local okR, r = pcall(function() return cam:K2_GetComponentRotation() end)
    if not (okL and l and type(l.X) == "number") then return nil end
    if not (okR and r and type(r.Yaw) == "number") then return nil end
    local p, y = math.rad(r.Pitch), math.rad(r.Yaw)
    local cp = math.cos(p)
    return {
        x = l.X, y = l.Y, z = l.Z,
        yaw = r.Yaw, pitch = r.Pitch,
        fx = cp * math.cos(y), fy = cp * math.sin(y), fz = math.sin(p),
        -- the head's RIGHT, level with the floor: X axis turned by yaw is
        -- forward, the Y axis turned by yaw is right
        rx = -math.sin(y), ry = math.cos(y), rz = 0.0,
    }
end

---------------------------------------------------------------------------
-- TOUCH BESIDE YOUR HEAD: LAMP AND NIGHT VISION (2026-09-18)
---------------------------------------------------------------------------
-- The game's own switches are overlap volumes on your CHEST, which is exactly
-- why a hand kept brushing them mid-fight - that is what No Accidental Lamp
-- locks out. This puts them somewhere a hand only ever goes on purpose:
-- beside your head. Reach up to the LEFT of your head for one, the RIGHT for
-- the other, with whichever hand is free.
--
-- What it does per tick is three position reads and some arithmetic. The only
-- thing it ever CALLS is the pawn's own lamp / night-vision event, through the
-- existing game-thread wrapper, and only on the moment a hand arrives - never
-- while it stays there, and never twice inside the cool-down.

PlayerMods.headTouch = {
    inL = false, inR = false, lamp = 0, nvg = 0, fires = 0,
    dL = nil, dR = nil, zoneL = nil, zoneR = nil,
    last = "none", lastAt = -99, live = false,
}
local headTouchAt = { L = -99, R = -99 }
onDropCaches(function()
    PlayerMods.headTouch.inL = false
    PlayerMods.headTouch.inR = false
    headTouchAt.L, headTouchAt.R = -99, -99
end)

PlayerMods.HEAD_TOUCH_ACTIONS = { "FLASHLIGHT", "NIGHT VISION", "NOTHING" }

local function headTouchDo(which)
    which = math.floor((which or 0) + 0.5)
    if which == 0 then
        PlayerMods.ToggleHeadlamp()
        PlayerMods.headTouch.lamp = PlayerMods.headTouch.lamp + 1
        return "FLASHLIGHT"
    elseif which == 1 then
        PlayerMods.ToggleNightVision()
        PlayerMods.headTouch.nvg = PlayerMods.headTouch.nvg + 1
        return "NIGHT VISION"
    end
    return nil
end

-- TWO BUTTONS BESIDE YOUR HEAD, NOT ONE SPHERE AROUND IT (2026-09-20).
--
-- A whole session read fires=0 with the feature on and live. The old test was
-- "close to the middle of your head AND far enough to one side", which is two
-- conditions pulling against each other: the closer you get to the middle of
-- your head, the harder it is to also be to one side of it. With the range at
-- its slider minimum of 12 cm it could not be satisfied at all - a controller
-- cannot get 12 cm from the centre of a headset while your hand is beside
-- your ear, because your ear is further away than that.
--
-- So the buttons are where they were always described as being: two points,
-- one beside each ear, HEAD_SIDE out along the way your head is facing. The
-- range is now simply how big those buttons are, which is what the label said
-- all along, and turning it UP always makes it easier - it never used to.
local HEAD_SIDE = 16.0    -- cm from the middle of your head to a button
-- A hand out in front of your face is not reaching for your ear, and that is
-- the hand you point the menu with. Reaching back past your ear is fine.
local HEAD_FRONT_MAX = 12.0

-- Which button this hand is in, and how far it is from the nearer one.
local function headZone(eye, hand, range)
    if not isValid(hand) then return nil, nil end
    local ok, l = pcall(function() return hand:K2_GetComponentLocation() end)
    if not (ok and l and type(l.X) == "number") then return nil, nil end
    local function distTo(sign)
        local cx = eye.x + eye.rx * HEAD_SIDE * sign
        local cy = eye.y + eye.ry * HEAD_SIDE * sign
        local cz = eye.z + eye.rz * HEAD_SIDE * sign
        local ax, ay, az = l.X - cx, l.Y - cy, l.Z - cz
        return math.sqrt(ax * ax + ay * ay + az * az)
    end
    local dl, dr = distTo(-1), distTo(1)
    local near = (dl < dr) and dl or dr
    if near > range then return nil, near end
    local fwd = (l.X - eye.x) * eye.fx + (l.Y - eye.y) * eye.fy
              + (l.Z - eye.z) * eye.fz
    if fwd > HEAD_FRONT_MAX then return nil, near end
    return (dl <= dr) and "L" or "R", near
end

-- Below this the buttons cannot be reached at all, whatever the slider says.
-- A saved profile from before this was understood can still be carrying 12.
local HEAD_RANGE_MIN = 20.0
local function headRange(s)
    local r = s.HeadTouchRange or 38
    if r < HEAD_RANGE_MIN then return HEAD_RANGE_MIN end
    return r
end

function PlayerMods.HeadTouchTick()
    local s = PlayerMods.state
    local ht = PlayerMods.headTouch
    if s.HeadTouch ~= true then
        ht.inL, ht.inR, ht.live = false, false, false
        ht.dL, ht.dR, ht.zoneL, ht.zoneR = nil, nil, nil, nil
        return
    end
    if PlayerMods.dormant then return end

    local eye = PlayerMods.AimEye()
    if not eye then
        ht.live = false
        return
    end
    local range = headRange(s)
    local left, right = PlayerMods.GetHand(true), PlayerMods.GetHand(false)
    local zl, dl = headZone(eye, left, range)
    local zr, dr = headZone(eye, right, range)
    ht.dL, ht.dR, ht.zoneL, ht.zoneR = dl, dr, zl, zr
    ht.live = (left ~= nil) or (right ~= nil)

    -- either hand can press either side
    local inZone = { L = (zl == "L") or (zr == "L"),
                     R = (zl == "R") or (zr == "R") }
    local now = os.clock()
    for _, z in ipairs({ "L", "R" }) do
        local was = (z == "L") and ht.inL or ht.inR
        if inZone[z] and not was and (now - headTouchAt[z]) > 0.8 then
            headTouchAt[z] = now
            local did = headTouchDo((z == "L") and s.HeadTouchLeft or s.HeadTouchRight)
            if did then
                ht.fires = ht.fires + 1
                ht.last = z .. " " .. did
                ht.lastAt = now
            end
        end
        if z == "L" then ht.inL = inZone[z] else ht.inR = inZone[z] end
    end
end

local HEAD_ACTION_SHORT = { [0] = "LAMP", [1] = "NVG", [2] = "OFF" }

function PlayerMods.HeadTouchText()
    local s = PlayerMods.state
    local ht = PlayerMods.headTouch
    if s.HeadTouch ~= true then return "off" end
    -- ON, LIVE, AND WIRED TO NOTHING.
    --
    -- A whole session read on=true live=true fires=0, and the reach was only
    -- half of why: the saved profile had BOTH sides set to NOTHING. A press
    -- would have registered and then done exactly what it was told - nothing -
    -- and this line would still have sat there counting centimetres as though
    -- it were armed. Say it instead.
    local aL = math.floor((s.HeadTouchLeft or 0) + 0.5)
    local aR = math.floor((s.HeadTouchRight or 1) + 0.5)
    if aL == 2 and aR == 2 then
        return "both sides set to NOTHING - pick one above"
    end
    if not ht.live then return "waiting for your hands" end
    -- What it just did wins the line, so a press is unmistakable.
    if (os.clock() - (ht.lastAt or -99)) < 4 and ht.last then
        return "SWITCHED " .. ht.last
    end
    -- Otherwise: are you in a zone RIGHT NOW, and if not, how far off.
    if ht.inL or ht.inR then
        local z = ht.inL and "LEFT" or "RIGHT"
        local a = ht.inL and s.HeadTouchLeft or s.HeadTouchRight
        return string.format("TOUCHING %s -> %s", z,
            HEAD_ACTION_SHORT[math.floor((a or 0) + 0.5)] or "?")
    end
    -- The value column is narrow, so this has to say the whole story short:
    -- how far each hand is, and how close it has to get.
    local range = headRange(s)
    return string.format("L %s R %s  need %.0f",
        ht.dL and string.format("%.0f", ht.dL) or "-",
        ht.dR and string.format("%.0f", ht.dR) or "-", range)
end

function PlayerMods.HeadTouchLine()
    local s = PlayerMods.state
    local ht = PlayerMods.headTouch
    local SHORT = HEAD_ACTION_SHORT
    return string.format("on=%s live=%s inL=%s inR=%s dL=%s dR=%s range=%d " ..
                         "left=%s right=%s lamp=%d nvg=%d fires=%d last=%s",
        tostring(s.HeadTouch == true), tostring(ht.live),
        tostring(ht.inL), tostring(ht.inR),
        ht.dL and string.format("%.0f", ht.dL) or "n/a",
        ht.dR and string.format("%.0f", ht.dR) or "n/a",
        math.floor(headRange(s)),
        SHORT[math.floor((s.HeadTouchLeft or 0) + 0.5)] or "?",
        SHORT[math.floor((s.HeadTouchRight or 1) + 0.5)] or "?",
        ht.lamp, ht.nvg, ht.fires, ht.last or "none")
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
    PlayerMods.InGameThread("test-god", function()
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

    -- ON THE GAME THREAD (2026-10-05): a console command off it is the 0x40
    -- crash the Optimizer's own commands caused - see optimizer.lua. Claimed
    -- here so the loop does not queue the same value again before it runs,
    -- and released if it could not be sent.
    lastGamma = want
    PlayerMods.InGameThread("gamma", function()
        local pawn = PlayerMods.GetPawn()
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not (isValid(pawn) and isValid(ksl)) then lastGamma = nil return end
        local ok = pcall(function()
            ksl:ExecuteConsoleCommand(pawn, string.format("gamma %.2f", want), nil)
        end)
        if ok then
            PlayerMods.brightState = string.format("gamma %.2f", want)
        else
            lastGamma = nil
        end
    end)
end

function PlayerMods.Screenshot()
    PlayerMods.InGameThread("screenshot", function()
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

    PlayerMods.InGameThread("esp-restart", function()
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
    -- (on the game thread: registering a hook while the game thread runs
    -- one is the 0xC0000264 crash - see main.lua)
    PlayerMods.hooksBound = false
    PlayerMods.InGameThread("bind-hooks", function()
        pcall(PlayerMods.RegisterEnemyWatch)
        pcall(PlayerMods.EnsureHooks)
    end)

        PlayerMods.espRestarts = (PlayerMods.espRestarts or 0) + 1
    print("[ModMenu] ESP restarted (" .. PlayerMods.espRestarts ..
          ") - pawn, display and enemy list rebuilt\n")
end

-- Travel to a map by path, so Raid Mode can be entered and tested without a
-- headset. e.g. /Game/Maps/Raid/Levels/V3/Map_Raid_lvl1
function PlayerMods.LoadMap(mapPath)
    if type(mapPath) ~= "string" or mapPath == "" then return end
    PlayerMods.InGameThread("map-load", function()
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
    PlayerMods.InGameThread("time-scale", function()
        pcall(function()
            local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if not isValid(gs) then return end
            local pawn = PlayerMods.GetPawn()
            if isValid(pawn) then gs:SetGlobalTimeDilation(pawn, scale) end
        end)
    end)
end

return PlayerMods
