--[[
    Dungeon Quest - Overhead Teleport Auto Dodger

    Design goals:
      * Stay above the current/nearest mob.
      * Lightweight velocity follower while tracking; teleport only when a distinct attack actually threatens the held point.
      * Treat hostile geometry as XZ-dangerous regardless of player Y.
      * Exact BridgeNet2 precast detection for Cube/Circle.
      * Conservative fallback detection for EnemyEffects, map-specific boss remotes,
        enemy-owned transient attack/projectile parts, and melee animation windups.
      * Commit to a dodge point and hold it; re-dodge only for a NEW distinct threat that makes that held point unsafe.
      * Compact semi-transparent Enum.Font.Code HUD.
      * Auto-combat through the game's native Q/E ability pipeline (Q priority), driven directly by the game cooldown/busy values.
      * 3D target-lock aiming before every cast so directional skills point at the mob.
      * Exact Aquatic Temple Temple Core Generator Water Line / Water Orb event geometry.
      * Dump-derived Temple Core kill-column prediction, full orb-path avoidance, and dynamic body-safe hover height.

    Notes:
      * The decompiled PrecastHitbox module only renders the telegraph client-side.
        The server damage code is not in the dump, so this script intentionally DOES
        NOT assume high Y makes a precast harmless.
      * Precasts/beams/projectiles are intentionally tested in XZ regardless of Y.
      * Melee is different: it only counts when the player is within the mob's estimated TRUE 3D attack reach, so normal overhead hovering ignores it.
]]

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

--// Configuration
local CFG = {
    ENABLED = true,

    -- Overhead behavior
    OVERHEAD_HEIGHT = 18,              -- Y is always targetMobY + this value
    FOLLOW_UPDATE_INTERVAL = 0.06,      -- ~16 Hz follower update; avoids per-frame physics churn
    FOLLOW_GAIN_XZ = 4.0,
    FOLLOW_GAIN_Y = 5.0,
    -- The fresh client dump does not expose a server anti-cheat threshold, but it
    -- consistently treats Humanoid.WalkSpeed as the live movement-speed state.
    -- Never request faster replicated movement than that live server-owned value.
    FOLLOW_MAX_FORCE = 30000,
    FORCED_WALK_SPEED = 27.5,
    SERVER_SPEED_FALLBACK = 27.5,
    SERVER_TRACK_SPEED_MULT = 1.00,
    SERVER_DODGE_SPEED_MULT = 1.00,
    SERVER_SPEED_MIN = 4.0,
    SERVER_SPEED_MAX = 48.0,
    SERVER_CORRECTION_DISTANCE = 3.0,
    SERVER_CORRECTION_BACKOFF = 0.82,
    SERVER_CORRECTION_MIN_SCALE = 0.62,
    SERVER_CORRECTION_RECOVER_DELAY = 3.0,
    SERVER_CORRECTION_RECOVER_RATE = 0.025,
    -- Dodge uses the same replicated follower, but only the gain changes. The final
    -- velocity cap is always derived from the current Humanoid.WalkSpeed below.
    DODGE_FOLLOW_GAIN_XZ = 10.0,
    DODGE_FOLLOW_GAIN_Y = 7.0,
    TARGET_SCAN_INTERVAL = 0.25,
    TARGET_MAX_DISTANCE = 2000,
    DEEP_NPC_RESCAN_INTERVAL = 2.0,     -- recovery scan only when there are zero LIVE candidates
    SPAWN_REGISTER_RETRY = 0.20,       -- catches mobs whose Humanoid/root replicate on separate frames
    TARGET_STICK_TIME = 0.35,
    OVERHEAD_MODEL_CLEARANCE = 8,
    OVERHEAD_MAX_DYNAMIC_HEIGHT = 120,   -- sanity ceiling relative to target root; far above old 34-stud clamp
    OVERHEAD_GEOMETRY_REFRESH_INTERVAL = 0.12,
    PLAYER_ROOT_TO_BOTTOM_FALLBACK = 3.25,
    TARGET_BODY_XZ_CLEARANCE = 3.0,
    TEMPLE_CORE_HEADORB_CLEARANCE = 10.0,

    -- Temple Core Generator uses a ground walking profile instead of overhead.
    -- Its mechanics are arena/XZ based, and the dump showed overhead creates extra
    -- interactions with tall columns/orbs without granting immunity.
    -- Temple Core now uses the SAME overhead movement controller as every other enemy.
    -- Boss-specific ATTACK detection remains enabled, but there is no floor/walk/TP movement mode.
    TEMPLE_CORE_WALK_MODE = false,
    TEMPLE_CORE_FLOOR_TELEPORT = false,
    TEMPLE_CORE_FLOOR_FOLLOW_SNAP = 0.25,
    TEMPLE_CORE_FLOOR_FOLLOW_INTERVAL = 0.030,
    TEMPLE_CORE_FLOOR_SEARCH_RADII = {4, 6, 8, 10, 12, 15, 18, 22, 26, 32, 40, 50},
    TEMPLE_CORE_FLOOR_SEARCH_ANGLES = 32,
    TEMPLE_CORE_FLOOR_THREAT_MARGIN = 3.5,
    TEMPLE_CORE_FLOOR_FAILSAFE_RADIUS = 56.0,
    TEMPLE_CORE_WALK_IDLE_RADIUS = 5.0,    -- requested: hug boss; body/hazard checks push outward only as needed
    TEMPLE_CORE_WALK_MAX_IDLE_RADIUS = 26.0,
    TEMPLE_CORE_WALK_IDLE_RADII = {5, 7, 9, 11, 13, 16, 19, 22, 26},
    TEMPLE_CORE_WALK_SPEED = 90.0,         -- fast enough to clear short telegraphs
    TEMPLE_CORE_WALK_GOAL_REFRESH = 0.045,
    TEMPLE_CORE_WALK_REACH = 1.6,
    TEMPLE_CORE_WALK_PATH_STEP = 1.35,     -- sample full MoveTo segment, not only endpoint
    TEMPLE_CORE_WALK_ROUTE_RADII = {4, 6, 8, 10, 13, 16, 20},
    TEMPLE_CORE_WALK_ROUTE_ANGLES = 24,
    TEMPLE_CORE_GROUND_RAY_UP = 90.0,
    TEMPLE_CORE_GROUND_RAY_DOWN = 220.0,
    TEMPLE_CORE_GROUND_ROOT_CLEARANCE = 0.18,

    -- Dodge behavior
    -- Larger fallback rings are only used when normal close offsets are unsafe.
    -- They matter for true homing projectiles: one side-step needs enough room for
    -- the projectile to pass before it is allowed to re-arm for another approach.
    -- Tight rings first: stay as close to the target as safety allows.
    DODGE_RADII = {4, 6, 8, 10, 12, 15, 18, 22, 27, 33, 42, 54, 66},
    DODGE_ANGLES = 24,                 -- ORIGINAL dodge sampling / feel
    SAFETY_MARGIN = 4.5,
    DODGE_CLEARANCE_REWARD = 0.62,     -- among equally-close safe points, prefer the one deeper inside free space
    -- Strategic combat-preserving dodge scoring. Safety/reachability come first, but
    -- among safe choices hug the current enemy so Q/E stay in range and directional
    -- casts continue landing instead of fleeing to an unnecessarily distant ring.
    STRATEGIC_DODGE = true,
    STRATEGIC_COMBAT_RANGE_BUFFER = 2.0, -- target <= COMBAT_MAX_XZ_RANGE - this whenever possible
    STRATEGIC_TARGET_DIST_WEIGHT = 12.0, -- strongest tie-breaker: stay close to enemy
    STRATEGIC_MOVE_DIST_WEIGHT = 1.15,   -- then prefer a short server-accepted route
    STRATEGIC_INERTIA_WEIGHT = 0.10,
    STRATEGIC_CLEARANCE_REWARD = 0.18,  -- small reward only; never flee far just for clearance
    STRATEGIC_ROUTE_STEP = 2.5,
    PROJECTILE_PREDICT_TIME = 0.70,
    PROJECTILE_EXTRA_LOOKAHEAD = 0.35, -- reserve a little farther down moving projectile paths
    PROJECTILE_LATENCY_PAD_TIME = 0.075,-- convert projectile speed into a small replication/latency position pad
    PROJECTILE_MAX_DYNAMIC_PAD = 6.0,
    VISUAL_UNCERTAINTY_PAD = 0.75,      -- generic visual fallbacks are less authoritative than exact remotes
    CLEAR_GRACE = 0.22,
    PRECAST_LINGER = 0.55,

    -- Temple Guard uses the generic ReplicatedStorage.modules.PrecastHitbox.Circle.
    -- The renderer is an anonymous Neon Cylinder, so name-based visual fallback misses it.
    TEMPLE_GUARD_CIRCLE_PAD = 6.0,
    TEMPLE_GUARD_CIRCLE_POST_HIT_HOLD = 0.90,
    GENERIC_RENDERED_CIRCLE_POST_HIT_HOLD = 0.70,
    RENDERED_PRECAST_CIRCLE_SCAN_INTERVAL = 0.025,
    -- Generic PrecastHitbox.Circle itself is 0.5 studs thick, but several dungeon
    -- attack templates use thicker flat cylinders. The anonymous renderer check is
    -- still restricted to direct Workspace Parts named "Part"; named hostile
    -- cylinders are ownership-gated separately below.
    RENDERED_PRECAST_CIRCLE_THICK_MAX = 24.0,
    RENDERED_PRECAST_CIRCLE_MIN_DIAMETER = 4.0,
    RENDERED_PRECAST_CIRCLE_MAX_DIAMETER = 500.0,
    GENERIC_CYLINDER_PAD = 3.5,
    GENERIC_CYLINDER_POST_REMOVE = 0.85,
    GENERIC_CYLINDER_MAX_LIFE = 8.0,
    LARGE_CIRCLE_ESCAPE_PAD = 8.0,
    MAX_ADAPTIVE_DODGE_RADIUS = 180.0,

    -- Temple Guard authoritative damage-part fallback.
    TEMPLE_GUARD_HITBOX_PAD = 5.5,
    TEMPLE_GUARD_HITBOX_POST_REMOVE = 0.85,
    TEMPLE_GUARD_HITBOX_MAX_LIFE = 3.0,
    EVENT_DEFAULT_HOLD = 1.30,
    DODGE_EPISODE_HARD_CAP = 12.0,     -- whole chained attack sequence failsafe
    DODGE_EPISODE_MIN_CAP = 0.75,
    DODGE_DEAD_THREAT_GRACE = 0.16,    -- quiet time before returning overhead
    POST_KILL_THREAT_MIN_HOLD = 1.35,  -- keep known non-melee attacks alive after the mob dies
    POST_KILL_LIVE_PART_GRACE = 1.10,  -- late server damage may trail a destroyed client hitbox
    POST_KILL_QUIET_GRACE = 0.32,      -- require a genuinely quiet window before leaving post-kill hold
    POST_KILL_CAPTURE_WINDOW = 2.50,   -- attacks that replicate just after death inherit post-kill retention
    REDODGE_ENABLED = true,
    REDODGE_MIN_GAP = 0.09,            -- exact/event/melee: fast enough for sequential precast lines
    REDODGE_VISUAL_MIN_GAP = 0.28,     -- visual fallback is noisier, so rate-limit it harder
    REDODGE_MAX_TELEPORTS = 24,        -- safety cap for one continuous boss combo

    -- Melee fallback
    MELEE_SCAN_INTERVAL = 0.10,
    MELEE_DEFAULT_RANGE = 13,
    MELEE_BOSS_MULT = 1.60,
    MELEE_CONE_HALF_ANGLE = math.rad(78),
    MELEE_SPIN_RANGE_MULT = 1.25,
    MELEE_TRACK_MAX_HOLD = 1.35,
    MELEE_RANGE_BUFFER = 1.5,            -- small true-3D reach pad; overhead mobs normally cannot touch us

    -- Transient visual/projectile scan
    VISUAL_MAX_DISTANCE = 280,
    VISUAL_DEFAULT_HOLD = 1.65,
    PROJECTILE_RADIUS_PAD = 4.0,

    -- Volcanic Chambers / Ancient Lava Mage
    -- Decompiled First Boss Orb Explosion expands genericNeonBall to 60x60x60,
    -- i.e. a visible ~30-stud blast radius.  Track the follow orb as an ARMED
    -- moving blast before the explosion event arrives; the explosion event itself
    -- is too late to be our first warning because server damage can resolve that frame.
    VOLCANIC_FOLLOW_ORB_BLAST_RADIUS = 32.0,
    VOLCANIC_FOLLOW_ORB_PREDICT = 0.85, -- known homing orb: reserve more of its incoming path
    VOLCANIC_FOLLOW_ORB_MAX_LIFE = 60.0, -- informational; live Part lifetime is authoritative
    VOLCANIC_FOLLOW_ORB_POST_REMOVE_GRACE = 0.90, -- projectile can vanish on the detonation frame
    VOLCANIC_ORB_EXPLOSION_RADIUS = 34.0,
    VOLCANIC_ORB_EXPLOSION_LINGER = 0.80,
    -- Explosive Lava Walker: the decompiled client exposes the firing event but the
    -- server damage script is absent. Use this only as an early conservative envelope;
    -- live explosiveMobShot1/2/3 geometry supersedes it as soon as it appears.
    VOLCANIC_EXPLOSIVE_WALKER_EVENT_RADIUS = 34.0,
    VOLCANIC_EXPLOSIVE_WALKER_EVENT_HOLD = 1.65,

    -- Artillery Lava Walker. Decompiled volcanicBossSpecficEvents("Artillery Mob Shot", payload)
    -- gives payload[2] = the LOCKED landing CFrame immediately. The client then waits
    -- 0.40s, spawns artilleryRock 100 studs above that XZ, and tweens it down for 0.50s.
    -- Reserve the landing circle from the event itself instead of waiting for the rock visual.
    -- The decompiled impact visual grows to Size 15 after landing. Treat that as a
    -- ~7.5-stud visible radius plus a small local pad; the normal SAFETY_MARGIN is
    -- added separately by the solver. This keeps the ~0.9s warning escapable at the
    -- player's legitimate WalkSpeed instead of reserving an artificial 22-stud radius.
    VOLCANIC_ARTILLERY_IMPACT_RADIUS = 9.25,
    VOLCANIC_ARTILLERY_EVENT_HOLD = 1.45,       -- covers 0.40 + 0.50 travel + impact/removal grace
    VOLCANIC_ARTILLERY_POST_REMOVE = 0.65,
    VOLCANIC_ARTILLERY_MAX_LIFE = 2.20,

    -- Volcanic Chambers / Lava King bomb mechanic. The decompiled client spawns
    -- six `thirdBossCurseRing` parts on the cursed character for 6 seconds. The
    -- bomb is cancelled only by entering the small green safe zone, so this
    -- objective temporarily outranks normal overhead/dodge positioning.
    LAVA_KING_CURSE_RING_NAME = "thirdBossCurseRing",
    LAVA_KING_SAFE_SPOT_NAME = "thirdBossSafeSpot",
    LAVA_KING_CURSE_RADIUS = 15.0,
    LAVA_KING_CURSE_HOLD = 6.25,
    LAVA_KING_SAFE_SCAN_INTERVAL = 0.035,
    LAVA_KING_SAFE_REENTER_INTERVAL = 0.10,
    LAVA_KING_SAFE_CENTER_FRACTION = 0.55, -- stay well inside activation radius
    LAVA_KING_SAFE_MIN_RADIUS = 5.0,
    LAVA_KING_SAFE_MAX_RADIUS = 22.0,
    LAVA_KING_SAFE_GROUND_PAD = 0.18,

    -- Ancient Lava Mage / Searing Orb homing behavior.
    -- The same physical orb is allowed to threaten more than once.  It is disarmed
    -- immediately after a dodge, then re-armed only after it has separated from us,
    -- preventing both "one dodge then die" and rapid CFrame spam.
    SEARING_ORB_HOMING = true,
    SEARING_ORB_TRIGGER_RADIUS = 42.0,   -- arm before the ~30-stud detonation can overlap us
    SEARING_ORB_RELEASE_RADIUS = 62.0,   -- clean separation after an ordinary side dodge
    SEARING_ORB_SIDE_STEP = 64.0,        -- enough space even if the first warning arrives very close
    SEARING_ORB_SIDE_STEP_FAR = 84.0,    -- fallback when other attacks occupy the close side
    SEARING_ORB_REARM_MIN_TIME = 0.075,
    SEARING_ORB_REDODGE_MIN_GAP = 0.12,
    SEARING_ORB_CLOSE_REARM_EXTRA = 16.0, -- re-arm if it never got outside release radius but turns back in
    SEARING_ORB_APPROACH_DOT = 0.10,
    SEARING_ORB_MANUAL_VELOCITY_DT = 0.020,

    -- Aquatic Temple / Temple Core Generator exact boss geometry
    TEMPLE_CORE_LASER_WIDTH = 16.0,     -- dump shows actual Water Line precast is 16x1x150
    TEMPLE_CORE_LASER_LINGER = 0.30,
    TEMPLE_CORE_ORB_RADIUS = 22.0,      -- V3: repeated empty deaths follow moving-orb events; use wider moving body
    TEMPLE_CORE_ORB_LINGER = 1.40,      -- keep danger after client travel ends for delayed server damage
    TEMPLE_CORE_ORB_PREDICT = 1.25,     -- 150 studs / 2 sec ~= 75 studs/s; reserve farther ahead
    TEMPLE_CORE_ORB_PATH_WIDTH = 48.0,  -- V3: conservative full-lane corridor for server-side width / replication
    TEMPLE_CORE_ORB_PATH_LINGER = 1.45,
    TEMPLE_CORE_ORB_ENDPOINT_RADIUS = 34.0,
    TEMPLE_CORE_ORB_START_RADIUS = 26.0,
    TEMPLE_CORE_ORB_STORM_HOLD = 2.75,  -- do not return overhead between ~0.5s chained orb launches

    -- Temple Core passive Water Squares. Normal precasts only need a short post-hit
    -- linger, but this boss can have a moving/sweeping square sequence still active
    -- after the telegraph attack moment. Keep exact Cube geometry conservative for
    -- the boss, and live-track any actual enemy precast/damage Part with a hard cap.
    TEMPLE_CORE_SQUARE_POST_HIT_HOLD = 2.35,
    TEMPLE_CORE_LIVE_PART_MAX = 4.25,
    TEMPLE_CORE_PART_REMOVE_GRACE = 1.25, -- dump #4: lethal HP update trailed a real hitBox touch by ~0.85s
    TEMPLE_CORE_SERVER_DAMAGE_GRACE = 1.15,
    TEMPLE_CORE_SWEEP_REDODGE_GAP = 0.035, -- dump: a spawned column can reach the character ~0.067s later
    TEMPLE_CORE_SWEEP_ACTIVE_HOLD = 1.30, -- do not return overhead between ~1s passive-square sweep steps
    TEMPLE_CORE_SWEEP_PREDICT_TIME = 1.45,-- extrapolate the next sweep step before its kill column is parented
    TEMPLE_CORE_SWEEP_PREDICT_PAD = 10.0,
    TEMPLE_CORE_SWEEP_UNKNOWN_AHEAD = 36.0, -- first sample: reserve both directions until sweep velocity is learned
    TEMPLE_CORE_SQUARE_PRECAST_PAD = 8.0,
    TEMPLE_CORE_SQUARE_XZ = 20.0,         -- dump: Model.hitBox/precast are 20x...x20
    TEMPLE_CORE_COLUMN_MIN_Y = 40.0,      -- dump: real kill column is ~128.3 studs tall
    TEMPLE_CORE_LASER_LENGTH_MIN = 100.0, -- dump: Water Line visual is 16x1x150

    -- Local-player Aquatic ability VFX. The damage probe saw these being spawned
    -- by abilityCast with LocalPlayer as caster; they must never enter the hostile table.
    LOCAL_AQUATIC_FX_QUARANTINE = 2.60, -- Big Phase Ball / Phase Ring can persist >1.4s after our Water Orb cast

    -- Threat hitbox visualizer (solver geometry only, never raw Workspace spam)
    HITBOX_VISUALIZER = true,
    HITBOX_VISUALIZER_KEY = Enum.KeyCode.V,
    HITBOX_VISUALIZER_INTERVAL = 0.08,
    HITBOX_VISUALIZER_TRANSPARENCY = 0.68,
    HITBOX_VISUALIZER_THICKNESS = 0.34,
    HITBOX_VISUALIZER_MAX_DRAW = 80,

    -- Combat / skill automation
    COMBAT_ENABLED = true,
    COMBAT_SCAN_INTERVAL = 0.35,        -- slow safety fallback only; cooldown/busy signals are the fast path
    COMBAT_MAX_XZ_RANGE = 28,          -- do not waste a skill from a far held dodge
    COMBAT_AIM_HOLD = 0.00,            -- no movement hold; visual aim is handled separately
    COMBAT_Q_PRIORITY = true,           -- when both are ready, Q always fires first

    -- Character combat aiming (camera is never modified)
    ALWAYS_FACE_TARGET = true,
    CHARACTER_AIM_ENABLED = true,      -- force character/root pitch + yaw toward the current enemy pack
    CHARACTER_AIM_MAX_XZ_RANGE = 42,   -- include nearby live enemies when computing shared character aim
    CHARACTER_AIM_TARGET_WEIGHT = 1.15,-- slight bias toward selected target while centering the pack

    -- Native auto replay / auto start
    -- Decompiled ReplayDungeonButton sends collectDungeonData() to remotes.replayDungeon.
    -- Replay is armed only after both completion and cloneRewardGui (loot grant) are observed.
    AUTO_REPLAY_ENABLED = true,
    AUTO_REPLAY_MAX_RETRIES = 3,
    AUTO_REPLAY_RETRY_DELAY = 0.85,
    AUTO_START_ENABLED = true,

    -- Noclip (character parts only; writes only when CanCollide was turned back on)
    NOCLIP = true,
    NOCLIP_SWEEP_INTERVAL = 0.18,

    -- HUD
    TOGGLE_KEY = Enum.KeyCode.H,
    HUD_VISIBLE = true,

    -- Optional debugging
    PRINT_EVENTS = false,
}

--// Runtime state
local S = {
    enabled = CFG.ENABLED,
    char = nil,
    hum = nil,
    root = nil,

    target = nil,
    targetRoot = nil,
    targetHum = nil,
    targetSince = 0,
    targetLossHandledFor = nil,
    lastTargetLostAt = 0,
    lastTargetPosition = nil,

    -- Cached target geometry. GetBoundingBox() is relatively expensive, so compute
    -- it at a low rate and reuse it for every dodge candidate in that frame.
    targetGeometryTarget = nil,
    targetGeometryAt = 0,
    targetBoundsCFrame = nil,
    targetBoundsSize = nil,
    targetTopY = nil,
    targetTopOffset = nil,
    characterRootToBottom = nil,
    enemyCache = {},
    enemyRegistry = setmetatable({}, {__mode = "k"}),
    lastDeepNpcScan = 0,
    registryCount = 0,

    threats = {},
    threatCounter = 0,
    activeMeleeTracks = setmetatable({}, {__mode = "k"}),

    dodging = false,
    dodgeOffset = Vector3.zero,
    dodgeWorldGoal = nil,               -- fixed world-space hold point for the entire dodge
    dodgeReason = "none",
    lastDangerTime = 0,
    lastReplan = 0,
    lastTargetScan = 0,
    lastMeleeScan = 0,
    dodgeEpisodeTarget = nil,
    dodgeStartedAt = 0,
    dodgeHardEndAt = 0,
    dodgeTriggerIds = {},              -- union of threats that have actually forced a snap in this chain
    dodgeHandledIds = {},              -- one threat ID can force at most one teleport
    dodgeClearSince = nil,
    dodgeBlockerCount = 0,
    dodgeChainStartedAt = 0,
    dodgeLastTeleportAt = 0,
    dodgeChainTeleports = 0,
    dodgeSequenceReason = "none",
    dodgeUsesWorldSpace = false,        -- target death/change must never invalidate a held safe point

    -- Samurai Palace / Miyamoto state from mapSpecificLocals.client.luau
    miyamotoCycloneThreatId = nil,
    miyamotoFlameThreatIds = {},

    -- Ancient Lava Mage / Searing Orb. Weak keys keep spawned orb models from
    -- being retained after Dungeon Quest destroys them.
    homingOrbThreatByRoot = setmetatable({}, {__mode = "k"}),
    homingOrbDodges = 0,

    -- Lava King bomb / green safe-zone objective. This state is intentionally
    -- independent from the generic threat table: being inside the green circle is
    -- a required mechanic, not merely another low-score dodge candidate.
    lavaKingCurseActiveUntil = 0,
    lavaKingCurseVictim = nil,
    lavaKingCurseResolvedAt = 0,
    lavaKingSafeMode = false,
    lavaKingSafeObject = nil,
    lavaKingSafePart = nil,
    lavaKingSafeGoal = nil,
    lavaKingSafeRadius = 0,
    lavaKingLastSafeScan = -math.huge,
    lavaKingLastSafeTeleport = -math.huge,
    lavaKingSafeEntries = 0,

    -- Temple Core passive square sweep prediction. The dump shows rows of 20x128.3x20
    -- columns advancing in ~1s steps. Once one row has two samples, predict the next
    -- step before the actual kill column appears (appearing itself can already be late).
    templeCoreSweepRows = {},
    templeCoreLastSquareAt = 0,
    templeCoreLastOrbAt = 0,

    -- Noclip
    noclipParts = setmetatable({}, {__mode = "k"}),
    noclipOriginal = setmetatable({}, {__mode = "k"}),
    lastNoclipSweep = 0,
    charConnections = {},

    teleports = 0,
    dodgeCount = 0,
    precastCount = 0,
    precastHookMode = "boot",
    meleeCount = 0,
    projectileCount = 0,
    eventCount = 0,
    lastThreatText = "none",
    lastAction = "boot",

    -- Combat
    abilityUsedRemote = nil,
    lastCombatScan = 0,
    lastCastAt = 0,
    aimHoldUntil = 0,
    qCasts = 0,
    eCasts = 0,
    lastCast = "none",
    qTool = nil,
    eTool = nil,
    qCooldown = 0,
    eCooldown = 0,
    combatStatus = "boot",
    combatDirty = true,
    combatKickScheduled = false,
    combatConnections = {},
    watchedQTool = nil,
    watchedETool = nil,
    characterAimCount = 0,
    characterAimPoint = nil,
    lastLocalCastAt = 0,
    lastLocalCastToolName = "",
    castVisualAimUntil = 0,
    localVisualRoots = setmetatable({}, {__mode = "k"}),
    ignoredOwnVisuals = 0,
    localEffectQuarantine = {},
    precastDedupe = {},

    -- Completion / replay
    replayScheduled = false,
    replayAttempts = 0,
    replayStatus = "armed",
    replayTeleportData = nil,

    hud = nil,
    hudText = nil,

    -- Threat hitbox visualizer
    visualizerEnabled = CFG.HITBOX_VISUALIZER,
    visualizerFolder = nil,
    visualizerParts = {},
    visualizerDrawn = 0,
    lastVisualizerUpdate = 0,

    -- Lightweight non-teleport follower
    hoverAttachment = nil,
    hoverVelocity = nil,
    hoverGoal = nil,
    lastFollowUpdate = 0,
    serverWalkSpeed = 0,
    serverMoveCap = 0,
    serverMoveScale = 1.0,
    serverLastGoalDistance = nil,
    serverLastCorrectionAt = -math.huge,
    serverCorrectionCount = 0,

    -- Temple Core walking mode
    walkModeActive = false,
    walkGoal = nil,
    walkLastMoveAt = 0,
    walkSavedSpeed = nil,
    lastFloorTeleportAt = 0,
    lastRenderedCircleScan = -math.huge,
}

--// Small helpers
local function clock()
    return os.clock()
end

local function serverNow()
    local ok, value = pcall(function()
        return workspace:GetServerTimeNow()
    end)
    return ok and value or time()
end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a, b)
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function flatMagnitude(v)
    return math.sqrt(v.X * v.X + v.Z * v.Z)
end

local function flatUnit(v, fallback)
    local m = flatMagnitude(v)
    if m <= 1e-5 then
        return fallback or Vector3.new(0, 0, -1)
    end
    return Vector3.new(v.X / m, 0, v.Z / m)
end

local function clamp(x, a, b)
    return math.max(a, math.min(b, x))
end

local function lower(x)
    return string.lower(tostring(x or ""))
end

local function containsAny(text, words)
    text = lower(text)
    for _, word in ipairs(words) do
        if string.find(text, word, 1, true) then
            return true
        end
    end
    return false
end

local ATTACK_WORDS = {
    "attack", "slash", "swing", "strike", "slam", "spin", "whirl", "cyclone",
    "punch", "smash", "cleave", "bite", "thrust", "combo", "cast", "stomp",
    "clap", "whip", "crush", "stab", "beam", "laser", "fire", "flame", "breath",
    "orb", "shot", "missile", "rocket", "projectile", "spike", "rock", "explod",
    "geyser", "pulse", "crescent", "line", "blast", "bomb", "shuriken", "curse",
    "mark", "target", "charge", "wall", "rain", "barrage", "aura", "meteor",
    "fall", "drop", "sprinkler", "cannon", "gatling", "wipe", "one shot"
}

local NON_ATTACK_WORDS = {
    "idle", "walk", "walking", "run", "running", "jump", "falling", "swim",
    "movement", "turn", "sit", "death", "die", "dead", "spawn effect", "music"
}

local SAFE_OR_COSMETIC_WORDS = {
    "safe spot", "safe zone", "safe color", "highlight", "particle", "particles",
    "smoke", "sound", "glow", "lower shield", "remove mark", "unmark", "picked up",
    "pick up supplies", "remove supplies", "hide safe", "show safe"
}

local VISUAL_DANGER_WORDS = {
    "precast", "hitbox", "damage", "projectile", "missile", "rocket", "beam", "laser",
    "flame", "fire", "lava", "geyser", "spike", "orb", "blast", "explosion", "bomb",
    "crescent", "shuriken", "rock", "meteor", "breath", "cyclone", "swirl", "strike",
    "slam", "line", "aura", "pulse", "wall", "shot", "explosive", "circle", "cylinder"
}

-- Dungeon Quest separates player spell visuals and mob/boss attack visuals in the
-- decompile: ReplicatedStorage.projectiles vs ReplicatedStorage.enemyProjectiles.
-- Build name indexes from those real template folders so the generic Workspace
-- fallback can reject our own Q/E effects instead of guessing from words like
-- "beam", "orb", "fire", or "hitbox". Exact precasts / EnemyEffects / boss
-- remotes are independent of this filter and remain fully active.
local PLAYER_PROJECTILE_NAMES = {}
local ENEMY_PROJECTILE_NAMES = {}

local function indexProjectileTemplates(folderName, output)
    local folder = ReplicatedStorage:FindFirstChild(folderName)
    if not folder then return end
    for _, child in ipairs(folder:GetChildren()) do
        output[lower(child.Name)] = true
    end
end

indexProjectileTemplates("projectiles", PLAYER_PROJECTILE_NAMES)
indexProjectileTemplates("enemyProjectiles", ENEMY_PROJECTILE_NAMES)

local GENERIC_CAST_WORDS = {
    fire=true, flame=true, beam=true, blast=true, orb=true, strike=true, barrage=true,
    slash=true, storm=true, field=true, rain=true, bomb=true, shot=true, throw=true,
    cyclone=true, spikes=true, spike=true, lightning=true, electric=true, blade=true,
}

local function recentCastMatchesName(name)
    if S.lastLocalCastToolName == "" or clock() - S.lastLocalCastAt > 1.25 then
        return false
    end
    local visualName = lower(name)
    local castName = lower(S.lastLocalCastToolName)
    if visualName == castName or string.find(visualName, castName, 1, true) then
        return true
    end

    local meaningful = 0
    local matched = 0
    for token in string.gmatch(castName, "[%w']+") do
        if #token >= 4 and not GENERIC_CAST_WORDS[token] then
            meaningful += 1
            if string.find(visualName, token, 1, true) then
                matched += 1
            end
        end
    end
    return meaningful > 0 and matched > 0
end

local function ownershipAttributeSaysLocal(inst)
    local keys = {"OwnerUserId", "ownerUserId", "UserId", "userId", "CreatorUserId", "creatorUserId", "Owner", "owner", "Caster", "caster", "Creator", "creator"}
    for _, key in ipairs(keys) do
        local ok, value = pcall(function() return inst:GetAttribute(key) end)
        if ok and value ~= nil then
            if type(value) == "number" and value == LocalPlayer.UserId then return true end
            if type(value) == "string" and (value == LocalPlayer.Name or value == tostring(LocalPlayer.UserId)) then return true end
        end
    end

    for _, child in ipairs(inst:GetChildren()) do
        if child:IsA("ObjectValue") and containsAny(child.Name, {"owner", "caster", "creator", "player", "source"}) then
            local value = child.Value
            if value == LocalPlayer or value == S.char or (typeof(value) == "Instance" and S.char and value:IsDescendantOf(S.char)) then
                return true
            end
        end
    end
    return false
