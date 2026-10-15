-- Blood Trail Mod Menu - OPTIMIZER tab
--
-- Folded in from the standalone BTOptimizer mod (2026-09-17). Running both
-- would have two things issuing the same console variables, so BTOptimizer is
-- retired and everything it did lives here, plus a good deal more.
--
-- WHAT IT TOUCHES, AND WHY EACH IS SAFE
--
--   * Console variables. An unknown one prints "Command not recognized" and
--     does nothing - the opposite of a wrong PROPERTY name, which is a native
--     crash pcall cannot catch. Every cvar below was still checked against the
--     shipping executable with research/tools/cvars.py. Three that do NOT exist
--     here were dropped: au.MaxChannels, r.ParticleMinTimeBetweenTicks,
--     fx.MaxCPUParticlesPerEmitter. grass.DensityScale is also absent.
--   * Three properties on the PLAYER pawn - RagdollLifetimeInSeconds,
--     DecalLifetimeInSeconds, PlayerOptionFreezeRagdolls (WendigoVrChar.hpp
--     141/142/280). The pawn is not destroyed when a round ends, and "Gore
--     Never Despawns" has written the first two from the loop for months.
--     Nothing here ever touches an enemy.
--   * Two read-only getters for the FPS meter: GetWorldDeltaSeconds and
--     GetGlobalTimeDilation (Engine.hpp 11353 / 11372).
--
-- WHAT IT DELIBERATELY LEAVES ALONE
--
--   * The game's tuned DefaultEngine.ini: forward shading, mobile HDR off,
--     AO off, motion blur off. Overriding those costs performance.
--   * r.MaterialQualityLevel and r.SceneColorFormat. Both exist, but changing
--     either at runtime recompiles shaders or reallocates render targets - a
--     multi-second freeze in a headset. Not worth offering.
--   * p.RagdollPhysics. Turning ragdolls off would break Grab & Throw and the
--     punch knockdowns, which depend on them.
--
-- "RESET" RESTORES YOUR GAME, NOT A GUESS
--
-- BTOptimizer's "Off" preset wrote Unreal's stock defaults, which are not what
-- Blood Trail ships with. Here every cvar is read with
-- GetConsoleVariableFloatValue (Engine.hpp 13248) BEFORE the first write, and
-- Reset puts exactly those values back.

local Opt = {}
local PlayerMods = nil

function Opt.Init(pm) PlayerMods = pm end

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------

local function alive(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

-- The engine's library objects never go away, so each is looked up ONCE and
-- kept. Every lookup is UE4SS's own unlocked FindObject, and from the loop
-- thread (the frame sampler asked for GameplayStatics every tick) that is
-- the lookup that crashed racing the game tearing a round down (7 October).
local kslObj, gpsObj = nil, nil

-- From the loop with nothing kept: the game thread is asked to look - at most
-- once every 20 loop ticks (two seconds), counted in the loop's own ticks so
-- that a look that found it long ago does not delay the next. The first look
-- is queued at start-up, but a job queued just before a map change is
-- dropped, and then nothing would ever look again.
local warmAt = nil
local function warmSoon()
    local now = PlayerMods and PlayerMods.tickStamp or 0
    if warmAt and now - warmAt < 20 then return end
    warmAt = now
    Opt.Warm()
end

local function ksl()
    if kslObj and alive(kslObj) then return kslObj end
    -- never looked up from the loop thread: the game thread fills it (Warm)
    if PlayerMods and PlayerMods.loopBodyActive then warmSoon() return nil end
    local o = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if alive(o) then kslObj = o return o end
    return nil
end

local function gps()
    if gpsObj and alive(gpsObj) then return gpsObj end
    if PlayerMods and PlayerMods.loopBodyActive then warmSoon() return nil end
    local o = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if alive(o) then gpsObj = o return o end
    return nil
end

-- the first lookups, on the game thread, as soon as the module is wired up
function Opt.Warm()
    if PlayerMods and PlayerMods.InGameThread then
        PlayerMods.InGameThread("opt-warm", function() ksl() gps() end)
    end
end

-- Numbers go out without trailing zeros, so a value the game already holds as
-- "2" is not seen as different from our "2.000".
local function fmtNum(v)
    if type(v) ~= "number" then return tostring(v) end
    if math.abs(v - math.floor(v + 0.5)) < 0.0001 then
        return string.format("%d", math.floor(v + 0.5))
    end
    return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ""))
end

---------------------------------------------------------------------------
-- presets
--
-- Tuned for the RTX 2070 SUPER this was built on: 8 GB of VRAM is the tight
-- resource, not the 32 GB of RAM. Shadows go first - the game is
-- forward-shaded with many dynamic lights (headlamp, muzzle flashes, lamp).
-- Foliage and view distance matter most on the outdoor Raid maps.
--
-- Each entry is { cvar, value }. Order matters: sg.* scalability groups reset
-- the r.* settings underneath them, so they always go first.
---------------------------------------------------------------------------

