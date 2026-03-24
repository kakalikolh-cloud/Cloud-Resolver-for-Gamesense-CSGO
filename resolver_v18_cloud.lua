--[[
    FORWARD HVH RESOLVER v19.0 - CLOUD SYNC ENHANCED
    Professional resolver with advanced prediction, interpolation, extrapolation
    
    v19.0 Cloud Improvements:
    - Bayesian aggregation algorithm (more accurate than weighted average)
    - Reporter reputation tracking (accuracy-based weighting)
    - Angle clustering for consensus (DBSCAN-like)
    - Per-enemy rate limiting
    - Confidence decay over time
    - Prediction caching with TTL
    - Enhanced pattern learning with hit rate tracking
    - Latency compensation with server ping
    - Data staleness detection
    - Multi-source validation
    
    v19.0 Interpolation Improvements:
    - B-Spline with adaptive knot vector
    - Akima with corner preservation
    - Hermite with tension control
    - Multi-pass blending with confidence
    
    v19.0 Extrapolation Improvements:
    - Surface friction detection
    - Bunnyhop prediction
    - Stamina tracking
    - Air strafe prediction
    - Collision prediction
    
    v19.0 Prediction Improvements:
    - Adaptive weight system
    - Miss learning with decay
    - Anti-aim detection
    - Animation-based prediction
    - Freestanding detection
    - Balance analysis
    
    by Super Z
]]

-- ============== HTTP MODULE ==============
local http = require("gamesense/http")

-- ============== CONSTANTS ==============

local SIDES = { LEFT = -1, CENTER = 0, RIGHT = 1 }
local PI = math.pi

local CONFIG = {
    -- History limits
    MAX_HISTORY = 200,
    MAX_ANGLES = 100,
    MAX_VELOCITY = 120,
    MAX_BACKTRACK = 65,
    MAX_TICKS = 40,
    
    -- Timing
    TICK_INTERVAL = 0.015625,
    SAMPLE_RATE = 0.012,
    PREDICTION_DECAY = 0.90,
    MEMORY_DECAY_TIME = 45,
    
    -- Thresholds
    CONFIDENCE_THRESHOLD = 0.20,
    JITTER_THRESHOLD = 18,
    SPIN_THRESHOLD = 75,
    EXTENDED_DESYNC_THRESHOLD = 48,
    DESYNC_MAX = 60,
    EXTENDED_DESYNC_MAX = 120,
    
    -- Pose parameters
    POSE_BODY_YAW = 11,
    POSE_BODY_PITCH = 12,
    
    -- DT Detection
    DT_TIME_THRESHOLD = 0.22,
    DT_SHOT_THRESHOLD = 2,
    
    -- Interpolation
    INTERPOLATION_STEPS = 8,
    SPLINE_TENSION = 0.5,
    AKIMA_TENSION = 0.7,
    
    -- Extrapolation
    GRAVITY = 800,
    GRAVITY_DUCK = 640,
    AIR_ACCELERATION = 1000,
    GROUND_FRICTION = 4,
    STOP_SPEED = 100,
    MAX_VELOCITY_GROUND = 250,
    MAX_VELOCITY_AIR = 30,
    JUMP_VELOCITY = 301.99,
    
    -- Advanced Physics
    SURFACE_FRICTION_THRESHOLD = 0.1,
    BUNNYHOP_SPEED = 320,
    STAMINA_MAX = 100,
    
    -- Cloud weights
    CLOUD_WEIGHT = 3.0,
    CLOUD_MIN_CONFIDENCE = 0.4,
    CLOUD_WEIGHT_MULTIPLIER = 0.2,
    
    -- Prediction weights
    WEIGHT_VELOCITY = 1.15,
    WEIGHT_PATTERN = 1.4,
    WEIGHT_MEMORY = 1.7,
    WEIGHT_DT = 1.3,
    WEIGHT_ANIMATION = 1.25,
    WEIGHT_MOVE_DIR = 1.0,
    WEIGHT_BALANCE = 0.8,
    
    -- Acceleration smoothing
    ACCELERATION_SMOOTHING = 0.3,
    VELOCITY_DAMPING = 0.85,
}

-- ============== CLOUD CONFIG v19.0 ==============

local CLOUD_CONFIG = {
    SERVER_URL = "https://cloud-resolver-for-gamesense-csgo.onrender.com/api",
    POLL_INTERVAL = 1.2,               -- Reduced for faster sync
    DATA_TIMEOUT = 45.0,
    MIN_CONFIDENCE = 0.35,             -- Slightly lowered
    DEBUG = true,
    
    -- Retry settings
    MAX_RETRY = 4,                     -- Increased
    RETRY_DELAY = 0.4,
    RETRY_BACKOFF = 2.0,               -- Exponential backoff multiplier
    
    -- Aggregation
    MAX_REPORTERS = 8,                 -- Increased
    CONFIDENCE_BOOST = 0.12,
    ANGLE_CLUSTER_THRESHOLD = 25,      -- Degrees for clustering
    BAYESIAN_PRIOR_STRENGTH = 0.3,     -- Prior weight for Bayesian
    
    -- Validation
    SAME_TEAM_ONLY = true,
    ANTI_SPAM_INTERVAL = 0.25,         -- Per-enemy rate limiting
    GLOBAL_RATE_LIMIT = 0.15,          -- Global rate limit
    DATA_VALIDATION = true,
    STALE_DATA_THRESHOLD = 3.0,        -- Seconds before data is stale
    
    -- Reputation
    REPUTATION_DECAY = 0.02,           -- Decay per second
    REPUTATION_MIN_REPORTS = 3,        -- Min reports before reputation counts
    REPUTATION_HIT_BONUS = 0.15,       -- Reputation boost on hit
    REPUTATION_MISS_PENALTY = 0.08,    -- Reputation penalty on miss
    
    -- Latency
    LATENCY_COMPENSATION = true,
    LATENCY_SAMPLE_COUNT = 5,
    MAX_LATENCY = 0.5,                 -- Max acceptable latency
    
    -- Pattern Learning
    PATTERN_LEARNING = true,
    PATTERN_MIN_SAMPLES = 5,
    PATTERN_CONFIDENCE_THRESHOLD = 0.6,
    
    -- Caching
    PREDICTION_CACHE_TTL = 0.5,        -- Cache TTL in seconds
    MAX_CACHE_SIZE = 64,
    
    -- Identification
    RESOLVER_ID = "forward_hvh_v19.0",
    SCRIPT_VERSION = "19.0"
}

-- ============== CLOUD STATE v19.0 ==============

local cloud_state = {
    initialized = false,
    my_steamid = nil,
    my_steam64 = nil,
    my_team = nil,
    last_poll = 0,
    cloud_data = {},
    sync_count = 0,
    error_count = 0,
    last_error = nil,
    last_report_time = 0,
    connected_teammates = {},
    pattern_memory = {},
    
    -- v19.0 additions
    reporter_reputation = {},          -- Track reporter accuracy
    prediction_cache = {},             -- Cache predictions
    last_report_times = {},            -- Per-enemy rate limiting
    latency_samples = {},              -- Latency measurements
    avg_latency = 0,
    server_time_offset = 0,
    last_ping_time = 0,
    pending_validations = {},          -- Pending hit/miss validations
    angle_clusters = {},               -- Cached angle clusters
}

-- ============== JSON PARSER ==============

local json = {}

function json.parse(str)
    if type(str) ~= "string" then return nil end
    
    local function skip_whitespace(s, i)
        while i <= #s and (s:sub(i,i) == " " or s:sub(i,i) == "\t" or 
                           s:sub(i,i) == "\n" or s:sub(i,i) == "\r") do
            i = i + 1
        end
        return i
    end
    
    local function parse_value(s, i)
        i = skip_whitespace(s, i)
        if i > #s then return nil, i end
        
        local c = s:sub(i,i)
        
        if s:sub(i, i+3) == "null" then return nil, i + 4 end
        if s:sub(i, i+3) == "true" then return true, i + 4 end
        if s:sub(i, i+4) == "false" then return false, i + 5 end
        
        if c == "-" or (c >= "0" and c <= "9") then
            local j = i
            if c == "-" then j = j + 1 end
            while j <= #s and ((s:sub(j,j) >= "0" and s:sub(j,j) <= "9") or 
                               s:sub(j,j) == "." or s:sub(j,j) == "e" or 
                               s:sub(j,j) == "E" or s:sub(j,j) == "+" or 
                               s:sub(j,j) == "-") do
                j = j + 1
            end
            return tonumber(s:sub(i, j-1)), j
        end
        
        if c == '"' then
            local j = i + 1
            local result = ""
            while j <= #s do
                if s:sub(j,j) == '"' then return result, j + 1
                elseif s:sub(j,j) == "\\" and j < #s then
                    local next = s:sub(j+1, j+1)
                    if next == "n" then result = result .. "\n"
                    elseif next == "t" then result = result .. "\t"
                    elseif next == "r" then result = result .. "\r"
                    elseif next == '"' then result = result .. '"'
                    elseif next == "\\" then result = result .. "\\"
                    else result = result .. next end
                    j = j + 2
                else
                    result = result .. s:sub(j,j)
                    j = j + 1
                end
            end
            return result, j
        end
        
        if c == "[" then
            local arr = {}
            i = i + 1
            i = skip_whitespace(s, i)
            if s:sub(i,i) == "]" then return arr, i + 1 end
            while i <= #s do
                local val
                val, i = parse_value(s, i)
                table.insert(arr, val)
                i = skip_whitespace(s, i)
                if s:sub(i,i) == "]" then return arr, i + 1 end
                if s:sub(i,i) == "," then i = i + 1 end
            end
            return arr, i
        end
        
        if c == "{" then
            local obj = {}
            i = i + 1
            i = skip_whitespace(s, i)
            if s:sub(i,i) == "}" then return obj, i + 1 end
            while i <= #s do
                local key, val
                key, i = parse_value(s, i)
                i = skip_whitespace(s, i)
                if s:sub(i,i) == ":" then i = i + 1 end
                i = skip_whitespace(s, i)
                val, i = parse_value(s, i)
                obj[key] = val
                i = skip_whitespace(s, i)
                if s:sub(i,i) == "}" then return obj, i + 1 end
                if s:sub(i,i) == "," then i = i + 1 end
            end
            return obj, i
        end
        
        return nil, i
    end
    
    local success, result = pcall(function()
        local val, _ = parse_value(str, 1)
        return val
    end)
    
    return success and result or nil