end

local function cleanupLocalEffectQuarantine(now)
    now = now or clock()
    for name, untilAt in pairs(S.localEffectQuarantine) do
        if now >= untilAt then
            S.localEffectQuarantine[name] = nil
        end
    end
end

local function quarantineLocalEffectName(name, duration)
    if not name then return end
    S.localEffectQuarantine[lower(name)] = clock() + (duration or CFG.LOCAL_AQUATIC_FX_QUARANTINE)
end

local function localEffectAncestorIsQuarantined(part)
    cleanupLocalEffectQuarantine()
    local current = part
    for _ = 1, 10 do
        if not current or current == workspace then break end
        local untilAt = S.localEffectQuarantine[lower(current.Name)]
        if untilAt and clock() < untilAt then
            S.localVisualRoots[current] = true
            return true, current
        end
        current = current.Parent
    end
    return false, nil
end

local function classifyVisualSource(part)
    if not part or not part.Parent then return "unknown", nil end
    if S.char and part:IsDescendantOf(S.char) then return "player", S.char end

    local quarantined, qroot = localEffectAncestorIsQuarantined(part)
    if quarantined then
        return "player", qroot
    end

    local current = part
    local playerMatch, enemyMatch
    for _ = 1, 8 do
        if not current or current == workspace then break end

        if S.localVisualRoots[current] then
            return "player", current
        end
        if current:IsA("Model") and (current == S.target or S.enemyRegistry[current]) then
            return "enemy", current
        end
        if ownershipAttributeSaysLocal(current) then
            return "player", current
        end

        local n = lower(current.Name)
        local isPlayerTemplate = PLAYER_PROJECTILE_NAMES[n] == true
        local isEnemyTemplate = ENEMY_PROJECTILE_NAMES[n] == true
        if isPlayerTemplate then playerMatch = playerMatch or current end
        if isEnemyTemplate then enemyMatch = enemyMatch or current end

        -- A handful of names exist in both template folders (for example Flame
        -- Cyclone). If that exact visual appears immediately after our own cast and
        -- matches the cast name, bind that spawned root to the player side.
        if isPlayerTemplate and isEnemyTemplate and recentCastMatchesName(n) then
            S.localVisualRoots[current] = true
            return "player", current
        end

        current = current.Parent
    end

    if enemyMatch and not playerMatch then return "enemy", enemyMatch end
    if playerMatch and not enemyMatch then
        S.localVisualRoots[playerMatch] = true
        return "player", playerMatch
    end
    if enemyMatch and playerMatch then
        -- Shared names exist in both projectile libraries. Never let one of our own
        -- freshly spawned skill effects cause a dodge. During the short local-cast
        -- window, ambiguous shared-template visuals are quarantined as player FX.
        -- Exact enemy precasts and boss remotes bypass this generic visual filter.
        if clock() - (S.lastLocalCastAt or 0) <= 1.25 then
            S.localVisualRoots[playerMatch or enemyMatch] = true
            return "player", playerMatch or enemyMatch
        end
        return "enemy", enemyMatch
    end
    return "unknown", nil
end

local function isPlayerCharacter(model)
    if not model then return false end
    if model == S.char then return true end
    return Players:GetPlayerFromCharacter(model) ~= nil
end

local function getModelParts(model)
    if not model or not model:IsA("Model") then
        return nil, nil
    end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if root and root:IsA("BasePart") then
        return root, hum
    end
    return nil, hum
end

local function isAliveEnemy(model)
    if not model or not model:IsA("Model") or isPlayerCharacter(model) then
        return false
    end
    local root, hum = getModelParts(model)
    if not root or not hum or hum.Health <= 0 then
        return false
    end
    return true
end

local function looksLikeBoss(model, root)
    if containsAny(model and model.Name, {"boss"}) then
        return true
    end
    if root and root.Size.Y > 10 then
        return true
    end
    if model then
        local ok, size = pcall(function() return model:GetExtentsSize() end)
        if ok and size.Y > 13 then
            return true
        end
    end
    return false
end

local function registerEnemyModel(model)
    if not model or not model:IsA("Model") or isPlayerCharacter(model) then
        return false
    end

    -- Dungeon Quest mobs expose these as direct children in the decompile.
    -- Do not require a particular Workspace folder/tag: live dungeons can nest
    -- mob models several levels deep under room/map models.
    local hum = model:FindFirstChild("Humanoid")
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if hum and hum:IsA("Humanoid") and root and root:IsA("BasePart") then
        S.enemyRegistry[model] = true
        return true
    end
    return false
end

local function deepRefreshEnemyRegistry(force)
    -- Full Workspace traversal is the expensive fallback. Do it only during an
    -- actual no-live-target recovery window (or once on startup), never every tick.
    local t = clock()
    if not force and t - S.lastDeepNpcScan < CFG.DEEP_NPC_RESCAN_INTERVAL then
        return false
    end
    S.lastDeepNpcScan = t

    for _, inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("Humanoid") then
            local model = inst.Parent
            if model and model:IsA("Model") then
                registerEnemyModel(model)
            else
                registerEnemyModel(inst:FindFirstAncestorOfClass("Model"))
            end
        end
    end
    return true
end

local function getEnemyCandidates()
    local result = {}
    local seen = {}

    local function add(inst)
        if not inst then return end
        local model = inst:IsA("Model") and inst or inst:FindFirstAncestorOfClass("Model")
        if not model or seen[model] then return end

        registerEnemyModel(model)
        if isAliveEnemy(model) then
            seen[model] = true
            table.insert(result, model)
        end
    end

    -- Fast path: live registry only.
    local registryCount = 0
    for model in pairs(S.enemyRegistry) do
        if not model or not model.Parent then
            S.enemyRegistry[model] = nil
        else
            registryCount += 1
            if isAliveEnemy(model) then
                add(model)
            end
        end
    end
    S.registryCount = registryCount

    -- Cheap tag fallback before touching all Workspace descendants.
    if #result == 0 then
        for _, tag in ipairs({"Spider Mob", "runAnimations", "Enemy", "Mob", "Boss"}) do
            local ok, tagged = pcall(function()
                return CollectionService:GetTagged(tag)
            end)
            if ok then
                for _, inst in ipairs(tagged) do
                    add(inst)
                end
            end
        end
    end

    -- IMPORTANT: dead models can remain parented after a wave. The previous build
    -- interpreted that as a non-empty registry and never recovered. Only when there
    -- are zero LIVE candidates do one throttled deep pass, then consume discoveries.
    if #result == 0 then
        local didScan = deepRefreshEnemyRegistry(false)
        if didScan then
            registryCount = 0
            for model in pairs(S.enemyRegistry) do
                if not model or not model.Parent then
                    S.enemyRegistry[model] = nil
                else
                    registryCount += 1
                    if isAliveEnemy(model) then
                        add(model)
                    end
                end
            end
            S.registryCount = registryCount
        end
    end

    return result
end

-- Register spawned mobs immediately. Retry once because some waves replicate the
-- Humanoid and HumanoidRootPart on different scheduler frames.
local function tryRegisterFromDescendant(inst)
    if not inst or not inst.Parent then return end
    local model
    if inst:IsA("Humanoid") and inst.Parent and inst.Parent:IsA("Model") then
        model = inst.Parent
    else
        model = inst:FindFirstAncestorOfClass("Model")
    end
    if model then
        registerEnemyModel(model)
    end
end

workspace.DescendantAdded:Connect(function(inst)
    if inst:IsA("Humanoid") or (inst:IsA("BasePart") and inst.Name == "HumanoidRootPart") then
        task.defer(tryRegisterFromDescendant, inst)
        task.delay(CFG.SPAWN_REGISTER_RETRY, function()
            tryRegisterFromDescendant(inst)
        end)
    end
end)

-- Seed once on load instead of waiting for the first periodic refresh.
task.defer(function()
    S.lastDeepNpcScan = -math.huge
    deepRefreshEnemyRegistry(true)
end)

local function resetDodgeEpisode(reason)
    local wasDodging = S.dodging
    S.dodging = false
    S.dodgeOffset = Vector3.zero
    S.dodgeWorldGoal = nil
    S.dodgeReason = "none"
    S.dodgeEpisodeTarget = nil
    S.dodgeStartedAt = 0
    S.dodgeHardEndAt = 0
    S.dodgeTriggerIds = {}
    S.dodgeHandledIds = {}
    S.dodgeClearSince = nil
    S.dodgeBlockerCount = 0
    S.dodgeChainStartedAt = 0
    S.dodgeLastTeleportAt = 0
    S.dodgeChainTeleports = 0
    S.dodgeSequenceReason = "none"
    S.dodgeUsesWorldSpace = false
    S.lastDangerTime = 0
    S.lastReplan = 0
    if reason and wasDodging then
        S.lastAction = reason
    end
end

local function chooseTarget(force)
    if not S.root then return end
    local t = clock()
    if not force and t - S.lastTargetScan < CFG.TARGET_SCAN_INTERVAL then
        return
    end
    S.lastTargetScan = t

    local oldTarget = S.target
    local oldAlive = oldTarget and isAliveEnemy(oldTarget)
    if S.targetRoot and S.targetRoot.Parent then
        S.lastTargetPosition = S.targetRoot.Position
    end

    local candidates = getEnemyCandidates()
    S.enemyCache = candidates

    -- IMPORTANT: enemy death is not attack death. If the old mob has died but any
    -- registered precast/projectile/hitbox is still alive, keep a post-kill danger
    -- phase instead of immediately switching anchors. Combat already refuses dead
    -- targets, while updateMovement continues evaluating the independent threat table.
    if oldTarget and not oldAlive and next(S.threats) ~= nil then
        if S.dodging then
            S.dodgeUsesWorldSpace = true
        end
        return
    end

    -- Keep a living target to prevent ping-ponging inside a packed wave.
    if oldAlive and S.targetRoot and S.targetRoot.Parent then
        local freshRoot, freshHum = getModelParts(oldTarget)
        if freshRoot and freshHum then
            local d = flatDistance(S.root.Position, freshRoot.Position)
            if d <= CFG.TARGET_MAX_DISTANCE then
                S.targetRoot, S.targetHum = freshRoot, freshHum
                S.lastTargetPosition = freshRoot.Position
                return
            end
        end
    end

    local best, bestRoot, bestHum, bestDist
    for _, model in ipairs(candidates) do
        local root, hum = getModelParts(model)
        if root and hum then
            local d = flatDistance(S.root.Position, root.Position)
            if d <= CFG.TARGET_MAX_DISTANCE and (not bestDist or d < bestDist) then
                best, bestRoot, bestHum, bestDist = model, root, hum, d
            end
        end
    end

    if best ~= oldTarget then
        -- Never destroy an active dodge merely because target identity changed.
        -- The committed dodge point is world-space; preserve it until its threats
        -- actually clear, then normal following can attach to the new target.
        if S.dodging then
            S.dodgeUsesWorldSpace = true
        end

        S.target = best
        S.targetRoot = bestRoot
        S.targetHum = bestHum
        S.targetSince = t
        S.targetLossHandledFor = nil
        if bestRoot then S.lastTargetPosition = bestRoot.Position end
        S.templeCoreSweepRows = {}
        S.templeCoreLastSquareAt = 0
        S.templeCoreLastOrbAt = 0
        if best then
            S.lastAction = S.dodging and ("target -> " .. best.Name .. " / preserve danger hold") or ("target -> " .. best.Name)
        elseif not S.dodging then
            S.lastAction = "waiting for next live mob / watching lingering attacks"
        end
    elseif best then
        S.targetRoot = bestRoot
        S.targetHum = bestHum
        if bestRoot then S.lastTargetPosition = bestRoot.Position end
    else
        -- No live target. Do not reset the dodge here: updateMovement owns threat
        -- lifetime and can continue in targetless world-space mode.
        S.target = nil
        S.targetRoot = nil
        S.targetHum = nil
    end
end

--// Threat management
local function nextThreatId(prefix)
    S.threatCounter += 1
    return string.format("%s:%d", prefix or "T", S.threatCounter)
end

local function addThreat(threat)
    local now = clock()
    threat.id = threat.id or nextThreatId(threat.kind or "T")
    threat.created = threat.created or now
    threat.endAt = threat.endAt or (now + CFG.EVENT_DEFAULT_HOLD)

    -- Some attack objects/remotes replicate a frame or two AFTER their caster has
    -- already died. Capture those too; target-loss preservation is not limited to
    -- threats that happened to exist on the exact Health==0 frame.
    local liveTarget = S.target and isAliveEnemy(S.target)
    if threat.source ~= "melee" and not liveTarget
        and (S.lastTargetLostAt or 0) > 0
        and now - S.lastTargetLostAt <= CFG.POST_KILL_CAPTURE_WINDOW then
        threat.postKillRetainUntil = math.max(tonumber(threat.postKillRetainUntil) or 0, now + CFG.POST_KILL_THREAT_MIN_HOLD)
        threat.endAt = math.max(tonumber(threat.endAt) or 0, now + CFG.POST_KILL_THREAT_MIN_HOLD)
    end

    S.threats[threat.id] = threat
    S.lastThreatText = threat.label or threat.kind or "threat"
    return threat.id
end

local function removeThreat(id)
    S.threats[id] = nil
end

local function getThreatPosition(th)
    if th.part and th.part.Parent and th.part:IsA("BasePart") then
        return th.part.Position
    end
    if th.root and th.root.Parent and th.root:IsA("BasePart") then
        return th.root.Position
    end

    -- Some decompiled boss remotes provide a deterministic projectile trajectory
    -- instead of an Instance we can track. Reconstruct its current world position
    -- from the same server-time math used by the game's client visual.
    if th.pathStartCFrame and typeof(th.pathStartCFrame) == "CFrame" then
        local startTime = tonumber(th.pathStartServerTime) or serverNow()
        local duration = math.max(tonumber(th.pathDuration) or 0.01, 0.01)
        local distance = tonumber(th.pathDistance) or 0
        local alpha = clamp((serverNow() - startTime) / duration, 0, 1)
        return th.pathStartCFrame.Position + th.pathStartCFrame.LookVector * (distance * alpha)
    end

    if th.position then return th.position end
    if th.cframe then return th.cframe.Position end
    return Vector3.zero
end

local function getThreatCFrame(th)
    if th.part and th.part.Parent and th.part:IsA("BasePart") then
        return th.part.CFrame
    end
    return th.cframe
end

local function getThreatSize(th)
    if th.part and th.part.Parent and th.part:IsA("BasePart") then
        return th.part.Size
    end
    return th.size
end

-- AssemblyLinearVelocity can be zero/unreliable for server-CFrame-driven boss
-- projectiles.  Maintain our own XZ velocity sample for homing threats so prediction
-- continues to work even when Roblox does not expose a useful assembly velocity.
local function sampleThreatKinematics(th, now)
    if not th or not th.repeatableHoming or not th.part or not th.part.Parent then return end
    now = now or clock()
    local pos = th.part.Position
    local lastPos = th.kinematicLastPos
    local lastAt = th.kinematicLastAt
    if lastPos and lastAt then
        local dt = now - lastAt
        if dt >= CFG.SEARING_ORB_MANUAL_VELOCITY_DT then
            local v = (pos - lastPos) / math.max(dt, 1e-4)
            local fv = flat(v)
            if flatMagnitude(fv) > 0.25 then
                if th.estimatedVelocity then
                    th.estimatedVelocity = th.estimatedVelocity:Lerp(fv, 0.55)
                else
                    th.estimatedVelocity = fv
                end
            end
            th.kinematicLastPos = pos
            th.kinematicLastAt = now
        end
    else
        th.kinematicLastPos = pos
        th.kinematicLastAt = now
    end
end

local function getThreatVelocity(th)
    if th.part and th.part.Parent then
        local av = flat(th.part.AssemblyLinearVelocity)
        if flatMagnitude(av) > 1.0 then
            return av
        end
    end
    if th.estimatedVelocity and flatMagnitude(th.estimatedVelocity) > 0.25 then
        return flat(th.estimatedVelocity)
    end
    return flat(th.velocity or Vector3.zero)
end

local function updateHomingThreatArming(referencePos, now)
    if not referencePos then return end
    now = now or clock()
    for _, th in pairs(S.threats) do
        if th.repeatableHoming then
            sampleThreatKinematics(th, now)
            local center = getThreatPosition(th)
            local dist = flatDistance(referencePos, center)
            local previousDist = th.homingLastReferenceDistance
            th.homingLastReferenceDistance = dist
            th.currentDistance = dist

            if th.homingArmed == false
                and now - (th.homingLastDodgeAt or 0) >= CFG.SEARING_ORB_REARM_MIN_TIME then
                local releaseRadius = th.releaseRadius or CFG.SEARING_ORB_RELEASE_RADIUS
                local triggerRadius = th.triggerRadius or CFG.SEARING_ORB_TRIGGER_RADIUS
                local velocity = getThreatVelocity(th)
                local toPlayer = flat(referencePos - center)
                local approaching = false
                if flatMagnitude(velocity) > 0.5 and flatMagnitude(toPlayer) > 0.5 then
                    approaching = flatUnit(velocity):Dot(flatUnit(toPlayer)) >= CFG.SEARING_ORB_APPROACH_DOT
                end
                local closingByDistance = previousDist ~= nil and dist < previousDist - 0.20
                local closeAgain = dist <= triggerRadius + CFG.SEARING_ORB_CLOSE_REARM_EXTRA
                    and (approaching or closingByDistance)

                -- Normal path: a side-step creates a clean gap. Emergency path:
                -- a very late dodge may leave the orb inside releaseRadius; once it
                -- visibly turns/closes on the new held point, allow the SAME orb to
                -- force another snap instead of waiting for separation that never comes.
                if dist >= releaseRadius or closeAgain then
                    th.homingArmed = true
                    th.homingApproachSerial = (th.homingApproachSerial or 0) + 1
                end
            end
        end
    end
end

local function pruneThreats()
    local t = clock()
    for id, th in pairs(S.threats) do
        sampleThreatKinematics(th, t)

        local partAlive = th.part and th.part.Parent and th.part:IsA("BasePart")
        local expired

        -- Cache the last real geometry of non-melee spawned attack parts. If the
        -- caster dies and Roblox destroys the client Part before the server's final
        -- damage resolution, post-kill retention can still test the last known area.
        if partAlive and th.source ~= "melee" then
            th.position = th.part.Position
            th.cframe = th.part.CFrame
            th.size = th.part.Size

            -- Circular visuals frequently tween their Size while the damage area is
            -- arming/exploding. Keep the solver radius synchronized with the actual
            -- live Part instead of freezing the radius at DescendantAdded time.
            if th.dynamicRadiusFromPart then
                local ps = th.part.Size
                local pad = tonumber(th.dynamicRadiusPad) or 0
                if th.part.ClassName == "Part"
                    and th.part.Shape == Enum.PartType.Cylinder
                    and math.abs(th.part.CFrame.RightVector.Y) >= 0.45 then
                    th.radius = math.max(ps.Y, ps.Z) * 0.5 + pad
                else
                    th.radius = math.max(ps.X, ps.Z) * 0.5 + pad
                end
            end
        end

        if th.livePartUntilRemoved then
            -- Boss-specific exception for a REAL live attack Part. Cache the final
            -- CFrame/Size every prune so the last known server-danger geometry can
            -- remain active for a tiny grace after the client object is destroyed.
            if partAlive then
                th.cframe = th.part.CFrame
                if th.templeCoreKillColumn then
                    local pad = CFG.TEMPLE_CORE_SWEEP_PREDICT_PAD
                    th.size = Vector3.new(th.part.Size.X + pad * 2, th.part.Size.Y, th.part.Size.Z + pad * 2)
                else
                    th.size = th.part.Size
                end
                th.partGoneAt = nil
                expired = (th.hardEndAt and t >= th.hardEndAt) or false
            else
                th.partGoneAt = th.partGoneAt or t
                local grace = tonumber(th.postRemoveGrace) or 0
                expired = (t - th.partGoneAt >= grace)
                    or (th.hardEndAt and t >= th.hardEndAt)
                    or false
            end
        else
            -- Generic visuals remain strictly timer-bounded. This preserves the old
            -- HOLD-leak fix for pooled/persistent attack-looking effects.
            expired = t >= (th.endAt or 0)
        end

        if th.track then
            local ok, playing = pcall(function() return th.track.IsPlaying end)
            if not ok or not playing then
                expired = true
            end
        end
        if th.requiresPart and not partAlive and not th.livePartUntilRemoved then
            expired = true
        end
        if th.requiresRoot and (not th.root or not th.root.Parent) then
            expired = true
        end

        -- Target death may race the final damage packet. During this short window,
        -- non-melee geometry wins over normal timer/Part cleanup rules.
        if th.source ~= "melee" and th.postKillRetainUntil and t < th.postKillRetainUntil then
            expired = false
        end

        if expired then
            S.threats[id] = nil
        end
    end
end

local function preserveThreatsAfterTargetLoss(now)
    now = now or clock()
    S.lastTargetLostAt = now
    local kept = 0

    for _, th in pairs(S.threats) do
        -- Melee animation/proximity threats legitimately die with the mob. Precasts,
        -- projectiles, event geometry and spawned hitboxes do not: server damage can
        -- resolve after Humanoid.Health has already replicated as zero.
        if th.source ~= "melee" then
            kept += 1
            th.postKillRetainUntil = math.max(tonumber(th.postKillRetainUntil) or 0, now + CFG.POST_KILL_THREAT_MIN_HOLD)
            if th.livePartUntilRemoved then
                th.postRemoveGrace = math.max(tonumber(th.postRemoveGrace) or 0, CFG.POST_KILL_LIVE_PART_GRACE)
                if th.hardEndAt then
                    th.hardEndAt = math.max(th.hardEndAt, now + CFG.POST_KILL_THREAT_MIN_HOLD)
                end
            else
                th.endAt = math.max(tonumber(th.endAt) or 0, now + CFG.POST_KILL_THREAT_MIN_HOLD)
            end
        end
    end

    if kept > 0 then
        S.lastAction = string.format("target dead -> preserve %d lingering attack(s)", kept)
    else
        S.lastAction = "target dead -> post-kill threat watch"
    end
end

local function hasRegisteredThreats()
    return next(S.threats) ~= nil
end

local function closestPointOnSegmentXZ(p, a, b)
    local apx, apz = p.X - a.X, p.Z - a.Z
    local abx, abz = b.X - a.X, b.Z - a.Z
    local denom = abx * abx + abz * abz
    if denom <= 1e-6 then
        return a
    end
    local u = clamp((apx * abx + apz * abz) / denom, 0, 1)
    return Vector3.new(a.X + abx * u, p.Y, a.Z + abz * u)
end

-- Precasts / beams / projectiles are XZ-dangerous because the decompile does not
-- prove that altitude avoids their server hit checks. Melee is the exception: a mob
-- swing only matters when the player is inside its estimated TRUE 3D reach.
local function isInsideThreat(pos, th, extraMargin)
    local margin = (extraMargin or 0) + (th.margin or 0)
    local kind = th.kind

    if kind == "CIRCLE" or kind == "RADIAL" or kind == "SPIN" then
        local center = getThreatPosition(th)
        if th.source == "melee" then
            return (pos - center).Magnitude <= ((th.radius or th.range or CFG.MELEE_DEFAULT_RANGE) + margin)
        end
        return flatDistance(pos, center) <= ((th.radius or 0) + margin)
    end

    if kind == "CUBE" or kind == "OBB" then
        local cf = getThreatCFrame(th)
        local size = getThreatSize(th)
        if not cf or not size then return false end
        -- Pure 2D oriented-box math: no candidate Y participates at all.
        local rel = flat(pos - cf.Position)
        local right = flatUnit(cf.RightVector, Vector3.new(1, 0, 0))
        local forward = flatUnit(cf.LookVector, Vector3.new(0, 0, -1))
        local lx = rel:Dot(right)
        local lz = rel:Dot(forward)
        return math.abs(lx) <= size.X * 0.5 + margin
           and math.abs(lz) <= size.Z * 0.5 + margin
    end

    if kind == "PROJECTILE" then
        local center = getThreatPosition(th)
        local velocity = getThreatVelocity(th)
        local future = center + flat(velocity) * (th.predictTime or CFG.PROJECTILE_PREDICT_TIME)
        local cp = closestPointOnSegmentXZ(pos, center, future)
        local radius = (th.radius or 4) + margin

        if th.repeatableHoming then
            -- A homing orb can curve after the current velocity sample, so pure
            -- line prediction is insufficient.  Use both its short-term intercept
            -- corridor and a radial proximity trigger around the live orb.
            local radial = (th.triggerRadius or th.radius or CFG.SEARING_ORB_TRIGGER_RADIUS) + margin
            return flatDistance(pos, center) <= radial or flatDistance(pos, cp) <= radius
        end

        return flatDistance(pos, cp) <= radius
    end

    if kind == "CONE" then
        local origin = getThreatPosition(th)
        local look
        if th.root and th.root.Parent then
            look = flatUnit(th.root.CFrame.LookVector)
        elseif th.look then
            look = flatUnit(th.look)
        else
            look = Vector3.new(0, 0, -1)
        end

        local rel3 = pos - origin
        local range = (th.range or CFG.MELEE_DEFAULT_RANGE) + margin
        if th.source == "melee" and rel3.Magnitude > range then
            return false
        end

        local rel = flat(rel3)
        local dist = flatMagnitude(rel)
        if th.source ~= "melee" and dist > range then
            return false
        end
        if dist <= 1e-4 then return true end
        local dir = rel / dist
        local halfAngle = th.halfAngle or CFG.MELEE_CONE_HALF_ANGLE
        return look:Dot(dir) >= math.cos(halfAngle)
    end

    return false
end

local function threatClearance(pos, th)
    -- Positive-ish number = farther from danger. Used only as fallback scoring.
    local kind = th.kind
    if kind == "CIRCLE" or kind == "RADIAL" or kind == "SPIN" then
        local center = getThreatPosition(th)
        if th.source == "melee" then
            return (pos - center).Magnitude - (th.radius or th.range or CFG.MELEE_DEFAULT_RANGE)
        end
        return flatDistance(pos, center) - (th.radius or 0)
    elseif kind == "PROJECTILE" then
        local center = getThreatPosition(th)
        local velocity = getThreatVelocity(th)
        local future = center + flat(velocity) * (th.predictTime or CFG.PROJECTILE_PREDICT_TIME)
        local cp = closestPointOnSegmentXZ(pos, center, future)
        local corridorClearance = flatDistance(pos, cp) - (th.radius or 4)
        if th.repeatableHoming then
            local radialClearance = flatDistance(pos, center) - (th.triggerRadius or th.radius or CFG.SEARING_ORB_TRIGGER_RADIUS)
            return math.min(corridorClearance, radialClearance)
        end
        return corridorClearance
    elseif kind == "CUBE" or kind == "OBB" then
        local cf = getThreatCFrame(th)
        local size = getThreatSize(th)
        if cf and size then
            local rel = flat(pos - cf.Position)
            local right = flatUnit(cf.RightVector, Vector3.new(1, 0, 0))
            local forward = flatUnit(cf.LookVector, Vector3.new(0, 0, -1))
            local lx = rel:Dot(right)
            local lz = rel:Dot(forward)
            local dx = math.abs(lx) - size.X * 0.5
            local dz = math.abs(lz) - size.Z * 0.5
            return math.max(dx, dz)
        end
    elseif kind == "CONE" then
        local origin = getThreatPosition(th)
        if th.source == "melee" then
            return (pos - origin).Magnitude - (th.range or CFG.MELEE_DEFAULT_RANGE)
        end
        return flatDistance(pos, origin) - (th.range or CFG.MELEE_DEFAULT_RANGE)
    end
    return 0
end

local function countThreatKinds()
    local total, precasts, melee, projectiles, events = 0, 0, 0, 0, 0
    for _, th in pairs(S.threats) do
        total += 1
        if th.source == "precast" then precasts += 1 end
        if th.source == "melee" then melee += 1 end
        if th.kind == "PROJECTILE" then projectiles += 1 end
        if th.source == "event" or th.source == "enemyEffects" then events += 1 end
    end
    return total, precasts, melee, projectiles, events
end

local function characterRootToBottom()
    if S.characterRootToBottom then
        return S.characterRootToBottom
    end
    if S.char and S.char.Parent and S.root and S.root.Parent then
        local ok, cf, size = pcall(function()
            local bcf, bsize = S.char:GetBoundingBox()
            return bcf, bsize
        end)
        if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
            local bottomY = cf.Position.Y - size.Y * 0.5
            local offset = S.root.Position.Y - bottomY
            if offset > 0.5 and offset < 12 then
                S.characterRootToBottom = offset
                return offset
            end
        end
    end
    return CFG.PLAYER_ROOT_TO_BOTTOM_FALLBACK
end

local function refreshTargetGeometry(force)
    if not S.target or not S.target.Parent or not S.targetRoot or not S.targetRoot.Parent then
        S.targetGeometryTarget = nil
        S.targetBoundsCFrame = nil
        S.targetBoundsSize = nil
        S.targetTopY = nil
        S.targetTopOffset = nil
        return false
    end

    local now = clock()
    local changed = S.targetGeometryTarget ~= S.target
    if not force and not changed and now - (S.targetGeometryAt or 0) < CFG.OVERHEAD_GEOMETRY_REFRESH_INTERVAL then
        return S.targetTopY ~= nil
    end

    S.targetGeometryTarget = S.target
    S.targetGeometryAt = now

    local ok, cf, size = pcall(function()
        local bcf, bsize = S.target:GetBoundingBox()
        return bcf, bsize
    end)
    if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
        S.targetBoundsCFrame = cf
        S.targetBoundsSize = size
        S.targetTopY = cf.Position.Y + size.Y * 0.5
        S.targetTopOffset = S.targetTopY - S.targetRoot.Position.Y
    else
        local okSize, ext = pcall(function() return S.target:GetExtentsSize() end)
        if okSize and typeof(ext) == "Vector3" then
            S.targetBoundsCFrame = S.targetRoot.CFrame
            S.targetBoundsSize = ext
            S.targetTopY = S.targetRoot.Position.Y + ext.Y * 0.5
            S.targetTopOffset = ext.Y * 0.5
        else
            S.targetBoundsCFrame = S.targetRoot.CFrame
            S.targetBoundsSize = S.targetRoot.Size
            S.targetTopY = S.targetRoot.Position.Y + S.targetRoot.Size.Y * 0.5
            S.targetTopOffset = S.targetRoot.Size.Y * 0.5
        end
    end

    -- Temple Core's headOrb is the exact geometry the probe caught us intersecting.
    -- GetBoundingBox should already include it, but explicitly include its highest
    -- BasePart so streaming/PrimaryPart quirks cannot place the hover point inside it.
    if lower(S.target.Name) == "temple core generator" then
        local headOrb = S.target:FindFirstChild("headOrb")
        if headOrb then
            local highest = S.targetTopY or -math.huge
            for _, inst in ipairs(headOrb:GetDescendants()) do
                if inst:IsA("BasePart") then
                    highest = math.max(highest, inst.Position.Y + inst.Size.Y * 0.5)
                end
            end
            S.targetTopY = highest
            S.targetTopOffset = highest - S.targetRoot.Position.Y
        end
    end

    return true
end

local destroyHoverController
local restoreNoclip
local rebuildNoclipCache

local function isTempleCoreWalkTarget()
    -- Temple Core movement override removed. It always uses normal OVERHEAD mode.
    return false
end

local function setTempleCoreWalkMode(enabled)
    enabled = enabled and true or false
    if enabled == S.walkModeActive then
        return
    end

    S.walkModeActive = enabled
    S.walkGoal = nil
    S.walkLastMoveAt = 0
    S.lastFloorTeleportAt = 0

    if enabled then
        -- Temple Core FLOOR-TP mode:
        -- no hover force, no noclip, no Humanoid pathing, no WalkSpeed manipulation.
        -- We stand on real collidable arena geometry and reposition only by snaps.
        if S.hum and S.hum.Parent then
            S.walkSavedSpeed = S.hum.WalkSpeed
            S.hum:Move(Vector3.zero, false)
        end
        destroyHoverController()
        restoreNoclip()
        S.lastAction = "Temple Core -> FLOOR TELEPORT mode"
    else
        if S.hum and S.hum.Parent and S.walkSavedSpeed then
            S.hum.WalkSpeed = S.walkSavedSpeed
        end
        S.walkSavedSpeed = nil
        if S.char and S.char.Parent then
            rebuildNoclipCache()
        end
        S.lastAction = "Temple Core FLOOR TELEPORT ended"
    end
end