Opt.PRESETS = {
    {
        name = "Game Default",
        note = "Blood Trail exactly as it shipped. Nothing overridden.",
        cvars = {},
    },
    {
        name = "Quality",
        note = "Looks untouched. Trims only what you cannot see in a headset.",
        cvars = {
            { "sg.ShadowQuality", 3 }, { "sg.EffectsQuality", 3 }, { "sg.TextureQuality", 3 },
            { "sg.PostProcessQuality", 2 }, { "sg.ViewDistanceQuality", 3 },
            { "sg.FoliageQuality", 3 },
            { "r.Shadow.MaxResolution", 2048 }, { "r.Shadow.CSM.MaxCascades", 3 },
            { "r.Shadow.RadiusThreshold", 0.04 },
            { "r.SceneColorFringeQuality", 0 }, { "r.DepthOfFieldQuality", 0 },
            { "r.LightFunctionQuality", 1 },
            { "r.Streaming.LimitPoolSizeToVRAM", 1 }, { "r.Streaming.PoolSize", 2000 },
        },
    },
    {
        name = "Balanced",
        note = "For normal play. Big shadow and foliage savings, resolution barely touched.",
        cvars = {
            { "sg.ShadowQuality", 2 }, { "sg.EffectsQuality", 2 }, { "sg.TextureQuality", 3 },
            { "sg.PostProcessQuality", 1 }, { "sg.ViewDistanceQuality", 2 },
            { "sg.FoliageQuality", 2 },
            { "r.ScreenPercentage", 95 }, { "vr.PixelDensity", 0.9 },
            { "r.ShadowQuality", 3 }, { "r.Shadow.MaxResolution", 1024 },
            { "r.Shadow.MaxCSMResolution", 1024 }, { "r.Shadow.DistanceScale", 0.8 },
            { "r.Shadow.CSM.MaxCascades", 2 }, { "r.Shadow.RadiusThreshold", 0.06 },
            { "r.DistanceFieldShadowing", 0 },
            { "foliage.DensityScale", 0.7 }, { "r.ViewDistanceScale", 0.8 },
            { "r.StaticMeshLODDistanceScale", 1.5 },
            { "r.BloomQuality", 3 }, { "r.SceneColorFringeQuality", 0 },
            { "r.DepthOfFieldQuality", 0 }, { "r.LightFunctionQuality", 1 },
            { "fx.Niagara.QualityLevel", 2 }, { "r.MaxAnisotropy", 4 },
            { "r.Streaming.LimitPoolSizeToVRAM", 1 }, { "r.Streaming.PoolSize", 1500 },
            { "r.OneFrameThreadLag", 1 },
        },
    },
    {
        name = "Performance",
        note = "Busy Raid maps and heavy gore. Softer shadows, thinner foliage.",
        cvars = {
            { "sg.ShadowQuality", 1 }, { "sg.EffectsQuality", 1 }, { "sg.TextureQuality", 2 },
            { "sg.PostProcessQuality", 1 }, { "sg.ViewDistanceQuality", 1 },
            { "sg.FoliageQuality", 1 },
            { "r.ScreenPercentage", 85 }, { "vr.PixelDensity", 0.8 },
            { "r.ShadowQuality", 2 }, { "r.Shadow.MaxResolution", 512 },
            { "r.Shadow.MaxCSMResolution", 512 }, { "r.Shadow.DistanceScale", 0.6 },
            { "r.Shadow.CSM.MaxCascades", 1 }, { "r.Shadow.RadiusThreshold", 0.1 },
            { "r.DistanceFieldShadowing", 0 },
            { "foliage.DensityScale", 0.4 }, { "r.ViewDistanceScale", 0.6 },
            { "r.StaticMeshLODDistanceScale", 2.5 }, { "r.SkeletalMeshLODBias", 1 },
            { "r.BloomQuality", 1 }, { "r.SceneColorFringeQuality", 0 },
            { "r.DepthOfFieldQuality", 0 }, { "r.LightFunctionQuality", 0 },
            { "r.Tonemapper.Quality", 0 }, { "r.LensFlareQuality", 0 },
            { "r.ParticleLODBias", 1 }, { "r.EmitterSpawnRateScale", 0.7 },
            { "fx.Niagara.QualityLevel", 1 }, { "r.MaxAnisotropy", 2 },
            { "r.Streaming.LimitPoolSizeToVRAM", 1 }, { "r.Streaming.PoolSize", 1000 },
            { "r.Streaming.MipBias", 0.5 }, { "r.OneFrameThreadLag", 1 },
        },
    },
    {
        name = "Potato",
        note = "Maximum FPS. Also the one for two copies of the game at once. Ugly on purpose.",
        cvars = {
            { "sg.ShadowQuality", 0 }, { "sg.EffectsQuality", 0 }, { "sg.TextureQuality", 1 },
            { "sg.PostProcessQuality", 0 }, { "sg.ViewDistanceQuality", 0 },
            { "sg.FoliageQuality", 0 },
            { "r.ScreenPercentage", 70 }, { "vr.PixelDensity", 0.65 },
            { "r.ShadowQuality", 0 }, { "r.Shadow.MaxResolution", 256 },
            { "r.Shadow.MaxCSMResolution", 256 }, { "r.Shadow.DistanceScale", 0.3 },
            { "r.Shadow.CSM.MaxCascades", 1 }, { "r.Shadow.RadiusThreshold", 0.2 },
            { "r.DistanceFieldShadowing", 0 },
            { "foliage.DensityScale", 0.15 }, { "r.ViewDistanceScale", 0.4 },
            { "r.StaticMeshLODDistanceScale", 4.0 }, { "r.SkeletalMeshLODBias", 2 },
            { "r.BloomQuality", 0 }, { "r.SceneColorFringeQuality", 0 },
            { "r.DepthOfFieldQuality", 0 }, { "r.LightFunctionQuality", 0 },
            { "r.Tonemapper.Quality", 0 }, { "r.LensFlareQuality", 0 },
            { "r.LightShaftQuality", 0 }, { "r.VolumetricFog", 0 },
            { "r.ParticleLODBias", 2 }, { "r.EmitterSpawnRateScale", 0.4 },
            { "fx.Niagara.QualityLevel", 0 }, { "r.MaxAnisotropy", 0 },
            { "r.Streaming.LimitPoolSizeToVRAM", 1 }, { "r.Streaming.PoolSize", 600 },
            { "r.Streaming.MipBias", 1.5 }, { "r.OneFrameThreadLag", 1 },
        },
    },
}