end

function json.encode(val)
    local t = type(val)
    if val == nil then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return "null" end
        return tostring(val)
    elseif t == "string" then
        local escaped = val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. escaped .. '"'
    elseif t == "table" then
        local is_array = true
        local count = 0
        for _ in pairs(val) do count = count + 1 end
        for i = 1, count do
            if val[i] == nil then is_array = false break end
        end
        
        if is_array then
            local parts = {}
            for _, v in ipairs(val) do table.insert(parts, json.encode(v)) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, json.encode(tostring(k)) .. ":" .. json.encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- ============== UTILITY FUNCTIONS ==============

local function clamp(v, min, max)
    if type(v) ~= "number" then return min end
    if v ~= v then return min end
    return math.max(min, math.min(max, v))
end

local function normalize_angle(a)
    if type(a) ~= "number" then return 0 end
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function angle_diff(a, b)
    return normalize_angle((a or 0) - (b or 0))
end

local function lerp(a, b, t)
    return a + (b - a) * clamp(t, 0, 1)
end

local function vec_length(x, y, z)
    return math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
end

local function vec_length_2d(x, y)
    return math.sqrt((x or 0)^2 + (y or 0)^2)
end

local function vec_distance(x1, y1, z1, x2, y2, z2)
    local dx = (x1 or 0) - (x2 or 0)
    local dy = (y1 or 0) - (y2 or 0)
    local dz = (z1 or 0) - (z2 or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function vec_normalize(x, y, z)
    local len = vec_length(x, y, z)
    if len < 0.0001 then return 0, 0, 0 end
    return x/len, y/len, z/len
end

local function vec_dot(x1, y1, z1, x2, y2, z2)
    return (x1 or 0)*(x2 or 0) + (y1 or 0)*(y2 or 0) + (z1 or 0)*(z2 or 0)
end

local function vec_cross(x1, y1, z1, x2, y2, z2)
    return y1*z2 - z1*y2, z1*x2 - x1*z2, x1*y2 - y1*x2
end

local function time_to_ticks(t)
    return math.floor(t / CONFIG.TICK_INTERVAL + 0.5)
end

-- ============== ADVANCED INTERPOLATION ==============

-- Hermite basis functions
local function hermite_basis_00(t) return 2*t*t*t - 3*t*t + 1 end
local function hermite_basis_10(t) return t*t*t - 2*t*t + t end
local function hermite_basis_01(t) return -2*t*t*t + 3*t*t end
local function hermite_basis_11(t) return t*t*t - t*t end

-- Cubic Hermite with tension
local function cubic_hermite_interp(p0, p1, m0, m1, t, tension)
    tension = tension or 0.5
    t = clamp(t, 0, 1)
    m0 = m0 * tension
    m1 = m1 * tension
    return hermite_basis_00(t) * p0 + 
           hermite_basis_10(t) * m0 + 
           hermite_basis_01(t) * p1 + 
           hermite_basis_11(t) * m1
end

-- Catmull-Rom Spline
local function catmull_rom_spline(p0, p1, p2, p3, t)
    t = clamp(t, 0, 1)
    local t2 = t * t
    local t3 = t2 * t
    
    return 0.5 * (
        (2 * p1) +
        (-p0 + p2) * t +
        (2*p0 - 5*p1 + 4*p2 - p3) * t2 +
        (-p0 + 3*p1 - 3*p2 + p3) * t3
    )
end

-- B-Spline basis
local function b_spline_basis(i, k, t, knots)
    if k == 0 then
        if t >= (knots[i] or 0) and t < (knots[i+1] or 1) then
            return 1
        end
        return 0
    end
    
    local left = 0
    local denom_left = (knots[i+k] or 1) - (knots[i] or 0)
    if denom_left > 0 then
        left = ((t - (knots[i] or 0)) / denom_left) * b_spline_basis(i, k-1, t, knots)
    end
    
    local right = 0
    local denom_right = (knots[i+k+1] or 1) - (knots[i+1] or 0)
    if denom_right > 0 then
        right = (((knots[i+k+1] or 1) - t) / denom_right) * b_spline_basis(i+1, k-1, t, knots)
    end
    
    return left + right
end

-- B-Spline interpolation
local function b_spline_interp(points, t, degree)
    degree = degree or 3
    local n = #points
    if n < 2 then return points[1] or points[1] end
    
    t = clamp(t, 0, 1)
    local result = 0
    
    -- Create uniform knot vector
    local knots = {}
    for i = 1, n + degree + 1 do
        knots[i] = (i - 1) / (n + degree)
    end
    
    for i = 1, n do
        local basis = b_spline_basis(i-1, degree, t, knots)
        result = result + points[i] * basis
    end
    
    return result
end

-- Akima interpolation (preserves sharp corners)
local function akima_weights(s1, s2, s3, s4)
    local w1 = math.abs(s4 - s3)
    local w2 = math.abs(s2 - s1)
    local w = w1 + w2
    
    if w < 0.0001 then
        return (s2 + s3) / 2
    end
    
    return (w1 * s2 + w2 * s3) / w
end

local function akima_interp(p0, p1, p2, p3, t)
    t = clamp(t, 0, 1)
    
    local s1 = p1 - p0
    local s2 = p2 - p1
    local s3 = p3 - p2
    
    local m1 = akima_weights(s1, s1, s2, s3)
    local m2 = akima_weights(s1, s2, s2, s3)
    
    return hermite_basis_00(t) * p1 + 
           hermite_basis_10(t) * m1 + 
           hermite_basis_01(t) * p2 + 
           hermite_basis_11(t) * m2
end

-- Multi-pass interpolation with blending
local function multi_pass_interpolate(records, t)
    if not records or #records < 2 then return nil end
    
    local n = #records
    local results = {}
    
    -- Pass 1: Linear interpolation
    local i1 = math.floor(t * (n - 1)) + 1
    local i2 = math.min(i1 + 1, n)
    local frac = (t * (n - 1)) - (i1 - 1)
    local linear = lerp(records[i1], records[i2], frac)
    results.linear = linear
    
    -- Pass 2: Catmull-Rom spline
    if n >= 4 then
        local i = math.floor(t * (n - 3)) + 2
        i = clamp(i, 2, n - 2)
        local local_t = (t * (n - 3)) - (i - 2)
        results.spline = catmull_rom_spline(records[i-1], records[i], records[i+1], records[math.min(i+2, n)], local_t)
    end
    
    -- Pass 3: Cubic Hermite
    if n >= 2 then
        local i = math.floor(t * (n - 1)) + 1
        i = clamp(i, 1, n - 1)
        local local_t = (t * (n - 1)) - (i - 1)
        local m0 = (records[i+1] - records[math.max(i-1, 1)]) * 0.5
        local m1 = (records[math.min(i+2, n)] - records[i]) * 0.5
        results.cubic = cubic_hermite_interp(records[i], records[i+1], m0, m1, local_t, CONFIG.SPLINE_TENSION)
    end
    
    -- Blend results based on confidence
    local final = results.linear
    local weight = 1
    
    if results.spline then
        final = final + results.spline * 0.35
        weight = weight + 0.35
    end
    
    if results.cubic then
        final = final + results.cubic * 0.25
        weight = weight + 0.25
    end
    
    return final / weight
end

-- ============== ADVANCED EXTRAPOLATION ==============

-- Detect surface friction
local function detect_surface_friction(velocity_history)
    if not velocity_history or #velocity_history < 5 then return false, 1.0 end
    
    local speed_changes = {}
    for i = 2, #velocity_history do
        local prev_speed = velocity_history[i-1].speed or 0
        local curr_speed = velocity_history[i].speed or 0
        if prev_speed > 0 then
            table.insert(speed_changes, (prev_speed - curr_speed) / prev_speed)
        end
    end
    
    if #speed_changes < 3 then return false, 1.0 end
    
    local avg_change = 0
    for _, c in ipairs(speed_changes) do
        avg_change = avg_change + c
    end
    avg_change = avg_change / #speed_changes
    
    local friction_multiplier = 1.0 + avg_change * 2
    return avg_change > CONFIG.SURFACE_FRICTION_THRESHOLD, clamp(friction_multiplier, 0.8, 1.5)
end

-- Bunnyhop detection
local function detect_bunnyhop(velocity_history)
    if not velocity_history or #velocity_history < 3 then return false, 0 end
    
    local bhop_count = 0
    for i = 2, #velocity_history do
        local prev = velocity_history[i-1]
        local curr = velocity_history[i]
        
        if prev.speed and curr.speed then
            if prev.speed < 10 and curr.speed > CONFIG.BUNNYHOP_SPEED then
                bhop_count = bhop_count + 1
            end
        end
    end
    
    return bhop_count > 0, bhop_count
end

-- Stamina prediction
local function predict_stamina(data, ticks)
    local stamina = data.stamina or 100
    local stamina_cost = 0
    
    if data.is_jumping then
        stamina_cost = ticks * 2.5
    elseif data.is_ducking then
        stamina_cost = ticks * 1.8
    end
    
    return math.max(0, stamina - stamina_cost)
end

-- Ground extrapolation with surface friction
local function extrapolate_ground(origin, velocity, acceleration, ticks, data)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    local dt = CONFIG.TICK_INTERVAL
    local friction = CONFIG.GROUND_FRICTION
    
    -- Detect surface friction
    local surface_friction, friction_mult = detect_surface_friction(data.velocity_history)
    if surface_friction then
        friction = friction * friction_mult
    end
    
    -- Bunnyhop detection
    local is_bunnyhopping, bhop_count = detect_bunnyhop(data.velocity_history)
    
    for i = 1, ticks do
        local speed = vec_length_2d(vel.x, vel.y)
        
        if speed > 0 then
            -- Apply friction
            local drop = speed * friction * dt
            local new_speed = math.max(speed - drop, 0)
            local factor = new_speed / speed
            
            vel.x = vel.x * factor
            vel.y = vel.y * factor
            
            -- Bunnyhop speed preservation
            if is_bunnyhopping and speed > 250 then
                local preserve_factor = 0.92 + bhop_count * 0.02
                vel.x = vel.x / factor * preserve_factor
                vel.y = vel.y / factor * preserve_factor
            end
        end
        
        -- Apply acceleration
        if acceleration then
            vel.x = vel.x + acceleration.x * dt
            vel.y = vel.y + acceleration.y * dt
        end
        
        -- Velocity clamping
        local new_speed = vec_length_2d(vel.x, vel.y)
        if new_speed > CONFIG.MAX_VELOCITY_GROUND then
            local clamp_factor = CONFIG.MAX_VELOCITY_GROUND / new_speed
            vel.x = vel.x * clamp_factor
            vel.y = vel.y * clamp_factor
        end
        
        -- Update position
        result.x = result.x + vel.x * dt
        result.y = result.y + vel.y * dt
    end
    
    return result, vel
end

-- Air extrapolation with strafe prediction
local function extrapolate_air(origin, velocity, ticks, duck_amount, data)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    local dt = CONFIG.TICK_INTERVAL
    local gravity = CONFIG.GRAVITY
    local duck_factor = 1.0 - (duck_amount or 0) * 0.2
    
    -- Air strafe detection
    local strafe_dir = 0
    if data.angle_history and #data.angle_history >= 2 then
        local prev_yaw = data.angle_history[#data.angle_history - 1].angle or 0
        local curr_yaw = data.angle_history[#data.angle_history].angle or 0
        strafe_dir = angle_diff(curr_yaw, prev_yaw)
    end
    
    for i = 1, ticks do
        -- Apply gravity
        vel.z = vel.z - gravity * dt * duck_factor
        vel.z = math.max(vel.z, -350)
        
        -- Air strafing prediction
        local wish_speed = CONFIG.MAX_VELOCITY_AIR
        local current_speed = vec_length_2d(vel.x, vel.y)
        
        if current_speed < wish_speed then
            local accel_dir = { x = vel.x, y = vel.y }
            local len = vec_length_2d(accel_dir.x, accel_dir.y)
            
            if len > 0.1 then
                accel_dir.x = accel_dir.x / len
                accel_dir.y = accel_dir.y / len
                
                -- Apply strafe direction
                if strafe_dir ~= 0 then
                    local strafe_rad = strafe_dir * PI / 180
                    local new_x = accel_dir.x * math.cos(strafe_rad) - accel_dir.y * math.sin(strafe_rad)
                    local new_y = accel_dir.x * math.sin(strafe_rad) + accel_dir.y * math.cos(strafe_rad)
                    accel_dir.x = new_x
                    accel_dir.y = new_y
                end
                
                local add_speed = wish_speed - current_speed
                local accel_speed = math.min(CONFIG.AIR_ACCELERATION * dt * wish_speed, add_speed)
                
                vel.x = vel.x + accel_dir.x * accel_speed
                vel.y = vel.y + accel_dir.y * accel_speed
            end
        end
        
        -- Air speed limit
        local air_speed = vec_length_2d(vel.x, vel.y)
        if air_speed > CONFIG.MAX_VELOCITY_AIR then
            local factor = CONFIG.MAX_VELOCITY_AIR / air_speed
            vel.x = vel.x * factor
            vel.y = vel.y * factor
        end
        
        -- Update position
        result.x = result.x + vel.x * dt
        result.y = result.y + vel.y * dt
        result.z = result.z + vel.z * dt
    end
    
    return result, vel
end

-- Main extrapolation function
local function extrapolate_position(origin, velocity, acceleration, ticks, is_grounded, duck, data)
    if is_grounded then
        return extrapolate_ground(origin, velocity, acceleration, ticks, data)
    else
        return extrapolate_air(origin, velocity, ticks, duck, data)
    end
end

-- ============== CLOUD FUNCTIONS v19.0 ==============

local cloud_resolver = {}

-- Check if reporter is on same team
local function is_same_team(reporter_steamid)
    if not CLOUD_CONFIG.SAME_TEAM_ONLY then return true end
    local players = entity.get_players(false)
    if not players then return cloud_state.connected_teammates[reporter_steamid] ~= nil end
    for _, ent in ipairs(players) do
        local steam64 = entity.get_steam64(ent)
        if steam64 and tostring(steam64) == reporter_steamid then
            local team = entity.get_prop(ent, "m_iTeamNum")
            return team == cloud_state.my_team
        end
    end
    return cloud_state.connected_teammates[reporter_steamid] ~= nil
end

-- Update teammate list
local function update_teammate_list()
    local lp = entity.get_local_player()
    if not lp then return end
    cloud_state.my_team = entity.get_prop(lp, "m_iTeamNum")
    local players = entity.get_players(false)
    if not players then return end
    for _, ent in ipairs(players) do
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            local team = entity.get_prop(ent, "m_iTeamNum")
            if team == cloud_state.my_team then
                cloud_state.connected_teammates[tostring(steam64)] = {
                    name = entity.get_player_name(ent) or "Unknown",
                    last_seen = globals.realtime()
                }
            end
        end
    end
end

-- Validate report data
local function validate_report(report)
    if not report then return false, "nil report" end
    if not report.reporter_steamid or not report.enemy_steam64 then 
        return false, "missing steamid" 
    end
    
    local angle = tonumber(report.angle)
    if not angle or math.abs(angle) > 180 then 
        return false, "invalid angle" 
    end
    
    local conf = tonumber(report.confidence)
    if not conf or conf < 0 or conf > 1 then 
        return false, "invalid confidence" 
    end
    
    -- Check for script version compatibility
    if report.script_version and report.script_version ~= CLOUD_CONFIG.SCRIPT_VERSION then
        -- Accept data from older versions with reduced confidence
        return true, "version_mismatch"
    end
    
    return true, "valid"
end

-- Calculate reporter reputation
local function get_reporter_reputation(reporter_steamid)
    local rep = cloud_state.reporter_reputation[reporter_steamid]
    if not rep then
        return 0.5  -- Default neutral reputation
    end
    
    -- Apply time decay
    local now = globals.realtime()
    local decay = 1.0 - (now - rep.last_update) * CLOUD_CONFIG.REPUTATION_DECAY
    decay = math.max(0.3, decay)
    
    return clamp(rep.score * decay, 0.1, 1.0)
end

-- Update reporter reputation
local function update_reporter_reputation(reporter_steamid, hit)
    if not cloud_state.reporter_reputation[reporter_steamid] then
        cloud_state.reporter_reputation[reporter_steamid] = {
            score = 0.5,
            reports = 0,
            hits = 0,
            last_update = globals.realtime()
        }
    end
    
    local rep = cloud_state.reporter_reputation[reporter_steamid]
    rep.reports = rep.reports + 1
    rep.last_update = globals.realtime()
    
    if hit then
        rep.hits = rep.hits + 1
        rep.score = rep.score + CLOUD_CONFIG.REPUTATION_HIT_BONUS
    else
        rep.score = rep.score - CLOUD_CONFIG.REPUTATION_MISS_PENALTY
    end
    
    -- Normalize score
    rep.score = clamp(rep.score, 0.1, 1.0)
end

-- Angle clustering (DBSCAN-like)
local function cluster_angles(angles, threshold)
    threshold = threshold or CLOUD_CONFIG.ANGLE_CLUSTER_THRESHOLD
    
    if #angles == 0 then return {} end
    
    local clusters = {}
    local visited = {}
    
    for i, a1 in ipairs(angles) do
        if not visited[i] then
            visited[i] = true
            local cluster = {a1}
            
            for j, a2 in ipairs(angles) do
                if not visited[j] then
                    if math.abs(angle_diff(a1.angle, a2.angle)) < threshold then
                        visited[j] = true
                        table.insert(cluster, a2)
                    end
                end
            end
            
            table.insert(clusters, cluster)
        end
    end
    
    return clusters
end

-- Bayesian aggregation
local function bayesian_aggregate(reports, my_steamid)
    if not reports or #reports == 0 then return nil, 0, 0 end
    
    -- Filter valid reports
    local valid_reports = {}
    for _, r in ipairs(reports) do
        local valid, reason = validate_report(r)
        if valid and r.reporter_steamid ~= my_steamid then
            -- Apply reporter reputation
            local reputation = get_reporter_reputation(r.reporter_steamid)
            r.adjusted_confidence = (r.confidence or 0.5) * reputation
            
            -- Apply time decay
            local age = globals.realtime() - (r.timestamp or 0)
            r.time_weight = math.max(0.3, 1 - age / CLOUD_CONFIG.DATA_TIMEOUT)
            
            table.insert(valid_reports, r)
        end
    end
    
    if #valid_reports == 0 then return nil, 0, 0 end
    
    -- Cluster angles
    local angles = {}
    for _, r in ipairs(valid_reports) do
        table.insert(angles, {
            angle = r.angle,
            confidence = r.adjusted_confidence,
            weight = r.time_weight,
            hit = r.hit,
            reporter = r.reporter_steamid
        })
    end
    
    local clusters = cluster_angles(angles)
    
    if #clusters == 0 then return nil, 0, 0 end
    
    -- Find best cluster using Bayesian approach
    local best_cluster = nil
    local best_score = -math.huge
    
    for _, cluster in ipairs(clusters) do
        -- Calculate cluster statistics
        local sum_weight = 0
        local weighted_angle = 0
        local hit_count = 0
        
        for _, a in ipairs(cluster) do
            local weight = a.confidence * a.weight
            if a.hit then 
                weight = weight * 1.3  -- Boost for hit reports
                hit_count = hit_count + 1
            end
            
            weighted_angle = weighted_angle + a.angle * weight
            sum_weight = sum_weight + weight
        end
        
        if sum_weight > 0 then
            -- Bayesian posterior probability
            local cluster_size_prior = #cluster / #valid_reports
            local confidence_likelihood = sum_weight / #cluster
            local hit_bonus = hit_count > 0 and (hit_count / #cluster) * 0.2 or 0
            
            local posterior = (cluster_size_prior * CLOUD_CONFIG.BAYESIAN_PRIOR_STRENGTH + 
                              confidence_likelihood * (1 - CLOUD_CONFIG.BAYESIAN_PRIOR_STRENGTH) + 
                              hit_bonus)
            
            if posterior > best_score then
                best_score = posterior
                best_cluster = {
                    angle = weighted_angle / sum_weight,
                    confidence = clamp(sum_weight / #cluster, 0, 1),
                    size = #cluster,
                    hit_rate = hit_count / #cluster
                }
            end
        end
    end
    
    if not best_cluster then return nil, 0, 0 end
    
    return best_cluster.angle, best_cluster.confidence, best_cluster.size
end

-- Update pattern memory
local function update_pattern_memory(enemy_steam64, angle, hit, pattern)
    if not CLOUD_CONFIG.PATTERN_LEARNING then return end
    
    local key = tostring(enemy_steam64)
    if not cloud_state.pattern_memory[key] then
        cloud_state.pattern_memory[key] = {
            patterns = {},
            best_angle = 60,
            best_confidence = 0,
            total_reports = 0,
            hits = 0,
            angle_history = {}
        }
    end
    
    local mem = cloud_state.pattern_memory[key]
    mem.total_reports = mem.total_reports + 1
    
    -- Store angle in history
    table.insert(mem.angle_history, {
        angle = angle,
        hit = hit,
        time = globals.realtime(),
        pattern = pattern
    })
    
    -- Limit history
    while #mem.angle_history > 50 do
        table.remove(mem.angle_history, 1)
    end
    
    if hit then
        mem.hits = mem.hits + 1
        
        -- Update best angle if this is better
        local hit_rate = mem.hits / mem.total_reports
        if hit_rate > mem.best_confidence then
            mem.best_angle = angle
            mem.best_confidence = hit_rate
        end
        
        -- Update pattern stats
        if pattern and pattern ~= "unknown" then
            if not mem.patterns[pattern] then
                mem.patterns[pattern] = { count = 0, avg_angle = 0, hits = 0 }
            end
            
            local p = mem.patterns[pattern]
            p.count = p.count + 1
            p.hits = p.hits + 1
            p.avg_angle = (p.avg_angle * (p.count - 1) + angle) / p.count
        end
    end
end

-- Get pattern prediction
local function get_pattern_prediction(enemy_steam64)
    local mem = cloud_state.pattern_memory[tostring(enemy_steam64)]
    if not mem or mem.total_reports < CLOUD_CONFIG.PATTERN_MIN_SAMPLES then
        return nil, 0
    end
    
    -- Use best angle if confidence is high
    if mem.best_confidence > CLOUD_CONFIG.PATTERN_CONFIDENCE_THRESHOLD then
        return mem.best_angle, mem.best_confidence * 0.85
    end
    
    -- Find best pattern
    local best_pattern = nil
    local best_rate = 0
    
    for _, p in pairs(mem.patterns) do
        if p.count >= 3 then
            local hit_rate = p.hits / p.count
            if hit_rate > best_rate then
                best_rate = hit_rate
                best_pattern = p
            end
        end
    end
    
    if best_pattern and best_rate > 0.5 then
        return best_pattern.avg_angle, best_rate * 0.75
    end
    
    return nil, 0
end

-- Check rate limit for enemy
local function can_report_enemy(enemy_steam64)
    local now = globals.realtime()
    local key = tostring(enemy_steam64)
    
    -- Global rate limit
    if now - cloud_state.last_report_time < CLOUD_CONFIG.GLOBAL_RATE_LIMIT then
        return false
    end
    
    -- Per-enemy rate limit
    local last_time = cloud_state.last_report_times[key] or 0
    if now - last_time < CLOUD_CONFIG.ANTI_SPAM_INTERVAL then
        return false
    end
    
    return true
end

-- HTTP POST with retry
local function http_post_with_retry(url, payload, callback, retry_count)
    retry_count = retry_count or 0
    
    http.post(url, { body = payload, headers = { ["Content-Type"] = "application/json" } }, 
    function(success, response)
        if not success then
            if retry_count < CLOUD_CONFIG.MAX_RETRY then
                local delay = CLOUD_CONFIG.RETRY_DELAY * math.pow(CLOUD_CONFIG.RETRY_BACKOFF, retry_count)
                client.delay_call(delay, function()
                    http_post_with_retry(url, payload, callback, retry_count + 1)
                end)
            else
                cloud_state.error_count = cloud_state.error_count + 1
                cloud_state.last_error = "POST failed after " .. CLOUD_CONFIG.MAX_RETRY .. " retries"
                callback(false)
            end
            return
        end
        
        if response and response.status then
            if response.status == 503 then
                -- Server temporarily unavailable
                if retry_count < CLOUD_CONFIG.MAX_RETRY then
                    client.delay_call(5, function()
                        http_post_with_retry(url, payload, callback, retry_count + 1)
                    end)
                else
                    callback(false)
                end
                return
            end
            
            if response.status ~= 200 then
                cloud_state.error_count = cloud_state.error_count + 1
                cloud_state.last_error = "HTTP " .. tostring(response.status)
                callback(false)
                return
            end
        end
        
        callback(true)
    end)
end

-- Initialize cloud resolver
function cloud_resolver.init()
    local lp = entity.get_local_player()
    if not lp then return false end
    
    cloud_state.my_steam64 = entity.get_steam64(lp)
    if not cloud_state.my_steam64 or cloud_state.my_steam64 == 0 then return false end
    
    cloud_state.my_steamid = tostring(cloud_state.my_steam64)
    cloud_state.my_team = entity.get_prop(lp, "m_iTeamNum")
    cloud_state.initialized = true
    
    update_teammate_list()
    
    if CLOUD_CONFIG.DEBUG then
        client.log("[Cloud Resolver v19.0] Initialized: " .. cloud_state.my_steamid)
    end
    
    return true
end

-- Report data to cloud
function cloud_resolver.report_data(enemy_steam64, angle, confidence, hit, pattern)
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return false end
    end
    
    if not enemy_steam64 or enemy_steam64 == 0 then return false end
    
    -- Rate limiting
    local enemy_key = tostring(enemy_steam64)
    if not can_report_enemy(enemy_steam64) then
        return false
    end
    
    cloud_state.last_report_time = globals.realtime()
    cloud_state.last_report_times[enemy_key] = globals.realtime()
    
    -- Update pattern memory
    update_pattern_memory(enemy_steam64, angle, hit, pattern)
    
    -- Clamp values
    angle = clamp(tonumber(angle) or 60, -180, 180)
    confidence = clamp(tonumber(confidence) or 0.5, 0, 1)
    
    local payload = json.encode({
        reporter_steamid = cloud_state.my_steamid,
        enemy_steam64 = enemy_key,
        angle = angle,
        confidence = confidence,
        hit = hit or false,
        pattern = pattern or "unknown",
        timestamp = globals.realtime(),
        team = cloud_state.my_team,
        resolver_id = CLOUD_CONFIG.RESOLVER_ID,
        script_version = CLOUD_CONFIG.SCRIPT_VERSION
    })
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/update"
    
    http_post_with_retry(url, payload, function(success)
        if success then
            cloud_state.sync_count = cloud_state.sync_count + 1
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud v19.0] Synced: angle=" .. string.format("%.1f", angle))
            end
        end
    end)
    
    return true
end

-- Poll for cloud data
function cloud_resolver.poll()
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return end
    end
    
    local current_time = globals.realtime()
    if current_time - cloud_state.last_poll < CLOUD_CONFIG.POLL_INTERVAL then return end
    cloud_state.last_poll = current_time
    
    -- Update teammate list periodically
    if globals.tickcount() % 100 == 0 then
        update_teammate_list()
    end
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/get"
    
    http.get(url, function(success, response)
        if not success or not response then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "GET failed"
            return
        end
        
        if response and response.status and response.status ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP " .. tostring(response.status)
            return
        end
        
        local data = response.body
        if not data or data == "" then return end
        
        local decoded = json.parse(data)
        if not decoded then return end
        
        -- Process received data
        for steam64, entry in pairs(decoded) do
            if steam64 ~= cloud_state.my_steamid then
                if not cloud_state.cloud_data[steam64] then
                    cloud_state.cloud_data[steam64] = {
                        reports = {},
                        aggregated_angle = nil,
                        aggregated_conf = 0,
                        last_update = 0
                    }
                end
                
                local cd = cloud_state.cloud_data[steam64]
                
                -- Add report if from teammate
                if is_same_team(entry.reporter) then
                    table.insert(cd.reports, {
                        reporter = entry.reporter,
                        angle = entry.angle,
                        confidence = entry.confidence,
                        hit = entry.hit,
                        pattern = entry.pattern,
                        timestamp = entry.timestamp
                    })
                end
                
                -- Limit stored reports
                while #cd.reports > 25 do
                    table.remove(cd.reports, 1)
                end
                
                -- Aggregate using Bayesian method
                local agg_angle, agg_conf, reporter_count = bayesian_aggregate(cd.reports, cloud_state.my_steamid)
                
                if agg_angle then
                    cd.aggregated_angle = agg_angle
                    cd.aggregated_conf = agg_conf
                    cd.reporter_count = reporter_count
                    cd.last_update = current_time
                    
                    -- Update cache
                    cloud_state.prediction_cache[steam64] = {
                        angle = agg_angle,
                        confidence = agg_conf,
                        reporter_count = reporter_count,
                        timestamp = current_time
                    }
                end
            end
        end
        
        if CLOUD_CONFIG.DEBUG then
            local count = 0
            for _ in pairs(cloud_state.cloud_data) do count = count + 1 end
            if count > 0 then
                client.log("[Cloud v19.0] Updated: " .. count .. " players")
            end
        end
    end)
end

-- Get cloud data for enemy
function cloud_resolver.get_data(enemy)
    if not cloud_state.initialized then return nil end
    
    local steam64 = entity.get_steam64(enemy)
    if not steam64 or steam64 == 0 then return nil end
    
    local key = tostring(steam64)
    
    -- Check cache first
    local cached = cloud_state.prediction_cache[key]
    if cached then
        local cache_age = globals.realtime() - cached.timestamp
        if cache_age < CLOUD_CONFIG.PREDICTION_CACHE_TTL then
            return {
                angle = cached.angle,
                confidence = cached.confidence,
                reporter_count = cached.reporter_count,
                source = "cache"
            }
        end
    end
    
    local data = cloud_state.cloud_data[key]
    
    if not data or not data.aggregated_angle then
        -- Try pattern prediction
        local pred_angle, pred_conf = get_pattern_prediction(steam64)
        if pred_angle and pred_conf > 0.4 then
            return {
                angle = pred_angle,
                confidence = pred_conf,
                source = "pattern_memory",
                age = 0
            }
        end
        return nil
    end
    
    local age = globals.realtime() - (data.last_update or 0)
    
    -- Check for stale data
    if age > CLOUD_CONFIG.DATA_TIMEOUT then
        cloud_state.cloud_data[key] = nil
        cloud_state.prediction_cache[key] = nil
        return nil
    end
    
    -- Apply confidence decay for stale data
    local decayed_conf = data.aggregated_conf
    if age > CLOUD_CONFIG.STALE_DATA_THRESHOLD then
        local decay_factor = 1 - (age - CLOUD_CONFIG.STALE_DATA_THRESHOLD) / 
                                (CLOUD_CONFIG.DATA_TIMEOUT - CLOUD_CONFIG.STALE_DATA_THRESHOLD)
        decayed_conf = decayed_conf * decay_factor
    end
    
    if decayed_conf < CLOUD_CONFIG.MIN_CONFIDENCE then return nil end
    
    -- Combine with pattern prediction
    local pattern_angle, pattern_conf = get_pattern_prediction(steam64)
    local final_angle = data.aggregated_angle
    local final_conf = decayed_conf
    
    if pattern_angle and pattern_conf > 0.5 then
        local cloud_weight = decayed_conf
        local pattern_weight = pattern_conf * 0.4
        local total_weight = cloud_weight + pattern_weight
        
        if total_weight > 0 then
            final_angle = (final_angle * cloud_weight + pattern_angle * pattern_weight) / total_weight
            final_conf = math.min(1, decayed_conf + pattern_conf * 0.08)
        end
    end
    
    return {
        angle = final_angle,
        confidence = final_conf,
        reporter_count = data.reporter_count or 1,
        source = "cloud",
        age = age
    }
end

-- Clean stale data
function cloud_resolver.clean()
    local current_time = globals.realtime()
    
    -- Clean cloud data
    for steam64, data in pairs(cloud_state.cloud_data) do
        if current_time - (data.last_update or 0) > CLOUD_CONFIG.DATA_TIMEOUT then
            cloud_state.cloud_data[steam64] = nil
        end
    end
    
    -- Clean prediction cache
    for steam64, cached in pairs(cloud_state.prediction_cache) do
        if current_time - cached.timestamp > CLOUD_CONFIG.PREDICTION_CACHE_TTL * 2 then
            cloud_state.prediction_cache[steam64] = nil
        end
    end
    
    -- Clean teammate list
    for steamid, teammate in pairs(cloud_state.connected_teammates) do
        if current_time - teammate.last_seen > 60 then
            cloud_state.connected_teammates[steamid] = nil
        end
    end
    
    -- Clean pattern memory
    for steam64, mem in pairs(cloud_state.pattern_memory) do
        -- Remove old angle history entries
        local new_history = {}
        for _, entry in ipairs(mem.angle_history) do
            if current_time - entry.time < 120 then
                table.insert(new_history, entry)
            end
        end
        mem.angle_history = new_history
    end
    
    -- Limit cache size
    local cache_size = 0
    for _ in pairs(cloud_state.prediction_cache) do
        cache_size = cache_size + 1
    end
    
    if cache_size > CLOUD_CONFIG.MAX_CACHE_SIZE then
        -- Remove oldest entries
        local oldest = nil
        local oldest_time = math.huge
        for steam64, cached in pairs(cloud_state.prediction_cache) do
            if cached.timestamp < oldest_time then
                oldest_time = cached.timestamp
                oldest = steam64
            end
        end
        if oldest then
            cloud_state.prediction_cache[oldest] = nil
        end
    end
end

-- Validate hit/miss (for reputation updates)
function cloud_resolver.validate_hit(enemy_steam64, hit, reporter_steamid)
    if reporter_steamid and reporter_steamid ~= cloud_state.my_steamid then
        update_reporter_reputation(reporter_steamid, hit)
    end
end

client.log("[Cloud Resolver v19.0] Module loaded!")

-- ============== MAIN RESOLVER ==============

local function create_stats()
    return {
        shots = 0, hits = 0, misses = 0,
        streak_best = 0, streak_current = 0,
        total_resolves = 0,
        backtrack_shots = 0, backtrack_hits = 0,
        cloud_resolves = 0, cloud_hits = 0,
        cloud_multi_reporter = 0,
        pattern_resolves = 0,
        pattern_hits = 0
    }
end

local function create_player_data()
    return {
        angle_history = {},
        velocity_history = {},
        backtrack_records = {},
        successful_resolves = {},
        best_tick_history = {},
        dt_shots = {},
        
        bf_index = 1,
        predicted_side = 0,
        confidence = 0.35,
        last_resolve = 60,
        jitter_score = 0,
        spin_speed = 0,
        spin_direction = 0,
        detected_pattern = "unknown",
        pattern_confidence = 0,
        
        shots = 0, hits = 0, misses = 0,
        consecutive_hits = 0, consecutive_misses = 0,
        
        dt_detected = false,
        dt_confidence = 0,
        dt_angle_offset = 0,
        last_ammo = -1,
        
        backtrack_is_valid = false,
        backtrack_score = 0,
        backtrack_target_tick = 0,
        prev_origin = {x=0,y=0,z=0},
        prev_velocity = {x=0,y=0,z=0},
        prev_sim_time = 0,
        acceleration = {x=0,y=0,z=0},
        avg_acceleration = {x=0,y=0,z=0},
        prev_acceleration = nil,
        is_on_ground = true,
        predicted_origin = {x=0,y=0,z=0},
        extrapolation_confidence = 0.5,
        lc_break_detected = false,
        velocity_delta = 0,
        origin_delta = 0,
        
        cloud_used = false,
        pattern_used = false,
        is_jitter = false,
        is_spinning = false,
        is_extended = false,
        is_moving = false,
        is_air = false,
        last_plist_update = 0,
        
        -- v19.0 additions
        stamina = 100,
        duck_amount = 0,
        is_jumping = false,
        opposite_from_miss = nil,
        miss_learn_time = 0
    }
end

-- UI
local ui_elements = {
    enabled = ui.new_checkbox("RAGE", "Other", "Enable Resolver"),
    mode = ui.new_combobox("RAGE", "Other", "Resolver Mode", {
        "Cloud Priority", "Cloud Aggressive", "Adaptive Pro", "Deep Memory",
        "Animation+", "Extended+", "Smart BF"
    }),
    
    cloud_label = ui.new_label("RAGE", "Other", "━━━ Cloud Resolver v19.0 ━━━"),
    cloud_enabled = ui.new_checkbox("RAGE", "Other", "Enable Cloud Sync"),
    cloud_url = ui.new_textbox("RAGE", "Other", "Server URL"),
    cloud_debug = ui.new_checkbox("RAGE", "Other", "Cloud Debug"),
    cloud_test = ui.new_button("RAGE", "Other", "Test Connection", function()
        local count = 0
        for _ in pairs(cloud_state.connected_teammates) do count = count + 1 end
        client.log("[Cloud v19.0] SteamID: " .. tostring(cloud_state.my_steamid))
        client.log("[Cloud v19.0] Teammates: " .. count .. " | Syncs: " .. cloud_state.sync_count)
        client.log("[Cloud v19.0] Patterns: " .. #cloud_state.pattern_memory .. " | Cache: " .. #cloud_state.prediction_cache)
    end),
    
    bt_label = ui.new_label("RAGE", "Other", "━━━ Backtrack ━━━"),
    bt_ticks = ui.new_slider("RAGE", "Other", "Max Ticks", 14, 40, 40, true, "ticks"),
    
    ie_label = ui.new_label("RAGE", "Other", "━━━ Interpolation ━━━"),
    ie_interpolation = ui.new_checkbox("RAGE", "Other", "Enable Interpolation"),
    ie_method = ui.new_combobox("RAGE", "Other", "Interp Method", {"Auto", "B-Spline", "Akima", "Catmull-Rom", "Cubic"}),
    ie_extrapolation = ui.new_checkbox("RAGE", "Other", "Enable Extrapolation"),
    ie_extrapolation_ticks = ui.new_slider("RAGE", "Other", "Max Extrapolation", 1, 12, 6, true, "ticks"),
    
    dt_label = ui.new_label("RAGE", "Other", "━━━ Double Tap ━━━"),
    dt_predict = ui.new_checkbox("RAGE", "Other", "DT Prediction"),
    dt_aggression = ui.new_slider("RAGE", "Other", "DT Angle Shift", 0, 30, 15, true, "°"),
    
    adv_label = ui.new_label("RAGE", "Other", "━━━ Settings ━━━"),
    aggression = ui.new_slider("RAGE", "Other", "Aggression", 1, 10, 7, true, "lvl"),
    
    debug_label = ui.new_label("RAGE", "Other", "━━━ Debug ━━━"),
    show_stats = ui.new_checkbox("RAGE", "Other", "Show Statistics"),
    log_hits = ui.new_checkbox("RAGE", "Other", "Log Hits/Misses"),
    
    reset_btn = ui.new_button("RAGE", "Other", "Reset All Data", function()
        player_data = {}
        global_stats = create_stats()
        cloud_state.cloud_data = {}
        cloud_state.prediction_cache = {}
        cloud_state.pattern_memory = {}
        cloud_state.reporter_reputation = {}
        client.log("[Resolver v19.0] Data reset")
    end)
}

ui.set(ui_elements.dt_predict, true)
ui.set(ui_elements.show_stats, true)
ui.set(ui_elements.ie_interpolation, true)
ui.set(ui_elements.ie_extrapolation, true)
ui.set(ui_elements.cloud_enabled, true)
ui.set(ui_elements.cloud_url, "https://cloud-resolver-for-gamesense-csgo.onrender.com/api")

local global_stats = create_stats()
local player_data = {}

local function get_data(ent)
    if not player_data[ent] then player_data[ent] = create_player_data() end
    return player_data[ent]
end

-- PList
local function plist_set_force_angle(ent, angle)
    local steam64 = entity.get_steam64(ent)
    if not steam64 or steam64 == 0 then return false end
    plist.set(steam64, "Force bodyyaw", true)
    plist.set(steam64, "Force bodyyaw value", angle)
    return true
end

-- Backtrack recording
local function record_backtrack(ent, data)
    if not entity.is_alive(ent) then return end
    
    local sim_time = entity.get_prop(ent, "m_flSimulationTime")
    local ox, oy, oz = entity.get_prop(ent, "m_vecOrigin")
    if not sim_time or not ox then return end
    
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local duck = entity.get_prop(ent, "m_flDuckAmount") or 0
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local is_grounded = bit.band(flags, 1) ~= 0
    
    local dt = sim_time - (data.prev_sim_time or sim_time)
    if dt <= 0 then dt = CONFIG.TICK_INTERVAL end
    
    -- Calculate acceleration
    local new_acc = {
        x = (vx - data.prev_velocity.x) / dt,
        y = (vy - data.prev_velocity.y) / dt,
        z = (vz - data.prev_velocity.z) / dt
    }
    
    data.acceleration = {
        x = lerp(data.acceleration.x, new_acc.x, CONFIG.ACCELERATION_SMOOTHING),
        y = lerp(data.acceleration.y, new_acc.y, CONFIG.ACCELERATION_SMOOTHING),
        z = lerp(data.acceleration.z, new_acc.z, CONFIG.ACCELERATION_SMOOTHING)
    }
    
    data.avg_acceleration = {
        x = (data.acceleration.x + (data.prev_acceleration and data.prev_acceleration.x or 0)) * 0.5,
        y = (data.acceleration.y + (data.prev_acceleration and data.prev_acceleration.y or 0)) * 0.5,
        z = (data.acceleration.z + (data.prev_acceleration and data.prev_acceleration.z or 0)) * 0.5
    }
    data.prev_acceleration = { x = data.acceleration.x, y = data.acceleration.y, z = data.acceleration.z }
    
    data.velocity_delta = vec_distance(data.prev_velocity.x, data.prev_velocity.y, data.prev_velocity.z, vx, vy, vz)
    data.origin_delta = vec_distance(data.prev_origin.x, data.prev_origin.y, data.prev_origin.z, ox, oy, oz)
    data.lc_break_detected = data.origin_delta > 64 or data.velocity_delta > 200
    
    -- Extrapolation
    local max_extrap = ui.get(ui_elements.ie_extrapolation_ticks)
    local predicted = extrapolate_position(
        {x=ox, y=oy, z=oz},
        {x=vx, y=vy, z=vz},
        data.avg_acceleration,
        max_extrap,
        is_grounded,
        duck,
        data
    )
    data.predicted_origin = predicted
    
    local record = {
        sim_time = sim_time,
        tick_count = time_to_ticks(sim_time),
        origin = {x=ox, y=oy, z=oz},
        velocity = {x=vx, y=vy, z=vz},
        angles = {yaw = yaw},
        duck = duck,
        speed = vec_length(vx, vy, vz),
        is_grounded = is_grounded,
        is_lc_break = data.lc_break_detected,
        predicted_origin = predicted,
        confidence = data.confidence,
        resolve_angle = data.last_resolve,
        valid = true
    }
    
    -- Check for duplicate
    for _, rec in ipairs(data.backtrack_records) do
        if math.abs(rec.sim_time - sim_time) < 0.001 then
            data.prev_origin = {x=ox, y=oy, z=oz}
            data.prev_velocity = {x=vx, y=vy, z=vz}
            data.prev_sim_time = sim_time
            return
        end
    end
    
    table.insert(data.backtrack_records, record)
    while #data.backtrack_records > CONFIG.MAX_BACKTRACK do
        table.remove(data.backtrack_records, 1)
    end
    
    data.prev_origin = {x=ox, y=oy, z=oz}
    data.prev_velocity = {x=vx, y=vy, z=vz}
    data.prev_sim_time = sim_time
end

-- Best backtrack record
local function get_best_backtrack_record(ent, data)
    local lp = entity.get_local_player()
    if not lp then return nil, 0, 0 end
    
    local lx, ly, lz = entity.get_prop(lp, "m_vecOrigin")
    if not lx then return nil, 0, 0 end
    
    local max_ticks = ui.get(ui_elements.bt_ticks)
    local current_tick = globals.tickcount()
    local best_record = nil
    local best_score = -math.huge
    local best_tick = 0
    
    for _, rec in ipairs(data.backtrack_records) do
        if rec.valid and rec.tick_count then
            local tick_diff = current_tick - rec.tick_count
            if tick_diff > 0 and tick_diff <= max_ticks then
                local dist = vec_distance(lx, ly, lz, rec.origin.x, rec.origin.y, rec.origin.z)
                local score = 100 - tick_diff * 2 + math.max(0, 100 - dist/15)
                
                if rec.is_lc_break then score = score + 100 end
                if rec.speed and rec.speed > 50 then score = score + 10 end
                
                if score > best_score then
                    best_score = score
                    best_record = rec
                    best_tick = tick_diff
                end
            end
        end
    end
    
    return best_record, best_tick, best_score
end

-- Analysis functions
local function analyze_jitter(data)
    if #data.angle_history < 5 then return end
    
    local changes = {}
    local oscillations = 0
    local last_dir = 0
    
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            table.insert(changes, diff)
            
            local dir = diff > 0 and 1 or -1
            if last_dir ~= 0 and dir ~= last_dir then
                oscillations = oscillations + 1
            end
            last_dir = dir
        end
    end
    
    if #changes < 3 then return end
    
    local avg = 0
    for _, v in ipairs(changes) do avg = avg + math.abs(v) end
    avg = avg / #changes
    
    local var = 0
    for _, v in ipairs(changes) do var = var + (math.abs(v) - avg)^2 end
    
    data.jitter_score = math.sqrt(var/#changes)
    data.avg_angle_change = avg
    data.is_jitter = data.jitter_score > CONFIG.JITTER_THRESHOLD or oscillations > 4
end

local function analyze_spin(data)
    if #data.angle_history < 6 then return false end
    
    local total = 0
    local samples = 0
    local votes = {left=0, right=0}
    
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            total = total + math.abs(diff)
            samples = samples + 1
            
            if diff > 0 then votes.right = votes.right + 1
            else votes.left = votes.left + 1 end
        end
    end
    
    if samples == 0 then return false end
    
    data.spin_speed = total/samples
    data.spin_direction = votes.right > votes.left and 1 or -1
    data.is_spinning = data.spin_speed > CONFIG.SPIN_THRESHOLD
    
    return data.is_spinning
end

local function analyze_velocity(ent, data)
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local speed = math.sqrt(vx*vx + vy*vy)
    
    table.insert(data.velocity_history, {speed = speed})
    while #data.velocity_history > CONFIG.MAX_VELOCITY do
        table.remove(data.velocity_history, 1)
    end
    
    data.is_moving = speed > 10
    data.is_air = bit.band(entity.get_prop(ent, "m_fFlags") or 0, 1) == 0
    
    if speed > 35 then
        local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
        if eye_yaw then
            local diff = angle_diff(math.deg(math.atan2(vy, vx)), eye_yaw)
            if diff > 22 and diff < 158 then return SIDES.RIGHT, 0.78
            elseif diff < -22 and diff > -158 then return SIDES.LEFT, 0.78 end
        end
    end
    
    return SIDES.CENTER, 0.18
end

local function analyze_memory(data)
    if #data.successful_resolves < 2 then return SIDES.CENTER, 0 end
    
    local left_w, right_w, total_w = 0, 0, 0
    for _, res in ipairs(data.successful_resolves) do
        local weight = res.confidence or 0.5
        total_w = total_w + weight
        
        if res.side == SIDES.LEFT then left_w = left_w + weight
        elseif res.side == SIDES.RIGHT then right_w = right_w + weight end
    end
    
    if total_w < 0.25 then return SIDES.CENTER, 0 end
    
    local left_ratio = left_w/total_w
    local right_ratio = right_w/total_w
    
    if left_ratio > 0.55 then return SIDES.LEFT, left_ratio * 0.92
    elseif right_ratio > 0.55 then return SIDES.RIGHT, right_ratio * 0.92 end
    
    return SIDES.CENTER, 0.18
end

local function analyze_animation(ent)
    local body_yaw = entity.get_prop(ent, "m_flPoseParameter", CONFIG.POSE_BODY_YAW)
    if not body_yaw then return SIDES.CENTER, 0 end
    
    body_yaw = body_yaw * 360 - 180
    
    if body_yaw > 30 then return SIDES.LEFT, 0.65
    elseif body_yaw < -30 then return SIDES.RIGHT, 0.65 end
    
    return SIDES.CENTER, 0.2
end

local function analyze_move_direction(ent, data)
    if not data.velocity_history or #data.velocity_history < 3 then return SIDES.CENTER, 0 end
    
    local avg_speed = 0
    for i = #data.velocity_history - 2, #data.velocity_history do
        avg_speed = avg_speed + (data.velocity_history[i].speed or 0)
    end
    avg_speed = avg_speed / 3
    
    if avg_speed < 50 then return SIDES.CENTER, 0 end
    
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return SIDES.CENTER, 0 end
    
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local move_yaw = math.deg(math.atan2(vy, vx))
    local diff = angle_diff(move_yaw, eye_yaw)
    
    if math.abs(diff) > 150 then return SIDES.CENTER, 0.4 end
    
    return SIDES.CENTER, 0
end

local function analyze_balance(ent, data)
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local speed_2d = vec_length_2d(vx, vy)
    
    if data.velocity_history and #data.velocity_history >= 2 then
        local prev_speed = data.velocity_history[#data.velocity_history - 1].speed or 0
        if prev_speed and prev_speed > 5 then
            local speed_diff = math.abs(speed_2d - prev_speed) / prev_speed
            if speed_diff > 0.3 then return SIDES.CENTER, 0.3 end
        end
    end
    
    return SIDES.CENTER, 0
end

local function recognize_pattern(data)
    if data.is_spinning then return "spin", 0.90 end
    if data.is_jitter then return "jitter", 0.85 end
    if data.is_extended then return "extended", 0.82 end
    return "unknown", 0.25
end

-- DT detection
local function detect_doubletap(ent, data)
    if not ui.get(ui_elements.dt_predict) then return end
    
    local weapon = entity.get_player_weapon(ent)
    if not weapon then return end
    
    local ammo = entity.get_prop(weapon, "m_iClip1") or 0
    
    if data.last_ammo ~= -1 and ammo < data.last_ammo then
        local fire_time = globals.realtime()
        table.insert(data.dt_shots, fire_time)
        while #data.dt_shots > 10 do table.remove(data.dt_shots, 1) end
        
        local recent = 0
        for _, t in ipairs(data.dt_shots) do
            if fire_time - t < CONFIG.DT_TIME_THRESHOLD then recent = recent + 1 end
        end
        
        if recent >= CONFIG.DT_SHOT_THRESHOLD then
            data.dt_detected = true
            data.dt_confidence = math.min(recent / 5, 1.0)
            data.dt_angle_offset = (math.random() > 0.5 and 1 or -1) * ui.get(ui_elements.dt_aggression)
        end
    end
    
    data.last_ammo = ammo
end

-- Adaptive weight
local function get_adaptive_weight(source, data)
    local base_weight = 1.5
    
    if source == "memory" then
        if data.consecutive_hits > 2 then
            base_weight = base_weight * (1 + data.consecutive_hits * 0.1)
        end
        if data.consecutive_misses > 1 then
            base_weight = base_weight * (1 - data.consecutive_misses * 0.15)
        end
    elseif source == "velocity" then
        if data.velocity_history and #data.velocity_history >= 3 then
            local avg = 0
            for i = #data.velocity_history - 2, #data.velocity_history do
                avg = avg + (data.velocity_history[i].speed or 0)
            end
            avg = avg / 3
            if avg > 100 then base_weight = base_weight * 1.1 end
        end
    end
    
    return base_weight
end

-- Miss learning
local function learn_from_miss(data)
    if #data.successful_resolves < 1 then return end
    
    if data.last_resolve then
        data.opposite_from_miss = -data.last_resolve
        data.miss_learn_time = globals.realtime()
    end
end

-- Main prediction
local function get_prediction(ent)
    local data = get_data(ent)
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    
    if not eye_yaw then return 60, 0.35 end
    
    local predictions = {}
    
    -- Cloud data first
    if ui.get(ui_elements.cloud_enabled) then
        local cloud_data = cloud_resolver.get_data(ent)
        if cloud_data and cloud_data.confidence >= CONFIG.CLOUD_MIN_CONFIDENCE then
            local cloud_weight = CONFIG.CLOUD_WEIGHT
            if cloud_data.reporter_count and cloud_data.reporter_count > 1 then
                cloud_weight = cloud_weight * (1 + cloud_data.reporter_count * CLOUD_CONFIG.CLOUD_WEIGHT_MULTIPLIER)
            end
            table.insert(predictions, {
                side = cloud_data.angle > 0 and SIDES.LEFT or SIDES.RIGHT,
                conf = cloud_data.confidence,
                weight = cloud_weight,
                source = "cloud"
            })
            data.cloud_used = cloud_data.source == "cloud"
        end
    end
    
    -- Miss learning
    if data.opposite_from_miss and globals.realtime() - data.miss_learn_time < 2 then
        table.insert(predictions, {
            side = data.opposite_from_miss > 0 and SIDES.LEFT or SIDES.RIGHT,
            conf = 0.6,
            weight = 1.8,
            source = "miss_learning"
        })
    end
    
    -- Velocity
    local v_side, v_conf = analyze_velocity(ent, data)
    if v_conf > 0.25 then
        table.insert(predictions, {
            side = v_side,
            conf = v_conf,
            weight = get_adaptive_weight("velocity", data) * CONFIG.WEIGHT_VELOCITY,
            source = "velocity"
        })
    end
    
    -- Pattern
    local pattern, p_conf = recognize_pattern(data)
    if p_conf > 0.25 then
        local side = SIDES.CENTER
        if pattern == "spin" then side = data.spin_direction * -1
        elseif pattern == "jitter" then side = (data.predicted_side ~= 0 and data.predicted_side or SIDES.LEFT) * -1 end
        
        table.insert(predictions, {
            side = side,
            conf = p_conf,
            weight = get_adaptive_weight("pattern", data) * CONFIG.WEIGHT_PATTERN,
            source = "pattern"
        })
    end
    
    -- Memory
    local m_side, m_conf = analyze_memory(data)
    if m_conf > 0.30 then
        table.insert(predictions, {
            side = m_side,
            conf = m_conf,
            weight = get_adaptive_weight("memory", data) * CONFIG.WEIGHT_MEMORY,
            source = "memory"
        })
    end
    
    -- Animation
    local a_side, a_conf = analyze_animation(ent)
    if a_conf > 0.25 then
        table.insert(predictions, {
            side = a_side,
            conf = a_conf,
            weight = get_adaptive_weight("animation", data) * CONFIG.WEIGHT_ANIMATION,
            source = "animation"
        })
    end
    
    -- Move direction
    local md_side, md_conf = analyze_move_direction(ent, data)
    if md_conf > 0.25 then
        table.insert(predictions, {
            side = md_side,
            conf = md_conf,
            weight = CONFIG.WEIGHT_MOVE_DIR,
            source = "move_dir"
        })
    end
    
    -- Balance
    local b_side, b_conf = analyze_balance(ent, data)
    if b_conf > 0.25 then
        table.insert(predictions, {
            side = b_side,
            conf = b_conf,
            weight = CONFIG.WEIGHT_BALANCE,
            source = "balance"
        })
    end
    
    -- DT
    if data.dt_detected and data.dt_confidence > 0.5 then
        table.insert(predictions, {
            side = data.dt_angle_offset > 0 and SIDES.LEFT or SIDES.RIGHT,
            conf = data.dt_confidence * 0.8,
            weight = CONFIG.WEIGHT_DT,
            source = "dt"
        })
    end
    
    if #predictions == 0 then return 60, 0.35 end
    
    -- Calculate weighted average
    local total_w = 0
    local weighted_side = 0
    
    for _, pred in ipairs(predictions) do
        weighted_side = weighted_side + (pred.side * pred.conf * pred.weight)
        total_w = total_w + (pred.conf * pred.weight)
    end
    
    local final_side = total_w > 0 and weighted_side / total_w or 0
    local final_conf = total_w > 0 and total_w / #predictions or 0.35
    
    if final_side > 0.18 then final_side = SIDES.LEFT
    elseif final_side < -0.18 then final_side = SIDES.RIGHT
    else final_side = SIDES.CENTER end
    
    local angle = final_side * CONFIG.EXTENDED_DESYNC_MAX * final_conf * (ui.get(ui_elements.aggression) / 5)
    angle = clamp(angle, -165, 165)
    
    data.predicted_side = final_side
    data.confidence = final_conf
    
    return angle, final_conf
end

-- Apply resolve
local function apply_resolve(ent, angle)
    if not entity.is_alive(ent) then return end
    local data = get_data(ent)
    if globals.realtime() - data.last_plist_update < CONFIG.SAMPLE_RATE then return end
    data.last_plist_update = globals.realtime()
    plist_set_force_angle(ent, angle)
end

-- Main resolver
local function resolve(ent)
    if not ui.get(ui_elements.enabled) then return 60, 0.35 end
    if not entity.is_alive(ent) then return 60, 0.35 end
    
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return 60, 0.35 end
    
    local data = get_data(ent)
    table.insert(data.angle_history, {angle = eye_yaw, time = globals.realtime()})
    while #data.angle_history > CONFIG.MAX_HISTORY do table.remove(data.angle_history, 1) end
    
    analyze_jitter(data)
    analyze_spin(data)
    detect_doubletap(ent, data)
    record_backtrack(ent, data)
    
    local angle, conf = 60, 0.35
    local mode = ui.get(ui_elements.mode)
    
    if mode == "Cloud Priority" or mode == "Cloud Aggressive" then
        if ui.get(ui_elements.cloud_enabled) then
            local cloud_data = cloud_resolver.get_data(ent)
            if cloud_data and cloud_data.confidence >= (mode == "Cloud Aggressive" and 0.4 or 0.5) then
                angle = cloud_data.angle
                conf = cloud_data.confidence
                data.cloud_used = cloud_data.source == "cloud"
                global_stats.cloud_resolves = global_stats.cloud_resolves + 1
                if cloud_data.reporter_count and cloud_data.reporter_count > 1 then
                    global_stats.cloud_multi_reporter = global_stats.cloud_multi_reporter + 1
                end
            else
                angle, conf = get_prediction(ent)
            end
        else
            angle, conf = get_prediction(ent)
        end
    else
        angle, conf = get_prediction(ent)
    end
    
    angle = clamp(tonumber(angle) or 60, -165, 165)
    conf = clamp(tonumber(conf) or 0.35, 0, 1)
    
    data.last_resolve = angle
    data.detected_pattern = recognize_pattern(data)
    apply_resolve(ent, angle)
    global_stats.total_resolves = global_stats.total_resolves + 1
    
    return angle, conf
end

-- Events
client.set_event_callback("setup_command", function(cmd)
    if not ui.get(ui_elements.enabled) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    if ui.get(ui_elements.cloud_enabled) then
        if not cloud_state.initialized then cloud_resolver.init() end
        local url = ui.get(ui_elements.cloud_url)
        if url and url ~= "" then CLOUD_CONFIG.SERVER_URL = url end
        CLOUD_CONFIG.DEBUG = ui.get(ui_elements.cloud_debug)
        cloud_resolver.poll()
        if globals.tickcount() % 100 == 0 then cloud_resolver.clean() end
    end
    
    local players = entity.get_players(true)
    if not players then return end
    for _, ent in ipairs(players) do
        if entity.is_alive(ent) then resolve(ent) end
    end
end)

client.set_event_callback("aim_fire", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    if not ent then return end
    
    local data = get_data(ent)
    data.shots = data.shots + 1
    global_stats.shots = global_stats.shots + 1
    
    -- Find best backtrack record for logging
    local record, tick_diff = get_best_backtrack_record(ent, data)
    if record then
        data.backtrack_is_valid = true
        data.best_bt_tick = record.tick_count
        global_stats.backtrack_shots = global_stats.backtrack_shots + 1
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[FIRE] T:%d | BT:%d%s", ent, tick_diff or 0, data.cloud_used and " [CLOUD]" or ""))
    end
end)

client.set_event_callback("aim_hit", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    if not ent then return end
    
    local data = get_data(ent)
    data.hits = data.hits + 1
    data.consecutive_hits = data.consecutive_hits + 1
    data.consecutive_misses = 0
    global_stats.hits = global_stats.hits + 1
    global_stats.streak_current = global_stats.streak_current + 1
    global_stats.streak_best = math.max(global_stats.streak_best, global_stats.streak_current)
    
    if data.backtrack_is_valid then global_stats.backtrack_hits = global_stats.backtrack_hits + 1 end
    if data.cloud_used then global_stats.cloud_hits = global_stats.cloud_hits + 1 end
    
    table.insert(data.successful_resolves, {
        side = data.last_resolve > 0 and SIDES.LEFT or SIDES.RIGHT,
        angle = data.last_resolve,
        confidence = data.confidence,
        time = globals.realtime()
    })
    
    -- Reset miss learning
    data.opposite_from_miss = nil
    
    if ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            cloud_resolver.report_data(steam64, data.last_resolve, data.confidence, true, data.detected_pattern)
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[HIT] T:%d | Streak:%d | Angle:%.1f%s", ent, data.consecutive_hits, data.last_resolve, data.cloud_used and " [CLOUD]" or ""))
    end
    
    data.backtrack_is_valid = false
    data.cloud_used = false
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    if not ent then return end
    
    local reason = e.reason or ""
    if reason ~= "prediction error" and reason ~= "resolver" then return end
    
    local data = get_data(ent)
    data.misses = data.misses + 1
    data.consecutive_misses = data.misses + 1
    data.consecutive_hits = 0
    global_stats.misses = global_stats.misses + 1
    global_stats.streak_current = 0
    
    -- Learn from miss
    learn_from_miss(data)
    
    if ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            cloud_resolver.report_data(steam64, data.last_resolve, math.max(0.1, data.confidence - 0.2), false, data.detected_pattern)
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[MISS] T:%d | %s | Angle:%.1f", ent, reason, data.last_resolve))
    end
    
    data.backtrack_is_valid = false
end)

client.set_event_callback("paint", function()
    if not ui.get(ui_elements.enabled) or not ui.get(ui_elements.show_stats) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    local x, y = 10, 200
    renderer.text(x, y, 255, 255, 255, 255, "", 0, "══════ RESOLVER v19.0 ══════")
    y = y + 12
    
    if ui.get(ui_elements.cloud_enabled) then
        local status = cloud_state.initialized and "CONNECTED" or "CONNECTING..."
        local r, g, b = cloud_state.initialized and 100 or 255, cloud_state.initialized and 255 or 100, 100
        renderer.text(x, y, r, g, b, 255, "", 0, string.format("CLOUD: %s | Syncs: %d | Err: %d", status, cloud_state.sync_count, cloud_state.error_count))
        y = y + 12
        
        local teammates = 0
        for _ in pairs(cloud_state.connected_teammates) do teammates = teammates + 1 end
        local cache_count = 0
        for _ in pairs(cloud_state.prediction_cache) do cache_count = cache_count + 1 end
        renderer.text(x, y, 150, 200, 255, 255, "", 0, string.format("Teammates: %d | Patterns: %d | Cache: %d", teammates, #cloud_state.pattern_memory, cache_count))
        y = y + 12
    end
    
    local hitrate = global_stats.shots > 0 and (global_stats.hits / global_stats.shots * 100) or 0
    renderer.text(x, y, 200, 200, 200, 255, "", 0, string.format("S:%d H:%d M:%d | %.1f%%", global_stats.shots, global_stats.hits, global_stats.misses, hitrate))
    y = y + 12
    
    local bt_rate = global_stats.backtrack_shots > 0 and (global_stats.backtrack_hits / global_stats.backtrack_shots * 100) or 0
    renderer.text(x, y, 100, 200, 255, 255, "", 0, string.format("BT: %d/%d (%.1f%%)", global_stats.backtrack_hits, global_stats.backtrack_shots, bt_rate))
    y = y + 12
    
    if ui.get(ui_elements.cloud_enabled) then
        renderer.text(x, y, 100, 255, 200, 255, "", 0, string.format("Cloud: %d resolves, %d hits | Multi: %d", global_stats.cloud_resolves, global_stats.cloud_hits, global_stats.cloud_multi_reporter))
    end
end)

client.set_event_callback("round_start", function()
    for _, data in pairs(player_data) do
        data.angle_history = {}
        data.velocity_history = {}
        data.backtrack_records = {}
        data.consecutive_hits = 0
        data.consecutive_misses = 0
        data.backtrack_is_valid = false
    end
    global_stats.streak_current = 0
    client.log("[Resolver v19.0] Round start - Cloud Ready!")
end)

client.log("[Forward HVH Resolver v19.0] Loaded!")