local function projectToGroundRootPosition(worldPos)
    if not worldPos or not S.root then return nil, false end

    local exclude = {}
    if S.char then table.insert(exclude, S.char) end
    if S.target then table.insert(exclude, S.target) end
    if S.visualizerFolder then table.insert(exclude, S.visualizerFolder) end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = false

    local originY = math.max(
        worldPos.Y + CFG.TEMPLE_CORE_GROUND_RAY_UP,
        S.root.Position.Y + CFG.TEMPLE_CORE_GROUND_RAY_UP,
        (S.targetRoot and S.targetRoot.Position.Y or worldPos.Y) + CFG.TEMPLE_CORE_GROUND_RAY_UP
    )
    local origin = Vector3.new(worldPos.X, originY, worldPos.Z)
    local result

    -- Only accept real collidable arena geometry as ground. Dungeon Quest's
    -- precasts/hitboxes are commonly queryable but non-collidable, so a plain
    -- raycast can otherwise "stand" us on the top of an invisible kill column.
    for _ = 1, 10 do
        params.FilterDescendantsInstances = exclude
        result = workspace:Raycast(
            origin,
            Vector3.new(0, -CFG.TEMPLE_CORE_GROUND_RAY_DOWN, 0),
            params
        )
        if not result then break end

        local hit = result.Instance
        if hit and hit:IsA("BasePart") and hit.CanCollide then
            break
        end

        if hit then
            table.insert(exclude, hit)
            origin = Vector3.new(worldPos.X, result.Position.Y - 0.05, worldPos.Z)
        else
            result = nil
            break
        end
    end

    if not result or not result.Instance or not result.Instance:IsA("BasePart") or not result.Instance.CanCollide then
        -- Temple Core arena is effectively planar. A missed floor ray should not
        -- deadlock the controller; preserve the current root Y and still allow the
        -- XZ snap. Threat geometry remains authoritative for safety.
        return Vector3.new(worldPos.X, S.root.Position.Y, worldPos.Z), true
    end

    local rootY = result.Position.Y + characterRootToBottom() + CFG.TEMPLE_CORE_GROUND_ROOT_CLEARANCE
    return Vector3.new(worldPos.X, rootY, worldPos.Z), true
end

local targetBodyOverlapsRootPosition
local activeThreatsForPosition
local isPositionSafe

local function templeCoreWalkBase()
    if not isTempleCoreWalkTarget() or not S.root or not S.targetRoot then return nil end

    local targetPos = S.targetRoot.Position
    local away = flat(S.root.Position - targetPos)
    local dir = flatUnit(away, flatUnit(S.targetRoot.CFrame.RightVector, Vector3.new(1,0,0)))

    -- Simple floor anchor: stay very close to the Core on the same side we are
    -- already on. updateMovement will dodge only if this anchor is threatened.
    local raw = targetPos + dir * CFG.TEMPLE_CORE_WALK_IDLE_RADIUS
    local grounded = projectToGroundRootPosition(raw)
    return grounded
end

local function currentHoverWorldY()
    if not S.targetRoot or not S.targetRoot.Parent then return nil end
    refreshTargetGeometry(false)

    local rootY = S.targetRoot.Position.Y
    local baseY = rootY + CFG.OVERHEAD_HEIGHT
    local targetTop = S.targetTopY or (rootY + S.targetRoot.Size.Y * 0.5)
    local clearance = CFG.OVERHEAD_MODEL_CLEARANCE
    if S.target and lower(S.target.Name) == "temple core generator" then
        clearance = math.max(clearance, CFG.TEMPLE_CORE_HEADORB_CLEARANCE)
    end

    -- Root position must be high enough that the BOTTOM of our character is above
    -- the boss's highest real part, not merely targetRoot.Y + a fixed offset.
    local bodySafeY = targetTop + characterRootToBottom() + clearance
    local desired = math.max(baseY, bodySafeY)

    -- The old 34-stud clamp is what let the Core Generator's headOrb reach us.
    -- Keep only a very generous sanity ceiling; if real geometry legitimately needs
    -- more height, prefer safety and use the real geometry-derived value.
    local sanity = rootY + CFG.OVERHEAD_MAX_DYNAMIC_HEIGHT
    if desired > sanity then
        return desired
    end
    return desired
end

local function currentHoverHeight()
    if not S.targetRoot or not S.targetRoot.Parent then
        return CFG.OVERHEAD_HEIGHT
    end
    local y = currentHoverWorldY()
    return y and (y - S.targetRoot.Position.Y) or CFG.OVERHEAD_HEIGHT
end

local function currentOverheadBase()
    if not S.targetRoot or not S.targetRoot.Parent then return nil end
    local p = S.targetRoot.Position
    local y = currentHoverWorldY() or (p.Y + CFG.OVERHEAD_HEIGHT)
    return Vector3.new(p.X, y, p.Z)
end

local function movementPositionForOffset(offset)
    if not S.targetRoot then return nil, false end
    local targetPos = S.targetRoot.Position
    if isTempleCoreWalkTarget() then
        local raw = Vector3.new(targetPos.X + offset.X, targetPos.Y, targetPos.Z + offset.Z)
        return projectToGroundRootPosition(raw)
    end

    return Vector3.new(
        targetPos.X + offset.X,
        targetPos.Y + currentHoverHeight(),
        targetPos.Z + offset.Z
    ), true
end

local function dodgePositionForOffset(offset, basePos, forceWorldSpace)
    local canUseTarget = not forceWorldSpace and S.targetRoot and S.targetRoot.Parent
    if canUseTarget then
        return movementPositionForOffset(offset)
    end

    local anchor = basePos or (S.root and S.root.Position)
    if not anchor then return nil, false end
    return Vector3.new(anchor.X + offset.X, anchor.Y, anchor.Z + offset.Z), true
end

local function currentMovementBase()
    if isTempleCoreWalkTarget() then
        return templeCoreWalkBase()
    end
    return currentOverheadBase()
end

local function walkSegmentSafe(fromPos, toPos, margin)
    if not fromPos or not toPos then return false, nil end
    local dist = flatDistance(fromPos, toPos)
    if dist <= 0.1 then
        return isPositionSafe(toPos, margin or CFG.SAFETY_MARGIN), nil
    end

    local step = math.max(0.75, CFG.TEMPLE_CORE_WALK_PATH_STEP)
    local samples = math.max(1, math.ceil(dist / step))
    local startInside = {}
    local exited = {}

    for id, th in pairs(S.threats) do
        if isInsideThreat(fromPos, th, margin or CFG.SAFETY_MARGIN) then
            startInside[id] = true
        end
    end

    for i = 1, samples do
        local alpha = i / samples
        local x = fromPos.X + (toPos.X - fromPos.X) * alpha
        local z = fromPos.Z + (toPos.Z - fromPos.Z) * alpha
        local probeRaw = Vector3.new(x, toPos.Y, z)
        local probe, okGround = projectToGroundRootPosition(probeRaw)
        if not okGround or not probe then
            return false, "no ground"
        end
        if targetBodyOverlapsRootPosition(probe, 0) then
            return false, "boss body"
        end

        for id, th in pairs(S.threats) do
            local inside = isInsideThreat(probe, th, margin or CFG.SAFETY_MARGIN)
            if startInside[id] then
                if not inside then
                    exited[id] = true
                elseif exited[id] then
                    return false, th.label or th.kind
                end
                -- While escaping a threat that already covers us, permit the initial
                -- portion of the path until we cross its boundary.
            elseif inside then
                return false, th.label or th.kind
            end
        end
    end

    return true, nil
end

local function chooseSafeWalkWaypoint(finalGoal)
    if not finalGoal or not S.root or not S.targetRoot then return nil, "missing" end

    local direct, why = walkSegmentSafe(S.root.Position, finalGoal, CFG.SAFETY_MARGIN)
    if direct then
        return finalGoal, "direct"
    end

    local here = S.root.Position
    local targetPos = S.targetRoot.Position
    local toGoal = flat(finalGoal - here)
    local baseAngle = flatMagnitude(toGoal) > 0.1 and math.atan2(toGoal.Z, toGoal.X) or 0

    local best, bestScore, bestWhy
    for _, radius in ipairs(CFG.TEMPLE_CORE_WALK_ROUTE_RADII) do
        for i = 0, CFG.TEMPLE_CORE_WALK_ROUTE_ANGLES - 1 do
            local angle = baseAngle + (i / CFG.TEMPLE_CORE_WALK_ROUTE_ANGLES) * math.pi * 2
            local raw = here + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local candidate, okGround = projectToGroundRootPosition(raw)

            if okGround and candidate
                and not targetBodyOverlapsRootPosition(candidate, 0)
                and isPositionSafe(candidate, CFG.SAFETY_MARGIN) then

                local segSafe = walkSegmentSafe(here, candidate, CFG.SAFETY_MARGIN)
                if segSafe then
                    local bossDist = flatDistance(candidate, targetPos)
                    local goalDist = flatDistance(candidate, finalGoal)
                    -- Staying near the boss is the primary preference; progress toward
                    -- the final safe point breaks ties.
                    local score = bossDist * 1.00 + goalDist * 0.30 + radius * 0.04
                    if not bestScore or score < bestScore then
                        best = candidate
                        bestScore = score
                        bestWhy = why
                    end
                end
            end
        end
    end

    return best, bestWhy or why or "blocked"
end

local function chooseTempleCoreFloorCandidate(preferredGoal)
    if not isTempleCoreWalkTarget() or not S.root or not S.targetRoot then
        return preferredGoal, true
    end

    -- First trust the requested point if it is grounded and not in an active threat.
    if preferredGoal then
        local grounded = projectToGroundRootPosition(preferredGoal)
        if grounded and #activeThreatsForPosition(grounded, CFG.TEMPLE_CORE_FLOOR_THREAT_MARGIN) == 0 then
            return grounded, true
        end
    end

    -- Only when the requested point is actually threatened, perform one compact
    -- ring search around the boss. No body-bounds rejection: Temple Core's aggregate
    -- model bounds are enormous and were the source of the previous deadlock.
    local targetPos = S.targetRoot.Position
    local currentPos = S.root.Position
    local preferredDir = flatUnit(currentPos - targetPos, Vector3.new(1,0,0))
    local baseAngle = math.atan2(preferredDir.Z, preferredDir.X)
    local radii = {5, 7, 9, 12, 16, 22, 30, 40}

    for _, radius in ipairs(radii) do
        for i = 0, 23 do
            local angle = baseAngle + (i / 24) * math.pi * 2
            local raw = targetPos + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local grounded = projectToGroundRootPosition(raw)
            if grounded and #activeThreatsForPosition(grounded, CFG.TEMPLE_CORE_FLOOR_THREAT_MARGIN) == 0 then
                return grounded, true
            end
        end
    end

    -- Last-resort: never freeze. Move directly away on the floor even if our stale
    -- threat table currently paints every sampled point unsafe.
    local away = flatUnit(currentPos - targetPos, Vector3.new(1,0,0))
    local raw = targetPos + away * 48
    local grounded = projectToGroundRootPosition(raw)
    return grounded, false
end

local function floorTeleportTo(pos, action, forceNow)
    if not S.root or not S.root.Parent then return false end
    setTempleCoreWalkMode(true)

    local grounded, fullySafe = chooseTempleCoreFloorCandidate(pos)
    if not grounded then
        S.lastAction = "FLOOR TP: no grounded candidate"
        return false
    end

    local now = clock()
    local dist = flatDistance(S.root.Position, grounded)
    local shouldSnap = forceNow
        or dist >= CFG.TEMPLE_CORE_FLOOR_FOLLOW_SNAP
        or (dist >= 0.20 and now - (S.lastFloorTeleportAt or 0) >= CFG.TEMPLE_CORE_FLOOR_FOLLOW_INTERVAL)

    S.walkGoal = grounded
    if not shouldSnap then
        return true
    end

    -- Legacy floor mode is disabled in this build, but keep its compatibility path
    -- non-teleporting as well. If it is ever re-enabled, use ordinary Humanoid motion
    -- rather than snapping HumanoidRootPart.CFrame.
    if S.hum and S.hum.Parent then
        S.hum:MoveTo(grounded)
    end

    S.lastFloorTeleportAt = now
    if action then
        S.lastAction = action .. (fullySafe and "" or " / FAILSAFE")
    end
    return true
end

local function walkToGoal(pos, action, forceNow)
    -- Compatibility name retained because the surrounding state machine already
    -- branches on Temple Core mode. There is no walking/pathfinding here anymore.
    return floorTeleportTo(pos, action and action:gsub("WALK", "FLOOR TP") or "FLOOR TP", forceNow)
end


local function currentCommittedGoal()
    if not S.targetRoot or not S.targetRoot.Parent then return nil end
    local p = S.targetRoot.Position + S.dodgeOffset
    local y = currentHoverWorldY() or (S.targetRoot.Position.Y + CFG.OVERHEAD_HEIGHT)
    return Vector3.new(p.X, y, p.Z)
end

targetBodyOverlapsRootPosition = function(pos, extra)
    if not pos or not S.target or not S.target.Parent then return false end
    refreshTargetGeometry(false)
    local cf = S.targetBoundsCFrame
    local size = S.targetBoundsSize
    if not cf or not size then return false end

    local rel = cf:PointToObjectSpace(pos)
    local foot = characterRootToBottom()
    local xzPad = CFG.TARGET_BODY_XZ_CLEARANCE + (extra or 0)
    local yBottomPad = foot + CFG.OVERHEAD_MODEL_CLEARANCE

    return math.abs(rel.X) <= size.X * 0.5 + xzPad
       and math.abs(rel.Z) <= size.Z * 0.5 + xzPad
       and rel.Y >= -(size.Y * 0.5 + 2.0)
       and rel.Y < (size.Y * 0.5 + yBottomPad)
end

local function threatDynamicMargin(th, baseMargin)
    local margin = baseMargin or CFG.SAFETY_MARGIN
    if not th then return margin end

    if th.kind == "PROJECTILE" then
        -- Fast server/CFrame-driven projectiles can advance several studs between
        -- client observations. Convert measured speed into a bounded positional pad.
        local speed = flatMagnitude(getThreatVelocity(th))
        margin += math.min(CFG.PROJECTILE_MAX_DYNAMIC_PAD, speed * CFG.PROJECTILE_LATENCY_PAD_TIME)
    elseif th.source == "visual" and not th.templeCoreKillColumn and not th.templeGuardHitbox then
        -- Exact BridgeNet/event geometry already has authoritative dimensions; only
        -- widen generic visual fallback geometry by a small uncertainty allowance.
        margin += CFG.VISUAL_UNCERTAINTY_PAD
    end

    return margin
end

local function isThreatUnsafeAt(pos, th, baseMargin)
    local margin = threatDynamicMargin(th, baseMargin)
    if isInsideThreat(pos, th, margin) then
        return true
    end

    -- isInsideThreat already checks the normal predicted projectile corridor. Add
    -- one short extra horizon so a point is not selected directly in front of a
    -- fast projectile merely because it is just beyond the default time window.
    if th and th.kind == "PROJECTILE" then
        local center = getThreatPosition(th)
        local velocity = getThreatVelocity(th)
        if flatMagnitude(velocity) > 0.5 then
            local horizon = (th.predictTime or CFG.PROJECTILE_PREDICT_TIME) + CFG.PROJECTILE_EXTRA_LOOKAHEAD
            local future = center + flat(velocity) * horizon
            local cp = closestPointOnSegmentXZ(pos, center, future)
            local radius = (th.radius or 4) + margin + (th.margin or 0)
            if flatDistance(pos, cp) <= radius then
                return true
            end
        end
    end

    return false
end

local function adjustedThreatClearance(pos, th, baseMargin)
    -- Normalize clearance against the same effective pad used by the hard safety
    -- check, so the solver prefers a point with real breathing room instead of one
    -- sitting a fraction of a stud outside a padded edge.
    return threatClearance(pos, th)
        - threatDynamicMargin(th, baseMargin)
        - (th.margin or 0)
end

activeThreatsForPosition = function(pos, margin)
    local arr = {}
    for _, th in pairs(S.threats) do
        if isInsideThreat(pos, th, margin or CFG.SAFETY_MARGIN) then
            table.insert(arr, th)
        end
    end
    return arr
end

isPositionSafe = function(pos, margin)
    if targetBodyOverlapsRootPosition(pos, 0) then
        return false
    end
    for _, th in pairs(S.threats) do
        if isInsideThreat(pos, th, margin or CFG.SAFETY_MARGIN) then
            return false
        end
    end
    return true
end