-- Plain words for the GPU page.
function Opt.UpscaleText()
    local s = PlayerMods.state
    if not s.OptEnabled then return "Optimizer is off" end
    local mode = math.floor((s.OptUpscaler or 0) + 0.5)
    if mode <= 0 then return "off, full resolution" end
    local q = math.floor((s.OptUpscaleQuality or 1) + 0.5)
    local pct = UPSCALE_PCT[q + 1] or 67
    if mode == 1 then return string.format("BUILT-IN %d%%, any GPU", pct) end
    local short = ({ "FSR 1", "FSR 2", "DLSS" })[mode - 1] or "?"
    return string.format("%s %d%% - needs plugin", short, pct)
end

-- Plain words for the SYSTEM page: what is actually switched on there.
function Opt.SystemText()
    local s = PlayerMods.state
    if not s.OptEnabled then return "Optimizer is off" end
    local on = {}
    if math.floor((s.OptGcMode or 0) + 0.5) > 0 then on[#on + 1] = "GC" end
    if math.floor((s.OptPhysThreads or 0) + 0.5) > 0 then on[#on + 1] = "CPU" end
    if s.OptFewerRagdolls then on[#on + 1] = "bodies" end
    if s.OptAnimBudget then on[#on + 1] = "anim" end
    if s.OptStreamBoost or s.OptTrimRam then on[#on + 1] = "RAM" end
    if s.OptFastLoad then on[#on + 1] = "loading" end
    if #on == 0 then return "nothing on yet" end
    return "on: " .. table.concat(on, " ")
end

function Opt.GpuText()
    local g = Opt.gpuName
    if not g or g == "" then
        return "open the app to see"
    end
    -- Short enough for the headset, and the answer is the same whatever the
    -- card turns out to be: this game ships neither plugin.
    return g .. " - use BUILT-IN"
end

function Opt.PresetName(i)
    local p = Opt.PRESETS[math.floor((i or 1) + 0.5)]
    return p and p.name or "?"
end

function Opt.PresetNote(i)
    local p = Opt.PRESETS[math.floor((i or 1) + 0.5)]
    return p and p.note or ""
end

---------------------------------------------------------------------------
-- custom settings: each slider/toggle becomes one or more cvars
--
-- A slider at its "Game" position (-1 for the quality steps, 0 for the rest)
-- contributes nothing, so custom mode never overrides a setting the player
-- did not actually move.
---------------------------------------------------------------------------

local function customCvars(s, out)
    local function add(name, v) out[#out + 1] = { name, v } end
    local function quality(key, cvar)
        local v = s[key]
        if type(v) == "number" and v >= 0 then add(cvar, math.floor(v + 0.5)) end
    end

    -- scalability groups first, for the same reason as the presets
    quality("OptShadows",      "sg.ShadowQuality")
    quality("OptViewDistance", "sg.ViewDistanceQuality")
    quality("OptFoliage",      "sg.FoliageQuality")
    quality("OptEffects",      "sg.EffectsQuality")
    quality("OptPostProcess",  "sg.PostProcessQuality")
    quality("OptTextures",     "sg.TextureQuality")

    if type(s.OptResolution) == "number" and s.OptResolution > 0 then
        add("r.ScreenPercentage", s.OptResolution)
    end
    -- the auto-resolution loop owns pixel density while it is running
    if type(s.OptPixelDensity) == "number" and s.OptPixelDensity > 0 and not s.OptAutoRes then
        add("vr.PixelDensity", s.OptPixelDensity)
    end
    if type(s.OptTexturePool) == "number" and s.OptTexturePool > 0 then
        add("r.Streaming.LimitPoolSizeToVRAM", 1)
        add("r.Streaming.PoolSize", s.OptTexturePool)
    end
    if type(s.OptEnemyDetail) == "number" and s.OptEnemyDetail >= 0 then
        -- 0 = full detail. Each step drops every skeletal mesh one LOD - the
        -- enemies are the only skinned meshes on screen in any number, so this
        -- is the knob for big waves.
        add("r.SkeletalMeshLODBias", math.floor(s.OptEnemyDetail + 0.5))
    end
end


---------------------------------------------------------------------------
-- UPSCALING: DLSS, AMD FSR, and the one that works on any card
---------------------------------------------------------------------------
-- Rendering at less than full resolution and having something clever put the
-- pixels back is the single biggest thing you can do for VR frame rate, and
-- it costs the least picture quality.
--
-- THREE of these are offered because only one of them is guaranteed to be
-- here. DLSS and FSR are PLUGINS: their console variables exist only if the
-- game shipped with them, and Blood Trail was not built with either. Setting
-- a console variable that does not exist is a no-op - the engine prints
-- "Unknown command" and nothing else happens - so offering them costs
-- nothing, and if a future patch adds one it starts working.
--
-- BUILT-IN is not a plugin. Temporal upsampling (r.TemporalAA.Upsampling) has
-- been in Unreal since 4.19 and is in every build, including this one. It is
-- the same idea DLSS uses - reuse the last few frames to fill in a
-- lower-resolution image - without the hardware. It works on NVIDIA, AMD and
-- Intel alike, so it is the default choice and the one to use here.
--
-- Quality steps are the resolutions the DLSS/FSR presets use, so the three
-- upscalers are comparable at the same setting.
Opt.UPSCALERS = { "OFF (game's own)", "BUILT-IN (any GPU)", "AMD FSR 1",
                  "AMD FSR 2", "NVIDIA DLSS" }
Opt.UPSCALE_QUALITY = { "ULTRA QUALITY", "QUALITY", "BALANCED", "PERFORMANCE",
                        "ULTRA PERFORMANCE" }
-- render resolution as a percentage, per step
local UPSCALE_PCT = { 77, 67, 59, 50, 33 }
-- FSR2 QualityMode: 1 Quality .. 4 Ultra Performance
local FSR2_MODE    = { 1, 1, 2, 3, 4 }
-- DLSS: 2 Ultra Quality, 1 Quality, 0 Balanced, -1 Performance, -2 Ultra Perf
local DLSS_QUALITY = { 2, 1, 0, -1, -2 }

function Opt.UpscalerName(i)
    return Opt.UPSCALERS[math.floor((i or 0) + 0.5) + 1] or "?"
end

function Opt.UpscaleQualityName(i)
    return Opt.UPSCALE_QUALITY[math.floor((i or 1) + 0.5) + 1] or "?"
end

-- What the upscaler rows ask for. `add` is the caller's collector.
local function upscaleCvars(s, add)
    local mode = math.floor((s.OptUpscaler or 0) + 0.5)
    if mode <= 0 then return end
    local q = math.floor((s.OptUpscaleQuality or 1) + 0.5)
    if q < 0 then q = 0 end
    if q > 4 then q = 4 end
    local pct = UPSCALE_PCT[q + 1] or 67

    -- Every temporal upscaler needs temporal AA to be the one doing it.
    add("r.DefaultFeature.AntiAliasing", 2)   -- 2 = TemporalAA
    add("r.TemporalAA.Upsampling", 1)
    -- THE RENDER RESOLUTION, THE VR WAY.
    --
    -- `r.ScreenPercentage` is the flat-screen knob. In VR the size of the eye
    -- buffers is `vr.PixelDensity`, and setting the flat one instead leaves
    -- the headset rendering at full size while the upscaler does its work on
    -- top - all of the cost and none of the saving. A session that picked
    -- DLSS at Ultra Quality went from 59 fps to 10.
    --
    -- Both are set, in the right order: pixel density is what actually moves
    -- in VR, and screen percentage is left at 100 so nothing double-counts.
    -- The auto-resolution loop owns pixel density while it runs, so it is
    -- skipped then.
    add("r.ScreenPercentage", 100)
    if not s.OptAutoRes then
        add("vr.PixelDensity", pct / 100.0)
    end

    if mode == 2 then            -- AMD FSR 1
        add("r.FidelityFX.FSR.Enabled", 1)
        add("r.FidelityFX.FSR.PrimaryUpscale.Enabled", 1)
        add("r.FidelityFX.FSR.Sharpness", 0.7)
    elseif mode == 3 then        -- AMD FSR 2
        add("r.FidelityFX.FSR2.Enabled", 1)
        add("r.FidelityFX.FSR2.QualityMode", FSR2_MODE[q + 1] or 2)
        add("r.FidelityFX.FSR2.Sharpness", 0.5)
    elseif mode == 4 then        -- NVIDIA DLSS
        add("r.NGX.Enable", 1)
        add("r.NGX.DLSS.Enable", 1)
        add("r.NGX.DLSS.Quality", DLSS_QUALITY[q + 1] or 0)
    else                         -- BUILT-IN temporal upsampling
        -- A little more history than the desktop default: in VR the image is
        -- moving all the time and a low weight is what stops it shimmering.
        add("r.TemporalAASamples", 8)
        add("r.TemporalAACurrentFrameWeight", 0.12)
    end
    -- Upscaling always softens the picture; put a little of it back.
    if not (type(s.OptSharpen) == "number" and s.OptSharpen > 0) then
        add("r.Tonemapper.Sharpen", 0.5)
    end
end

-- Everything else the GPU page can ask for. All of these are "0/-1 means
-- leave the game's own value alone", so an untouched row issues nothing.
local function gpuCvars(s, add)
    local function step(key, cvar, floorAt)
        local v = s[key]
        if type(v) == "number" and v >= (floorAt or 0) then
            add(cvar, math.floor(v + 0.5))
        end
    end
    local function scale(key, cvar)
        local v = s[key]
        if type(v) == "number" and v > 0 then add(cvar, v) end
    end

    scale("OptSharpen",      "r.Tonemapper.Sharpen")
    scale("OptShadowDist",   "r.Shadow.DistanceScale")
    scale("OptAnisotropy",   "r.MaxAnisotropy")
    if type(s.OptCSMRes) == "number" and s.OptCSMRes > 0 then
        add("r.Shadow.MaxCSMResolution", math.floor(s.OptCSMRes + 0.5))
    end
    step("OptSSR",        "r.SSR.Quality", 0)
    step("OptAO",         "r.AmbientOcclusionLevels", 0)
    step("OptMotionBlur", "r.MotionBlurQuality", 0)
    step("OptDoF",        "r.DepthOfFieldQuality", 0)
    step("OptParticleLOD", "r.ParticleLODBias", 1)
    step("OptMipBias",    "r.Streaming.MipBias", 1)

    -- VR-only wins.
    --
    -- The desktop mirror is a SECOND render of the whole scene every frame,
    -- for a window you are not looking at. Turning it off is the cheapest
    -- frame rate in the whole optimizer - the only cost is that the monitor
    -- goes black, which also means screenshots stop working.
    if s.OptNoSpectator then add("vr.SpectatorScreenMode", 0) end
    -- Occlusion queries for one eye per frame instead of both.
    if s.OptRoundRobin then add("vr.RoundRobinOcclusion", 1) end
    -- Steadier frame delivery: let the render thread run a frame behind, and
    -- do not make the game thread wait for the GPU to finish the frame it is
    -- on. Helps judder far more than average fps.
    --
    -- `r.GTSyncType` is deliberately NOT here. It re-times the game thread
    -- against the RHI thread, and in VR the headset runtime already owns that
    -- timing - the two fight, and the session that had it on ran at 10 fps.
    if s.OptFramePacing then
        add("r.OneFrameThreadLag", 1)
        add("r.FinishCurrentFrame", 0)
    end
end

---------------------------------------------------------------------------
-- MEMORY, CPU AND THE REST OF THE MACHINE
---------------------------------------------------------------------------
-- Everything above this point is about the GPU. Frame rate in a VR game with
-- forty bodies on the floor is often not the GPU at all: it is the garbage
-- collector taking a long pause, the texture streamer thrashing a small pool,
-- physics running on one core, or audio voices piling up.
--
-- These default to "leave it alone" and only ever issue what has been asked
-- for. The RAM figures are given in plain megabytes, because that is what the
-- number on the box says.

-- FEWER CLEAN-UP PAUSES, NOT MORE (2026-10-15). These used to make the
-- collector run every 30 / 15 / 8 s, on the idea that smaller passes hitch
-- less. In UE 4.27 they do not: every pass stops the world to walk EVERY live
-- object, however little garbage there is, so twice as often was twice the
-- hitches - "the lagging in rounds". A round ends in a map load, which
-- collects anyway, so during a round the kindest setting is to wait longer.
Opt.GC_NAMES = { "GAME DEFAULT", "LESS OFTEN (every 2 min)", "RARELY (every 5 min)",
                 "BETWEEN ROUNDS (every 10 min)" }
local GC_SECONDS = { nil, 120, 300, 600 }

Opt.PHYS_NAMES = { "GAME DEFAULT", "2 THREADS", "4 THREADS", "6 THREADS",
                   "ALL CORES" }
local PHYS_THREADS = { nil, 2, 4, 6, 16 }

function Opt.GcName(i) return Opt.GC_NAMES[math.floor((i or 0) + 0.5) + 1] or "?" end
function Opt.PhysName(i) return Opt.PHYS_NAMES[math.floor((i or 0) + 0.5) + 1] or "?" end

local function systemCvars(s, add)
    -- ---- MEMORY -------------------------------------------------------
    -- The texture pool is the big one. Too small and the streamer swaps
    -- textures in and out for ever (that is the blurry-then-sharp pop, and
    -- the hitching that comes with it); too big and you run the card out of
    -- memory. It is already on the OPT CUSTOM page as OptTexturePool.
    if type(s.OptRamMipBias) == "number" and s.OptRamMipBias > 0 then
        add("r.Streaming.MipBias", s.OptRamMipBias)
    end
    if s.OptStreamBoost then
        -- Let the streamer use more of the pool before it starts dropping
        -- detail, and give it more time per frame to get the work done.
        add("r.Streaming.Boost", 1)
        add("r.Streaming.MaxTempMemoryAllowed", 128)
        add("r.Streaming.FramesForFullUpdate", 1)
    end
    if s.OptTrimRam then
        -- Hand memory back to Windows instead of sitting on it. Worth having
        -- on a machine that is doing something else as well.
        add("r.Streaming.PoolSizeForMeshes", -1)
        add("s.ForceGCAfterLevelStreamedOut", 1)
        add("s.ContinuouslyIncrementalGCWhileLevelsPendingPurge", 1)
    end

    -- ---- THE GARBAGE COLLECTOR ----------------------------------------
    -- Unreal stops the world to clear out dead objects. The default is one
    -- big pause about once a minute, which in VR is a lurch you feel. More
    -- frequent, smaller passes trade a little average frame time for not
    -- being thrown out of the game every minute.
    local gc = math.floor((s.OptGcMode or 0) + 0.5)
    local secs = GC_SECONDS[gc + 1]
    if secs then
        -- only the interval. NumRetriesBeforeForcingGC 3 FORCED a blocking
        -- collection sooner whenever streaming held one off; the others were
        -- the engine's defaults already.
        add("gc.TimeBetweenPurgingPendingKillObjects", secs)
    end

    -- ---- THE CPU ------------------------------------------------------
    -- Physics is what a pile of ragdolls costs, and by default a lot of it
    -- runs on one thread. Blood Trail leaves bodies lying around, so this is
    -- the setting that matters most once a round has been going a while.
    local pt = PHYS_THREADS[math.floor((s.OptPhysThreads or 0) + 0.5) + 1]
    if pt then
        add("p.NumPhysXThreads", pt)
        add("p.PhysXTreeRebuildRate", 10)
    end
    if s.OptFewerRagdolls then
        -- Let bodies settle and stop simulating sooner. A ragdoll that has
        -- come to rest still costs a solve every frame until it sleeps.
        add("p.MaxVelocityIterations", 1)
        add("p.MaxPositionIterations", 4)
        add("p.SleepThresholdMultiplier", 3)
        add("p.bEnableAsyncScene", 1)
    end
    if s.OptAnimBudget then
        -- Animation for characters you are not looking at, cheaper. The
        -- enemies are the only skinned meshes on screen in any number.
        add("a.URO.Enable", 1)
        add("a.URO.ForceAnimRate", 2)
        add("a.ParallelAnimEvaluation", 1)
        add("a.ParallelAnimUpdate", 1)
    end

    -- ---- AUDIO --------------------------------------------------------
    -- Every gunshot, scream and impact is a voice. They are cheap on their
    -- own and not cheap forty at a time.
    if type(s.OptAudioVoices) == "number" and s.OptAudioVoices > 0 then
        add("au.MaxConcurrentStreams", s.OptAudioVoices)
        add("au.LinearGainScalar", 1)
    end

    -- ---- LOADING ------------------------------------------------------
    if s.OptFastLoad then
        add("s.AsyncLoadingThreadEnabled", 1)
        add("s.EventDrivenLoaderEnabled", 1)
        add("s.AsyncLoadingTimeLimit", 4)
        add("s.PriorityAsyncLoadingExtraTime", 15)
    end
end

-- Toggles that apply on top of whichever preset or custom set is active.
local function extraCvars(s, out)
    local function add(name, v) out[#out + 1] = { name, v } end
    if type(s.OptFpsCap) == "number" and s.OptFpsCap > 0 then add("t.MaxFPS", s.OptFpsCap) end
    if s.OptNoFog          then add("r.VolumetricFog", 0) end
    if s.OptNoLensFlares   then add("r.LensFlareQuality", 0) end
    if s.OptNoLightShafts  then add("r.LightShaftQuality", 0) end
    if s.OptNoBloom        then add("r.BloomQuality", 0) end
    -- Blood decals fade out sooner. The game paints a LOT of them.
    if s.OptFastDecalFade  then add("r.Decal.FadeDurationScale", 0.3) end
    -- Fewer clean-up pauses during a round: every pass costs the same, so
    -- the only way to have fewer hitches is fewer passes (default 61 s).
    if s.OptSmoothGC       then add("gc.TimeBetweenPurgingPendingKillObjects", 120) end
    -- Spread level streaming over more frames: loads take a little longer,
    -- the stutter when a Raid section streams in is smaller.
    if s.OptSmoothStreaming then
        add("s.AsyncLoadingTimeLimit", 2)
        add("s.LevelStreamingComponentsRegistrationGranularity", 5)
    end

    -- The GPU page, applied on top of whatever preset is running so it works
    -- without having to turn Custom on first.
    upscaleCvars(s, add)
    gpuCvars(s, add)
    systemCvars(s, add)
end

-- The final list the current settings ask for: one entry per cvar (the last
-- value asked for wins), with every sg.* scalability group FIRST.
--
-- Ordering is not cosmetic. A scalability group rewrites the r.* settings
-- underneath it, so a custom "Shadows" group landing after a preset's
-- r.Shadow.MaxResolution would silently stamp that value back out.
local function desiredList(s)
    local raw = {}
    if not s.OptEnabled then return {} end
    local p = Opt.PRESETS[math.floor((s.OptPreset or 1) + 0.5)]
    if p then
        for _, cv in ipairs(p.cvars) do raw[#raw + 1] = cv end
    end
    if s.OptCustom then customCvars(s, raw) end
    extraCvars(s, raw)

    local last, order = {}, {}
    for _, cv in ipairs(raw) do
        -- auto resolution owns pixel density while it runs
        if not (s.OptAutoRes and cv[1] == "vr.PixelDensity") then
            if last[cv[1]] == nil then order[#order + 1] = cv[1] end
            last[cv[1]] = cv[2]
        end
    end

    local out = {}
    for _, name in ipairs(order) do
        if string.sub(name, 1, 3) == "sg." then out[#out + 1] = { name, last[name] } end
    end
    for _, name in ipairs(order) do
        if string.sub(name, 1, 3) ~= "sg." then out[#out + 1] = { name, last[name] } end
    end
    return out
end

---------------------------------------------------------------------------
-- applying, with the originals captured first
---------------------------------------------------------------------------

Opt.original = {}      -- [cvar] = value the game had before we ever touched it
Opt.applied  = {}      -- [cvar] = string we last issued
Opt.applyCount = 0
Opt.lastReport = "not applied yet"

-- THE CONSOLE IS GAME-THREAD WORK (2026-10-05).
--
-- UE4SS writes crash dumps of its own next to the game, and the one from
-- 28 September 00:23 carries the mod's Lua stack: the game faulted at
-- BTVR+0x1213dd1 INSIDE the ExecuteConsoleCommand this file used to make,
-- from the loop thread. That is the same 0x40 crash as on 18 and 27
-- September. A console command runs the setting's own handlers - render
-- targets, scalability groups - and those belong to the game thread.
--
-- So nothing here talks to the console directly any more. Commands are
-- queued in order, and the batch runs as ONE job through the mod's
-- game-thread door, reading the game's own value of each setting just before
-- the first write to it (the read is a call into the engine too).
Opt.console = {}          -- { name, text } waiting for the game thread, in order
Opt.consoleSent = 0

local function queueConsole(name, text)
    Opt.console[#Opt.console + 1] = { name, text }
end

function Opt.FlushConsole()
    if #Opt.console == 0 then return end
    local batch = Opt.console
    Opt.console = {}
    local function run()
        local K = ksl()
        local ctx = PlayerMods.GetPawn()
        if not (K and alive(ctx)) then return end
        for _, c in ipairs(batch) do
            local name, text = c[1], c[2]
            if Opt.original[name] == nil then
                local okR, v = pcall(function() return K:GetConsoleVariableFloatValue(name) end)
                if okR and type(v) == "number" then Opt.original[name] = v end
            end
            local ok = pcall(function()
                K:ExecuteConsoleCommand(ctx, name .. " " .. text, nil)
            end)
            if ok then Opt.consoleSent = Opt.consoleSent + 1 end
        end
    end
    if PlayerMods.InGameThread then
        PlayerMods.InGameThread("opt-console", run)
    else
        run()
    end
end

-- (the game's own value is read in the batch, just before the first write)
local function captureOriginal(name) end

local function issue(name, value)
    local text = fmtNum(value)
    if Opt.applied[name] == text then return false end
    queueConsole(name, text)
    Opt.applied[name] = text
    Opt.applyCount = Opt.applyCount + 1
    return true
end

-- Put back the game's own value for every cvar we changed that the current
-- settings no longer ask for.
local function restoreDropped(wanted)
    local autoOwnsDensity = PlayerMods.state.OptEnabled and PlayerMods.state.OptAutoRes
    for name, _ in pairs(Opt.applied) do
        if wanted[name] == nil and not (autoOwnsDensity and name == "vr.PixelDensity") then
            local orig = Opt.original[name]
            if orig ~= nil then
                queueConsole(name, fmtNum(orig))
            end
            Opt.applied[name] = nil
        end
    end
end

-- full = re-issue everything (a new world, or a scalability group changed and
-- stamped over the r.* settings under it)
-- Nothing here needs KismetSystemLibrary: every command is queued, and the
-- batch job finds it ON THE GAME THREAD (FlushConsole). Asking for it here,
-- on the loop, found nothing whenever the kept one had gone - and the change
-- you had just made was dropped for good.
function Opt.Apply(ctx, full)
    if not alive(ctx) then return false end
    local s = PlayerMods.state

    local list = desiredList(s)
    local wanted = {}
    for _, cv in ipairs(list) do
        captureOriginal(cv[1])
        wanted[cv[1]] = cv[2]
    end

    -- A scalability group resets the settings underneath it. If any of them is
    -- about to change, every other cvar must be re-issued after it.
    if not full then
        for _, cv in ipairs(list) do
            if string.sub(cv[1], 1, 3) == "sg." and Opt.applied[cv[1]] ~= fmtNum(cv[2]) then
                full = true
                break
            end
        end
    end
    -- Restore BEFORE forgetting what was applied. Clearing first on a full
    -- re-apply meant a setting switched off since the last world (say No Fog)
    -- was never put back - cvars outlive level travel.
    restoreDropped(wanted)
    if full then
        -- keep the auto-resolution value; it is re-asserted by its own loop
        local keepDensity = Opt.applied["vr.PixelDensity"]
        Opt.applied = {}
        if PlayerMods.state.OptAutoRes then Opt.applied["vr.PixelDensity"] = keepDensity end
    end

    for _, cv in ipairs(list) do
        issue(cv[1], cv[2])
    end
    Opt.FlushConsole()

    if s.OptEnabled then
        Opt.lastReport = string.format("%s%s  %d settings",
            Opt.PresetName(s.OptPreset), s.OptCustom and " + custom" or "", #list)
    else
        Opt.lastReport = "off - game settings"
    end
    return true
end

-- Everything back exactly as the game had it.
function Opt.ResetToGame(ctx)
    if not alive(ctx) then return end
    for name, orig in pairs(Opt.original) do
        queueConsole(name, fmtNum(orig))
    end
    Opt.FlushConsole()
    Opt.applied = {}
    Opt.autoDensity = nil
    Opt.lastReport = "reset to the game's own settings"
end

---------------------------------------------------------------------------
-- corpse / blood cleanup on the player pawn
---------------------------------------------------------------------------

local goreOrig = { pawn = nil }

local function pawnGoreTick(pawn, kind)
    local s = PlayerMods.state
    local okA, addr = pcall(function() return pawn:GetAddress() end)
    if not okA then return end
    -- EVERY read and write goes through the schema. The two pawns do not share
    -- these: PlayerOptionFreezeRagdolls exists on WendigoVrChar_C only
    -- (WendigoVrChar.hpp:280, absent from BP_VRCharacter.hpp). Reading a
    -- property a class does not have is the native crash pcall cannot catch -
    -- a pcall around the READ is no protection at all. Fail closed: with no
    -- schema check available, touch nothing.
    local has = PlayerMods.hasProp
    local function ok(prop) return has ~= nil and has(kind, prop) end

    if goreOrig.pawn ~= addr then
        -- a new body: capture its own values once, before any write
        goreOrig = { pawn = addr }
        if ok("RagdollLifetimeInSeconds") then
            pcall(function() goreOrig.ragdoll = pawn.RagdollLifetimeInSeconds end)
        end
        if ok("DecalLifetimeInSeconds") then
            pcall(function() goreOrig.decal = pawn.DecalLifetimeInSeconds end)
        end
        if ok("PlayerOptionFreezeRagdolls") then
            pcall(function() goreOrig.freeze = pawn.PlayerOptionFreezeRagdolls end)
        end
    end

    -- "Gore Never Despawns" asks for the opposite; it wins, and cleanup waits.
    if s.GoreForever then return end

    local function write(prop, value)
        if not ok(prop) then return end
        pcall(function() pawn[prop] = value end)
    end

    if s.OptEnabled and s.OptCorpseCleanup then
        write("RagdollLifetimeInSeconds", math.floor((s.OptCorpseSeconds or 20) + 0.5))
        goreOrig.ragdollTouched = true
    elseif goreOrig.ragdollTouched and type(goreOrig.ragdoll) == "number" then
        write("RagdollLifetimeInSeconds", goreOrig.ragdoll)
        goreOrig.ragdollTouched = false
    end

    if s.OptEnabled and s.OptBloodCleanup then
        write("DecalLifetimeInSeconds", math.floor((s.OptBloodSeconds or 30) + 0.5))
        goreOrig.decalTouched = true
    elseif goreOrig.decalTouched and type(goreOrig.decal) == "number" then
        write("DecalLifetimeInSeconds", goreOrig.decal)
        goreOrig.decalTouched = false
    end

    if s.OptEnabled and s.OptFreezeBodies then
        write("PlayerOptionFreezeRagdolls", true)
        goreOrig.freezeTouched = true
    elseif goreOrig.freezeTouched and type(goreOrig.freeze) == "boolean" then
        write("PlayerOptionFreezeRagdolls", goreOrig.freeze)
        goreOrig.freezeTouched = false
    end
end

---------------------------------------------------------------------------
-- FPS meter
---------------------------------------------------------------------------
-- Sampled once per loop tick (10 Hz). Each sample is the length of whichever
-- frame was most recent, so twenty samples make a fair two-second average and
-- the slowest of them is a usable "worst frame". World delta is scaled by time
-- dilation, so divide it back out - otherwise Slow Motion reads as 400 FPS.

local samples, sampleIdx = {}, 0
local SAMPLE_WINDOW = 20
Opt.fps, Opt.frameMs, Opt.lowFps = 0, 0, 0

local function sampleFrame(pawn)
    local G = gps()
    if not G then return end
    local okD, dt = pcall(function() return G:GetWorldDeltaSeconds(pawn) end)
    if not (okD and type(dt) == "number" and dt > 0) then return end
    local okT, dil = pcall(function() return G:GetGlobalTimeDilation(pawn) end)
    if okT and type(dil) == "number" and dil > 0.01 then dt = dt / dil end
    if dt > 1.0 then return end          -- a level load, not a frame

    sampleIdx = (sampleIdx % SAMPLE_WINDOW) + 1
    samples[sampleIdx] = dt

    local sum, worst, n = 0, 0, 0
    for _, v in pairs(samples) do
        sum = sum + v
        n = n + 1
        if v > worst then worst = v end
    end
    if n == 0 or sum <= 0 then return end
    local avg = sum / n
    Opt.frameMs = avg * 1000.0
    Opt.fps = 1.0 / avg
    Opt.lowFps = (worst > 0) and (1.0 / worst) or 0
end

function Opt.FpsText()
    if Opt.fps <= 0 then return "measuring..." end
    return string.format("%.0f fps  %.1f ms  low %.0f", Opt.fps, Opt.frameMs, Opt.lowFps)
end

---------------------------------------------------------------------------
-- auto resolution: hold a target frame rate
---------------------------------------------------------------------------
-- Every few seconds, compare the average to the target and move pixel density
-- one small step. Changing it reallocates the eye buffers, which is a brief
-- hitch of its own, so there is a long cooldown and a dead band either side of
-- the target so it does not hunt.

Opt.autoDensity = nil
Opt.autoReport = "off"
local autoCooldown = 0

local function autoResTick(ctx)
    local s = PlayerMods.state
    if not (s.OptEnabled and s.OptAutoRes) then
        if Opt.autoDensity ~= nil then
            Opt.autoDensity = nil
            Opt.autoReport = "off"
            -- Hand pixel density back. The applied entry is deliberately KEPT:
            -- the next Apply then either re-issues the preset's own value (it
            -- differs) or, if nothing asks for density, restores the game's.
            -- Clearing it here left the auto value stuck on screen.
            Opt.dirty = true
        end
        return
    end
    autoCooldown = autoCooldown - 1
    if autoCooldown > 0 or Opt.fps <= 0 then return end

    local target = s.OptTargetFps or 72
    local maxD = s.OptAutoMax or 1.0
    local minD = s.OptAutoMin or 0.6
    if Opt.autoDensity == nil then Opt.autoDensity = maxD end

    local d = Opt.autoDensity
    if Opt.fps < (target - 4) and d > minD then
        d = math.max(minD, d - 0.05)
    elseif Opt.fps > (target + 10) and d < maxD then
        d = math.min(maxD, d + 0.05)
    end

    if math.abs(d - Opt.autoDensity) > 0.001 or Opt.applied["vr.PixelDensity"] == nil then
        Opt.autoDensity = d
        if alive(ctx) then
            captureOriginal("vr.PixelDensity")
            issue("vr.PixelDensity", d)
            Opt.FlushConsole()
        end
        autoCooldown = 60          -- 6 s at 10 Hz
    else
        autoCooldown = 20          -- 2 s
    end
    Opt.autoReport = string.format("density %.2f  (target %d fps)", Opt.autoDensity, target)
end

---------------------------------------------------------------------------
-- the tick
---------------------------------------------------------------------------

local lastSig = nil
local worldDirty = true
local goreEvery = 0

-- Everything that changes the cvar list, as one string. Rebuilding the list
-- every tick allocates for nothing; this only rebuilds when a setting moved.
local SIG_KEYS = {
    "OptEnabled", "OptPreset", "OptCustom", "OptShadows", "OptViewDistance",
    "OptFoliage", "OptEffects", "OptPostProcess", "OptTextures", "OptResolution",
    "OptPixelDensity", "OptTexturePool", "OptEnemyDetail", "OptFpsCap",
    "OptNoFog", "OptNoLensFlares", "OptNoLightShafts", "OptNoBloom",
    "OptFastDecalFade", "OptSmoothGC", "OptSmoothStreaming", "OptAutoRes",
}

local function signature(s)
    local parts = {}
    for i, k in ipairs(SIG_KEYS) do parts[i] = tostring(s[k]) end
    return table.concat(parts, "|")
end

function Opt.OnWorldChange()
    worldDirty = true
    goreOrig = { pawn = nil }
end

-- settled = the world has held still long enough for object work
function Opt.Tick(settled)
    if not PlayerMods then return end
    local pawn, kind = PlayerMods.GetPawn()
    if not alive(pawn) then return end
    local s = PlayerMods.state

    sampleFrame(pawn)

    goreEvery = goreEvery + 1
    if goreEvery >= 10 then            -- 1 Hz is plenty for three flags
        goreEvery = 0
        pawnGoreTick(pawn, kind)
    end

    if not settled then return end

    local sig = signature(s)
    if worldDirty or Opt.dirty or sig ~= lastSig then
        -- never touch the console on a fresh launch until the feature is used
        local everUsed = s.OptEnabled or next(Opt.applied) ~= nil
        if everUsed then
            Opt.Apply(pawn, worldDirty)
        end
        lastSig = sig
        worldDirty = false
        Opt.dirty = false
    end

    autoResTick(pawn)
end

-- one-shot from the menu or the app
function Opt.ApplyNow()
    local pawn = PlayerMods.GetPawn()
    if alive(pawn) then Opt.Apply(pawn, true) end
end

function Opt.ResetNow()
    local s = PlayerMods.state
    s.OptEnabled = false
    s.OptCustom = false
    s.OptAutoRes = false
    local pawn = PlayerMods.GetPawn()
    if alive(pawn) then Opt.ResetToGame(pawn) end
    lastSig = signature(s)
end

function Opt.StatusLine()
    return string.format("fps=%.0f ms=%.1f low=%.0f applied=%d report=%s auto=%s captured=%d",
        Opt.fps, Opt.frameMs, Opt.lowFps, Opt.applyCount, Opt.lastReport,
        Opt.autoReport, (function() local n = 0 for _ in pairs(Opt.original) do n = n + 1 end return n end)())
end

return Opt