-- Strategic live-target solver.
-- Safety is mandatory, then we rank safe points by:
--   1) reachable before the known impact,
--   2) still inside combat range,
--   3) smallest XZ distance to the target,
--   4) shortest movement from the current position.
-- This prevents the non-teleport build from "escaping" to a safe point that is much
-- farther from the mob than necessary and then wasting Q/E because it is out of range.
local function chooseDodgeOffset(basePos)
    if not S.targetRoot then return Vector3.zero, "no-target" end

    local targetPos = S.targetRoot.Position
    local currentPos = S.root and S.root.Position or basePos
    local bestOffset, bestScore, bestReason
    local fallbackOffset, fallbackClearance = nil, -math.huge

    local currentOffset = flat(S.dodgeOffset)
    local startAngle = 0
    if flatMagnitude(currentOffset) > 0.1 then
        startAngle = math.atan2(currentOffset.Z, currentOffset.X)
    elseif S.root then
        local rel = flat(S.root.Position - targetPos)
        if flatMagnitude(rel) > 0.1 then
            startAngle = math.atan2(rel.Z, rel.X)
        end
    end

    -- Earliest authoritative impact time among threats that currently cover us.
    -- Known precasts/artillery events therefore prefer points we can physically reach
    -- at the server-accepted 27.5 studs/s movement budget.
    local timeBudget = math.huge
    local nowForReach = clock()
    for _, th in pairs(S.threats) do
        if isInsideThreat(currentPos, th, CFG.SAFETY_MARGIN) and th.impactAt then
            timeBudget = math.min(timeBudget, math.max(0, th.impactAt - nowForReach))
        end
    end
    local ws = (S.hum and tonumber(S.hum.WalkSpeed)) or CFG.SERVER_SPEED_FALLBACK
    ws = clamp(ws, CFG.SERVER_SPEED_MIN, CFG.SERVER_SPEED_MAX)
    local reachable = timeBudget < math.huge and (ws * CFG.SERVER_DODGE_SPEED_MULT * timeBudget) or math.huge
    local combatLimit = math.max(4, CFG.COMBAT_MAX_XZ_RANGE - CFG.STRATEGIC_COMBAT_RANGE_BUFFER)

    -- Because we no longer teleport, endpoint safety alone is not enough: avoid
    -- selecting a close point on the opposite side of a different active attack.
    -- If we START inside a threat, allow the route to leave it once, but never re-enter.
    local function routeSafe(candidate)
        if not candidate then return false end
        local dist = flatDistance(currentPos, candidate)
        if dist <= 0.15 then return true end

        local samples = math.max(2, math.ceil(dist / CFG.STRATEGIC_ROUTE_STEP))
        local startInside = {}
        local exited = {}
        for id, th in pairs(S.threats) do
            if isInsideThreat(currentPos, th, CFG.SAFETY_MARGIN) then
                startInside[id] = true
            end
        end

        for i = 1, samples do
            local a = i / samples
            local probe = Vector3.new(
                currentPos.X + (candidate.X - currentPos.X) * a,
                candidate.Y,
                currentPos.Z + (candidate.Z - currentPos.Z) * a
            )
            if targetBodyOverlapsRootPosition(probe, 0) then
                return false
            end
            for id, th in pairs(S.threats) do
                local inside = isInsideThreat(probe, th, CFG.SAFETY_MARGIN)
                if startInside[id] then
                    if not inside then
                        exited[id] = true
                    elseif exited[id] then
                        return false
                    end
                elseif inside then
                    return false
                end
            end
        end
        return true
    end

    local function consider(offset, candidate, grounded, reason)
        if not candidate or not grounded or targetBodyOverlapsRootPosition(candidate, 0) then
            return
        end

        local safe = true
        local minClearance = math.huge
        for _, th in pairs(S.threats) do
            if isInsideThreat(candidate, th, CFG.SAFETY_MARGIN) then
                safe = false
            end
            minClearance = math.min(minClearance, adjustedThreatClearance(candidate, th, CFG.SAFETY_MARGIN))
        end

        if minClearance > fallbackClearance then
            fallbackClearance = minClearance
            fallbackOffset = offset
        end
        if not safe or not routeSafe(candidate) then
            return
        end

        local moveDist = flatDistance(candidate, currentPos)
        local targetDist = flatDistance(candidate, targetPos)
        local inertia = flatMagnitude(currentOffset) > 0.1 and flatDistance(offset, currentOffset) or 0
        local reachableNow = reachable == math.huge or moveDist <= reachable + 0.75
        local inCombat = targetDist <= combatLimit

        -- Lexicographic priority encoded as large score bands:
        -- reachable+in-range > reachable > in-range-but-late > any other safe point.
        local tier
        if reachableNow and inCombat then
            tier = 0
        elseif reachableNow then
            tier = 1
        elseif inCombat then
            tier = 2
        else
            tier = 3
        end

        local late = reachable < math.huge and math.max(0, moveDist - reachable) or 0
        local clearanceReward = minClearance < math.huge and math.min(12, math.max(-8, minClearance)) or 0
        local score = tier * 1000000
            + targetDist * CFG.STRATEGIC_TARGET_DIST_WEIGHT
            + moveDist * CFG.STRATEGIC_MOVE_DIST_WEIGHT
            + inertia * CFG.STRATEGIC_INERTIA_WEIGHT
            + late * 35.0
            - clearanceReward * CFG.STRATEGIC_CLEARANCE_REWARD

        if not bestScore or score < bestScore then
            bestScore = score
            bestOffset = offset
            bestReason = reason or S.lastThreatText
        end
    end

    -- Search around the CURRENT position first so we include tiny escape steps, but
    -- do not return early. Target-centered rings below are allowed to beat these if
    -- they keep us closer to the enemy while remaining reachable and route-safe.
    local localRadii = {2.5,3,4,5,6,7,8,9,10,11,12,14,16,18,20,22,26,30,36}
    for _, moveRadius in ipairs(localRadii) do
        for i = 0, CFG.DODGE_ANGLES - 1 do
            local angle = startAngle + (i / CFG.DODGE_ANGLES) * math.pi * 2
            local worldXZ = currentPos + Vector3.new(math.cos(angle) * moveRadius, 0, math.sin(angle) * moveRadius)
            local offset = flat(worldXZ - targetPos)
            local candidate, grounded = movementPositionForOffset(offset)
            consider(offset, candidate, grounded, S.lastThreatText)
        end
    end

    -- Boss-centered rings make "closest safe point to the enemy" explicit. Include
    -- tighter radii than the old teleport-oriented solver because the body-overlap
    -- test already rejects points that are physically too close to the model.
    local sampleRadii = {2.5,3,4,5,6,7,8,9,10,12,15,18,22,27,33,42,54,66}
    local largestRadius = sampleRadii[#sampleRadii] or 66
    local requiredRadius = largestRadius
    for _, th in pairs(S.threats) do
        if th.kind == "CIRCLE" or th.kind == "RADIAL" or th.kind == "SPIN" then
            local center = getThreatPosition(th)
            local threatRadius = tonumber(th.radius or th.range) or 0
            local centerOffset = flatDistance(targetPos, center)
            local escape = math.max(0, threatRadius + CFG.SAFETY_MARGIN - centerOffset) + CFG.LARGE_CIRCLE_ESCAPE_PAD
            requiredRadius = math.max(requiredRadius, escape)
        end
    end
    requiredRadius = math.min(CFG.MAX_ADAPTIVE_DODGE_RADIUS, requiredRadius)
    if requiredRadius > largestRadius + 0.5 then
        table.insert(sampleRadii, requiredRadius)
        if requiredRadius + 18 <= CFG.MAX_ADAPTIVE_DODGE_RADIUS then
            table.insert(sampleRadii, requiredRadius + 18)
        end
    end

    for _, radius in ipairs(sampleRadii) do
        for i = 0, CFG.DODGE_ANGLES - 1 do
            local angle = startAngle + (i / CFG.DODGE_ANGLES) * math.pi * 2
            local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local candidate, grounded = movementPositionForOffset(offset)
            consider(offset, candidate, grounded, S.lastThreatText)
        end
    end

    return bestOffset or fallbackOffset or Vector3.new(CFG.DODGE_RADII[#CFG.DODGE_RADII], 0, 0),
           bestReason or (bestOffset and "strategic close-safe" or "max-clearance"),
           bestOffset ~= nil
end

-- Post-kill-only world-space solver. It deliberately uses the SAME original threat
-- test and scoring as normal dodge; the only difference is that the dead mob can no
-- longer be used as an anchor.
local function chooseWorldSpaceDodgeOffset(basePos)
    if not basePos then return Vector3.zero, "no-base", false end

    local currentPos = S.root and S.root.Position or basePos
    local bestOffset, bestScore, bestReason
    local fallbackOffset, fallbackClearance = nil, -math.huge
    local currentOffset = flat(S.dodgeOffset)
    local startAngle = 0
    if flatMagnitude(currentOffset) > 0.1 then
        startAngle = math.atan2(currentOffset.Z, currentOffset.X)
    end

    local sampleRadii = {}
    for _, r in ipairs(CFG.DODGE_RADII) do table.insert(sampleRadii, r) end
    local largestRadius = sampleRadii[#sampleRadii] or 66
    local requiredRadius = largestRadius
    for _, th in pairs(S.threats) do
        if th.kind == "CIRCLE" or th.kind == "RADIAL" or th.kind == "SPIN" then
            local center = getThreatPosition(th)
            local threatRadius = tonumber(th.radius or th.range) or 0
            local centerOffset = flatDistance(basePos, center)
            local escape = math.max(0, threatRadius + CFG.SAFETY_MARGIN - centerOffset) + CFG.LARGE_CIRCLE_ESCAPE_PAD
            requiredRadius = math.max(requiredRadius, escape)
        end
    end
    requiredRadius = math.min(CFG.MAX_ADAPTIVE_DODGE_RADIUS, requiredRadius)
    if requiredRadius > largestRadius + 0.5 then
        table.insert(sampleRadii, requiredRadius)
        if requiredRadius + 18 <= CFG.MAX_ADAPTIVE_DODGE_RADIUS then
            table.insert(sampleRadii, requiredRadius + 18)
        end
    end

    for _, radius in ipairs(sampleRadii) do
        for i = 0, CFG.DODGE_ANGLES - 1 do
            local angle = startAngle + (i / CFG.DODGE_ANGLES) * math.pi * 2
            local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            local candidate = Vector3.new(basePos.X + offset.X, basePos.Y, basePos.Z + offset.Z)
            local safe = true
            local minClearance = math.huge
            local offender
            for _, th in pairs(S.threats) do
                if isInsideThreat(candidate, th, CFG.SAFETY_MARGIN) then
                    safe = false
                    offender = th
                end
                minClearance = math.min(minClearance, threatClearance(candidate, th))
            end
            if minClearance > fallbackClearance then
                fallbackClearance = minClearance
                fallbackOffset = offset
            end
            if safe then
                local moveDist = flatDistance(candidate, currentPos)
                local inertia = flatMagnitude(currentOffset) > 0.1 and flatDistance(offset, currentOffset) or 0
                local score = radius * 1.70 + moveDist * 0.12 + inertia * 0.08
                if not bestScore or score < bestScore then
                    bestScore = score
                    bestOffset = offset
                    bestReason = offender and (offender.label or offender.kind) or S.lastThreatText
                end
            end
        end
    end

    return bestOffset or fallbackOffset or Vector3.new(CFG.DODGE_RADII[#CFG.DODGE_RADII], 0, 0),
           bestReason or "post-kill max-clearance",
           bestOffset ~= nil
end

local function firstHomingThreat(threats)
    if not threats then return nil end
    for _, th in ipairs(threats) do
        if th and th.repeatableHoming then return th end
    end
    return nil
end

-- Searing Orb should be dodged sideways relative to the orb's *current approach*,
-- not merely by picking another generic ring point around the boss.  A perpendicular
-- snap makes a steering projectile spend time turning instead of following directly
-- through our old and new positions.
local function chooseHomingDodgeOffset(th, basePos)
    if not th or not S.targetRoot or not S.root then
        return chooseDodgeOffset(basePos)
    end

    sampleThreatKinematics(th, clock())
    local orbPos = getThreatPosition(th)
    local velocity = getThreatVelocity(th)
    local approach = flatUnit(velocity, flatUnit(S.root.Position - orbPos, Vector3.new(1,0,0)))
    local side = Vector3.new(-approach.Z, 0, approach.X)
    local targetPos = S.targetRoot.Position
    local current = S.root.Position
    local combatLimit = math.max(4, CFG.COMBAT_MAX_XZ_RANGE - CFG.STRATEGIC_COMBAT_RANGE_BUFFER)
    local bestOffset, bestScore

    -- Perpendicular movement still makes a steering orb turn, but with normal-speed
    -- movement a fixed 64/84-stud "sidestep" is too slow and leaves combat range.
    -- Search short side-steps first and only use the old long distances if required.
    local distances = {6,8,10,12,14,16,18,20,24,28,32,40,48,CFG.SEARING_ORB_SIDE_STEP,CFG.SEARING_ORB_SIDE_STEP_FAR}
    for _, dist in ipairs(distances) do
        for _, sign in ipairs({1, -1}) do
            local world = current + side * (dist * sign)
            local rawOffset = flat(world - targetPos)
            local candidate, grounded = movementPositionForOffset(rawOffset)
            if grounded and candidate and isPositionSafe(candidate, CFG.SAFETY_MARGIN) then
                local targetDist = flatDistance(candidate, targetPos)
                local moveDist = flatDistance(candidate, current)
                local inCombat = targetDist <= combatLimit
                local score = (inCombat and 0 or 1000000) + targetDist * 12.0 + moveDist * 1.2
                -- Prefer the side that actually increases separation from the orb.
                score -= math.min(40, flatDistance(candidate, orbPos)) * 0.12
                if not bestScore or score < bestScore then
                    bestScore = score
                    bestOffset = flat(candidate - targetPos)
                end
            end
        end
    end

    if bestOffset then
        return bestOffset, "SEARING ORB -> close combat sidestep", true
    end
    return chooseDodgeOffset(basePos)
end

local function chooseWorldSpaceHomingDodgeOffset(th, basePos)
    if not th or not S.root or not basePos then
        return chooseWorldSpaceDodgeOffset(basePos)
    end
    sampleThreatKinematics(th, clock())
    local orbPos = getThreatPosition(th)
    local velocity = getThreatVelocity(th)
    local approach = flatUnit(velocity, flatUnit(S.root.Position - orbPos, Vector3.new(1,0,0)))
    local side = Vector3.new(-approach.Z, 0, approach.X)
    local current = S.root.Position
    local options = {}
    for _, dist in ipairs({CFG.SEARING_ORB_SIDE_STEP, CFG.SEARING_ORB_SIDE_STEP_FAR}) do
        table.insert(options, current + side * dist)
        table.insert(options, current - side * dist)
    end
    table.sort(options, function(a, b)
        return flatDistance(a, orbPos) > flatDistance(b, orbPos)
    end)
    for _, world in ipairs(options) do
        local candidate = Vector3.new(world.X, basePos.Y, world.Z)
        local safe = true
        for _, threat in pairs(S.threats) do
            if isInsideThreat(candidate, threat, CFG.SAFETY_MARGIN) then safe = false break end
        end
        if safe then
            return flat(candidate - basePos), "SEARING ORB -> post-kill sidestep", true
        end
    end
    return chooseWorldSpaceDodgeOffset(basePos)
end

local function getYaw(cf)
    local _, y, _ = cf:ToOrientation()
    return y
end

destroyHoverController = function()
    if S.hoverVelocity then
        pcall(function() S.hoverVelocity:Destroy() end)
    end
    if S.hoverAttachment then
        pcall(function() S.hoverAttachment:Destroy() end)
    end
    S.hoverVelocity = nil
    S.hoverAttachment = nil
    S.hoverGoal = nil
    S.lastFollowUpdate = 0
end

local function ensureHoverController()
    if not S.root or not S.root.Parent then return nil end

    if S.hoverVelocity and S.hoverVelocity.Parent == S.root and
       S.hoverAttachment and S.hoverAttachment.Parent == S.root then
        return S.hoverVelocity
    end

    destroyHoverController()

    local attachment = Instance.new("Attachment")
    attachment.Name = "DQ_LightFollowerAttachment"
    attachment.Parent = S.root

    local velocity = Instance.new("LinearVelocity")
    velocity.Name = "DQ_LightFollower"
    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
    velocity.MaxForce = CFG.FOLLOW_MAX_FORCE
    velocity.VectorVelocity = Vector3.zero
    velocity.Enabled = true
    velocity.Parent = S.root

    S.hoverAttachment = attachment
    S.hoverVelocity = velocity
    return velocity
end

local function setHoverGoal(pos, action)
    if not pos then return end
    S.hoverGoal = pos
    local velocity = ensureHoverController()
    if velocity then
        velocity.Enabled = S.enabled
    end
    if action then S.lastAction = action end
end

local function updateFollower(forceNow)
    if not S.enabled or not S.root or not S.hoverGoal then return end
    local velocity = ensureHoverController()
    if not velocity then return end

    -- The game's own GameLoaded script can keep HumanoidRootPart anchored while
    -- geometry streams. Never accumulate a movement command during that window.
    if S.root.Anchored then
        velocity.VectorVelocity = Vector3.zero
        S.serverLastGoalDistance = nil
        return
    end

    local t = clock()
    if not forceNow and t - S.lastFollowUpdate < CFG.FOLLOW_UPDATE_INTERVAL then
        return
    end
    S.lastFollowUpdate = t

    local error = S.hoverGoal - S.root.Position
    local inherit = Vector3.zero
    if not S.dodging and S.targetRoot and S.targetRoot.Parent then
        -- In normal overhead mode inherit the mob's horizontal velocity so the
        -- follower does not repeatedly overshoot/correct as the mob walks.
        local tv = S.targetRoot.AssemblyLinearVelocity
        inherit = Vector3.new(tv.X, 0, tv.Z)
    end

    local gainXZ = S.dodging and CFG.DODGE_FOLLOW_GAIN_XZ or CFG.FOLLOW_GAIN_XZ
    local gainY = S.dodging and CFG.DODGE_FOLLOW_GAIN_Y or CFG.FOLLOW_GAIN_Y

    -- Fixed movement profile requested by the user. Keep the Humanoid itself at
    -- 27.5 WalkSpeed, then derive tracking/dodge velocity caps from that same value.
    if S.hum and S.hum.Parent and math.abs((tonumber(S.hum.WalkSpeed) or 0) - CFG.FORCED_WALK_SPEED) > 0.01 then
        pcall(function() S.hum.WalkSpeed = CFG.FORCED_WALK_SPEED end)
    end
    local walkSpeed = CFG.SERVER_SPEED_FALLBACK
    if S.hum and S.hum.Parent then
        local ok, ws = pcall(function() return tonumber(S.hum.WalkSpeed) end)
        if ok and ws and ws > 0 then walkSpeed = ws end
    end
    walkSpeed = clamp(walkSpeed, CFG.SERVER_SPEED_MIN, CFG.SERVER_SPEED_MAX)
    S.serverWalkSpeed = walkSpeed

    -- Detect a likely server correction only while chasing a FIXED dodge goal. Normal
    -- overhead tracking follows a moving mob, so goal-distance increases are expected
    -- there and must not be interpreted as rubber-banding.
    if S.dodging and S.dodgeWorldGoal then
        local goalDist = (S.dodgeWorldGoal - S.root.Position).Magnitude
        local prev = S.serverLastGoalDistance
        if prev and goalDist > prev + CFG.SERVER_CORRECTION_DISTANCE then
            S.serverMoveScale = math.max(
                CFG.SERVER_CORRECTION_MIN_SCALE,
                (S.serverMoveScale or 1.0) * CFG.SERVER_CORRECTION_BACKOFF
            )
            S.serverLastCorrectionAt = t
            S.serverCorrectionCount = (S.serverCorrectionCount or 0) + 1
            S.lastAction = string.format("server correction -> movement %.0f%%", S.serverMoveScale * 100)
        end
        S.serverLastGoalDistance = goalDist
    else
        S.serverLastGoalDistance = nil
    end

    if t - (S.serverLastCorrectionAt or -math.huge) >= CFG.SERVER_CORRECTION_RECOVER_DELAY then
        S.serverMoveScale = math.min(1.0, (S.serverMoveScale or 1.0) + CFG.SERVER_CORRECTION_RECOVER_RATE)
    end

    local mult = S.dodging and CFG.SERVER_DODGE_SPEED_MULT or CFG.SERVER_TRACK_SPEED_MULT
    local maxSpeed = walkSpeed * mult * (S.serverMoveScale or 1.0)
    S.serverMoveCap = maxSpeed

    local desired = Vector3.new(
        error.X * gainXZ,
        error.Y * gainY,
        error.Z * gainXZ
    ) + inherit

    -- Clamp the FULL 3D velocity, not only XZ. This matters while climbing back to
    -- overhead height: horizontal + vertical motion together still stays inside the
    -- same movement budget instead of accidentally exceeding WalkSpeed diagonally.
    if desired.Magnitude > maxSpeed then
        desired = desired.Unit * maxSpeed
    end

    -- Dead-zone kills tiny correction oscillations that look like character twitch.
    if math.abs(error.X) < 0.12 then desired = Vector3.new(inherit.X, desired.Y, desired.Z) end
    if math.abs(error.Y) < 0.10 then desired = Vector3.new(desired.X, 0, desired.Z) end
    if math.abs(error.Z) < 0.12 then desired = Vector3.new(desired.X, desired.Y, inherit.Z) end

    -- A final clamp after dead-zone edits keeps every requested vector inside budget.
    if desired.Magnitude > maxSpeed then
        desired = desired.Unit * maxSpeed
    end

    velocity.VectorVelocity = desired
end

local function driveToDodgeGoal(pos, action)
    -- Server-friendly dodge movement: commit the exact same solver goal, but reach it
    -- through the already-replicated LinearVelocity follower. No positional CFrame
    -- write is performed here, so the dodge no longer creates an instant TP for the
    -- server to correct/rubber-band.
    if not S.root or not S.root.Parent or not pos then return end
    setHoverGoal(pos, action)
    updateFollower(true)
end

local function executeDodgeGoal(pos, action)
    driveToDodgeGoal(pos, action)
end

local function markThreatsHandled(threats)
    if not threats then return end
    for _, th in ipairs(threats) do
        if th and th.id then
            S.dodgeHandledIds[th.id] = true
            S.dodgeTriggerIds[th.id] = true
        end
    end
end

local function noteHomingDodge(th, now)
    if not th or not th.repeatableHoming then return end
    now = now or clock()
    th.homingArmed = false
    th.homingLastDodgeAt = now
    th.homingLastReferenceDistance = nil
    th.homingDodges = (th.homingDodges or 0) + 1
    S.homingOrbDodges += 1
end

local function commitDodge(basePos, reason, triggerThreats)
    if S.dodging or not basePos then return end

    local now = clock()
    local liveTarget = S.target and isAliveEnemy(S.target) and S.targetRoot and S.targetRoot.Parent
    local homingThreat = firstHomingThreat(triggerThreats)
    local offset, why

    if liveTarget then
        -- ORIGINAL live-target path.
        if homingThreat then
            offset, why = chooseHomingDodgeOffset(homingThreat, basePos)
        else
            offset, why = chooseDodgeOffset(basePos)
        end
    else
        -- Only lingering post-kill attacks use world-space anchoring.
        if homingThreat then
            offset, why = chooseWorldSpaceHomingDodgeOffset(homingThreat, basePos)
        else
            offset, why = chooseWorldSpaceDodgeOffset(basePos)
        end
    end

    S.dodgeOffset = offset
    S.dodging = true
    S.dodgeCount += 1
    S.dodgeReason = reason or why or S.lastThreatText
    S.dodgeSequenceReason = S.dodgeReason
    S.dodgeEpisodeTarget = S.target
    S.dodgeUsesWorldSpace = not liveTarget
    S.dodgeStartedAt = now
    S.dodgeChainStartedAt = now
    S.dodgeLastTeleportAt = now
    S.dodgeChainTeleports = 1
    S.dodgeClearSince = nil
    S.dodgeTriggerIds = {}
    S.dodgeHandledIds = {}
    markThreatsHandled(triggerThreats)
    noteHomingDodge(homingThreat, now)
    S.dodgeHardEndAt = now + CFG.DODGE_EPISODE_HARD_CAP

    local goal, grounded
    if liveTarget then
        goal, grounded = movementPositionForOffset(offset)
    else
        goal, grounded = dodgePositionForOffset(offset, basePos, true)
    end
    if isTempleCoreWalkTarget() and not grounded then
        resetDodgeEpisode("Temple Core walk dodge cancelled: no ground")
        return
    end
    if not goal then
        resetDodgeEpisode("dodge cancelled: no goal")
        return
    end
    S.dodgeWorldGoal = goal
    executeDodgeGoal(goal, (liveTarget and "DODGE 1 -> " or "POST-KILL DODGE 1 -> ") .. S.dodgeReason)
end

local function redodgeEligible(th, t)
    if not CFG.REDODGE_ENABLED or not th or not th.id then return false end
    if th.redodgeEligible == false then return false end
    if S.dodgeChainTeleports >= CFG.REDODGE_MAX_TELEPORTS then return false end

    if th.repeatableHoming then
        -- Unlike a line/circle, the same Searing Orb can curve back into us. It may
        -- re-trigger only after the hysteresis logic has explicitly re-armed it.
        if th.homingArmed == false then return false end
        local gap = CFG.SEARING_ORB_REDODGE_MIN_GAP
        if t - S.dodgeLastTeleportAt < gap then return false end
        if t - (th.homingLastDodgeAt or 0) < CFG.SEARING_ORB_REDODGE_MIN_GAP then return false end
        return true
    end

    if th.repeatableSweep then
        -- Temple Core's same live Water Square can move into a position that was
        -- safe when we first teleported. Allow THAT SAME Part to force another snap
        -- only when it actually covers the held point again. The caller only invokes
        -- this for threats currently intersecting the hold position, so this cannot
        -- free-run while the square is elsewhere.
        -- Do NOT inherit the global 0.09s gap here. The dump measured only ~0.067s
        -- between a Core column appearing and character contact, so this one boss
        -- needs a much faster re-dodge cadence for the SAME moving square.
        local gap = CFG.TEMPLE_CORE_SWEEP_REDODGE_GAP
        if t - S.dodgeLastTeleportAt < gap then return false end
        if t - (th.sweepLastTryAt or 0) < gap then return false end
        th.sweepLastTryAt = t
        return true
    end

    if S.dodgeHandledIds[th.id] then return false end

    local gap = th.source == "visual" and CFG.REDODGE_VISUAL_MIN_GAP or CFG.REDODGE_MIN_GAP
    if t - S.dodgeLastTeleportAt < gap then return false end

    -- Static geometry that already existed before the previous snap was already
    -- considered by chooseDodgeOffset(). Don't let duplicate Parts from one visual
    -- effect immediately cause another snap. Moving projectiles are the exception.
    if th.kind ~= "PROJECTILE" and (th.created or 0) <= S.dodgeLastTeleportAt + 0.02 then
        return false
    end

    return true
end

local function performRedodge(threatsAtHold)
    if not S.dodgeWorldGoal then return false end
    local t = clock()
    local newThreats = {}
    for _, th in ipairs(threatsAtHold) do
        if redodgeEligible(th, t) then
            table.insert(newThreats, th)
        end
    end
    if #newThreats == 0 then return false end

    local oldGoal = S.dodgeWorldGoal
    local liveTarget = S.target and isAliveEnemy(S.target) and S.targetRoot and S.targetRoot.Parent and not S.dodgeUsesWorldSpace
    local homingThreat = firstHomingThreat(newThreats)
    local offset, why, newGoal, grounded

    if liveTarget then
        -- ORIGINAL live-target redodge path.
        if homingThreat then
            offset, why = chooseHomingDodgeOffset(homingThreat, oldGoal)
        else
            offset, why = chooseDodgeOffset(oldGoal)
        end
        newGoal, grounded = movementPositionForOffset(offset)
    else
        if homingThreat then
            offset, why = chooseWorldSpaceHomingDodgeOffset(homingThreat, oldGoal)
        else
            offset, why = chooseWorldSpaceDodgeOffset(oldGoal)
        end
        newGoal, grounded = dodgePositionForOffset(offset, oldGoal, true)
    end

    if isTempleCoreWalkTarget() and (not grounded or not newGoal) then
        S.lastAction = "Temple Core redodge rejected: no ground"
        return false
    end
    if not newGoal then return false end

    markThreatsHandled(threatsAtHold)
    if flatDistance(newGoal, oldGoal) < 1.75 then
        S.lastAction = "new attack seen; current dodge already best"
        return false
    end

    S.dodgeOffset = offset
    S.dodgeWorldGoal = newGoal
    S.dodgeUsesWorldSpace = not liveTarget
    S.dodgeLastTeleportAt = t
    S.dodgeChainTeleports += 1
    S.dodgeCount += 1
    S.dodgeClearSince = nil
    S.dodgeReason = newThreats[1].label or why or "new chained attack"
    noteHomingDodge(homingThreat, t)
    executeDodgeGoal(newGoal, string.format("%sREDODGE %d -> %s", liveTarget and "" or "POST-KILL ", S.dodgeChainTeleports, S.dodgeReason))
    return true
end

--// Volcanic Chambers / Lava King mandatory green safe-zone mechanic
-- Decompiled volcanicBossSpecficEvents behavior:
--   "Third Boss Curse Char" spawns six thirdBossCurseRing parts for 6 seconds and
--   Heartbeat-locks every ring to the cursed character's HumanoidRootPart.
-- The ring therefore tells us WHO has the bomb; it is not the safe zone itself.
local function lavaKingObjectPosition(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("BasePart") then return obj.Position end
    if obj:IsA("Model") then
        local ok, pivot = pcall(function() return obj:GetPivot() end)
        if ok and typeof(pivot) == "CFrame" then return pivot.Position end
    end
    local part = obj:FindFirstChildWhichIsA("BasePart", true)
    return part and part.Position or nil
end

local function lavaKingRepresentativePart(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("BasePart") then return obj end
    local precast = obj:FindFirstChild("precast", true)
    if precast and precast:IsA("BasePart") then return precast end
    if obj:IsA("Model") and obj.PrimaryPart then return obj.PrimaryPart end
    return obj:FindFirstChildWhichIsA("BasePart", true)
end

local function lavaKingCircleRadiusFromObject(obj, part)
    local size
    if obj and obj:IsA("Model") then
        local ok, ext = pcall(function() return obj:GetExtentsSize() end)
        if ok and typeof(ext) == "Vector3" then size = ext end
    end
    size = size or (part and part.Size)
    if not size then return CFG.LAVA_KING_SAFE_MIN_RADIUS end

    -- A flat Roblox Cylinder can use X as its thickness depending on rotation.
    -- Taking the middle of the three dimensions is stable for both 1x20x20 and
    -- 20x1x20 floor discs while rejecting the tiny thickness dimension.
    local dims = {math.abs(size.X), math.abs(size.Y), math.abs(size.Z)}
    table.sort(dims)
    local diameter = dims[2]
    return clamp(diameter * 0.5, CFG.LAVA_KING_SAFE_MIN_RADIUS, CFG.LAVA_KING_SAFE_MAX_RADIUS)
end

local function localLavaKingCurseRing()
    if not S.root or not S.root.Parent then return nil end
    -- Match the runtime layout shown by the decompile/user probe: the six rings are
    -- direct Workspace children and remain centered on the cursed character.
    for _, o in ipairs(workspace:GetChildren()) do
        if o.Name == CFG.LAVA_KING_CURSE_RING_NAME then
            local p = lavaKingObjectPosition(o)
            if p and (p - S.root.Position).Magnitude < CFG.LAVA_KING_CURSE_RADIUS then
                return o
            end
        end
    end
    return nil
end

local function pathNameLower(inst)
    local names = {}
    local cur = inst
    for _ = 1, 8 do
        if not cur or cur == workspace then break end
        table.insert(names, lower(cur.Name))
        cur = cur.Parent
    end
    return table.concat(names, " ")
end

local function isGreenFloorSafeCandidate(part)
    if not part or not part:IsA("BasePart") or not part.Parent then return false end
    if S.char and part:IsDescendantOf(S.char) then return false end
    if S.visualizerFolder and part:IsDescendantOf(S.visualizerFolder) then return false end

    local path = pathNameLower(part)
    if path:find("cursering", 1, true)
        or path:find("frozencircle", 1, true)
        or path:find("linkbeam", 1, true)
        or path:find("safezonemarker", 1, true) then
        return false
    end

    local c = part.Color
    local greenDominant = c.G >= 0.55 and c.G > c.R * 1.25 and c.G > c.B * 1.15
    if not greenDominant then return false end

    local dims = {math.abs(part.Size.X), math.abs(part.Size.Y), math.abs(part.Size.Z)}
    table.sort(dims)
    -- Green Curse Sizzle is a 27x27x27 ball; require a floor-disc-like thin axis.
    if dims[2] < CFG.LAVA_KING_SAFE_MIN_RADIUS * 1.4 then return false end
    if dims[1] > dims[2] * 0.55 then return false end

    if S.root and flatDistance(part.Position, S.root.Position) > 500 then return false end
    return true
end

local function findLavaKingGreenSafeZone(force)
    local now = clock()
    if not force and now - (S.lavaKingLastSafeScan or -math.huge) < CFG.LAVA_KING_SAFE_SCAN_INTERVAL then
        if S.lavaKingSafeObject and S.lavaKingSafeObject.Parent then
            return S.lavaKingSafeObject, S.lavaKingSafePart
        end
        return nil, nil
    end
    S.lavaKingLastSafeScan = now

    -- Exact template/runtime name first. This avoids confusing the green player-link
    -- circles with the Lava Bomb safe spot in multiplayer.
    local exact = workspace:FindFirstChild(CFG.LAVA_KING_SAFE_SPOT_NAME, true)
    if exact then
        local part = lavaKingRepresentativePart(exact)
        if part then
            S.lavaKingSafeObject, S.lavaKingSafePart = exact, part
            return exact, part
        end
    end

    -- Fallback for server-spawned/renamed copies: while WE are cursed only, accept a
    -- green flat floor disc. Prefer names that mention safe/spot/thirdboss/precast,
    -- then nearest valid disc. Spherical green Sizzle FX are explicitly rejected.
    local bestPart, bestScore
    for _, inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("BasePart") and isGreenFloorSafeCandidate(inst) then
            local path = pathNameLower(inst)
            local score = flatDistance(S.root.Position, inst.Position)
            if path:find("safe", 1, true) then score -= 1000 end
            if path:find("spot", 1, true) then score -= 500 end
            if path:find("thirdboss", 1, true) then score -= 250 end
            if path:find("precast", 1, true) then score -= 100 end
            if not bestScore or score < bestScore then
                bestPart, bestScore = inst, score
            end
        end
    end
    if bestPart then
        S.lavaKingSafeObject, S.lavaKingSafePart = bestPart, bestPart
        return bestPart, bestPart
    end

    S.lavaKingSafeObject, S.lavaKingSafePart = nil, nil
    return nil, nil
end

local function lavaKingGroundRootPosition(center, safeObj)
    if not center or not S.root then return nil end
    local exclude = {}
    if S.char then table.insert(exclude, S.char) end
    if S.target then table.insert(exclude, S.target) end
    if S.visualizerFolder then table.insert(exclude, S.visualizerFolder) end
    if safeObj then table.insert(exclude, safeObj) end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = false

    local origin = Vector3.new(center.X, math.max(center.Y + 80, S.root.Position.Y + 40), center.Z)
    local hit = workspace:Raycast(origin, Vector3.new(0, -220, 0), params)
    if hit then
        return Vector3.new(center.X, hit.Position.Y + characterRootToBottom() + CFG.LAVA_KING_SAFE_GROUND_PAD, center.Z)
    end

    -- The safe zone itself is visual/non-collidable in many builds; if no floor was
    -- streamed yet, use its Y as a conservative floor reference rather than keeping
    -- the normal overhead height (which may fail the server's safe-zone check).
    return Vector3.new(center.X, center.Y + characterRootToBottom() + CFG.LAVA_KING_SAFE_GROUND_PAD, center.Z)
end

local function choosePointInsideLavaKingSafeZone(centerGoal, radius)
    if not centerGoal then return nil end
    radius = clamp(radius or CFG.LAVA_KING_SAFE_MIN_RADIUS, CFG.LAVA_KING_SAFE_MIN_RADIUS, CFG.LAVA_KING_SAFE_MAX_RADIUS)
    local usable = math.max(1.0, radius * CFG.LAVA_KING_SAFE_CENTER_FRACTION)

    -- Stay INSIDE the mandatory zone first; within that area, maximize clearance from
    -- simultaneous cross-slash/beam/projectile threats. Center always remains a valid
    -- fallback because satisfying the bomb mechanic has priority over ordinary dodge.
    local best = centerGoal
    local bestScore = -math.huge
    local sampleRadii = {0, usable * 0.28, usable * 0.52, usable * 0.78}
    for _, r in ipairs(sampleRadii) do
        local count = r == 0 and 1 or 20
        for i = 0, count - 1 do
            local a = (i / count) * math.pi * 2
            local p = centerGoal + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
            local unsafe = 0
            local minClear = math.huge
            for _, th in pairs(S.threats) do
                if isThreatUnsafeAt(p, th, CFG.SAFETY_MARGIN) then unsafe += 1 end
                minClear = math.min(minClear, adjustedThreatClearance(p, th, CFG.SAFETY_MARGIN))
            end
            if minClear == math.huge then minClear = 999 end
            local travelPenalty = flatDistance(S.root.Position, p) * 0.02
            local score = -unsafe * 100000 + minClear - travelPenalty
            if score > bestScore then
                best, bestScore = p, score
            end
        end
    end
    return best
end

local function lavaKingCurseIsActive(now)
    now = now or clock()

    -- Curse Sizzle/Explosion resolves the mechanic immediately, but the six visual
    -- rings are Debris-timed and can survive until their original 6-second lifetime.
    -- Ignore those stale rings until a fresh Curse Char event explicitly re-arms us.
    if (S.lavaKingCurseResolvedAt or 0) > 0
        and now - S.lavaKingCurseResolvedAt < CFG.LAVA_KING_CURSE_HOLD then
        return false, nil
    end

    local ring = localLavaKingCurseRing()
    if ring then
        S.lavaKingCurseActiveUntil = math.max(S.lavaKingCurseActiveUntil or 0, now + 0.30)
        return true, ring
    end
    return now < (S.lavaKingCurseActiveUntil or 0), nil
end

local function exitLavaKingSafeMode(reason)
    if not S.lavaKingSafeMode then return end
    S.lavaKingSafeMode = false
    S.lavaKingSafeObject = nil
    S.lavaKingSafePart = nil
    S.lavaKingSafeGoal = nil
    S.lavaKingSafeRadius = 0
    -- Keep all registered attack geometry. Re-arm only the movement episode so the
    -- normal solver immediately reassesses whatever Lava King attack is still live.
    resetDodgeEpisode(reason or "Lava King bomb resolved -> dodge re-armed")
end

local function updateLavaKingSafeZoneOverride(now)
    now = now or clock()
    local active = lavaKingCurseIsActive(now)
    if not active then
        exitLavaKingSafeMode("Lava King bomb resolved -> normal dodge")
        return false
    end

    local safeObj, safePart = findLavaKingGreenSafeZone(false)
    if not safeObj or not safePart then
        S.lastAction = "LAVA KING BOMB: CURSED / searching GREEN SAFE ZONE"
        return false
    end

    local center = lavaKingObjectPosition(safePart) or lavaKingObjectPosition(safeObj)
    if not center then
        S.lastAction = "LAVA KING BOMB: safe zone found but has no position"
        return false
    end

    local centerGoal = lavaKingGroundRootPosition(center, safeObj)
    if not centerGoal then return false end
    local radius = lavaKingCircleRadiusFromObject(safeObj, safePart)
    local goal = choosePointInsideLavaKingSafeZone(centerGoal, radius)
    if not goal then return false end

    local entering = not S.lavaKingSafeMode
    local changed = not S.lavaKingSafeGoal or flatDistance(goal, S.lavaKingSafeGoal) > 1.0
    S.lavaKingSafeMode = true
    S.lavaKingSafeObject = safeObj
    S.lavaKingSafePart = safePart
    S.lavaKingSafeGoal = goal
    S.lavaKingSafeRadius = radius

    -- Make this a committed world-space objective so target movement and ordinary
    -- attack replans cannot pull us back over the boss before the bomb is cancelled.
    S.dodging = true
    S.dodgeUsesWorldSpace = true
    S.dodgeWorldGoal = goal
    S.dodgeReason = "LAVA KING BOMB -> GREEN SAFE ZONE"
    S.dodgeSequenceReason = S.dodgeReason
    S.dodgeEpisodeTarget = S.target
    S.dodgeClearSince = nil
    S.dodgeHardEndAt = math.max(S.dodgeHardEndAt or 0, now + 1.0)

    local dist = flatDistance(S.root.Position, goal)
    local shouldSnap = entering or changed or dist > math.max(2.0, radius * 0.70)
    if shouldSnap and now - (S.lavaKingLastSafeTeleport or -math.huge) >= CFG.LAVA_KING_SAFE_REENTER_INTERVAL then
        driveToDodgeGoal(goal, string.format("LAVA KING BOMB -> GREEN SAFE ZONE (r=%.1f)", radius))
        S.lavaKingLastSafeTeleport = now
        S.lavaKingSafeEntries += 1
    else
        setHoverGoal(goal, "LAVA KING BOMB -> HOLD GREEN SAFE ZONE")
        updateFollower(false)
    end

    return true
end

local function updateMovement()
    if not S.enabled or not S.root then return end

    -- Prune first so post-kill mode only reacts to genuinely live attack geometry.
    pruneThreats()
    local t = clock()
    local liveTarget = S.target and isAliveEnemy(S.target) and S.targetRoot and S.targetRoot.Parent
    updateHomingThreatArming(S.root.Position, t)

    -- Lava King is the one intentional override: the green circle is mandatory.
    -- Do NOT scan Workspace for curse rings during every ordinary room/boss. The
    -- original dodger stayed lightweight; only enable this scanner when Lava King is
    -- actually the target or a curse event/safe-mode has already armed it.
    local targetNameLower = S.target and lower(S.target.Name) or ""
    local lavaRelevant = S.lavaKingSafeMode
        or t < (S.lavaKingCurseActiveUntil or 0)
        or targetNameLower:find("lava king", 1, true) ~= nil
    if lavaRelevant and updateLavaKingSafeZoneOverride(t) then
        return
    end

    if not liveTarget then
        -- Isolated post-kill mode. This NEVER changes how normal live-target dodging
        -- selects or holds positions.
        setTempleCoreWalkMode(false)
        if S.hum and S.hum.Parent then S.hum.AutoRotate = true end

        local watchPos = (S.dodging and S.dodgeWorldGoal) or S.root.Position
        local threatsHere = activeThreatsForPosition(watchPos, CFG.SAFETY_MARGIN)

        if not S.dodging then
            if #threatsHere > 0 then
                commitDodge(watchPos, threatsHere[1].label or threatsHere[1].kind, threatsHere)
            else
                setHoverGoal(S.root.Position, hasRegisteredThreats() and "POST-KILL THREAT WATCH" or "NO TARGET / HOLD")
                updateFollower(true)
            end
            return
        end

        S.dodgeUsesWorldSpace = true
        if S.dodgeWorldGoal then
            setHoverGoal(S.dodgeWorldGoal, "POST-KILL HOLD / WATCH NEXT ATTACK")
            updateFollower(false)
            local holdThreats = activeThreatsForPosition(S.dodgeWorldGoal, CFG.SAFETY_MARGIN)
            if #holdThreats > 0 and performRedodge(holdThreats) then return end
        end

        if hasRegisteredThreats() then
            S.dodgeClearSince = nil
            return
        end
        if not S.dodgeClearSince then
            S.dodgeClearSince = t
            return
        end
        if t - S.dodgeClearSince < CFG.POST_KILL_QUIET_GRACE then return end

        resetDodgeEpisode("post-kill threats fully clear")
        setHoverGoal(S.root.Position, "POST-KILL CLEAR / WAITING")
        updateFollower(true)
        return
    end

    -- -------------------------------------------------------------------------
    -- ORIGINAL LIVE-TARGET MOVEMENT PATH
    -- -------------------------------------------------------------------------
    if S.dodging and S.dodgeEpisodeTarget ~= S.target then
        resetDodgeEpisode("new target -> dodge re-armed")
    end

    if S.walkModeActive then
        setTempleCoreWalkMode(false)
    end
    local base = currentMovementBase()
    if not base then return end

    local baseThreats = activeThreatsForPosition(base, CFG.SAFETY_MARGIN)

    if not S.dodging then
        if #baseThreats > 0 then
            local labels = {}
            for i = 1, math.min(3, #baseThreats) do
                table.insert(labels, baseThreats[i].label or baseThreats[i].kind)
            end
            commitDodge(base, table.concat(labels, ", "), baseThreats)
            return
        end

        S.dodgeOffset = Vector3.zero
        S.dodgeWorldGoal = nil
        S.dodgeUsesWorldSpace = false
        if S.walkModeActive then
            walkToGoal(base, "FLOOR TP CLOSE / WATCH", false)
        else
            setHoverGoal(base, "TRACK / WATCH")
            updateFollower(false)
        end
        return
    end

    if S.dodgeWorldGoal then
        if S.walkModeActive then
            walkToGoal(S.dodgeWorldGoal, "FLOOR TP HOLD / WATCH NEXT ATTACK", false)
        else
            setHoverGoal(S.dodgeWorldGoal, "HOLD / WATCH NEXT ATTACK")
            updateFollower(false)
        end

        local holdThreats = activeThreatsForPosition(S.dodgeWorldGoal, CFG.SAFETY_MARGIN)
        if #holdThreats > 0 and performRedodge(holdThreats) then
            return
        end
    end

    S.dodgeBlockerCount = #baseThreats

    local isTempleCoreTarget = S.target and lower(S.target.Name) == "temple core generator"
    local coreSweepRecent = isTempleCoreTarget
        and (t - (S.templeCoreLastSquareAt or 0) <= CFG.TEMPLE_CORE_SWEEP_ACTIVE_HOLD)
    local coreOrbStormRecent = isTempleCoreTarget
        and (t - (S.templeCoreLastOrbAt or 0) <= CFG.TEMPLE_CORE_ORB_STORM_HOLD)

    if coreSweepRecent or coreOrbStormRecent then
        S.dodgeClearSince = nil
        S.dodgeBlockerCount = math.max(S.dodgeBlockerCount, 1)
        local extraHold = coreOrbStormRecent and CFG.TEMPLE_CORE_ORB_STORM_HOLD or CFG.TEMPLE_CORE_SWEEP_ACTIVE_HOLD
        S.dodgeHardEndAt = math.max(S.dodgeHardEndAt or 0, t + extraHold + 0.35)
        return
    end

    -- Ancient Lava Mage exception: once a live firstBossFollowOrb forced a dodge,
    -- keep the committed point until that physical orb is actually gone. Returning
    -- overhead after the normal 0.16s clear grace lets the steering orb simply curve
    -- into us. The held-point threat check above still performs repeatable redodges.
    local liveHomingOrb = false
    for _, th in pairs(S.threats) do
        if th.repeatableHoming then
            liveHomingOrb = true
            break
        end
    end
    if liveHomingOrb then
        S.dodgeClearSince = nil
        S.dodgeBlockerCount = math.max(S.dodgeBlockerCount, 1)
        -- A real live orb outranks the generic combo timeout.
        if S.dodgeHardEndAt > 0 and t >= S.dodgeHardEndAt - 0.25 then
            S.dodgeHardEndAt = t + 1.0
        end
        return
    end

    if S.dodgeHardEndAt > 0 and t >= S.dodgeHardEndAt then
        resetDodgeEpisode("combo HOLD timeout -> re-armed")
        if S.walkModeActive then
            walkToGoal(base, "RETURN -> FLOOR CLOSE", true)
        else
            setHoverGoal(base, "RETURN -> overhead")
            updateFollower(true)
        end
        return
    end

    if #baseThreats > 0 then
        S.dodgeClearSince = nil
        return
    end

    if not S.dodgeClearSince then
        S.dodgeClearSince = t
        return
    end

    if t - S.dodgeClearSince < CFG.DODGE_DEAD_THREAT_GRACE then
        return
    end

    resetDodgeEpisode()
    if S.walkModeActive then
        walkToGoal(base, "RETURN -> FLOOR CLOSE", true)
    else
        setHoverGoal(base, "RETURN -> overhead")
        updateFollower(true)
    end
end

--// Exact game PrecastHitbox hook + BridgeNet2 fallback
-- The decompiled client module connects to BridgeNet2 once, then dynamically calls
-- u5[payload[action]](...). Replacing the returned module table's Circle/Cube entries
-- therefore intercepts the exact same call the game uses to render every normal
-- precast (including Temple Guard circles) without needing to identify visual Parts.
local function exactPrecastDedupeKey(action, a, b, delayUntilAttack, startTime)
    local attackAt = (tonumber(startTime) or serverNow()) + (tonumber(delayUntilAttack) or 0.6)
    if action == "Circle" and typeof(a) == "Vector3" then
        return string.format(
            "C:%.2f:%.1f:%.1f:%.1f:%.1f",
            attackAt, a.X, a.Y, a.Z, tonumber(b) or 0
        )
    elseif action == "Cube" and typeof(a) == "CFrame" and typeof(b) == "Vector3" then
        local p = a.Position
        local l = a.LookVector
        return string.format(
            "B:%.2f:%.1f:%.1f:%.1f:%.2f:%.2f:%.1f:%.1f:%.1f",
            attackAt, p.X, p.Y, p.Z, l.X, l.Z, b.X, b.Y, b.Z
        )
    end
    return nil
end

local function exactPrecastIsDuplicate(key)
    if not key then return false end
    local now = clock()
    for k, at in pairs(S.precastDedupe) do
        if now - at > 0.45 then
            S.precastDedupe[k] = nil
        end
    end
    local old = S.precastDedupe[key]
    S.precastDedupe[key] = now
    return old ~= nil and now - old < 0.35
end

local function registerExactPrecast(action, a, b, delayUntilAttack, startTime, source)
    delayUntilAttack = tonumber(delayUntilAttack) or 0.6
    startTime = tonumber(startTime) or serverNow()
    local dedupeKey = exactPrecastDedupeKey(action, a, b, delayUntilAttack, startTime)
    if exactPrecastIsDuplicate(dedupeKey) then
        return true
    end
    local remaining = math.max(0, startTime + delayUntilAttack - serverNow())
    local hold = remaining + CFG.PRECAST_LINGER
    local templeCoreCube = action == "Cube" and S.target and lower(S.target.Name) == "temple core generator"

    -- Temple Core's passive Water Square sequence can still be sweeping after the
    -- normal precast's attack moment. Retain the exact XZ square conservatively so
    -- return-to-overhead cannot happen inside the trailing sweep.
    if templeCoreCube then
        hold = math.max(hold, remaining + CFG.TEMPLE_CORE_SQUARE_POST_HIT_HOLD)
    end

    if action == "Cube" and typeof(a) == "CFrame" and typeof(b) == "Vector3" then
        S.precastCount += 1
        local cubeSize = b
        if templeCoreCube then
            local pad = CFG.TEMPLE_CORE_SQUARE_PRECAST_PAD
            cubeSize = Vector3.new(b.X + pad * 2, b.Y, b.Z + pad * 2)
        end
        addThreat({
            kind = "CUBE",
            source = "precast",
            label = templeCoreCube and "TEMPLE CORE: Water Square (PRE-DAMAGE)" or "PRECAST CUBE",
            cframe = a,
            size = cubeSize,
            impactAt = clock() + remaining,
            endAt = clock() + hold,
            redodgeEligible = true,
            boss = templeCoreCube and "Temple Core Generator" or nil,
            templeCoreSquare = templeCoreCube or nil,
        })
        if CFG.PRINT_EVENTS then
            print("[DQ Dodge][Precast]", source or "unknown", "Cube", a.Position, b, "hold", hold)
        end
        return true
    end

    if action == "Circle" and typeof(a) == "Vector3" then
        local radius = tonumber(b) or 8
        local targetName = S.target and lower(S.target.Name) or ""
        local templeGuardCircle = targetName:find("temple guard", 1, true) ~= nil

        -- Temple Guard's circle AOE is the ordinary PrecastHitbox.Circle path.
        -- Give it a server-edge buffer and keep the XZ zone dangerous a little
        -- beyond the visual attack moment so a late/edge damage check cannot land
        -- after we have already returned overhead.
        if templeGuardCircle then
            radius += CFG.TEMPLE_GUARD_CIRCLE_PAD
            hold = math.max(hold, remaining + CFG.TEMPLE_GUARD_CIRCLE_POST_HIT_HOLD)
        end

        S.precastCount += 1
        addThreat({
            kind = "CIRCLE",
            source = "precast",
            label = templeGuardCircle and "TEMPLE GUARD: Circle AOE" or "PRECAST CIRCLE",
            position = a,
            radius = radius,
            impactAt = clock() + remaining,
            endAt = clock() + hold,
            redodgeEligible = true,
            templeGuardCircle = templeGuardCircle or nil,
        })
        if CFG.PRINT_EVENTS then
            print("[DQ Dodge][Precast]", source or "unknown", "Circle", a, radius, "hold", hold)
        end
        return true
    end

    return false
end

local function hookPrecasts()
    local utility = ReplicatedStorage:FindFirstChild("Utility")
    local bridgeModule = utility and utility:FindFirstChild("BridgeNet2")
    if not bridgeModule then
        S.lastAction = "BridgeNet2 missing"
        S.precastHookMode = "missing BridgeNet2"
        return
    end

    local ok, BridgeNet2 = pcall(require, bridgeModule)
    if not ok or not BridgeNet2 then
        S.lastAction = "BridgeNet2 require failed"
        S.precastHookMode = "BridgeNet2 require failed"
        return
    end

    local okAction, actionId = pcall(function()
        return BridgeNet2.ReferenceIdentifier("action")
    end)

    -- Preferred path: wrap the game's actual PrecastHitbox module functions.
    -- We keep stable references to the ORIGINAL renderer functions on the module table.
    -- If this script is executed again, we replace the old wrapper rather than stacking
    -- wrappers around wrappers.
    local moduleHooked = false
    local modules = ReplicatedStorage:FindFirstChild("modules")
    local precastModuleScript = modules and modules:FindFirstChild("PrecastHitbox")
    if precastModuleScript then
        local okModule, PrecastHitbox = pcall(require, precastModuleScript)
        if okModule and type(PrecastHitbox) == "table" then
            local originalCircle = rawget(PrecastHitbox, "__DQ_DODGER_ORIGINAL_CIRCLE")
            local originalCube = rawget(PrecastHitbox, "__DQ_DODGER_ORIGINAL_CUBE")

            if type(originalCircle) ~= "function" and type(PrecastHitbox.Circle) == "function" then
                originalCircle = PrecastHitbox.Circle
                rawset(PrecastHitbox, "__DQ_DODGER_ORIGINAL_CIRCLE", originalCircle)
            end
            if type(originalCube) ~= "function" and type(PrecastHitbox.Cube) == "function" then
                originalCube = PrecastHitbox.Cube
                rawset(PrecastHitbox, "__DQ_DODGER_ORIGINAL_CUBE", originalCube)
            end

            if type(originalCircle) == "function" and type(originalCube) == "function" then
                PrecastHitbox.Circle = function(position, radius, delayUntilAttack, startTime, properties)
                    -- Register BEFORE rendering so the dodge solver sees the circle on
                    -- the same scheduler turn that Dungeon Quest receives it.
                    registerExactPrecast("Circle", position, radius, delayUntilAttack, startTime, "PrecastHitbox.Circle")
                    return originalCircle(position, radius, delayUntilAttack, startTime, properties)
                end

                PrecastHitbox.Cube = function(cframe, size, delayUntilAttack, startTime, properties)
                    registerExactPrecast("Cube", cframe, size, delayUntilAttack, startTime, "PrecastHitbox.Cube")
                    return originalCube(cframe, size, delayUntilAttack, startTime, properties)
                end

                moduleHooked = true
                S.precastHookMode = "MODULE Circle+Cube"
                S.lastAction = "PrecastHitbox Circle/Cube hooked"
            end
        end
    end

    -- Keep a direct BridgeNet observer even when the module wrapper succeeds.
    -- Temple Guard exposed that one interception path can be missed in some live
    -- sessions. exactPrecastDedupeKey() prevents the same server precast from being
    -- registered twice when both paths fire.
    if okAction and actionId then
        local okBridge, precastBridge = pcall(function()
            return BridgeNet2.ReferenceBridge("precastHitbox")
        end)
        if okBridge and precastBridge then
            local okConnect = pcall(function()
                precastBridge:Connect(function(payload)
                    if type(payload) ~= "table" then return end
                    local action = payload[actionId]
                    if action == "Cube" then
                        registerExactPrecast(
                            "Cube",
                            payload.cframe,
                            payload.size,
                            payload.delayUntilAttack,
                            payload.startTime,
                            "BridgeNet fallback"
                        )
                    elseif action == "Circle" then
                        registerExactPrecast(
                            "Circle",
                            payload.position,
                            payload.radius,
                            payload.delayUntilAttack,
                            payload.startTime,
                            "BridgeNet fallback"
                        )
                    end
                end)
            end)
            if okConnect then
                if moduleHooked then
                    S.precastHookMode = "MODULE+BRIDGE Circle+Cube"
                    S.lastAction = "Precast module + bridge observers active"
                else
                    S.precastHookMode = "BRIDGE Circle+Cube"
                    S.lastAction = "Precast bridge observer active"
                end
            else
                if moduleHooked then
                    S.precastHookMode = "MODULE Circle+Cube"
                    S.lastAction = "Precast module active; bridge observer unavailable"
                else
                    S.precastHookMode = "FAILED"
                    S.lastAction = "precast hook failed"
                end
            end
        end
    end

    -- EnemyEffects exists in the decompile and carries action/enemy/timestamp/data.
    local okEnemyBridge, enemyBridge = pcall(function()
        return BridgeNet2.ClientBridge("EnemyEffects")
    end)
    local okEnemyId, enemyId = pcall(function()
        return BridgeNet2.ReferenceIdentifier("enemy")
    end)
    local okTimestampId, timestampId = pcall(function()
        return BridgeNet2.ReferenceIdentifier("timestamp")
    end)

    if okEnemyBridge and enemyBridge and okAction and actionId and okEnemyId and enemyId then
        pcall(function()
            enemyBridge:Connect(function(payload)
                if type(payload) ~= "table" then return end
                local action = tostring(payload[actionId] or "")
                local enemy = payload[enemyId]
                if action == "" then return end
                if containsAny(action, SAFE_OR_COSMETIC_WORDS) or containsAny(action, NON_ATTACK_WORDS) then
                    return
                end
                if not containsAny(action, ATTACK_WORDS) then
                    return
                end

                local root
                if typeof(enemy) == "Instance" then
                    local model = enemy:IsA("Model") and enemy or enemy:FindFirstAncestorOfClass("Model")
                    if model then root = select(1, getModelParts(model)) end
                end
                if not root then root = S.targetRoot end
                if not root then return end

                local name = lower(action)
                local duration = containsAny(name, {"beam", "laser", "breath", "flame", "fire"}) and 1.8
                    or (containsAny(name, {"mark", "curse", "target"}) and 2.5 or 1.2)

                local kind, radius, range, halfAngle = "RADIAL", 16, nil, nil
                if containsAny(name, {"beam", "laser", "line", "breath", "flame throw", "charge"}) then
                    kind = "CONE"
                    range = 75
                    halfAngle = math.rad(32)
                elseif containsAny(name, {"spin", "cyclone", "whirl", "aura", "slam", "stomp", "explod", "blast"}) then
                    kind = "RADIAL"
                    radius = 22
                elseif containsAny(name, {"slash", "swing", "strike", "punch", "cleave", "bite", "stab"}) then
                    kind = "CONE"
                    range = 18
                    halfAngle = CFG.MELEE_CONE_HALF_ANGLE
                end

                S.eventCount += 1
                addThreat({
                    kind = kind,
                    source = "enemyEffects",
                    label = "ENEMY: " .. action,
                    root = root,
                    requiresRoot = true,
                    radius = radius,
                    range = range,
                    halfAngle = halfAngle,
                    endAt = clock() + duration,
                    redodgeEligible = true,
                })

                if CFG.PRINT_EVENTS then
                    print("[DQ Dodge][EnemyEffects]", action, enemy, payload[timestampId])
                end
            end)
        end)
    end
end

--// Map-specific boss remotes seen in the decompile
local MAP_EVENT_REMOTES = {
    "aquaticBossSpecficEvents",
    "bossSpecficEvents",
    "easterIslandBossSpecficEvents",
    "enchantedBossSpecficEvents",
    "ghastlyBossSpecficEvents",
    "gildedBossSpecficEvents",
    "glitchBossSpecficEvents",
    "golemClientEvents",
    "mapSpecificEvent",
    "miyamotoClientEvents",
    "northernBossSpecficEvents",
    "orbitalBossSpecficEvents",
    "sanadaClientEvents",
    "steampunkBossSpecficEvents",
    "volcanicBossSpecficEvents",
}

local function extractPositionFromValue(v, depth)
    depth = depth or 0
    if depth > 2 then return nil end
    local tv = typeof(v)
    if tv == "Vector3" then return v end
    if tv == "CFrame" then return v.Position end
    if tv == "Instance" then
        if v:IsA("BasePart") then return v.Position end
        if v:IsA("Model") then
            local root = v:FindFirstChild("HumanoidRootPart") or v.PrimaryPart
            if root then return root.Position end
            local ok, pivot = pcall(function() return v:GetPivot() end)
            if ok then return pivot.Position end
        end
    end
    if type(v) == "table" then
        for _, x in pairs(v) do
            local p = extractPositionFromValue(x, depth + 1)
            if p then return p end
        end
    end
    return nil
end

local function inferEventThreat(action, args)
    if action == "" then return end
    if containsAny(action, SAFE_OR_COSMETIC_WORDS) then return end
    if not containsAny(action, ATTACK_WORDS) then return end

    local pos
    for i = 1, (args.n or #args) do
        pos = extractPositionFromValue(args[i])
        if pos then break end
    end

    local name = lower(action)
    local duration = CFG.EVENT_DEFAULT_HOLD
    if containsAny(name, {"mark", "target", "curse", "caught fire", "charging"}) then
        duration = 2.7
    elseif containsAny(name, {"beam", "laser", "flame wall", "fire beam", "breath", "gatling"}) then
        duration = 2.0
    elseif containsAny(name, {"explod", "slam", "spike", "rock fall", "geyser", "pulse"}) then
        duration = 1.35
    end

    local threat
    if pos then
        local radius = 15
        if name:find("explosive mob shot", 1, true) then
            -- Volcanic Chambers' client event only flashes the Lava Walker muzzle;
            -- explosiveMobShot1/2/3 are separate enemyProjectile templates and their
            -- server-side damage creation is not present in this dump. Start moving
            -- on the firing event, then let the live visual geometry take over.
            radius = CFG.VOLCANIC_EXPLOSIVE_WALKER_EVENT_RADIUS
            duration = math.max(duration, CFG.VOLCANIC_EXPLOSIVE_WALKER_EVENT_HOLD)
        elseif containsAny(name, {"big", "everyone gets hit", "explod", "slam", "aura", "pulse", "tall swirly"}) then
            radius = 26
        elseif containsAny(name, {"orb", "bomb", "spike", "rock", "shot", "missile"}) then
            radius = 11
        end
        threat = {
            kind = "CIRCLE",
            source = "event",
            label = "EVENT: " .. action,
            position = pos,
            radius = radius,
            endAt = clock() + duration,
            redodgeEligible = true,
        }
    elseif S.targetRoot then
        if containsAny(name, {"beam", "laser", "line", "breath", "flame throw", "charge", "crescent"}) then
            threat = {
                kind = "CONE",
                source = "event",
                label = "EVENT: " .. action,
                root = S.targetRoot,
                requiresRoot = true,
                range = 85,
                halfAngle = math.rad(38),
                endAt = clock() + duration,
            }
        else
            threat = {
                kind = "RADIAL",
                source = "event",
                label = "EVENT: " .. action,
                root = S.targetRoot,
                requiresRoot = true,
                radius = 24,
                endAt = clock() + duration,
            }
        end
    end

    if threat then
        S.eventCount += 1
        addThreat(threat)
    end
end

local function clearMiyamotoFlameThreats()
    for id in pairs(S.miyamotoFlameThreatIds) do
        removeThreat(id)
    end
    S.miyamotoFlameThreatIds = {}
end

local function handleMiyamotoEvent(action, args)
    if action == "fireCyclone" then
        -- Decompiled client keeps ReplicatedStorage.enemyProjectiles["Flame Cyclone"]
        -- attached to Miyamoto's HumanoidRootPart and Debris-removes it after 3.5s.
        -- Treat it as one moving radial attack; it may coexist with later precasts.
        if S.miyamotoCycloneThreatId then removeThreat(S.miyamotoCycloneThreatId) end
        local root = S.targetRoot
        local data = args[2]
        if type(data) == "table" and typeof(data[1]) == "Instance" then
            local model = data[1]:IsA("Model") and data[1] or data[1]:FindFirstAncestorOfClass("Model")
            if model then root = select(1, getModelParts(model)) or root end
        end
        if root then
            local id = nextThreatId("MIYAMOTO_CYCLONE")
            S.miyamotoCycloneThreatId = id
            addThreat({
                id = id,
                kind = "RADIAL",
                source = "event",
                label = "MIYAMOTO: Flame Cyclone",
                root = root,
                requiresRoot = true,
                radius = 24,
                endAt = clock() + 3.75,
                redodgeEligible = true,
            })
        end
        return true
    end

    if action == "endFireCyclone" then
        if S.miyamotoCycloneThreatId then
            removeThreat(S.miyamotoCycloneThreatId)
            S.miyamotoCycloneThreatId = nil
        end
        return true
    end

    if action == "flameBeams" then
        -- Decompiled client only starts a ~4s animation/effect here; it does not give
        -- beam geometry. Do NOT invent a broad circle/cone. The exact BridgeNet2
        -- Cube/Circle precasts arriving during this sequence drive each line dodge.
        S.lastAction = "Miyamoto flameBeams -> watching exact precasts"
        return true
    end

    if action == "spinFlameShuriken" then
        -- This remote only rotates the supplied shuriken visual every frame. Geometry
        -- is handled by the projectile/visual detector, avoiding a fake boss-centered AOE.
        return true
    end

    if action == "showFire" then
        clearMiyamotoFlameThreats()
        local folder = workspace:FindFirstChild("miyamotoFlames")
        if folder then
            for _, inst in ipairs(folder:GetDescendants()) do
                if inst:IsA("BasePart") and lower(inst.Name):find("flame", 1, true) then
                    local id = nextThreatId("MIYAMOTO_FIRE")
                    S.miyamotoFlameThreatIds[id] = true
                    addThreat({
                        id = id,
                        kind = "OBB",
                        source = "event",
                        label = "MIYAMOTO: floor flame",
                        part = inst,
                        requiresPart = true,
                        endAt = clock() + 15,
                        redodgeEligible = true,
                    })
                end
            end
        end
        return true
    end

    if action == "hideFire" then
        clearMiyamotoFlameThreats()
        return true
    end

    return false
end

--// Aquatic Temple: Temple Core Generator exact event geometry
-- Decompiled mapSpecificLocals.client.luau shows:
--   "first boss laser shot"  payload = {laserStartTime, laserEndTime, startCFrame, travelLength, bossModel, topIndex}
--   "first boss moving orb"  payload = {startCFrame, startTime, endTime, travelLength, duration}
-- The passive Water Squares are emitted through the normal PrecastHitbox Cube path,
-- which hookPrecasts() already handles exactly in XZ.
local function isTempleCoreGenerator(model)
    return model and lower(model.Name) == "temple core generator"
end

local function templeCoreLaserWidth()
    local width = CFG.TEMPLE_CORE_LASER_WIDTH
    local folder = ReplicatedStorage:FindFirstChild("enemyProjectiles")
    local template = folder and folder:FindFirstChild("firstBossLaserPrecast")
    if template then
        local ok, size = pcall(function()
            if template:IsA("BasePart") then
                return template.Size
            elseif template:IsA("Model") then
                return template:GetExtentsSize()
            end
        end)
        if ok and typeof(size) == "Vector3" then
            -- The laser runs along LookVector/local Z. Use the smaller horizontal
            -- dimension as a width hint, but never shrink below the safe default.
            local hinted = math.min(math.abs(size.X), math.abs(size.Z))
            if hinted > 0.1 then
                width = math.max(width, hinted)
            end
        end
    end
    return width
end

local function handleAquaticTempleEvent(action, args)
    if action == "first boss laser shot" then
        local data = args[2]
        if type(data) ~= "table" then return true end

        local laserStart = tonumber(data[1]) or serverNow()
        local laserEnd = tonumber(data[2]) or (laserStart + 1.0)
        local startCF = data[3]
        local travelLength = math.max(tonumber(data[4]) or 120, 1)
        if typeof(startCF) ~= "CFrame" then return true end

        -- The decompiled visual starts at startCF and extends along LookVector for
        -- travelLength. Represent the entire telegraphed lane as an XZ OBB so being
        -- high above the boss never falsely counts as safe.
        local midCF = startCF + startCF.LookVector * (travelLength * 0.5)
        local width = templeCoreLaserWidth()
        local remaining = math.max(0.18, laserEnd - serverNow())

        S.eventCount += 1
        addThreat({
            kind = "OBB",
            source = "event",
            label = "TEMPLE CORE: Water Line",
            cframe = midCF,
            size = Vector3.new(width, 8, travelLength + width),
            endAt = clock() + remaining + CFG.TEMPLE_CORE_LASER_LINGER,
            redodgeEligible = true,
            boss = "Temple Core Generator",
        })
        S.lastAction = "Temple Core Water Line -> exact lane"
        return true
    end

    if action == "first boss moving orb" then
        local data = args[2]
        if type(data) ~= "table" then return true end

        local startCF = data[1]
        local startTime = tonumber(data[2]) or serverNow()
        local endTime = tonumber(data[3])
        local travelLength = math.max(tonumber(data[4]) or 0, 0)
        local duration = math.max(tonumber(data[5]) or 1.0, 0.05)
        if typeof(startCF) ~= "CFrame" then return true end
        if not endTime then endTime = startTime + duration end

        local velocity = startCF.LookVector * (travelLength / duration)
        local remaining = math.max(0.18, endTime - serverNow())
        S.templeCoreLastOrbAt = clock()

        S.projectileCount += 1
        S.eventCount += 1
        addThreat({
            kind = "PROJECTILE",
            source = "event",
            label = "TEMPLE CORE: Water Orb (MOVING)",
            pathStartCFrame = startCF,
            pathStartServerTime = startTime,
            pathDuration = duration,
            pathDistance = travelLength,
            velocity = velocity,
            radius = CFG.TEMPLE_CORE_ORB_RADIUS,
            predictTime = CFG.TEMPLE_CORE_ORB_PREDICT,
            endAt = clock() + remaining + CFG.TEMPLE_CORE_ORB_LINGER,
            redodgeEligible = true,
            boss = "Temple Core Generator",
        })

        -- This orb is deterministic and straight in mapSpecificLocals: CFrame =
        -- startCF + LookVector * travelLength * alpha. The dump caught lethal deaths
        -- with a moving-orb event ~0.8s earlier and no square covering the snapshot.
        -- Reserve the COMPLETE lane immediately instead of waiting for the moving
        -- point prediction to get close enough.
        local pathMid = startCF + startCF.LookVector * (travelLength * 0.5)
        addThreat({
            kind = "OBB",
            source = "event",
            label = "TEMPLE CORE: Water Orb FULL PATH",
            cframe = pathMid,
            size = Vector3.new(CFG.TEMPLE_CORE_ORB_PATH_WIDTH, 8, travelLength + CFG.TEMPLE_CORE_ORB_PATH_WIDTH),
            endAt = clock() + remaining + CFG.TEMPLE_CORE_ORB_PATH_LINGER,
            redodgeEligible = true,
            boss = "Temple Core Generator",
            templeCoreOrbPath = true,
        })

        -- V3: the damage probe repeatedly recorded lethal, geometry-empty frames
        -- 0.47-0.99s after first-boss-moving-orb events. Reserve both launch and
        -- terminal areas as radial danger too; this catches any server-side spawn/
        -- impact radius that is not represented by the thin client travel visual.
        local endPos = startCF.Position + startCF.LookVector * travelLength
        addThreat({
            kind = "CIRCLE",
            source = "event",
            label = "TEMPLE CORE: Water Orb LAUNCH ZONE",
            position = startCF.Position,
            radius = CFG.TEMPLE_CORE_ORB_START_RADIUS,
            endAt = clock() + math.min(remaining, 0.65) + 0.45,
            redodgeEligible = true,
            boss = "Temple Core Generator",
            templeCoreOrbZone = true,
        })
        addThreat({
            kind = "CIRCLE",
            source = "event",
            label = "TEMPLE CORE: Water Orb ENDPOINT BLAST",
            position = endPos,
            radius = CFG.TEMPLE_CORE_ORB_ENDPOINT_RADIUS,
            endAt = clock() + remaining + CFG.TEMPLE_CORE_ORB_PATH_LINGER,
            redodgeEligible = true,
            boss = "Temple Core Generator",
            templeCoreOrbZone = true,
        })

        S.lastAction = "Temple Core Water Orb -> wide path + endpoint reserved"
        return true
    end

    -- Cosmetic/setup Aquatic events must not become generic fake danger zones.
    if action == "second boss show damage parts" or action == "Shake Screens" then
        return true
    end

    return false
end


--// Volcanic Chambers: Ancient Lava Mage exact orb handling
-- Decompiled mapSpecificLocals.client.luau:
--   volcanicBossSpecficEvents("First Boss Orb Explosion", explosionCFrame)
-- clones genericNeonBall at that CFrame and tweens it to Size = Vector3.new(60,60,60)
-- in 0.4s.  The remote is a detonation visual, not a useful pre-warning: in the
-- recorded death, HP reached 0 on the same frame this event was observed.
local function handleVolcanicBossEvent(action, args)
    -- Artillery Lava Walker exact impact targeting. Decompiled mapSpecificLocals:
    --   payload[1] = Artillery Lava Walker model
    --   payload[2] = locked landing CFrame
    --   wait(0.15) + wait(0.25), then artilleryRock starts 100 studs above payload[2]
    --   and reaches payload[2] in another 0.50s.
    -- Generic event inference recursively scans payload tables and can pick payload[1]
    -- (the SHOOTER position) before payload[2], so handle this action explicitly.
    if action == "Artillery Mob Shot" then
        local payload = args[2]
        local landing
        if type(payload) == "table" then
            landing = extractPositionFromValue(payload[2])
        end
        if not landing then
            -- Defensive fallback for alternate server payload shapes: prefer the last
            -- positional argument, since the decompiled canonical shape puts target last.
            local n = args.n or #args
            for i = n, 2, -1 do
                landing = extractPositionFromValue(args[i])
                if landing then break end
            end
        end

        if landing then
            S.eventCount += 1
            addThreat({
                kind = "CIRCLE",
                source = "event",
                label = "VOLCANIC: Artillery Lava Walker LANDING",
                position = landing,
                radius = CFG.VOLCANIC_ARTILLERY_IMPACT_RADIUS,
                impactAt = clock() + 0.90, -- 0.15 + 0.25 warmup + 0.50 fall from the decompile
                endAt = clock() + CFG.VOLCANIC_ARTILLERY_EVENT_HOLD,
                redodgeEligible = true,
                artilleryLavaWalker = true,
            })
            S.lastAction = "Artillery Lava Walker -> evade locked landing zone"
        else
            S.lastAction = "Artillery Lava Walker event -> landing CFrame missing"
        end
        return true
    end

    -- Lava King / third boss bomb. The decompile passes the cursed Character as
    -- args[2], spawns six thirdBossCurseRing parts centered on that character for
    -- six seconds, and later emits Curse Sizzle (successful green-zone cancel) or
    -- Curse Explosion (failed bomb). Handle these explicitly so generic event
    -- inference does not incorrectly classify our own curse rings as dodge-away AoE.
    if action == "Third Boss Curse Char" then
        local victim = args[2]
        if victim == S.char or victim == LocalPlayer.Character then
            S.lavaKingCurseVictim = victim
            S.lavaKingCurseResolvedAt = 0
            S.lavaKingCurseActiveUntil = clock() + CFG.LAVA_KING_CURSE_HOLD
            S.lavaKingLastSafeScan = -math.huge
            S.lavaKingSafeObject = nil
            S.lavaKingSafePart = nil
            S.lastAction = "LAVA KING BOMB: local curse acquired -> find GREEN SAFE ZONE"
        end
        return true
    end

    if action == "Third Boss Curse Sizzle" then
        local victim = args[2]
        if victim == S.char or victim == LocalPlayer.Character then
            S.lavaKingCurseActiveUntil = 0
            S.lavaKingCurseResolvedAt = clock()
            S.lavaKingCurseVictim = nil
            exitLavaKingSafeMode("Lava King GREEN SAFE ZONE triggered -> bomb cancelled")
            S.lastAction = "LAVA KING BOMB: GREEN SAFE ZONE SUCCESS"
        end
        return true
    end

    if action == "Third Boss Curse Explosion" then
        local victim = args[2]
        if victim == S.char or victim == LocalPlayer.Character then
            S.lavaKingCurseActiveUntil = 0
            S.lavaKingCurseResolvedAt = clock()
            S.lavaKingCurseVictim = nil
            exitLavaKingSafeMode("Lava King curse exploded -> dodge re-armed")
        end
        -- The visual is spawned at detonation time and grows to 170 studs. It is too
        -- late to be our primary warning, but preserving a brief global-radius threat
        -- stops the controller from immediately snapping back into the explosion.
        local victimRoot = typeof(victim) == "Instance" and victim:FindFirstChild("HumanoidRootPart") or nil
        if victimRoot then
            S.eventCount += 1
            addThreat({
                kind = "CIRCLE",
                source = "event",
                label = "VOLCANIC: Lava King Curse Explosion",
                position = victimRoot.Position,
                radius = 85.0,
                endAt = clock() + 1.0,
                redodgeEligible = true,
                boss = "Lava King",
            })
        end
        return true
    end

    if action == "First Boss Orb Explosion" then
        local pos = extractPositionFromValue(args[2])
        if pos then
            S.eventCount += 1
            addThreat({
                kind = "CIRCLE",
                source = "event",
                label = "VOLCANIC: First Boss Orb Explosion",
                position = pos,
                radius = CFG.VOLCANIC_ORB_EXPLOSION_RADIUS,
                endAt = clock() + CFG.VOLCANIC_ORB_EXPLOSION_LINGER,
                redodgeEligible = true,
                boss = "Ancient Lava Mage",
            })
            S.lastAction = "Ancient Lava Mage orb detonated (backup event)"
        end
        return true
    end

    return false
end

local function hookLocalAbilityVisualEvents()
    local remotes = ReplicatedStorage:FindFirstChild("remotes")
    local abilityCast = remotes and remotes:FindFirstChild("abilityCast")
    if not abilityCast or not abilityCast:IsA("RemoteEvent") then return end

    abilityCast.OnClientEvent:Connect(function(caster, action, ...)
        if caster ~= LocalPlayer or type(action) ~= "string" then return end
        local a = lower(action)

        -- Dump evidence:
        --   <LocalPlayer> | "Water Orb Spawn" -> Workspace."Big Phase Ball"
        --   <LocalPlayer> | "Water Orb Hit"   -> Workspace.phaseBeamModel
        -- Quarantine only these names for a short window; Aquatic boss attacks use
        -- aquaticBossSpecficEvents and are unaffected.
        if a == "water orb spawn" then
            quarantineLocalEffectName("Big Phase Ball")
            quarantineLocalEffectName("Phase Ring")
            S.ignoredOwnVisuals += 1
        elseif a == "water orb hit" then
            quarantineLocalEffectName("phaseBeamModel")
            quarantineLocalEffectName("Phase Ring")
            quarantineLocalEffectName("Big Phase Ball")
            S.ignoredOwnVisuals += 1
        end
    end)
end

local function hookMapEvents()
    local remotes = ReplicatedStorage:FindFirstChild("remotes")
    if not remotes then return end

    -- Remotes can finish replicating after an auto-executed script begins. Keep this
    -- hook idempotent and attach map-specific boss remotes that arrive late too.
    local hooked = setmetatable({}, {__mode = "k"})
    local function attach(remote, remoteName)
        if not remote or not remote:IsA("RemoteEvent") or hooked[remote] then return end
        hooked[remote] = true
        remote.OnClientEvent:Connect(function(...)
            local args = table.pack(...)
            local action = type(args[1]) == "string" and args[1] or remoteName
            local handledSpecial = false
            if remoteName == "miyamotoClientEvents" then
                handledSpecial = handleMiyamotoEvent(action, args)
            elseif remoteName == "aquaticBossSpecficEvents" then
                handledSpecial = handleAquaticTempleEvent(action, args)
            elseif remoteName == "volcanicBossSpecficEvents" then
                handledSpecial = handleVolcanicBossEvent(action, args)
            end
            if not handledSpecial then
                inferEventThreat(action, args)
            end
            if CFG.PRINT_EVENTS then
                print("[DQ Dodge][MapEvent]", remoteName, action, ...)
            end
        end)
    end

    local function tryAttach(remote)
        if not remote then return end
        for _, remoteName in ipairs(MAP_EVENT_REMOTES) do
            if remote.Name == remoteName then
                attach(remote, remoteName)
                return
            end
        end
    end

    for _, remoteName in ipairs(MAP_EVENT_REMOTES) do
        attach(remotes:FindFirstChild(remoteName), remoteName)
    end
    remotes.ChildAdded:Connect(tryAttach)
end

--// Newly-created transient attack geometry / projectiles
local function visualNameOf(inst)
    local names = {}
    local current = inst
    for _ = 1, 10 do
        if not current or current == workspace then break end
        table.insert(names, current.Name)
        current = current.Parent
    end
    return lower(table.concat(names, " "))
end

local function findNamedAncestor(inst, needle)
    needle = lower(needle)
    local current = inst
    for _ = 1, 12 do
        if not current or current == workspace then break end
        if string.find(lower(current.Name), needle, 1, true) then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function isTempleCoreRuntimeAttackPart(part)
    if not part or not part:IsA("BasePart") then return false, nil end
    if not S.target or lower(S.target.Name) ~= "temple core generator" then return false, nil end
    if not S.targetRoot or not S.targetRoot.Parent then return false, nil end
    if flatDistance(part.Position, S.targetRoot.Position) > CFG.VISUAL_MAX_DISTANCE then return false, nil end

    local n = lower(part.Name)
    local size = part.Size
    local sx, sy, sz = math.abs(size.X), math.abs(size.Y), math.abs(size.Z)
    local squareXZ = math.abs(sx - CFG.TEMPLE_CORE_SQUARE_XZ) <= 2.5
                 and math.abs(sz - CFG.TEMPLE_CORE_SQUARE_XZ) <= 2.5

    if n == "hitbox" and squareXZ and sy >= CFG.TEMPLE_CORE_COLUMN_MIN_Y then
        return true, "squareColumn"
    end

    if n == "precast" and squareXZ and sy <= 4.0 then
        return true, "squarePrecast"
    end

    -- The dump repeatedly shows Water Line visuals as Model.precast 16x1x150.
    if n == "precast" and sy <= 4.0 then
        local longSide = math.max(sx, sz)
        local shortSide = math.min(sx, sz)
        if longSide >= CFG.TEMPLE_CORE_LASER_LENGTH_MIN and shortSide <= 24.0 then
            return true, "laserPrecast"
        end
    end

    return false, nil
end

local function templeCoreSweepRowKey(z)
    -- Water-square rows in the dump are spaced at 20 studs. A 4-stud bucket is
    -- tolerant of replication jitter while still separating adjacent rows.
    return tostring(math.floor(z / 4 + 0.5) * 4)
end

local function updateTempleCoreSweepPrediction(part)
    if not part or not part.Parent or not part:IsA("BasePart") then return end
    if lower(part.Name) ~= "hitbox" then return end
    if not S.target or lower(S.target.Name) ~= "temple core generator" then return end

    local now = clock()
    local pos = part.Position
    local key = templeCoreSweepRowKey(pos.Z)
    local row = S.templeCoreSweepRows[key]
    if not row then
        row = {}
        S.templeCoreSweepRows[key] = row
    end

    local dt = row.lastAt and (now - row.lastAt) or nil
    local dx = row.lastX and (pos.X - row.lastX) or nil
    if dt and dx and dt >= 0.45 and dt <= 1.60 and math.abs(dx) >= 6.0 then
        local vx = dx / math.max(dt, 1e-3)
        if math.abs(vx) >= 8 and math.abs(vx) <= 90 then
            row.vx = row.vx and (row.vx * 0.35 + vx * 0.65) or vx
        end
    end

    row.lastX = pos.X
    row.lastZ = pos.Z
    row.lastAt = now
    S.templeCoreLastSquareAt = now

    local pad = CFG.TEMPLE_CORE_SWEEP_PREDICT_PAD
    local centerX, sizeX
    if row.vx and math.abs(row.vx) >= 8 then
        -- Block from the current column through the next ~1.45 seconds of travel.
        -- Choosing a point BEHIND the sweep is therefore preferred over jumping
        -- into the square that the server is about to create next.
        local travel = row.vx * CFG.TEMPLE_CORE_SWEEP_PREDICT_TIME
        centerX = pos.X + travel * 0.5
        sizeX = math.abs(travel) + CFG.TEMPLE_CORE_SQUARE_XZ + pad * 2
    else
        -- On the first sample we do not know direction yet. Reserve a modest band
        -- on both sides; the second wave teaches the true direction ~1s later.
        centerX = pos.X
        sizeX = CFG.TEMPLE_CORE_SQUARE_XZ
              + (CFG.TEMPLE_CORE_SWEEP_UNKNOWN_AHEAD + pad) * 2
    end

    local id = row.predictedThreatId
    local th = id and S.threats[id]
    if not th then
        id = addThreat({
            kind = "OBB",
            source = "prediction",
            label = "TEMPLE CORE: PREDICTED Water Square SWEEP",
            cframe = CFrame.new(centerX, pos.Y, pos.Z),
            size = Vector3.new(sizeX, 8, CFG.TEMPLE_CORE_SQUARE_XZ + pad * 2),
            endAt = now + CFG.TEMPLE_CORE_SWEEP_ACTIVE_HOLD,
            redodgeEligible = true,
            boss = "Temple Core Generator",
            templeCoreSquare = true,
            templeCorePredictedSweep = true,
        })
        row.predictedThreatId = id
    else
        th.cframe = CFrame.new(centerX, pos.Y, pos.Z)
        th.size = Vector3.new(sizeX, 8, CFG.TEMPLE_CORE_SQUARE_XZ + pad * 2)
        th.endAt = now + CFG.TEMPLE_CORE_SWEEP_ACTIVE_HOLD
    end
end

-- Exact client renderer signature from ReplicatedStorage.modules.PrecastHitbox:
-- Circle -> anonymous Neon Cylinder, Anchored, CanTouch/CanQuery/CanCollide false,
-- Size = Vector3.new(0.5, radius*2, radius*2), then CFrame rotated 90 degrees.
-- This is intentionally checked BEFORE name-based filtering because the Part is
-- literally named "Part" and otherwise never reaches the generic visual scanner.
local function isRenderedPrecastCircle(part)
    -- Decompiled PrecastHitbox.Circle creates an anonymous direct Workspace Part:
    --   Shape = Cylinder; Size = (0.5, diameter, diameter); then rotates local X
    --   (the cylinder axis) onto world Y. Some properties can make it thicker, so
    --   recognize the geometry/orientation rather than requiring exactly X == 0.5.
    if not part or part.ClassName ~= "Part" then return false end
    if part.Parent ~= workspace then return false end
    if S.visualizerFolder and part:IsDescendantOf(S.visualizerFolder) then return false end
    if part.Shape ~= Enum.PartType.Cylinder then return false end
    if not part.Anchored then return false end

    -- properties can rename the Part, so do not require Name == "Part". Instead
    -- require the non-physical behavior used by PrecastHitbox.createHitbox. Tolerate
    -- one property override because some attacks customize the renderer table.
    local passiveFlags = 0
    if not part.CanCollide then passiveFlags += 1 end
    if not part.CanTouch then passiveFlags += 1 end
    if not part.CanQuery then passiveFlags += 1 end
    if passiveFlags < 2 then return false end

    local s = part.Size
    local diameterA = math.abs(s.Y)
    local diameterB = math.abs(s.Z)
    local diameter = math.max(diameterA, diameterB)
    local axisVertical = math.abs(part.CFrame.RightVector.Y)

    if axisVertical < 0.55 then return false end
    if diameter < CFG.RENDERED_PRECAST_CIRCLE_MIN_DIAMETER then return false end
    if diameter > CFG.RENDERED_PRECAST_CIRCLE_MAX_DIAMETER then return false end
    if math.abs(diameterA - diameterB) > math.max(3.0, diameter * 0.25) then return false end
    if math.abs(s.X) > math.max(CFG.RENDERED_PRECAST_CIRCLE_THICK_MAX, diameter * 0.40) then return false end

    return true
end

local function hasEquivalentCircleThreat(center, radius)
    for _, th in pairs(S.threats) do
        if th.kind == "CIRCLE" and th.source ~= "melee" then
            local p = getThreatPosition(th)
            local r = tonumber(th.radius) or 0
            if flatDistance(center, p) <= 2.5 and math.abs(r - radius) <= 7.0 then
                return true
            end
        end
    end
    return false
end

local function renderedCircleBelongsToTempleGuard(center, radius)
    if S.target and S.targetRoot and S.targetRoot.Parent
        and lower(S.target.Name):find("temple guard", 1, true)
        and flatDistance(center, S.targetRoot.Position) <= radius + 28 then
        return true
    end

    for model in pairs(S.enemyRegistry) do
        if model and model.Parent and lower(model.Name):find("temple guard", 1, true) and isAliveEnemy(model) then
            local root = getModelParts(model)
            if root and flatDistance(center, root.Position) <= radius + 28 then
                return true
            end
        end
    end
    return false
end

local function registerRenderedPrecastCircle(part)
    if not isRenderedPrecastCircle(part) then return false end
    if not S.root then return false end
    if flatDistance(part.Position, S.root.Position) > CFG.VISUAL_MAX_DISTANCE then return false end

    local seenKey = "__DQ_CIRCLE_RENDERER_TRACKED"
    if part:GetAttribute(seenKey) then return true end

    local rawRadius = math.max(part.Size.Y, part.Size.Z) * 0.5
    local templeGuardCircle = renderedCircleBelongsToTempleGuard(part.Position, rawRadius)
    local radius = rawRadius + (templeGuardCircle and CFG.TEMPLE_GUARD_CIRCLE_PAD or 0)

    -- If the module/Bridge observer already caught the same server precast, don't
    -- create a second blocker. The renderer fallback exists for sessions where
    -- those interception paths are missed by the executor.
    if hasEquivalentCircleThreat(part.Position, radius) then
        pcall(function() part:SetAttribute(seenKey, true) end)
        return true
    end

    pcall(function() part:SetAttribute(seenKey, true) end)
    S.precastCount += 1
    addThreat({
        kind = "CIRCLE",
        source = "rendered-precast",
        label = templeGuardCircle
            and "TEMPLE GUARD: Rendered Circle AOE"
            or "RENDERED PRECAST CIRCLE",
        part = part,
        position = part.Position,
        radius = radius,
        requiresPart = false,
        livePartUntilRemoved = true,
        postRemoveGrace = templeGuardCircle
            and CFG.TEMPLE_GUARD_CIRCLE_POST_HIT_HOLD
            or CFG.GENERIC_RENDERED_CIRCLE_POST_HIT_HOLD,
        hardEndAt = clock() + 6.0,
        endAt = clock() + 6.0,
        redodgeEligible = true,
        templeGuardCircle = templeGuardCircle or nil,
    })

    S.lastAction = templeGuardCircle
        and "Temple Guard rendered Circle -> XZ blocker"
        or "Rendered Precast Circle -> fallback blocker"
    return true
end

local function scanRenderedPrecastCircles(force)
    if not S.enabled or not S.root then return end
    local now = clock()
    if not force and now - (S.lastRenderedCircleScan or -math.huge) < CFG.RENDERED_PRECAST_CIRCLE_SCAN_INTERVAL then
        return
    end
    S.lastRenderedCircleScan = now

    -- PrecastHitbox.createHitbox parents the anonymous Part directly to Workspace.
    -- Scanning only GetChildren() is cheap and catches the final post-properties state
    -- even if DescendantAdded observed the object too early.
    for _, inst in ipairs(workspace:GetChildren()) do
        if isRenderedPrecastCircle(inst)
            and flatDistance(inst.Position, S.root.Position) <= CFG.VISUAL_MAX_DISTANCE then
            registerRenderedPrecastCircle(inst)
        end

        if inst:IsA("Model") and lower(inst.Name) == "model" then
            for _, child in ipairs(inst:GetChildren()) do
                if child:IsA("BasePart") and isTempleGuardRuntimeHitBox(child) then
                    registerTempleGuardRuntimeHitBox(child)
                end
            end
        end
    end
end

local function shouldTrackVisualPart(part)
    if not part:IsA("BasePart") then return false end
    if S.visualizerFolder and part:IsDescendantOf(S.visualizerFolder) then return false end
    if S.char and part:IsDescendantOf(S.char) then return false end
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character and part:IsDescendantOf(p.Character) then return false end
    end

    -- Temple Core creates its real square kill columns under generic Workspace.Model
    -- containers, not under the boss model. Ownership classifiers therefore call them
    -- "unknown". The dump gives us authoritative geometry signatures, so allow those
    -- exact runtime parts before the generic ownership gate.
    local isCorePart = isTempleCoreRuntimeAttackPart(part)
    if isCorePart then return true end

    local name = visualNameOf(part)
    if containsAny(name, {"safe", "heal", "friendly"}) then return false end
    if not containsAny(name, VISUAL_DANGER_WORDS) then return false end
    if not S.root then return false end
    if flatDistance(part.Position, S.root.Position) > CFG.VISUAL_MAX_DISTANCE then return false end

    -- Known Ancient Lava Mage server projectile. This exact runtime hierarchy is
    -- enemy-owned even if the generic template-name classifier cannot resolve a
    -- deeply nested child such as its red precast/trail Part.
    if CFG.SEARING_ORB_HOMING and findNamedAncestor(part, "firstbossfolloworb") then
        return true
    end

    -- Critical ownership gate: generic visual geometry is considered dangerous
    -- only when the decompiled enemy projectile templates (or a registered enemy
    -- model) identify it as mob-owned. Player projectile templates are explicitly
    -- ignored, so our Q/E hitboxes cannot cause a dodge.
    local sourceClass = classifyVisualSource(part)
    if sourceClass == "player" then
        S.ignoredOwnVisuals += 1
        return false
    end
    if sourceClass ~= "enemy" then
        return false
    end
    return true
end

local function nearbyTempleGuardForPart(part)
    if not part or not part:IsA("BasePart") then return nil end
    local pos = part.Position

    if S.target and S.targetRoot and S.targetRoot.Parent
        and lower(S.target.Name):find("temple guard", 1, true)
        and flatDistance(pos, S.targetRoot.Position) <= 80 then
        return S.target
    end

    for model in pairs(S.enemyRegistry) do
        if model and model.Parent and lower(model.Name):find("temple guard", 1, true) and isAliveEnemy(model) then
            local root = getModelParts(model)
            if root and flatDistance(pos, root.Position) <= 80 then
                return model
            end
        end
    end
    return nil
end

local function isTempleGuardRuntimeHitBox(part)
    if not part or not part:IsA("BasePart") then return false end
    if lower(part.Name) ~= "hitbox" then return false end

    local parent = part.Parent
    if not parent or lower(parent.Name) ~= "model" then return false end

    -- Death probe confirmed these anonymous Workspace.Model.hitBox parts are the
    -- actual damage geometry. Require a nearby live Temple Guard to avoid stealing
    -- Temple Core's similarly named hitboxes.
    return nearbyTempleGuardForPart(part) ~= nil
end

local function registerTempleGuardRuntimeHitBox(part)
    if not isTempleGuardRuntimeHitBox(part) then return false end

    local key = "__templeGuardRuntimeHitbox"
    if part:GetAttribute(key) then return true end
    pcall(function() part:SetAttribute(key, true) end)

    local s = part.Size
    local kind = "OBB"
    local radius

    -- Temple Guard circle AOEs can manifest as a damage Part after the visual
    -- cylinder. If X/Z are roughly equal, model it as a circular XZ blocker;
    -- otherwise preserve the actual OBB footprint.
    if math.abs(s.X - s.Z) <= math.max(2.5, math.max(s.X, s.Z) * 0.20) then
        kind = "CIRCLE"
        radius = math.max(s.X, s.Z) * 0.5 + CFG.TEMPLE_GUARD_HITBOX_PAD
    end

    addThreat({
        kind = kind,
        source = "temple-guard-hitbox",
        label = "TEMPLE GUARD: LIVE DAMAGE HITBOX",
        part = part,
        cframe = part.CFrame,
        position = part.Position,
        size = s + Vector3.new(
            kind == "OBB" and CFG.TEMPLE_GUARD_HITBOX_PAD * 2 or 0,
            0,
            kind == "OBB" and CFG.TEMPLE_GUARD_HITBOX_PAD * 2 or 0
        ),
        radius = radius,
        requiresPart = false,
        livePartUntilRemoved = true,
        postRemoveGrace = CFG.TEMPLE_GUARD_HITBOX_POST_REMOVE,
        hardEndAt = clock() + CFG.TEMPLE_GUARD_HITBOX_MAX_LIFE,
        endAt = clock() + CFG.TEMPLE_GUARD_HITBOX_MAX_LIFE,
        redodgeEligible = true,
        templeGuardHitbox = true,
    })

    S.lastAction = "Temple Guard LIVE hitBox -> authoritative blocker"
    return true
end

local function registerVisualPart(part)
    -- Authoritative Temple Guard damage geometry first.
    if registerTempleGuardRuntimeHitBox(part) then
        return
    end

    -- Ancient Lava Mage's firstBossFollowOrb is authoritative by exact decompiled
    -- template name. Check it BEFORE anonymous-circle/generic-cylinder fallbacks so
    -- an orb visual can never be downgraded into a one-shot static circle threat.
    local earlyFollowRoot = CFG.SEARING_ORB_HOMING and findNamedAncestor(part, "firstbossfolloworb") or nil

    -- Anonymous generic PrecastHitbox.Circle renderer fallback.
    -- Must happen before shouldTrackVisualPart(), except for the exact follow orb.
    if not earlyFollowRoot and registerRenderedPrecastCircle(part) then
        return
    end

    -- Exact firstBossFollowOrb bypasses the generic 280-stud/name ownership gate.
    -- If it spawns at the far side of the arena, it still needs to be registered now
    -- because there may be no later DescendantAdded event as that same Part homes in.
    if not earlyFollowRoot and not shouldTrackVisualPart(part) then return end

    local name = visualNameOf(part)
    local size = part.Size
    local maxXZ = math.max(size.X, size.Z)
    local velocity = flatMagnitude(part.AssemblyLinearVelocity)

    -- Handle the exact homing orb before generic shape classification.
    local followRoot = earlyFollowRoot or findNamedAncestor(part, "firstbossfolloworb")
    if CFG.SEARING_ORB_HOMING and (followRoot or name:find("firstbossfolloworb", 1, true)) then
        followRoot = followRoot or part
        local trackPart = part
        if followRoot:IsA("Model") then
            trackPart = followRoot.PrimaryPart or followRoot:FindFirstChildWhichIsA("BasePart", true) or part
        elseif followRoot:IsA("BasePart") then
            trackPart = followRoot
        end

        local existingId = S.homingOrbThreatByRoot[followRoot]
        if existingId and S.threats[existingId] then
            local th = S.threats[existingId]
            if not th.part or not th.part.Parent then th.part = trackPart end
            return
        end

        S.projectileCount += 1
        local id = addThreat({
            kind = "PROJECTILE",
            source = "visual",
            label = "VOLCANIC: Searing Orb (HOMING)",
            part = trackPart,
            position = trackPart.Position,
            requiresPart = false,
            livePartUntilRemoved = true,
            postRemoveGrace = CFG.VOLCANIC_FOLLOW_ORB_POST_REMOVE_GRACE,
            radius = CFG.VOLCANIC_FOLLOW_ORB_BLAST_RADIUS,
            triggerRadius = CFG.SEARING_ORB_TRIGGER_RADIUS,
            releaseRadius = CFG.SEARING_ORB_RELEASE_RADIUS,
            predictTime = CFG.VOLCANIC_FOLLOW_ORB_PREDICT,
            endAt = clock() + CFG.VOLCANIC_FOLLOW_ORB_MAX_LIFE,
            redodgeEligible = true,
            repeatableHoming = true,
            homingArmed = true,
            homingApproachSerial = 1,
            boss = "Ancient Lava Mage",
        })
        S.homingOrbThreatByRoot[followRoot] = id
        S.lastAction = "Searing Orb acquired -> HOLD until gone / repeat side-dodge"
        return
    end

    -- Any OWNERSHIP-CONFIRMED hostile flat Cylinder is circular in XZ. Previously
    -- these named cylinders fell through to OBB logic, which can reduce a real disc
    -- to a thin rectangle because Roblox cylinders use local X as their axis.
    if part.ClassName == "Part" and part.Shape == Enum.PartType.Cylinder then
        local diameter = math.max(math.abs(size.Y), math.abs(size.Z))
        local axisVertical = math.abs(part.CFrame.RightVector.Y)
        if axisVertical >= 0.45
            and diameter >= CFG.RENDERED_PRECAST_CIRCLE_MIN_DIAMETER
            and math.abs(size.Y - size.Z) <= math.max(4.0, diameter * 0.30) then
            local hardEnd = clock() + CFG.GENERIC_CYLINDER_MAX_LIFE
            addThreat({
                kind = "CIRCLE",
                source = "visual",
                label = name:find("explosivemobshot", 1, true)
                    and "VOLCANIC: Explosive Lava Walker CYLINDER"
                    or ("CYLINDER AOE: " .. part.Name),
                part = part,
                position = part.Position,
                radius = diameter * 0.5 + CFG.GENERIC_CYLINDER_PAD,
                dynamicRadiusFromPart = true,
                dynamicRadiusPad = CFG.GENERIC_CYLINDER_PAD,
                requiresPart = false,
                livePartUntilRemoved = true,
                postRemoveGrace = CFG.GENERIC_CYLINDER_POST_REMOVE,
                hardEndAt = hardEnd,
                endAt = hardEnd,
                redodgeEligible = true,
            })
            S.lastAction = name:find("explosivemobshot", 1, true)
                and "Explosive Lava Walker cylinder -> circular XZ blocker"
                or "hostile Cylinder -> circular XZ blocker"
            return
        end
    end

    -- Artillery Lava Walker live fallback. artilleryRock is tweened vertically, so
    -- AssemblyLinearVelocity may be zero and generic projectile prediction adds no value.
    -- Its XZ is already the exact landing XZ for its entire 0.5-second fall; treat it as
    -- the impact circle immediately. This also recovers if the script attached after the
    -- Artillery Mob Shot remote already fired.
    if name:find("artilleryrock", 1, true) then
        local hardEnd = clock() + CFG.VOLCANIC_ARTILLERY_MAX_LIFE
        addThreat({
            kind = "CIRCLE",
            source = "visual",
            label = "VOLCANIC: Artillery Lava Walker ROCK IMPACT",
            part = part,
            position = part.Position,
            radius = CFG.VOLCANIC_ARTILLERY_IMPACT_RADIUS,
            requiresPart = false,
            livePartUntilRemoved = true,
            postRemoveGrace = CFG.VOLCANIC_ARTILLERY_POST_REMOVE,
            hardEndAt = hardEnd,
            endAt = hardEnd,
            redodgeEligible = true,
            artilleryLavaWalker = true,
        })
        S.lastAction = "Artillery rock acquired -> landing XZ blocker"
        return
    end

    -- The Volcanic dump contains enemyProjectiles.explosiveMobShot1/2/3, but the
    -- client map event only shows the shooter's muzzle particle. Track every live
    -- part under those exact enemy-owned templates, using its real size and motion.
    if name:find("explosivemobshot", 1, true) then
        local hardEnd = clock() + CFG.GENERIC_CYLINDER_MAX_LIFE
        if velocity > 5 then
            S.projectileCount += 1
            addThreat({
                kind = "PROJECTILE",
                source = "visual",
                label = "VOLCANIC: Explosive Lava Walker SHOT",
                part = part,
                requiresPart = false,
                livePartUntilRemoved = true,
                postRemoveGrace = CFG.GENERIC_CYLINDER_POST_REMOVE,
                hardEndAt = hardEnd,
                radius = math.max(5, maxXZ * 0.55) + CFG.PROJECTILE_RADIUS_PAD,
                predictTime = CFG.PROJECTILE_PREDICT_TIME,
                endAt = hardEnd,
                redodgeEligible = true,
            })
        else
            addThreat({
                kind = "CIRCLE",
                source = "visual",
                label = "VOLCANIC: Explosive Lava Walker BLAST",
                part = part,
                position = part.Position,
                radius = math.max(5, maxXZ * 0.5) + CFG.GENERIC_CYLINDER_PAD,
                dynamicRadiusFromPart = true,
                dynamicRadiusPad = CFG.GENERIC_CYLINDER_PAD,
                requiresPart = false,
                livePartUntilRemoved = true,
                postRemoveGrace = CFG.GENERIC_CYLINDER_POST_REMOVE,
                hardEndAt = hardEnd,
                endAt = hardEnd,
                redodgeEligible = true,
            })
        end
        S.lastAction = "Explosive Lava Walker runtime attack acquired"
        return
    end

    -- Authoritative Temple Core runtime geometry from the dump:
    --   Model.hitBox  = 20 x 128.3 x 20  (real kill column)
    --   Model.precast = 20 x 1 x 20      (Water Square telegraph)
    --   Model.precast = 16 x 1 x 150     (Water Line telegraph/lane)
    -- These live under generic Workspace.Model containers, so generic ownership
    -- classification cannot identify them. Track the exact signatures directly.
    local isCorePart, coreKind = isTempleCoreRuntimeAttackPart(part)
    if isCorePart then
        local hardEnd = clock() + CFG.TEMPLE_CORE_LIVE_PART_MAX
        local isColumn = coreKind == "squareColumn"
        local isLaser = coreKind == "laserPrecast"
        if isColumn then
            updateTempleCoreSweepPrediction(part)
        end
        local id = addThreat({
            kind = "OBB",
            source = "visual",
            label = isColumn and "TEMPLE CORE: Water Square KILL COLUMN"
                 or (isLaser and "TEMPLE CORE: Live Water Line"
                 or "TEMPLE CORE: Live Water Square Precast"),
            part = part,
            cframe = part.CFrame,
            size = isColumn and Vector3.new(
                part.Size.X + CFG.TEMPLE_CORE_SWEEP_PREDICT_PAD * 2,
                part.Size.Y,
                part.Size.Z + CFG.TEMPLE_CORE_SWEEP_PREDICT_PAD * 2
            ) or part.Size,
            requiresPart = false, -- post-removal grace uses cached geometry
            livePartUntilRemoved = true,
            postRemoveGrace = CFG.TEMPLE_CORE_PART_REMOVE_GRACE,
            hardEndAt = hardEnd,
            endAt = hardEnd,
            redodgeEligible = true,
            repeatableSweep = not isLaser,
            boss = "Temple Core Generator",
            templeCoreSquare = not isLaser,
            templeCoreKillColumn = isColumn,
            templeCoreLaser = isLaser,
            visualizeFull3D = isColumn,
        })
        S.lastAction = isColumn
            and "Temple Core KILL COLUMN -> live XZ tracking"
            or (isLaser and "Temple Core live Water Line -> tracking"
            or "Temple Core square precast -> tracking")

        -- The dump shows the real 20x128.3x20 hitBox can touch the character only
        -- a few milliseconds after it is parented. If this exact new part already
        -- covers our current XZ, run the normal dodge state machine immediately
        -- rather than waiting for the next Heartbeat. commitDodge / performRedodge
        -- now redirect the velocity follower; they never position-teleport the root.
        local th = S.threats[id]
        if th and S.root and isInsideThreat(S.root.Position, th, CFG.SAFETY_MARGIN) then
            if not S.dodging then
                local base = currentMovementBase() or S.root.Position
                commitDodge(base, th.label or "Temple Core live hitbox", {th})
            elseif S.dodgeWorldGoal and isInsideThreat(S.dodgeWorldGoal, th, CFG.SAFETY_MARGIN) then
                performRedodge({th})
            end
        end
        return
    end

    if containsAny(name, {"projectile", "missile", "rocket", "orb", "shot", "shuriken", "rock", "bomb"}) or velocity > 8 then
        S.projectileCount += 1
        addThreat({
            kind = "PROJECTILE",
            source = "visual",
            label = "PROJECTILE: " .. part.Name,
            part = part,
            requiresPart = true,
            keepWhilePart = true, -- informational only; endAt is still authoritative
            radius = math.max(3.5, maxXZ * 0.55) + CFG.PROJECTILE_RADIUS_PAD,
            predictTime = CFG.PROJECTILE_PREDICT_TIME,
            endAt = clock() + CFG.VISUAL_DEFAULT_HOLD,
            redodgeEligible = true,
        })
    elseif containsAny(name, {"circle", "cylinder", "aura", "explosion", "blast", "geyser", "slam", "pulse"}) and math.abs(size.X - size.Z) < maxXZ * 0.55 then
        local hardEnd = clock() + math.max(CFG.VISUAL_DEFAULT_HOLD, CFG.GENERIC_CYLINDER_MAX_LIFE)
        addThreat({
            kind = "CIRCLE",
            source = "visual",
            label = "AOE: " .. part.Name,
            part = part,
            position = part.Position,
            requiresPart = false,
            livePartUntilRemoved = true,
            postRemoveGrace = CFG.GENERIC_CYLINDER_POST_REMOVE,
            hardEndAt = hardEnd,
            radius = math.max(4, maxXZ * 0.55),
            dynamicRadiusFromPart = true,
            dynamicRadiusPad = CFG.VISUAL_UNCERTAINTY_PAD,
            endAt = hardEnd,
            redodgeEligible = true,
        })
    else
        addThreat({
            kind = "OBB",
            source = "visual",
            label = "HITBOX: " .. part.Name,
            part = part,
            requiresPart = true,
            keepWhilePart = true, -- informational only; endAt is still authoritative
            endAt = clock() + CFG.VISUAL_DEFAULT_HOLD,
            redodgeEligible = true,
        })
    end
end

local function hookTransientVisuals()
    workspace.DescendantAdded:Connect(function(inst)
        if not S.enabled or not inst:IsA("BasePart") then return end

        -- Do not schedule a task for every decorative/map Part that streams in.
        -- Exact precasts are already handled by BridgeNet2, so the visual fallback
        -- only needs parts whose own/nearby names look attack-related.
        local p1 = inst.Parent
        local p2 = p1 and p1.Parent
        local p3 = p2 and p2.Parent
        local p4 = p3 and p3.Parent
        local quickName = lower(inst.Name .. " " .. (p1 and p1.Name or "") .. " " .. (p2 and p2.Name or "") .. " " .. (p3 and p3.Name or "") .. " " .. (p4 and p4.Name or ""))
        if isTempleGuardRuntimeHitBox(inst) then
            registerTempleGuardRuntimeHitBox(inst)
            return
        end

        local renderedCircle = isRenderedPrecastCircle(inst)
        if not renderedCircle and inst.ClassName == "Part" then
            task.defer(function()
                if inst.Parent and isRenderedPrecastCircle(inst) then
                    registerRenderedPrecastCircle(inst)
                end
            end)
        end
        -- Do not discard cylinders just because their runtime/template name is
        -- generic. registerVisualPart() will still ownership-gate them before they
        -- become threats, so player spell cylinders remain ignored.
        local cylinderCandidate = inst.ClassName == "Part" and inst.Shape == Enum.PartType.Cylinder
        local volcanicExplosiveCandidate = quickName:find("explosivemobshot", 1, true) ~= nil
        local volcanicArtilleryCandidate = quickName:find("artilleryrock", 1, true) ~= nil
        if not renderedCircle and not cylinderCandidate and not volcanicExplosiveCandidate and not volcanicArtilleryCandidate
            and not containsAny(quickName, VISUAL_DANGER_WORDS) then return end

        -- PrecastHitbox.Circle's anonymous renderer should be registered
        -- synchronously; waiting a deferred turn costs reaction time and the Part
        -- has no useful name for any other scanner to recover it.
        if renderedCircle then
            registerVisualPart(inst)
            return
        end

        local isCorePart = isTempleCoreRuntimeAttackPart(inst)
        if isCorePart then
            -- Do not defer the dump-confirmed Core kill geometry: its hitBox can
            -- begin touching the character within a few milliseconds of spawn.
            registerVisualPart(inst)
            return
        end

        task.defer(function()
            if inst.Parent then registerVisualPart(inst) end
        end)
    end)

    -- If the script was injected while an attack was already alive, DescendantAdded
    -- cannot see it retroactively. Do one recovery pass only; normal operation remains
    -- event-driven and the regular direct-Workspace circle scan stays cheap.
    task.defer(function()
        for _, inst in ipairs(workspace:GetDescendants()) do
            if inst:IsA("BasePart") then
                local n = visualNameOf(inst)
                if isRenderedPrecastCircle(inst)
                    or (inst.ClassName == "Part" and inst.Shape == Enum.PartType.Cylinder)
                    or n:find("explosivemobshot", 1, true)
                    or n:find("artilleryrock", 1, true)
                    or containsAny(n, VISUAL_DANGER_WORDS) then
                    registerVisualPart(inst)
                end
            end
        end
    end)
end

--// Melee animation detection
local function trackLooksLikeAttack(track)
    local pieces = {track.Name}
    local okAnim, anim = pcall(function() return track.Animation end)
    if okAnim and anim then table.insert(pieces, anim.Name) end
    local name = lower(table.concat(pieces, " "))

    if containsAny(name, NON_ATTACK_WORDS) then return false, false, name end
    local actionFallback = string.match(name, "action[1-4]") ~= nil
    local attack = actionFallback or containsAny(name, ATTACK_WORDS)
    local spin = containsAny(name, {"spin", "whirl", "cyclone", "360", "revolver", "circle", "aoe"})
    return attack, spin, name
end

local function estimateMeleeRange(model, root)
    local base = CFG.MELEE_DEFAULT_RANGE
    local ok, size = pcall(function() return model:GetExtentsSize() end)
    if ok then
        base += math.max(size.X, size.Z) * 0.28
    else
        base += math.max(root.Size.X, root.Size.Z) * 0.5
    end
    if looksLikeBoss(model, root) then
        base *= CFG.MELEE_BOSS_MULT
    end
    return base
end

local function registerMeleeTrack(model, root, track, spin, name)
    local existing = S.activeMeleeTracks[track]
    local remaining = CFG.MELEE_TRACK_MAX_HOLD
    pcall(function()
        if track.Length and track.Length > 0 then
            remaining = clamp(track.Length - track.TimePosition, 0.20, CFG.MELEE_TRACK_MAX_HOLD)
        end
    end)

    if existing and S.threats[existing] then
        S.threats[existing].endAt = clock() + remaining
        return
    end

    local range = estimateMeleeRange(model, root)
    local id = addThreat({
        kind = spin and "SPIN" or "CONE",
        source = "melee",
        label = spin and ("MELEE SPIN: " .. model.Name) or ("MELEE: " .. model.Name),
        root = root,
        requiresRoot = true,
        radius = spin and range * CFG.MELEE_SPIN_RANGE_MULT or nil,
        range = spin and nil or range,
        halfAngle = CFG.MELEE_CONE_HALF_ANGLE,
        track = track,
        endAt = clock() + remaining,
        redodgeEligible = true,
    })
    S.activeMeleeTracks[track] = id
    S.meleeCount += 1
end

local function scanMelee()
    local t = clock()
    if t - S.lastMeleeScan < CFG.MELEE_SCAN_INTERVAL then return end
    S.lastMeleeScan = t
    if not S.root then return end

    local enemies = (#S.enemyCache > 0) and S.enemyCache or getEnemyCandidates()
    local checked = 0
    for _, model in ipairs(enemies) do
        local root, hum = getModelParts(model)
        if root and hum and hum.Health > 0 then
            local meleeRange = estimateMeleeRange(model, root)
            local dist3D = (root.Position - S.root.Position).Magnitude

            -- Do not even inspect melee animations unless the mob can plausibly touch
            -- the player in 3D. This is especially important in overhead mode: a mob
            -- directly below us is NOT a dodge threat just because XZ distance is zero.
            if dist3D <= meleeRange + CFG.MELEE_RANGE_BUFFER then
                checked += 1
                local animator = hum:FindFirstChildOfClass("Animator")
                local tracks = {}
                if animator then
                    pcall(function() tracks = animator:GetPlayingAnimationTracks() end)
                else
                    pcall(function() tracks = hum:GetPlayingAnimationTracks() end)
                end

                for _, track in ipairs(tracks) do
                    local attack, spin, name = trackLooksLikeAttack(track)
                    if attack then
                        registerMeleeTrack(model, root, track, spin, name)
                    end
                end

                -- Conservative fallback, also true-3D only.
                local fallbackRange = meleeRange * 0.72
                if dist3D <= fallbackRange then
                    local vel = root.AssemblyLinearVelocity
                    local toward3D = S.root.Position - root.Position
                    local speed = vel.Magnitude
                    local towardUnit = toward3D.Magnitude > 1e-4 and toward3D.Unit or Vector3.zero
                    local movingToward = speed > 2 and vel.Unit:Dot(towardUnit) > 0.25
                    if movingToward then
                        local id = "proximity:" .. tostring(model)
                        S.threats[id] = {
                            id = id,
                            kind = "RADIAL",
                            source = "melee",
                            label = "MELEE PROXIMITY: " .. model.Name,
                            root = root,
                            requiresRoot = true,
                            radius = fallbackRange,
                            endAt = t + 0.20,
                            redodgeEligible = true,
                        }
                    end
                end

                if checked >= 8 then break end
            end
        end
    end
end

--// Native Q/E combat automation
-- Dungeon Quest's StarterGui/UIS.client.luau handles Q/E by:
--   1) locating the Backpack Tool whose abilitySlot.Value is "q" / "e"
--   2) tool.localEvent:Fire()
--   3) ReplicatedStorage.remotes.abilityUsed:FireServer(slot, tool)
-- The individual ability LocalScripts then fire their own actual spell RemoteEvent.
local function getAbilityUsedRemote()
    if S.abilityUsedRemote and S.abilityUsedRemote.Parent then
        return S.abilityUsedRemote
    end
    local remotes = ReplicatedStorage:FindFirstChild("remotes")
    local remote = remotes and remotes:FindFirstChild("abilityUsed")
    if remote and remote:IsA("RemoteEvent") then
        S.abilityUsedRemote = remote
        return remote
    end
    return nil
end

local function slotOf(tool)
    if not tool then return nil end
    local slot = tool:FindFirstChild("abilitySlot")
    if not slot then return nil end
    local ok, value = pcall(function() return string.lower(tostring(slot.Value)) end)
    return ok and value or nil
end

local function findAbilityTool(slotName)
    slotName = string.lower(slotName)

    -- Match the game's own input code: equipped abilities normally live in Backpack.
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if child:IsA("Tool") and slotOf(child) == slotName then
                return child
            end
        end
    end

    -- Fallback for the tiny window in which an ability Tool is parented to Character.
    if S.char then
        for _, child in ipairs(S.char:GetChildren()) do
            if child:IsA("Tool") and slotOf(child) == slotName then
                return child
            end
        end
    end
    return nil
end

local function cooldownOf(tool)
    if not tool then return math.huge end
    local cd = tool:FindFirstChild("cooldown")
    if not cd then return 0 end
    local ok, value = pcall(function() return tonumber(cd.Value) or 0 end)
    return ok and value or 0
end

local function cooldownLengthOf(tool)
    if not tool then return 0 end
    local cd = tool:FindFirstChild("cooldownLength")
    if not cd then return 0 end
    local ok, value = pcall(function() return tonumber(cd.Value) or 0 end)
    return ok and value or 0
end

local function isBusyCasting()
    if not S.char then return true end
    local busy = S.char:FindFirstChild("busyCasting")
    if not busy then return false end
    local ok, value = pcall(function() return busy.Value end)
    return ok and value == true
end

local function enemyBodyAimPoint(enemyRoot)
    if not enemyRoot or not enemyRoot.Parent then return nil end
    -- Aim around the center/upper-center of the mob instead of at its feet.
    local yOffset = math.max(0, enemyRoot.Size.Y * 0.20)
    return enemyRoot.Position + Vector3.new(0, yOffset, 0)
end

local function combatGroupAimPoint(origin)
    if not origin or not S.root or not S.root.Parent then return nil, 0 end

    local directionSum = Vector3.zero
    local distanceSum = 0
    local weightSum = 0
    local count = 0
    local seen = {}

    local function addEnemy(model)
        if not model or seen[model] or not isAliveEnemy(model) then return end
        seen[model] = true

        local enemyRoot = getModelParts(model)
        if not enemyRoot then return end

        -- Only average enemies in the current fight. Including alive mobs in later
        -- rooms would pull character aim between rooms and make directional skills miss.
        local xz = flatDistance(S.root.Position, enemyRoot.Position)
        if model ~= S.target and xz > CFG.CHARACTER_AIM_MAX_XZ_RANGE then return end

        local point = enemyBodyAimPoint(enemyRoot)
        if not point then return end
        local delta = point - origin
        if delta.Magnitude <= 0.05 then return end

        local weight = (model == S.target) and CFG.CHARACTER_AIM_TARGET_WEIGHT or 1.0
        directionSum += delta.Unit * weight
        distanceSum += delta.Magnitude * weight
        weightSum += weight
        count += 1
    end

    -- enemyCache is already refreshed by chooseTarget(); re-use it instead of doing
    -- another Workspace traversal every rendered frame.
    for _, model in ipairs(S.enemyCache or {}) do
        addEnemy(model)
    end
    addEnemy(S.target)

    local fallback = enemyBodyAimPoint(S.targetRoot)
    if count <= 0 or weightSum <= 0 or directionSum.Magnitude <= 0.05 then
        return fallback, fallback and 1 or 0
    end

    -- Average DIRECTION rather than world position. This centers character pitch/yaw
    -- across enemies without letting one farther-away mob pull the aim excessively.
    local meanDistance = math.max(8, distanceSum / weightSum)
    return origin + directionSum.Unit * meanDistance, count
end

local function targetAimPoint()
    if not S.root or not S.root.Parent then return nil end
    local point = combatGroupAimPoint(S.root.Position)
    return point
end

local function stableLookAt(origin, aim)
    local delta = aim - origin
    if delta.Magnitude <= 0.05 then return nil end

    local dir = delta.Unit
    local up = Vector3.new(0, 1, 0)
    if math.abs(dir:Dot(up)) > 0.96 then
        -- Directly-overhead combat makes world-up nearly parallel with the look
        -- vector. X-axis is a stable up hint and prevents random root roll.
        up = Vector3.new(1, 0, 0)
    end
    return CFrame.lookAt(origin, aim, up)
end

local function refreshCharacterAimState()
    if not CFG.CHARACTER_AIM_ENABLED or not S.enabled then
        S.characterAimCount = 0
        S.characterAimPoint = nil
        return nil, 0
    end
    if not S.root or not S.root.Parent or not S.targetRoot or not S.targetRoot.Parent then
        S.characterAimCount = 0
        S.characterAimPoint = nil
        return nil, 0
    end

    local aim, count = combatGroupAimPoint(S.root.Position)
    S.characterAimPoint = aim
    S.characterAimCount = count or 0
    return aim, count or 0
end

local function aimRootAtTarget(full3D)
    if not CFG.CHARACTER_AIM_ENABLED or not S.root or not S.root.Parent or not S.targetRoot or not S.targetRoot.Parent then
        return false
    end

    local here = S.root.Position
    local aim = refreshCharacterAimState()
    if not aim then return false end

    local delta = aim - here
    if delta.Magnitude <= 0.05 then
        return false
    end

    if full3D then
        local cf = stableLookAt(here, aim)
        if cf then S.root.CFrame = cf end
    else
        local f = flat(delta)
        if flatMagnitude(f) > 0.05 then
            local flatAim = here + flatUnit(f)
            S.root.CFrame = CFrame.lookAt(here, flatAim)
        end
    end
    S.root.AssemblyAngularVelocity = Vector3.zero
    return true
end

local function updateAlwaysFaceTarget()
    if not CFG.ALWAYS_FACE_TARGET or not S.enabled then return end
    if not S.root or not S.root.Parent or not S.targetRoot or not S.targetRoot.Parent then
        return
    end

    if S.hum and S.hum.Parent then
        S.hum.AutoRotate = false
    end

    -- Character-only orientation lock: preserve position and control only pitch/yaw.
    -- Camera CFrame/Focus are never touched. Full 3D aim is kept continuously so
    -- directional abilities inherit the same vertical + horizontal facing.
    aimRootAtTarget(true)
end

local function toolReady(tool, slotName)
    if not tool or not tool.Parent then return false, "missing" end
    -- No script-side cooldown/slot lock. The game's own cooldown.Value and
    -- busyCasting.Value are the only readiness gates.
    if cooldownOf(tool) > 0.001 then return false, "cooldown" end
    local localEvent = tool:FindFirstChild("localEvent")
    if not localEvent or not localEvent:IsA("BindableEvent") then
        return false, "no localEvent"
    end
    if isBusyCasting() then return false, "busyCasting" end
    return true, "ready"
end

local function canAttackTarget()
    if not CFG.COMBAT_ENABLED then return false, "combat off" end
    if not S.enabled then return false, "dodger off" end
    if not S.char or not S.hum or S.hum.Health <= 0 then return false, "dead/no char" end
    if not S.target or not isAliveEnemy(S.target) or not S.targetRoot then return false, "no target" end

    local peaceful = LocalPlayer:FindFirstChild("peaceful")
    if peaceful then
        local ok, value = pcall(function() return peaceful.Value end)
        if ok and value == true then return false, "peaceful" end
    end

    -- XZ is what matters for our overhead positioning. If a large precast forced a
    -- far lateral hold, preserve the dodge and wait instead of burning a cooldown.
    local xz = flatDistance(S.root.Position, S.targetRoot.Position)
    if xz > CFG.COMBAT_MAX_XZ_RANGE then
        return false, string.format("hold: range %.1f", xz)
    end

    return true, "target locked"
end

local updateCombat

local function fireAbility(slotName, tool)
    local remote = getAbilityUsedRemote()
    if not remote then
        S.combatStatus = "abilityUsed remote missing"
        return false
    end

    local localEvent = tool and tool:FindFirstChild("localEvent")
    if not localEvent or not localEvent:IsA("BindableEvent") then
        S.combatStatus = slotName .. ": localEvent missing"
        return false
    end

    -- Orientation-only look-down hold. This does NOT alter combat gating.
    local here = S.root and S.root.Position
    S.castVisualAimUntil = clock() + 0.24
    aimRootAtTarget(true)

    local okLocal = pcall(function()
        localEvent:Fire()
    end)
    local okRemote = pcall(function()
        remote:FireServer(slotName, tool)
    end)

    -- Keep the full 3D cast orientation active until castVisualAimUntil expires.
    if S.root and S.root.Parent and here then
        updateAlwaysFaceTarget()
        S.root.AssemblyAngularVelocity = Vector3.zero
    end

    if okLocal and okRemote then
        local now = clock()
        S.lastCastAt = now
        S.lastLocalCastAt = now
        S.lastLocalCastToolName = tool.Name
        S.lastCast = string.upper(slotName) .. " : " .. tool.Name
        S.combatStatus = "CAST " .. S.lastCast
        if slotName == "q" then
            S.qCasts += 1
        else
            S.eCasts += 1
        end
        S.lastAction = "cast " .. string.upper(slotName) .. " -> " .. S.target.Name

        -- No local cooldown timer is armed here. The next cast is driven only by
        -- the real cooldown.Value becoming ready and/or busyCasting becoming false.
        return true
    end

    S.combatStatus = string.format("%s fire failed L:%s R:%s", string.upper(slotName), tostring(okLocal), tostring(okRemote))
    return false
end

updateCombat = function(force)
    local t = clock()
    -- Normal Heartbeat calls are only a slow safety fallback. Relevant Roblox
    -- value changes (cooldown/busyCasting/tool changes) call this with force=true,
    -- so actual cooldown readiness is serviced on the next scheduler turn.
    if not force and not S.combatDirty and t - S.lastCombatScan < CFG.COMBAT_SCAN_INTERVAL then
        return
    end
    S.lastCombatScan = t
    S.combatDirty = false

    local qTool = findAbilityTool("q")
    local eTool = findAbilityTool("e")
    S.qTool, S.eTool = qTool, eTool
    S.qCooldown, S.eCooldown = cooldownOf(qTool), cooldownOf(eTool)

    local canAttack, why = canAttackTarget()
    if not canAttack then
        S.combatStatus = why
        return
    end

    if isBusyCasting() then
        S.combatStatus = "busyCasting"
        return
    end

    local qReady, qWhy = toolReady(qTool, "q")
    local eReady, eWhy = toolReady(eTool, "e")

    -- Q first whenever both become available. When Q is cooling down, immediately
    -- use E rather than idling; after busyCasting clears, the next ready skill wins.
    if CFG.COMBAT_Q_PRIORITY and qReady then
        local firedQ = fireAbility("q", qTool)
        -- If Q does not set busyCasting, use an already-ready E immediately in the
        -- same scheduler turn. No artificial delay and no slot timer.
        if firedQ and not isBusyCasting() then
            local eStillReady = toolReady(eTool, "e")
            if eStillReady then
                fireAbility("e", eTool)
            end
        end
        return
    end
    if eReady then
        fireAbility("e", eTool)
        return
    end
    if (not CFG.COMBAT_Q_PRIORITY) and qReady then
        fireAbility("q", qTool)
        return
    end

    if not qTool and not eTool then
        S.combatStatus = "Q/E tools missing"
    else
        S.combatStatus = string.format("Q:%s E:%s", qWhy or "?", eWhy or "?")
    end
end

--// Event-driven combat wakeups
local function disconnectCombatConnections()
    for _, conn in ipairs(S.combatConnections) do
        pcall(function() conn:Disconnect() end)
    end
    S.combatConnections = {}
    S.watchedQTool = nil
    S.watchedETool = nil
end

local function requestCombatCheck()
    S.combatDirty = true
    if S.combatKickScheduled then return end
    S.combatKickScheduled = true
    task.defer(function()
        S.combatKickScheduled = false
        if S.enabled and S.char and S.char.Parent and S.root and S.root.Parent then
            local ok, err = pcall(updateCombat, true)
            if not ok then
                S.combatStatus = "combat wake error: " .. tostring(err)
            end
        end
    end)
end

local function watchAbilityTool(tool, slotName)
    if not tool then return end

    local cooldown = tool:FindFirstChild("cooldown")
    if cooldown and cooldown:IsA("ValueBase") then
        table.insert(S.combatConnections, cooldown:GetPropertyChangedSignal("Value"):Connect(function()
            local ok, value = pcall(function() return tonumber(cooldown.Value) or 0 end)
            if not ok then return end

            -- Keep HUD telemetry current without waking the whole combat solver for
            -- every countdown tick. Only cooldown READY is latency-sensitive.
            if slotName == "q" then
                S.qCooldown = value
            else
                S.eCooldown = value
            end
            if value <= 0.001 then
                requestCombatCheck()
            end
        end))
    end

    table.insert(S.combatConnections, tool.AncestryChanged:Connect(function()
        requestCombatCheck()
    end))
end

local function setupCombatSignals()
    disconnectCombatConnections()

    local qTool = findAbilityTool("q")
    local eTool = findAbilityTool("e")
    S.watchedQTool, S.watchedETool = qTool, eTool
    watchAbilityTool(qTool, "q")
    watchAbilityTool(eTool, "e")

    local busy = S.char and S.char:FindFirstChild("busyCasting")
    if busy and busy:IsA("ValueBase") then
        table.insert(S.combatConnections, busy:GetPropertyChangedSignal("Value"):Connect(function()
            -- The instant a cast animation releases the global busy flag, try the
            -- other ready slot immediately.
            requestCombatCheck()
        end))
    end

    local peaceful = LocalPlayer:FindFirstChild("peaceful")
    if peaceful and peaceful:IsA("ValueBase") then
        table.insert(S.combatConnections, peaceful:GetPropertyChangedSignal("Value"):Connect(requestCombatCheck))
    end

    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:FindFirstChild("Backpack")
    if backpack then
        table.insert(S.combatConnections, backpack.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                task.defer(function()
                    setupCombatSignals()
                    requestCombatCheck()
                end)
            end
        end))
        table.insert(S.combatConnections, backpack.ChildRemoved:Connect(function(child)
            if child:IsA("Tool") then
                task.defer(function()
                    setupCombatSignals()
                    requestCombatCheck()
                end)
            end
        end))
    end

    if S.char then
        table.insert(S.combatConnections, S.char.ChildAdded:Connect(function(child)
            if child:IsA("Tool") or child.Name == "busyCasting" then
                task.defer(function()
                    setupCombatSignals()
                    requestCombatCheck()
                end)
            end
        end))
        table.insert(S.combatConnections, S.char.ChildRemoved:Connect(function(child)
            if child:IsA("Tool") or child.Name == "busyCasting" then
                task.defer(function()
                    setupCombatSignals()
                    requestCombatCheck()
                end)
            end
        end))
    end

    requestCombatCheck()
end

--// Solver hitbox visualizer
local function visualizerColor(th)
    if th.templeCorePredictedSweep then
        return Color3.fromRGB(255, 120, 40)
    end
    if th.templeCoreOrbPath then
        return Color3.fromRGB(185, 90, 255)
    end
    if th.templeCoreKillColumn then
        return Color3.fromRGB(255, 65, 65)
    end
    if th.templeGuardHitbox then
        return Color3.fromRGB(255, 0, 255)
    elseif th.templeCoreSquare then
        return Color3.fromRGB(75, 210, 255)
    end
    if th.source == "precast" then
        return Color3.fromRGB(255, 75, 75)
    end
    if th.kind == "PROJECTILE" then
        return Color3.fromRGB(255, 165, 55)
    end
    if th.source == "event" or th.source == "enemyEffects" then
        return Color3.fromRGB(85, 165, 255)
    end
    if th.source == "melee" then
        return Color3.fromRGB(255, 90, 190)
    end
    return Color3.fromRGB(255, 225, 75)
end

local function ensureVisualizerFolder()
    if S.visualizerFolder and S.visualizerFolder.Parent then
        return S.visualizerFolder
    end
    local folder = Instance.new("Folder")
    folder.Name = "__DQThreatVisualizer"
    folder.Parent = workspace
    S.visualizerFolder = folder
    return folder
end

local function clearThreatVisualizer()
    for id, part in pairs(S.visualizerParts) do
        if part and part.Parent then
            pcall(function() part:Destroy() end)
        end
        S.visualizerParts[id] = nil
    end
    S.visualizerDrawn = 0
end

local function getVisualizerPart(id)
    local part = S.visualizerParts[id]
    if part and part.Parent then return part end

    part = Instance.new("Part")
    part.Name = "DQViz"
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Transparency = CFG.HITBOX_VISUALIZER_TRANSPARENCY
    part.Size = Vector3.new(1, CFG.HITBOX_VISUALIZER_THICKNESS, 1)
    part.Parent = ensureVisualizerFolder()
    S.visualizerParts[id] = part
    return part
end

local function flatCFrameAt(cf, y)
    local pos = cf.Position
    local look = flatUnit(cf.LookVector, Vector3.new(0, 0, -1))
    local p = Vector3.new(pos.X, y, pos.Z)
    return CFrame.lookAt(p, p + look)
end

local function renderThreatVisualizer(id, th)
    local part = getVisualizerPart(id)
    local thickness = CFG.HITBOX_VISUALIZER_THICKNESS
    part.Color = visualizerColor(th)
    part.Transparency = CFG.HITBOX_VISUALIZER_TRANSPARENCY
    part.Shape = Enum.PartType.Block

    if th.kind == "CIRCLE" or th.kind == "RADIAL" or th.kind == "SPIN" then
        local center = getThreatPosition(th)
        local radius = math.max(0.5, tonumber(th.radius or th.range) or 1)
        part.Shape = Enum.PartType.Cylinder
        part.Size = Vector3.new(thickness, radius * 2, radius * 2)
        local vizY = center.Y + (th.source == "rendered-precast" and 0.55 or 0.22)
        part.CFrame = CFrame.new(center.X, vizY, center.Z) * CFrame.Angles(0, 0, math.rad(90))
        return
    end

    if th.kind == "CUBE" or th.kind == "OBB" then
        local cf = getThreatCFrame(th)
        local size = getThreatSize(th)
        if not cf or not size then
            part.Transparency = 1
            return
        end
        part.Shape = Enum.PartType.Block
        if th.visualizeFull3D then
            -- The actual Temple Core Water Square damage part is ~128 studs tall.
            -- Draw the real column so it is obvious why a 30-stud overhead hover dies.
            part.Size = Vector3.new(
                math.max(0.25, size.X),
                math.max(0.25, size.Y),
                math.max(0.25, size.Z)
            )
            part.CFrame = cf
            part.Transparency = math.min(0.82, CFG.HITBOX_VISUALIZER_TRANSPARENCY + 0.10)
        else
            part.Size = Vector3.new(math.max(0.25, size.X), thickness, math.max(0.25, size.Z))
            part.CFrame = flatCFrameAt(cf, cf.Position.Y + 0.22)
        end
        return
    end

    if th.kind == "PROJECTILE" then
        local center = getThreatPosition(th)
        local velocity = getThreatVelocity(th)
        local predict = tonumber(th.predictTime) or CFG.PROJECTILE_PREDICT_TIME
        local future = center + flat(velocity) * predict
        local radius = math.max(0.75, tonumber(th.triggerRadius or th.radius) or 4)
        local length = flatDistance(center, future)

        if length > 0.35 then
            local mid = Vector3.new((center.X + future.X) * 0.5, center.Y + 0.22, (center.Z + future.Z) * 0.5)
            local target = Vector3.new(future.X, mid.Y, future.Z)
            part.Shape = Enum.PartType.Block
            part.Size = Vector3.new(radius * 2, thickness, length + radius * 2)
            part.CFrame = CFrame.lookAt(mid, target)
        else
            part.Shape = Enum.PartType.Cylinder
            part.Size = Vector3.new(thickness, radius * 2, radius * 2)
            part.CFrame = CFrame.new(center.X, center.Y + 0.22, center.Z) * CFrame.Angles(0, 0, math.rad(90))
        end
        return
    end

    if th.kind == "CONE" then
        local center = getThreatPosition(th)
        local radius = math.max(1, tonumber(th.range or th.radius) or CFG.MELEE_DEFAULT_RANGE)
        -- Cheap conservative representation; actual dodge test still uses the cone.
        part.Shape = Enum.PartType.Cylinder
        part.Size = Vector3.new(thickness, radius * 2, radius * 2)
        part.CFrame = CFrame.new(center.X, center.Y + 0.22, center.Z) * CFrame.Angles(0, 0, math.rad(90))
        return
    end

    local center = getThreatPosition(th)
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(2, 2, 2)
    part.CFrame = CFrame.new(center)
end

local function updateThreatVisualizer(force)
    if not S.enabled or not S.visualizerEnabled then
        if S.visualizerDrawn > 0 then clearThreatVisualizer() end
        return
    end

    local now = clock()
    if not force and now - S.lastVisualizerUpdate < CFG.HITBOX_VISUALIZER_INTERVAL then return end
    S.lastVisualizerUpdate = now

    local seen = {}
    local drawn = 0
    for id, th in pairs(S.threats) do
        if drawn >= CFG.HITBOX_VISUALIZER_MAX_DRAW then break end
        seen[id] = true
        renderThreatVisualizer(id, th)
        drawn += 1
    end

    for id, part in pairs(S.visualizerParts) do
        if not seen[id] then
            if part and part.Parent then pcall(function() part:Destroy() end) end
            S.visualizerParts[id] = nil
        end
    end
    S.visualizerDrawn = drawn
end

--// Lightweight noclip
local function disconnectCharacterConnections()
    for _, conn in ipairs(S.charConnections) do
        pcall(function() conn:Disconnect() end)
    end
    S.charConnections = {}
    disconnectCombatConnections()
end

local function trackNoclipPart(part)
    if not part or not part:IsA("BasePart") then return end
    if S.noclipOriginal[part] == nil then
        S.noclipOriginal[part] = part.CanCollide
    end
    S.noclipParts[part] = true
    if S.enabled and CFG.NOCLIP and part.CanCollide then
        part.CanCollide = false
    end
end

rebuildNoclipCache = function()
    S.noclipParts = setmetatable({}, {__mode = "k"})
    S.noclipOriginal = setmetatable({}, {__mode = "k"})
    if not S.char then return end
    for _, inst in ipairs(S.char:GetDescendants()) do
        if inst:IsA("BasePart") then
            trackNoclipPart(inst)
        end
    end
end

local function updateNoclip(force)
    if not CFG.NOCLIP or not S.enabled or not S.char or not S.char.Parent then return end
    if S.walkModeActive then
        restoreNoclip()
        return
    end
    local t = clock()
    if not force and t - S.lastNoclipSweep < CFG.NOCLIP_SWEEP_INTERVAL then return end
    S.lastNoclipSweep = t

    -- Only write when Roblox/game code has turned collision back on. This keeps the
    -- noclip loop effectively idle most of the time instead of hammering properties.
    for part in pairs(S.noclipParts) do
        if not part or not part.Parent then
            S.noclipParts[part] = nil
            S.noclipOriginal[part] = nil
        elseif part.CanCollide then
            part.CanCollide = false
        end
    end
end

restoreNoclip = function()
    for part, original in pairs(S.noclipOriginal) do
        if part and part.Parent then
            pcall(function() part.CanCollide = original end)
        end
    end
end

--// Character management
local function bindCharacter(char)
    disconnectCharacterConnections()
    restoreNoclip()
    destroyHoverController()

    S.char = char
    S.hum = char:WaitForChild("Humanoid", 10)
    S.root = char:WaitForChild("HumanoidRootPart", 10)
    if S.hum then
        pcall(function() S.hum.WalkSpeed = CFG.FORCED_WALK_SPEED end)
    end
    S.target = nil
    S.targetRoot = nil
    S.targetHum = nil
    S.targetLossHandledFor = nil
    S.lastTargetLostAt = 0
    S.lastTargetPosition = nil
    S.targetGeometryTarget = nil
    S.targetGeometryAt = 0
    S.targetBoundsCFrame = nil
    S.targetBoundsSize = nil
    S.targetTopY = nil
    S.targetTopOffset = nil
    S.characterRootToBottom = nil
    S.walkModeActive = false
    S.walkGoal = nil
    S.walkLastMoveAt = 0
    S.walkSavedSpeed = nil
    resetDodgeEpisode()
    S.threats = {}
    S.activeMeleeTracks = setmetatable({}, {__mode = "k"})
    S.lastCombatScan = 0
    S.lastCastAt = 0
    S.aimHoldUntil = 0
    S.qTool, S.eTool = nil, nil
    S.qCooldown, S.eCooldown = 0, 0
    S.lastLocalCastAt = 0
    S.lastLocalCastToolName = ""
    S.castVisualAimUntil = 0
    S.characterAimCount = 0
    S.characterAimPoint = nil
    S.localVisualRoots = setmetatable({}, {__mode = "k"})
    S.localEffectQuarantine = {}
    S.precastDedupe = {}
    S.lavaKingCurseActiveUntil = 0
    S.lavaKingCurseVictim = nil
    S.lavaKingCurseResolvedAt = 0
    S.lavaKingSafeMode = false
    S.lavaKingSafeObject = nil
    S.lavaKingSafePart = nil
    S.lavaKingSafeGoal = nil
    S.lavaKingSafeRadius = 0
    S.lavaKingLastSafeScan = -math.huge
    S.lavaKingLastSafeTeleport = -math.huge
    S.lavaKingSafeEntries = 0
    if not S.replayScheduled then
        S.replayAttempts = 0
        S.replayStatus = "armed"
    end
    S.templeCoreSweepRows = {}
    S.templeCoreLastSquareAt = 0
    S.templeCoreLastOrbAt = 0
    S.combatStatus = "character bound"
    S.combatDirty = true
    clearThreatVisualizer()

    rebuildNoclipCache()
    table.insert(S.charConnections, char.DescendantAdded:Connect(function(inst)
        if inst:IsA("BasePart") then
            trackNoclipPart(inst)
        end
    end))
    if S.hum then
        table.insert(S.charConnections, S.hum:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if S.hum and S.hum.Parent and math.abs((tonumber(S.hum.WalkSpeed) or 0) - CFG.FORCED_WALK_SPEED) > 0.01 then
                pcall(function() S.hum.WalkSpeed = CFG.FORCED_WALK_SPEED end)
            end
        end))
    end
    updateNoclip(true)
    setupCombatSignals()

    -- Force immediate target recovery after respawn instead of waiting on stale timers.
    S.lastTargetScan = -math.huge
    S.lastDeepNpcScan = -math.huge
    S.lastAction = "character bound / dodge armed"
end

if LocalPlayer.Character then
    task.spawn(bindCharacter, LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(bindCharacter)

--// HUD
local function hudEscape(value)
    local s = tostring(value == nil and "" or value)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    return s
end

local function hudShort(value, maxChars)
    local s = tostring(value == nil and "" or value)
    maxChars = maxChars or 46
    if #s <= maxChars then return s end
    return string.sub(s, 1, math.max(1, maxChars - 3)) .. "..."
end

local HUD_COLORS = {
    text = "#DCE8EF",
    dim = "#81909B",
    cyan = "#67D9FF",
    green = "#6EF0A6",
    yellow = "#FFD66B",
    orange = "#FFAA5C",
    red = "#FF6B78",
    purple = "#C69CFF",
    white = "#F5FAFD",
}

local function hudColor(value, color)
    return string.format('<font color="%s">%s</font>', color or HUD_COLORS.text, hudEscape(value))
end

local function hudKV(label, value, color)
    return hudColor(string.format("%-11s", label) .. ": ", HUD_COLORS.dim) .. hudColor(value, color)
end

local function hudBoolColor(value)
    local s = string.upper(tostring(value or ""))
    if s == "ON" or s == "LOCK" or s == "READY" or s == "ARMED" or s == "SUCCESS" then
        return HUD_COLORS.green
    elseif s == "OFF" or s == "DISABLED" then
        return HUD_COLORS.dim
    end
    return HUD_COLORS.text
end

local function makeHud()
    if S.hud then pcall(function() S.hud:Destroy() end) end

    local gui = Instance.new("ScreenGui")
    gui.Name = "DQ_OverheadDodgerHUD"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local parented = false
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then
            gui.Parent = hui
            parented = true
        end
    end
    if not parented then
        local ok = pcall(function() gui.Parent = CoreGui end)
        if not ok then
            gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
    end

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Position = UDim2.fromOffset(14, 96)
    frame.Size = UDim2.fromOffset(500, 382)
    frame.BackgroundColor3 = Color3.fromRGB(9, 12, 16)
    frame.BackgroundTransparency = 0.16
    frame.BorderSizePixel = 0
    frame.ClipsDescendants = true
    frame.Parent = gui

    local scale = Instance.new("UIScale")
    scale.Name = "ResponsiveScale"
    scale.Scale = 1
    scale.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 1
    stroke.Transparency = 0.36
    stroke.Color = Color3.fromRGB(103, 217, 255)
    stroke.Parent = frame

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = frame

    local topBar = Instance.new("Frame")
    topBar.Name = "TopBar"
    topBar.BackgroundColor3 = Color3.fromRGB(14, 20, 27)
    topBar.BackgroundTransparency = 0.12
    topBar.BorderSizePixel = 0
    topBar.Size = UDim2.new(1, 0, 0, 28)
    topBar.Parent = frame

    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 0)
    title.Size = UDim2.new(1, -20, 1, 0)
    title.Font = Enum.Font.Code
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextYAlignment = Enum.TextYAlignment.Center
    title.RichText = true
    title.Text = '<font color="#67D9FF"><b>DQ OVERHEAD DODGER</b></font>  <font color="#81909B">[H] toggle  [V] hitboxes</font>'
    title.Parent = topBar

    local text = Instance.new("TextLabel")
    text.Name = "Telemetry"
    text.BackgroundTransparency = 1
    text.Position = UDim2.fromOffset(10, 34)
    text.Size = UDim2.new(1, -20, 1, -42)
    text.Font = Enum.Font.Code
    text.TextSize = 12
    text.LineHeight = 1.00
    text.TextXAlignment = Enum.TextXAlignment.Left
    text.TextYAlignment = Enum.TextYAlignment.Top
    text.TextColor3 = Color3.fromRGB(220, 232, 239)
    text.RichText = true
    text.TextWrapped = false
    text.TextTruncate = Enum.TextTruncate.None
    text.Text = hudColor("initializing...", HUD_COLORS.yellow)
    text.Parent = frame

    local function refreshHudScale()
        local camera = workspace.CurrentCamera
        if not camera then return end
        local vp = camera.ViewportSize
        -- Keep the entire panel on-screen. Normal desktop resolutions stay at 1:1;
        -- small windows scale the complete HUD instead of allowing text to escape it.
        local sx = math.max(0.1, (vp.X - 28) / 500)
        local sy = math.max(0.1, (vp.Y - 110) / 382)
        scale.Scale = math.min(1, sx, sy)
    end

    refreshHudScale()
    local camera = workspace.CurrentCamera
    if camera then
        pcall(function()
            camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshHudScale)
        end)
    end

    -- Minimal drag support.
    local dragging = false
    local dragStart, startPos
    frame.Active = true
    topBar.Active = true
    topBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)
    topBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    S.hud = gui
    S.hudText = text
    S.hudFrame = frame
    S.hudScale = scale
    gui.Enabled = CFG.HUD_VISIBLE
end

local function updateHud()
    if not S.hudText then return end

    local total, precasts, melee, projectiles, events = countThreatKinds()
    local targetName = S.target and S.target.Name or "none"
    local targetDist = (S.root and S.targetRoot) and flatDistance(S.root.Position, S.targetRoot.Position) or 0
    local state = not S.enabled and "DISABLED"
        or (S.lavaKingSafeMode and "LAVA KING SAFE ZONE")
        or (S.dodging and (S.walkModeActive and "FLOOR TP DODGING / HOLD" or "DODGING / HOLD"))
        or (S.targetRoot and (S.walkModeActive and "FLOOR TP" or "OVERHEAD") or "SEARCHING")

    local stateColor = HUD_COLORS.cyan
    if state == "DISABLED" then
        stateColor = HUD_COLORS.dim
    elseif S.lavaKingSafeMode then
        stateColor = HUD_COLORS.green
    elseif S.dodging then
        stateColor = HUD_COLORS.yellow
    elseif state == "SEARCHING" then
        stateColor = HUD_COLORS.purple
    end

    local hp = (S.hum and S.hum.Health) or 0
    local maxHp = (S.hum and S.hum.MaxHealth) or 0
    local hpRatio = maxHp > 0 and hp / maxHp or 0
    local hpColor = hpRatio <= 0.25 and HUD_COLORS.red
        or hpRatio <= 0.55 and HUD_COLORS.yellow
        or HUD_COLORS.green

    local threatColor = total > 0 and HUD_COLORS.red or HUD_COLORS.green
    local combatText = hudShort(S.combatStatus or "none", 50)
    local combatLower = string.lower(combatText)
    local combatColor = (combatLower:find("cast", 1, true) or combatLower:find("ready", 1, true) or combatLower:find("locked", 1, true)) and HUD_COLORS.green
        or (combatLower:find("cooldown", 1, true) or combatLower:find("busy", 1, true) or combatLower:find("hold", 1, true)) and HUD_COLORS.yellow
        or (combatLower:find("failed", 1, true) or combatLower:find("missing", 1, true) or combatLower:find("dead", 1, true)) and HUD_COLORS.red
        or HUD_COLORS.text

    local replayText = CFG.AUTO_REPLAY_ENABLED and (S.replayStatus or "armed") or "OFF"
    local replayLower = string.lower(replayText)
    local replayColor = replayLower:find("fail", 1, true) and HUD_COLORS.red
        or (replayLower:find("wait", 1, true) or replayLower:find("teleport", 1, true)) and HUD_COLORS.yellow
        or CFG.AUTO_REPLAY_ENABLED and HUD_COLORS.green
        or HUD_COLORS.dim

    local lavaActive = S.lavaKingSafeMode or ((S.lavaKingCurseActiveUntil or 0) > clock())
    local lavaText
    local lavaColor
    if S.lavaKingSafeMode then
        lavaText = string.format("HOLD GREEN ZONE  r=%.1f", S.lavaKingSafeRadius or 0)
        lavaColor = HUD_COLORS.green
    elseif lavaActive then
        lavaText = "CURSE ACTIVE / SEEKING SAFE ZONE"
        lavaColor = HUD_COLORS.red
    else
        lavaText = "idle"
        lavaColor = HUD_COLORS.dim
    end

    local aimText = (CFG.CHARACTER_AIM_ENABLED and S.enabled) and "LOCK" or "OFF"
    local aimColor = hudBoolColor(aimText)
    local noclipText = (CFG.NOCLIP and S.enabled and not S.walkModeActive) and "ON" or "OFF"
    local hitboxText = S.visualizerEnabled and "ON" or "OFF"
    local off = S.dodgeOffset or Vector3.zero
    local holdAge = (S.dodging and S.dodgeStartedAt > 0) and (clock() - S.dodgeStartedAt) or 0

    local lines = {
        hudKV("state", state, stateColor),
        hudKV("target", string.format("%s  XZ %.1f", hudShort(targetName, 34), targetDist), targetName == "none" and HUD_COLORS.dim or HUD_COLORS.white),
        hudKV("lava king", lavaText, lavaColor),
        hudKV("npcs", string.format("registry %d | valid %d", S.registryCount or 0, #(S.enemyCache or {})), HUD_COLORS.cyan),
        hudKV("height", string.format("+%.1f | goalY %.1f | top %.1f", S.walkModeActive and 0 or currentHoverHeight(), S.walkModeActive and (S.root and S.root.Position.Y or 0) or (currentHoverWorldY() or 0), S.targetTopY or 0), HUD_COLORS.cyan),
        hudKV("hp", string.format("%.0f / %.0f", hp, maxHp), hpColor),
        hudKV("noclip", noclipText, hudBoolColor(noclipText)),
        hudKV("precast", hudShort(S.precastHookMode or "unknown", 43), HUD_COLORS.cyan),
        hudKV("hitbox viz", string.format("%s | drawn %d", hitboxText, S.visualizerDrawn or 0), hudBoolColor(hitboxText)),
        hudKV("threats", string.format("%d | P:%d M:%d R:%d E:%d", total, precasts, melee, projectiles, events), threatColor),
        hudKV("ownFX skip", tostring(S.ignoredOwnVisuals or 0), HUD_COLORS.dim),
        hudKV("hold", string.format("%.2fs | off X%+.1f Z%+.1f", holdAge, off.X, off.Z), S.dodging and HUD_COLORS.yellow or HUD_COLORS.dim),
        hudKV("chain", string.format("blockers %d | redirects %d", S.dodgeBlockerCount or 0, S.dodgeChainTeleports or 0), S.dodging and HUD_COLORS.yellow or HUD_COLORS.dim),
        hudKV("reason", hudShort(S.dodgeReason or "none", 49), S.dodging and HUD_COLORS.yellow or HUD_COLORS.dim),
        hudKV("last threat", hudShort(S.lastThreatText or "none", 45), total > 0 and HUD_COLORS.red or HUD_COLORS.dim),
        hudKV("action", hudShort(S.lastAction or "none", 49), HUD_COLORS.white),
        hudKV("combat", combatText, combatColor),
        hudKV("aim", string.format("character %s | enemies %d", aimText, S.characterAimCount or 0), aimColor),
        hudKV("replay", hudShort(replayText, 46), replayColor),
        hudKV("Q / E cd", string.format("%.1f / %.1f | casts %d/%d", S.qCooldown or 0, S.eCooldown or 0, S.qCasts or 0, S.eCasts or 0), ((S.qCooldown or 0) <= 0.001 or (S.eCooldown or 0) <= 0.001) and HUD_COLORS.green or HUD_COLORS.yellow),
        hudKV("last cast", hudShort(S.lastCast or "none", 47), (S.lastCast and S.lastCast ~= "none") and HUD_COLORS.green or HUD_COLORS.dim),
        hudKV("dodges", string.format("%d | cap %.1f | rb %d", S.dodgeCount or 0, S.serverMoveCap or 0, S.serverCorrectionCount or 0), HUD_COLORS.cyan),
        hudKV("safety", "XZ-ONLY / Y never grants immunity", HUD_COLORS.orange),
    }

    S.hudText.Text = table.concat(lines, "\n")
end

makeHud()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == CFG.TOGGLE_KEY then
        S.enabled = not S.enabled
        S.lastAction = S.enabled and "enabled" or "disabled"
        if not S.enabled then
            resetDodgeEpisode()
            S.castAimUntil = 0
            S.castAimStartedAt = 0
            setTempleCoreWalkMode(false)
            if S.hum and S.hum.Parent then S.hum.AutoRotate = true end
            restoreNoclip()
            clearThreatVisualizer()
            if S.hoverVelocity then
                S.hoverVelocity.VectorVelocity = Vector3.zero
                S.hoverVelocity.Enabled = false
            end
        else
            -- H no longer provides any special recovery that normal runtime lacks.
            -- Enabling simply arms the exact same automatic state path.
            resetDodgeEpisode()
            S.lastTargetScan = -math.huge
            local follower = ensureHoverController()
            if follower then follower.Enabled = true end
            rebuildNoclipCache()
            updateNoclip(true)
            S.combatDirty = true
            requestCombatCheck()
            updateThreatVisualizer(true)
        end
    elseif input.KeyCode == CFG.HITBOX_VISUALIZER_KEY then
        S.visualizerEnabled = not S.visualizerEnabled
        S.lastAction = S.visualizerEnabled and "hitbox visualizer ON" or "hitbox visualizer OFF"
        if S.visualizerEnabled then
            updateThreatVisualizer(true)
        else
            clearThreatVisualizer()
        end
    end
end)

--// Native auto replay
-- IMPORTANT: this block is deliberately isolated from the dodge controller. It never
-- calls updateMovement(), commitDodge(), performRedodge(), addThreat(), or mutates dodge
-- state. This preserves the last known-good dodge behavior verbatim.
do
    local R = {
        complete = false,
        reward = false,
        sent = false,
        teleporting = false,
        attempts = 0,
        pm = nil,
    }

    pcall(function()
        local utility = ReplicatedStorage:FindFirstChild("Utility")
        local module = utility and utility:FindFirstChild("PlaceManager")
        if module then R.pm = require(module) end
    end)

    R.isOwner = function()
        if R.pm and type(R.pm.GetDungeonOwnerId) == "function" then
            local ok, id = pcall(function() return R.pm.GetDungeonOwnerId() end)
            if ok and id ~= nil then return tonumber(id) == LocalPlayer.UserId end
        end

        local ok, joinData = pcall(function() return LocalPlayer:GetJoinData() end)
        if ok and type(joinData) == "table" and type(joinData.TeleportData) == "table" then
            local td = joinData.TeleportData
            local owner = td.ownerId
            if owner == nil and type(td.dungeonStats) == "table" then
                owner = td.dungeonStats.ownerId
            end
            if owner ~= nil then return tonumber(owner) == LocalPlayer.UserId end
        end

        local dungeon = workspace:FindFirstChild("dungeon")
        if dungeon then
            local owner = dungeon:FindFirstChild("ownerId")
            if owner and owner:IsA("NumberValue") then return owner.Value == LocalPlayer.UserId end
            local bossRoom = dungeon:FindFirstChild("bossRoom")
            owner = bossRoom and bossRoom:FindFirstChild("ownerId")
            if owner and owner:IsA("NumberValue") then return owner.Value == LocalPlayer.UserId end
        end

        -- Solo fallback only; the native replay button is owner-only.
        return #Players:GetPlayers() <= 1
    end

    -- Exact data shape used by the decompiled ReplayDungeonButton.LocalScript.
    R.collect = function()
        local data = {}

        local dungeonName = workspace:FindFirstChild("dungeonName")
        if dungeonName and dungeonName:IsA("StringValue") then
            data.dungeonName = dungeonName.Value
        end

        local dungeonProgress = workspace:FindFirstChild("dungeonProgress")
        if dungeonProgress and dungeonProgress:IsA("StringValue") then
            data.dungeonProgress = dungeonProgress.Value
        end

        local dungeonStarted = workspace:FindFirstChild("dungeonStarted")
        if dungeonStarted and dungeonStarted:IsA("BoolValue") then
            data.dungeonStarted = dungeonStarted.Value
        end

        local hardcore = workspace:FindFirstChild("hardcore")
        if hardcore and hardcore:IsA("BoolValue") then
            data.hardcore = hardcore.Value
            data.isHardcore = hardcore.Value
        end

        local dungeon = workspace:FindFirstChild("dungeon")
        if dungeon then
            for _, child in ipairs(dungeon:GetChildren()) do
                if child:IsA("ValueBase") then
                    data[child.Name] = child.Value
                end
            end

            local bossRoom = dungeon:FindFirstChild("bossRoom")
            if bossRoom then
                for _, child in ipairs(bossRoom:GetChildren()) do
                    if child:IsA("ValueBase") then
                        data[child.Name] = child.Value
                    end
                end
            end
        end

        return data
    end

    R.finished = function()
        local dungeon = workspace:FindFirstChild("dungeon")
        local bossRoom = dungeon and dungeon:FindFirstChild("bossRoom")
        local finished = bossRoom and bossRoom:FindFirstChild("dungeonFinished")
        if finished and finished:IsA("BoolValue") and finished.Value == true then
            return true
        end

        -- Boss raids use dungeonProgress == bossKilled in the decompiled replay UI.
        local progress = workspace:FindFirstChild("dungeonProgress")
        return progress and progress:IsA("StringValue") and progress.Value == "bossKilled" or false
    end

    R.fire = function(source)
        if not CFG.AUTO_REPLAY_ENABLED or R.teleporting then return end
        if R.sent and R.attempts >= CFG.AUTO_REPLAY_MAX_RETRIES then return end
        if not R.reward then
            S.replayStatus = R.complete and "complete / waiting rewards" or "armed"
            return
        end
        if not (R.complete or R.finished()) then
            S.replayStatus = "rewards received / waiting completion"
            return
        end
        if not R.isOwner() then
            S.replayStatus = "native replay: not dungeon owner"
            return
        end

        local remotes = ReplicatedStorage:FindFirstChild("remotes")
        local replay = remotes and remotes:FindFirstChild("replayDungeon")
        if not replay or not replay:IsA("RemoteEvent") then
            S.replayStatus = "replayDungeon remote missing"
            return
        end

        local data = R.collect()
        if not data.dungeonName or tostring(data.dungeonName) == "" then
            S.replayStatus = "replay missing dungeonName"
            return
        end

        R.sent = true
        R.attempts += 1
        S.replayScheduled = true
        S.replayAttempts = R.attempts
        S.replayStatus = string.format("native replay sent %d/%d", R.attempts, CFG.AUTO_REPLAY_MAX_RETRIES)
        S.lastAction = "AUTO REPLAY -> " .. tostring(data.dungeonName)

        local ok, err = pcall(function()
            replay:FireServer(data)
        end)
        if not ok then
            R.sent = false
            S.replayStatus = "replay fire failed"
            S.lastAction = "AUTO REPLAY error: " .. tostring(err)
            return
        end

        -- Native button only fires once. This watchdog is intentionally conservative:
        -- retry only if no teleport has started and we are still in the finished run.
        if R.attempts < CFG.AUTO_REPLAY_MAX_RETRIES then
            task.delay(CFG.AUTO_REPLAY_RETRY_DELAY, function()
                if not R.teleporting and R.finished() then
                    R.sent = false
                    R.fire("watchdog")
                end
            end)
        end
    end

    R.maybe = function(source)
        if not CFG.AUTO_REPLAY_ENABLED or R.teleporting then return end
        if R.reward and (R.complete or R.finished()) and not R.sent then
            S.replayStatus = "rewards confirmed -> replay NOW"
            -- Let the game's own cloneRewardGui listener receive the same event turn,
            -- then replay on the next frame. Items are already server-granted at this point.
            task.defer(function()
                RunService.Heartbeat:Wait()
                R.fire(source or "complete+reward")
            end)
        elseif R.complete and not R.reward then
            S.replayStatus = "complete / waiting rewards"
        end
    end

    R.markComplete = function(source)
        R.complete = true
        S.replayStatus = R.reward and "complete + rewards" or "complete / waiting rewards"
        R.maybe(source)
    end

    R.markReward = function(payload)
        R.reward = true
        local count = 0
        if type(payload) == "table" and type(payload.items) == "table" then
            count = #payload.items
        end
        S.replayStatus = string.format("rewards received (%d items)", count)
        R.maybe("cloneRewardGui")
    end

    R.hookFinished = function(value)
        if not value or not value:IsA("ValueBase") then return end
        value.Changed:Connect(function()
            if R.finished() then R.markComplete("finished value") end
        end)
        if R.finished() then R.markComplete("existing finished value") end
    end

    R.hook = function()
        if not CFG.AUTO_REPLAY_ENABLED then
            S.replayStatus = "OFF"
            return true
        end
        if R.hooked then return true end

        local remotes = ReplicatedStorage:FindFirstChild("remotes")
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not remotes or not pg then
            S.replayStatus = "boot: waiting for game UI/remotes"
            return false
        end

        R.hooked = true
        R.remoteHooks = {}
        S.replayStatus = "armed / native replayDungeon"

        R.connectRemote = function(remote)
            if not remote or not remote:IsA("RemoteEvent") or R.remoteHooks[remote] then return end
            if remote.Name == "loadCompleteGui" then
                R.remoteHooks[remote] = remote.OnClientEvent:Connect(function()
                    R.markComplete("loadCompleteGui")
                end)
            elseif remote.Name == "cloneRewardGui" then
                R.remoteHooks[remote] = remote.OnClientEvent:Connect(function(payload)
                    R.markReward(payload)
                end)
            end
        end

        R.connectRemote(remotes:FindFirstChild("loadCompleteGui"))
        R.connectRemote(remotes:FindFirstChild("cloneRewardGui"))
        remotes.ChildAdded:Connect(function(child)
            R.connectRemote(child)
        end)

        pg.ChildAdded:Connect(function(child)
            if lower(child.Name) == "completegui" then
                R.markComplete("completeGui")
            end
        end)
        if pg:FindFirstChild("completeGui") then
            R.markComplete("existing completeGui")
        end

        R.hookedFinishedValues = setmetatable({}, {__mode = "k"})
        R.tryHookFinished = function(value)
            if not value or not value:IsA("ValueBase") or R.hookedFinishedValues[value] then return end
            R.hookedFinishedValues[value] = true
            R.hookFinished(value)
        end

        R.tryHookFinished(workspace:FindFirstChild("dungeonProgress"))
        workspace.ChildAdded:Connect(function(child)
            if child.Name == "dungeonProgress" then R.tryHookFinished(child) end
        end)

        task.spawn(function()
            while not R.teleporting do
                local dungeon = workspace:FindFirstChild("dungeon")
                local bossRoom = dungeon and dungeon:FindFirstChild("bossRoom")
                local finished = bossRoom and bossRoom:FindFirstChild("dungeonFinished")
                if finished then
                    R.tryHookFinished(finished)
                    break
                end
                task.wait(0.5)
            end
        end)

        pcall(function()
            LocalPlayer.OnTeleport:Connect(function(state)
                local n = tostring(state)
                if n:find("Started", 1, true)
                    or n:find("InProgress", 1, true)
                    or n:find("WaitingForServer", 1, true) then
                    R.teleporting = true
                    S.replayStatus = "native replay teleport started"
                end
            end)
        end)

        TeleportService.TeleportInitFailed:Connect(function(player)
            if player ~= LocalPlayer or R.teleporting or not R.sent then return end
            if R.attempts < CFG.AUTO_REPLAY_MAX_RETRIES then
                R.sent = false
                S.replayStatus = "teleport failed -> replay retry"
                task.delay(CFG.AUTO_REPLAY_RETRY_DELAY, function() R.fire("TeleportInitFailed") end)
            else
                S.replayStatus = "native replay failed"
            end
        end)
        return true
    end

    -- Auto-executors can run before ReplicatedStorage/PlayerGui finish replicating.
    -- Retry installation until the real game objects exist instead of permanently
    -- missing the reward/completion remotes on an early injection.
    task.spawn(function()
        while not R.hook() do
            task.wait(0.20)
        end
    end)
end

--// Auto start / auto ready -- boot-safe version
-- Decompiled behavior:
--   readyButton -> remotes.readyUp while dungeonProgress == "playersNotReady"
--   startButton -> remotes.changeStartValue after workspace.start + Utility exist
--   accepted Start -> loadCountdownGui removes startButton.
-- Do NOT one-shot these calls: early injection can reach the client before replication
-- is complete, and a successful FireServer() call does not prove the server accepted it.
do
    local A = {
        remotes = nil,
        pg = nil,
        pm = nil,
        installed = false,
        sawStartPrompt = false,
        sawReadyPrompt = false,
        countdownSeen = false,
        lastReadyAt = -math.huge,
        lastStartAt = -math.huge,
        readyAttempts = 0,
        startAttempts = 0,
        status = "booting",
    }

    A.refresh = function()
        A.remotes = ReplicatedStorage:FindFirstChild("remotes")
        A.pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if not A.pm then
            local utility = ReplicatedStorage:FindFirstChild("Utility")
            local module = utility and utility:FindFirstChild("PlaceManager")
            if module then
                pcall(function() A.pm = require(module) end)
            end
        end
        return A.remotes ~= nil and A.pg ~= nil
    end

    A.progress = function()
        local v = workspace:FindFirstChild("dungeonProgress")
        return v and tostring(v.Value) or nil
    end

    A.started = function()
        if A.countdownSeen then return true end
        local startValue = workspace:FindFirstChild("start")
        if startValue and startValue:IsA("BoolValue") and startValue.Value == true then return true end
        local dungeonStarted = workspace:FindFirstChild("dungeonStarted")
        if dungeonStarted and dungeonStarted:IsA("BoolValue") and dungeonStarted.Value == true then return true end
        local p = A.progress()
        return p == "inProgress" or p == "bossKilled"
    end

    A.isOwner = function()
        if A.pm and type(A.pm.GetDungeonOwnerId) == "function" then
            local ok, id = pcall(function() return A.pm.GetDungeonOwnerId() end)
            if ok and tonumber(id) then return tonumber(id) == LocalPlayer.UserId end
        end
        -- The server sends showStartButton only to a client allowed to press Start,
        -- so an existing/past Start prompt is also authoritative owner evidence.
        return A.sawStartPrompt or (A.pg and A.pg:FindFirstChild("startButton") ~= nil)
    end

    A.allReady = function()
        local players = Players:GetPlayers()
        if #players == 0 then return false end
        for _, player in ipairs(players) do
            local ready = player:FindFirstChild("ready")
            if not ready or not ready:IsA("BoolValue") or ready.Value ~= true then
                return false
            end
        end
        return true
    end

    A.tryReady = function(source)
        if not CFG.AUTO_START_ENABLED or A.started() then return false end
        if A.progress() ~= "playersNotReady" then return false end
        local readyValue = LocalPlayer:FindFirstChild("ready")
        if readyValue and readyValue:IsA("BoolValue") and readyValue.Value == true then
            A.status = "ready confirmed"
            return true
        end
        local now = clock()
        if now - A.lastReadyAt < 0.85 then return false end
        local remote = A.remotes and A.remotes:FindFirstChild("readyUp")
        if not remote or not remote:IsA("RemoteEvent") then
            A.status = "waiting readyUp"
            return false
        end
        A.lastReadyAt = now
        A.readyAttempts += 1
        local ok = pcall(function() remote:FireServer() end)
        A.status = ok and "ready sent / awaiting confirm" or "ready send failed"
        S.lastAction = "AUTO READY -> readyUp (" .. tostring(source or "supervisor") .. ")"
        return ok
    end

    A.tryStart = function(source)
        if not CFG.AUTO_START_ENABLED or A.started() then return false end
        if not A.isOwner() then return false end

        -- Prefer the exact server-created Start prompt. If we somehow missed that event
        -- because the executor injected too early, owner + all-ready is the fallback.
        local promptPresent = A.pg and A.pg:FindFirstChild("startButton") ~= nil
        if not promptPresent and not A.sawStartPrompt and not A.allReady() then return false end

        local startValue = workspace:FindFirstChild("start")
        local utility = ReplicatedStorage:FindFirstChild("Utility")
        if not startValue or not startValue:IsA("BoolValue") or not utility then
            A.status = "waiting start state"
            return false
        end

        local now = clock()
        -- Give the server plenty of time to replicate start/countdown before retrying;
        -- this avoids a second call racing an accepted first call.
        if now - A.lastStartAt < 1.75 then return false end
        local remote = A.remotes and A.remotes:FindFirstChild("changeStartValue")
        if not remote or not remote:IsA("RemoteEvent") then
            A.status = "waiting changeStartValue"
            return false
        end

        A.lastStartAt = now
        A.startAttempts += 1
        local ok = pcall(function() remote:FireServer() end)
        A.status = ok and "start sent / awaiting countdown" or "start send failed"
        S.lastAction = "AUTO START -> changeStartValue (" .. tostring(source or "supervisor") .. ")"
        return ok
    end

    A.install = function()
        if A.installed then return true end
        if not A.refresh() then
            A.status = "waiting game replication"
            return false
        end
        A.installed = true

        A.connectRemote = function(remote)
            if not remote or not remote:IsA("RemoteEvent") then return end
            if remote.Name == "showReadyGui" then
                remote.OnClientEvent:Connect(function()
                    A.sawReadyPrompt = true
                    task.defer(function() A.tryReady("showReadyGui") end)
                end)
            elseif remote.Name == "showStartButton" then
                remote.OnClientEvent:Connect(function()
                    A.sawStartPrompt = true
                    task.defer(function() A.tryStart("showStartButton") end)
                end)
            elseif remote.Name == "loadCountdownGui" then
                remote.OnClientEvent:Connect(function()
                    A.countdownSeen = true
                    A.status = "countdown / started"
                    S.lastAction = "AUTO START confirmed -> countdown"
                end)
            end
        end

        A.connectRemote(A.remotes:FindFirstChild("showReadyGui"))
        A.connectRemote(A.remotes:FindFirstChild("showStartButton"))
        A.connectRemote(A.remotes:FindFirstChild("loadCountdownGui"))
        A.remotes.ChildAdded:Connect(function(child)
            A.connectRemote(child)
        end)

        A.pg.ChildAdded:Connect(function(child)
            local n = lower(child.Name)
            if n == "readybutton" then
                A.sawReadyPrompt = true
                task.defer(function() A.tryReady("readyButton") end)
            elseif n == "startbutton" then
                A.sawStartPrompt = true
                task.defer(function() A.tryStart("startButton") end)
            elseif n == "countdowngui" then
                A.countdownSeen = true
                A.status = "countdown / started"
            end
        end)

        if A.pg:FindFirstChild("readyButton") then A.sawReadyPrompt = true end
        if A.pg:FindFirstChild("startButton") then A.sawStartPrompt = true end
        if A.pg:FindFirstChild("countDownGui") or A.pg:FindFirstChild("countdownGui") then
            A.countdownSeen = true
        end
        return true
    end

    task.spawn(function()
        -- Installation retry handles scripts auto-executed before remotes/PlayerGui exist.
        while CFG.AUTO_START_ENABLED and not A.install() do
            task.wait(0.20)
        end
        if not CFG.AUTO_START_ENABLED then return end

        -- Low-frequency supervisor runs only during the pre-start phase. It catches
        -- missed UI events and confirms server state before considering a call done.
        while not A.started() do
            A.refresh()
            A.tryReady("state supervisor")
            A.tryStart("state supervisor")
            task.wait(0.25)
        end
        A.status = "started"
    end)
end

--// Boot-safe hooks
-- Auto-execution can occur before Utility/remotes/BridgeNet2 are replicated. The old
-- one-shot hook calls would silently give up forever in that case, which also made
-- dodging appear randomly broken on some teleports.
do
    local B = {installed = false}
    task.spawn(function()
        while not B.installed do
            local remotes = ReplicatedStorage:FindFirstChild("remotes")
            local utility = ReplicatedStorage:FindFirstChild("Utility")
            local bridge = utility and utility:FindFirstChild("BridgeNet2")
            local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if remotes and utility and bridge and pg then
                -- Let the rest of the replicated children settle for one scheduler beat.
                task.wait(0.20)
                hookPrecasts()
                hookMapEvents()
                hookLocalAbilityVisualEvents()
                hookTransientVisuals()
                B.installed = true
                task.defer(function()
                    scanRenderedPrecastCircles(true)
                end)
            else
                S.lastAction = "BOOT WAIT -> remotes / Utility / BridgeNet2 / PlayerGui"
                task.wait(0.20)
            end
        end
    end)
end

--// Character orientation aim
-- Character pitch/yaw is updated from the main Heartbeat after movement.
-- No RenderStep camera override is installed; CurrentCamera is left entirely alone.

--// Main loop
local hudAccum = 0
RunService.Heartbeat:Connect(function(dt)
    if not S.char or not S.char.Parent or not S.root or not S.root.Parent then
        return
    end

    -- Enemy death is NOT permission to clear the attack table. Handle target loss
    -- once, extend already-known non-melee attack geometry for late server damage,
    -- and let updateMovement remain active in targetless/world-space mode.
    local hadTarget = S.target ~= nil
    local targetInvalid = hadTarget and ((not isAliveEnemy(S.target)) or (not S.targetRoot) or (not S.targetRoot.Parent))
    if targetInvalid and S.targetLossHandledFor ~= S.target then
        if S.targetRoot and S.targetRoot.Parent then
            S.lastTargetPosition = S.targetRoot.Position
        end
        S.targetLossHandledFor = S.target
        if S.dodging then
            S.dodgeUsesWorldSpace = true
        end
        preserveThreatsAfterTargetLoss(clock())
        S.lastTargetScan = -math.huge
    end
    local previousCombatTarget = S.target
    chooseTarget(false)
    if S.target ~= previousCombatTarget then
        requestCombatCheck()
    end
    if S.enabled then
        pcall(updateNoclip, false)
        pcall(scanRenderedPrecastCircles, false)
        pcall(scanMelee)

        local okMove, moveErr = pcall(updateMovement)
        if not okMove then
            S.lastAction = "movement error (combat isolated): " .. tostring(moveErr)
        end

        local okFace, faceErr = pcall(updateAlwaysFaceTarget)
        if not okFace then
            S.lastAction = "facing error: " .. tostring(faceErr)
        end

        -- Combat is deliberately isolated from movement/dodge errors.
        local okCombat, combatErr = pcall(updateCombat)
        if not okCombat then
            S.combatStatus = "combat error: " .. tostring(combatErr)
        end

        pcall(updateThreatVisualizer, false)
    else
        pruneThreats()
        clearThreatVisualizer()
        S.combatStatus = "disabled"
    end

    hudAccum += dt
    if hudAccum >= 0.15 then
        hudAccum = 0
        updateHud()
    end
end)

S.lastAction = "ready"
print("[DQ Adaptive Chain Dodger] loaded - boot-safe + native replay + server-speed adaptive overhead dodging (no positional TP).")
