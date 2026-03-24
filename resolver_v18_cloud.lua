--[[
    FORWARD HVH RESOLVER v18.4 - CLOUD SYNC ENHANCED
    Professional resolver with advanced cloud-based data sharing between teammates
    
    v18.4 Cloud Improvements:
    - Multi-reporter aggregation (weighted average from multiple teammates)
    - Retry mechanism with exponential backoff
    - Team validation (only accept data from same team)
    - Pattern learning & sharing
    - Confidence boosting based on reporter count
    - Latency compensation
    - Anti-spam protection
    - Data validation & sanity checks
    
    v18.x Features:
    - Full Backtrack Exploit with LC break detection
    - Cubic Hermite Interpolation
    - Catmull-Rom Spline Interpolation  
    - Physics Extrapolation (ground + air)
    - Air Trajectory Prediction
    - DT Prediction
    
    by Super Z
]]

-- ============== HTTP MODULE ==============
local http = require("gamesense/http")

-- ============== CLOUD RESOLVER MODULE ==============

local cloud_resolver = {}

local CLOUD_CONFIG = {
    SERVER_URL = "https://cloud-resolver-for-gamesense-csgo.onrender.com/api",
    POLL_INTERVAL = 1.5,           -- Faster polling
    DATA_TIMEOUT = 45.0,           -- Faster data expiration
    MIN_CONFIDENCE = 0.4,          -- Lower threshold to use cloud data
    DEBUG = true,
    
    -- Enhanced features
    MAX_RETRY = 3,
    RETRY_DELAY = 0.5,
    MAX_REPORTERS = 5,             -- Max reporters to aggregate
    CONFIDENCE_BOOST = 0.15,       -- Boost per additional reporter
    SAME_TEAM_ONLY = true,         -- Only accept data from same team
    ANTI_SPAM_INTERVAL = 0.3,      -- Min time between reports
    LATENCY_COMPENSATION = 0.1,    -- Compensate for network latency
    DATA_VALIDATION = true,        -- Validate incoming data
    PATTERN_LEARNING = true,       -- Learn patterns from successful hits
}

local cloud_state = {
    initialized = false,
    my_steamid = nil,
    my_steam64 = nil,
    my_team = nil,
    last_poll = 0,
    cloud_data = {},               -- [steam64] = {reports={}, aggregated_angle, aggregated_conf, ...}
    sync_count = 0,
    error_count = 0,
    last_error = nil,
    retry_count = 0,
    pending_reports = {},          -- Queue of pending reports
    last_report_time = 0,
    connected_teammates = {},      -- Track connected teammates
    pattern_memory = {},           -- Learned patterns per player
    local_hits = {},               -- Track local hits for pattern learning
    server_latency = 0,
    last_ping_time = 0,
}

-- JSON Parser
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

local function clamp_val(v, min, max)
    if type(v) ~= "number" then return min end
    return math.max(min, math.min(max, v))
end

-- ============== DATA VALIDATION ==============

local function validate_report(report)
    if not report then return false end
    if not report.reporter_steamid or not report.enemy_steam64 then return false end
    local angle = tonumber(report.angle)
    if not angle or math.abs(angle) > 180 then return false end
    local conf = tonumber(report.confidence)
    if not conf or conf < 0 or conf > 1 then return false end
    return true
end

-- ============== AGGREGATION ==============

local function aggregate_reports(reports, my_steamid)
    if not reports or #reports == 0 then return nil, 0 end
    
    local valid_reports = {}
    for _, r in ipairs(reports) do
        if r.reporter ~= my_steamid and validate_report(r) then
            table.insert(valid_reports, r)
        end
    end
    
    if #valid_reports == 0 then return nil, 0 end
    
    table.sort(valid_reports, function(a, b)
        if a.confidence ~= b.confidence then return a.confidence > b.confidence end
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    local max_reporters = math.min(#valid_reports, CLOUD_CONFIG.MAX_REPORTERS)
    local total_weight, weighted_angle = 0, 0
    local side_votes = {left = 0, right = 0}
    
    for i = 1, max_reporters do
        local r = valid_reports[i]
        local weight = r.confidence or 0.5
        if r.hit then weight = weight * 1.5 end
        local age = globals.realtime() - (r.timestamp or 0)
        weight = weight * math.max(0.5, 1 - age / CLOUD_CONFIG.DATA_TIMEOUT)
        total_weight = total_weight + weight
        weighted_angle = weighted_angle + (r.angle or 60) * weight
        if (r.angle or 0) > 0 then side_votes.left = side_votes.left + weight
        else side_votes.right = side_votes.right + weight end
    end
    
    if total_weight == 0 then return nil, 0 end
    
    local final_angle = weighted_angle / total_weight
    local base_conf = total_weight / max_reporters
    local total_votes = side_votes.left + side_votes.right
    local agreement = math.max(side_votes.left, side_votes.right) / total_votes
    local reporter_boost = (max_reporters - 1) * CLOUD_CONFIG.CONFIDENCE_BOOST
    local final_conf = clamp_val(base_conf + agreement * 0.2 + reporter_boost, 0, 1)
    
    return final_angle, final_conf, max_reporters
end

-- ============== TEAM VALIDATION ==============

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
                    ent = ent, name = entity.get_player_name(ent) or "Unknown", last_seen = globals.realtime()
                }
            end
        end
    end
end

-- ============== PATTERN LEARNING ==============

local function update_pattern_memory(enemy_steam64, angle, hit, pattern)
    if not CLOUD_CONFIG.PATTERN_LEARNING then return end
    local key = tostring(enemy_steam64)
    if not cloud_state.pattern_memory[key] then
        cloud_state.pattern_memory[key] = {patterns = {}, best_angle = 60, best_confidence = 0, total_reports = 0, hits = 0}
    end
    local mem = cloud_state.pattern_memory[key]
    mem.total_reports = mem.total_reports + 1
    if hit then
        mem.hits = mem.hits + 1
        if mem.best_confidence < 0.7 then
            mem.best_angle = angle
            mem.best_confidence = mem.hits / mem.total_reports
        end
        if pattern and pattern ~= "unknown" then
            if not mem.patterns[pattern] then mem.patterns[pattern] = {count = 0, avg_angle = 0, hits = 0} end
            local p = mem.patterns[pattern]
            p.count = p.count + 1
            p.hits = p.hits + 1
            p.avg_angle = (p.avg_angle * (p.count - 1) + angle) / p.count
        end
    end
end

local function get_pattern_prediction(enemy_steam64)
    local mem = cloud_state.pattern_memory[tostring(enemy_steam64)]
    if not mem or mem.total_reports < 3 then return nil, 0 end
    if mem.best_confidence > 0.6 then return mem.best_angle, mem.best_confidence * 0.8 end
    local best_pattern, best_rate = nil, 0
    for _, p in pairs(mem.patterns) do
        local hit_rate = p.hits / p.count
        if hit_rate > best_rate then best_rate = hit_rate; best_pattern = p end
    end
    if best_pattern and best_rate > 0.5 then return best_pattern.avg_angle, best_rate * 0.7 end
    return nil, 0
end

-- ============== HTTP WITH RETRY ==============

local function http_post_with_retry(url, payload, callback, retry_count)
    retry_count = retry_count or 0
    http.post(url, {body = payload, headers = {["Content-Type"] = "application/json"}}, function(success, response)
        if not success then
            if retry_count < CLOUD_CONFIG.MAX_RETRY then
                client.delay_call(CLOUD_CONFIG.RETRY_DELAY * math.pow(2, retry_count), function()
                    http_post_with_retry(url, payload, callback, retry_count + 1)
                end)
            else
                cloud_state.error_count = cloud_state.error_count + 1
                cloud_state.last_error = "POST failed"
                callback(false)
            end
            return
        end
        if response and response.status and response.status == 503 then
            if retry_count < CLOUD_CONFIG.MAX_RETRY then
                client.delay_call(5, function()
                    http_post_with_retry(url, payload, callback, retry_count + 1)
                end)
            else callback(false) end
            return
        end
        if response and response.status and response.status ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP " .. tostring(response.status)
            callback(false)
            return
        end
        callback(true)
    end)
end

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
        client.log("[Cloud Resolver v18.4] Initialized: " .. cloud_state.my_steamid)
    end
    return true
end

function cloud_resolver.report_data(enemy_steam64, angle, confidence, hit, pattern)
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return false end
    end
    
    if not enemy_steam64 or enemy_steam64 == 0 then return false end
    
    -- Anti-spam check
    local now = globals.realtime()
    if now - cloud_state.last_report_time < CLOUD_CONFIG.ANTI_SPAM_INTERVAL then
        return false
    end
    cloud_state.last_report_time = now
    
    -- Update pattern memory
    update_pattern_memory(enemy_steam64, angle, hit, pattern)
    
    angle = clamp_val(tonumber(angle) or 60, -180, 180)
    confidence = clamp_val(tonumber(confidence) or 0.5, 0, 1)
    
    local payload = json.encode({
        reporter_steamid = cloud_state.my_steamid,
        enemy_steam64 = tostring(enemy_steam64),
        angle = angle,
        confidence = confidence,
        hit = hit or false,
        pattern = pattern or "unknown",
        timestamp = now,
        team = cloud_state.my_team
    })
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/update"
    
    http_post_with_retry(url, payload, function(success)
        if success then
            cloud_state.sync_count = cloud_state.sync_count + 1
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver v18.4] Synced: angle=" .. string.format("%.1f", angle))
            end
        end
    end)
    
    return true
end

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
        
        for steam64, entry in pairs(decoded) do
            if steam64 ~= cloud_state.my_steamid then
                -- Initialize if needed
                if not cloud_state.cloud_data[steam64] then
                    cloud_state.cloud_data[steam64] = {
                        reports = {},
                        aggregated_angle = nil,
                        aggregated_conf = 0,
                        last_update = 0
                    }
                end
                
                local cd = cloud_state.cloud_data[steam64]
                
                -- Add report (single report format)
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
                
                -- Trim old reports
                while #cd.reports > 20 do table.remove(cd.reports, 1) end
                
                -- Aggregate reports
                local agg_angle, agg_conf, reporter_count = aggregate_reports(cd.reports, cloud_state.my_steamid)
                
                if agg_angle then
                    cd.aggregated_angle = agg_angle
                    cd.aggregated_conf = agg_conf
                    cd.reporter_count = reporter_count
                    cd.last_update = current_time
                end
            end
        end
        
        if CLOUD_CONFIG.DEBUG then
            local count = 0
            for _ in pairs(cloud_state.cloud_data) do count = count + 1 end
            if count > 0 then
                client.log("[Cloud Resolver v18.4] Updated: " .. count .. " players")
            end
        end
    end)
end

function cloud_resolver.get_data(enemy)
    if not cloud_state.initialized then return nil end
    
    local steam64 = entity.get_steam64(enemy)
    if not steam64 or steam64 == 0 then return nil end
    
    local key = tostring(steam64)
    local data = cloud_state.cloud_data[key]
    
    -- Try pattern prediction as fallback
    if not data or not data.aggregated_angle then
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
    
    -- Check data age
    local age = globals.realtime() - (data.last_update or 0)
    if age > CLOUD_CONFIG.DATA_TIMEOUT then
        cloud_state.cloud_data[key] = nil
        return nil
    end
    
    if (data.aggregated_conf or 0) < CLOUD_CONFIG.MIN_CONFIDENCE then return nil end
    
    -- Combine with pattern prediction
    local pattern_angle, pattern_conf = get_pattern_prediction(steam64)
    local final_angle = data.aggregated_angle
    local final_conf = data.aggregated_conf
    
    if pattern_angle and pattern_conf > 0.5 then
        local cloud_weight = final_conf
        local pattern_weight = pattern_conf * 0.5
        local total_weight = cloud_weight + pattern_weight
        if total_weight > 0 then
            final_angle = (final_angle * cloud_weight + pattern_angle * pattern_weight) / total_weight
            final_conf = math.min(1, final_conf + pattern_conf * 0.1)
        end
    end
    
    return {
        angle = final_angle,
        confidence = final_conf,
        pattern = data.pattern,
        hit = data.hit,
        age = age,
        reporter_count = data.reporter_count or 1,
        source = "cloud"
    }
end

function cloud_resolver.get_status()
    return {
        initialized = cloud_state.initialized,
        steamid = cloud_state.my_steamid,
        sync_count = cloud_state.sync_count,
        error_count = cloud_state.error_count,
        last_error = cloud_state.last_error
    }
end

function cloud_resolver.clean()
    local current_time = globals.realtime()
    for steam64, data in pairs(cloud_state.cloud_data) do
        if current_time - (data.timestamp or 0) > CLOUD_CONFIG.DATA_TIMEOUT then
            cloud_state.cloud_data[steam64] = nil
        end
    end
end

client.log("[Cloud Resolver] HTTP module loaded!")

-- ============== MAIN RESOLVER ==============

local CONFIG = {
    MAX_HISTORY = 200,
    MAX_ANGLES = 100,
    MAX_VELOCITY = 120,
    PREDICTION_DECAY = 0.90,
    CONFIDENCE_THRESHOLD = 0.20,
    JITTER_THRESHOLD = 18,
    SPIN_THRESHOLD = 75,
    EXTENDED_DESYNC_THRESHOLD = 48,
    DESYNC_MAX = 60,
    EXTENDED_DESYNC_MAX = 120,
    POSE_BODY_YAW = 11,
    POSE_BODY_PITCH = 12,
    SAMPLE_RATE = 0.012,
    DT_TIME_THRESHOLD = 0.22,
    DT_SHOT_THRESHOLD = 2,
    MEMORY_DECAY_TIME = 45,
    MIN_SAMPLES_FOR_PREDICT = 3,
    
    -- Backtrack Configuration
    BACKTRACK_MAX_TICKS = 40,
    BACKTRACK_HISTORY_SIZE = 65,
    TICK_INTERVAL = 0.015625,
    
    -- Interpolation Configuration
    INTERPOLATION_ENABLED = true,
    CUBIC_INTERPOLATION = true,
    CATMULL_ROM_SPLINE = true,
    INTERPOLATION_STEPS = 4,
    
    -- Extrapolation Configuration
    EXTRAPOLATION_ENABLED = true,
    MAX_EXTRAPOLATION_TICKS = 8,
    GRAVITY = 800,
    AIR_ACCELERATION = 1000,
    GROUND_FRICTION = 4,
    STOP_SPEED = 100,
    VELOCITY_DAMPING = 0.85,
    ACCELERATION_SMOOTHING = 0.3,
    
    -- Prediction Weights
    WEIGHT_DISTANCE = 1.0,
    WEIGHT_VELOCITY = 0.85,
    WEIGHT_LC_BREAK = 2.0,
    WEIGHT_INTERPOLATED = 1.2,
    WEIGHT_EXTRAPOLATED = 0.9,
    WEIGHT_PREDICTION_CONF = 1.1,
    
    -- Cloud Resolver Weights
    CLOUD_WEIGHT = 2.5,
    CLOUD_MIN_CONFIDENCE = 0.5
}

local function create_stats()
    return {
        shots = 0, hits = 0, misses = 0,
        resolved = 0, bruteforced = 0,
        headshots = 0, bodyshots = 0,
        streak_best = 0, streak_current = 0,
        prediction_accuracy = 0,
        extended_hits = 0, spin_hits = 0, jitter_hits = 0,
        adaptive_hits = 0, memory_hits = 0,
        total_resolves = 0,
        backtrack_shots = 0,
        backtrack_hits = 0,
        backtrack_ticks_used = 0,
        backtrack_avg_tick = 0,
        backtrack_lc_breaks = 0,
        backtrack_interpolated_hits = 0,
        backtrack_extrapolated_hits = 0,
        backtrack_cubic_hits = 0,
        backtrack_spline_hits = 0,
        backtrack_air_pred_hits = 0,
        backtrack_avg_score = 0,
        backtrack_best_score = 0,
        interpolation_accuracy = 0,
        extrapolation_accuracy = 0,
        cloud_resolves = 0,
        cloud_hits = 0,
        cloud_syncs = 0
    }
end

local function create_player_data()
    return {
        -- History
        angle_history = {},
        velocity_history = {},
        shot_history = {},
        resolve_history = {},
        backtrack_records = {},
        
        -- State
        bf_index = 1,
        bf_stage = 1,
        bf_angle = 60,
        predicted_side = 0,
        predicted_angle = 60,
        confidence = 0.35,
        last_resolve = 60,
        force_angle = 60,
        best_angle = 60,
        
        -- Analysis
        jitter_score = 0,
        jitter_amplitude = 0,
        jitter_phase = 0,
        spin_speed = 0,
        spin_direction = 0,
        spin_variance = 0,
        desync_amount = 60,
        extended_desync_amount = 0,
        bodyyaw_side = 0,
        freestand_side = 0,
        avg_angle_change = 0,
        angle_variance = 0,
        velocity_variance = 0,
        
        -- Pose
        pose_body_yaw = 0,
        pose_body_yaw_angle = 0,
        pose_body_pitch = 0,
        roll_angle = 0,
        
        -- Pattern
        detected_pattern = "unknown",
        pattern_confidence = 0,
        
        -- Statistics
        shots = 0,
        hits = 0,
        misses = 0,
        consecutive_hits = 0,
        consecutive_misses = 0,
        last_hit_angle = 0,
        successful_resolves = {},
        hit_angles = {},
        miss_angles = {},
        angle_success_rate = {},
        
        -- Learning
        learned_side = 0,
        learned_confidence = 0,
        side_weights = { left = 0, right = 0, center = 0 },
        pattern_memory = {},
        best_tick_history = {},
        
        -- DT
        dt_shots = {},
        dt_detected = false,
        dt_confidence = 0,
        dt_angle_offset = 0,
        dt_predicted_side = 0,
        dt_firing_speed = 0,
        last_ammo = -1,
        
        -- Backtrack State
        backtrack_best_tick = 0,
        backtrack_last_tick = 0,
        backtrack_sim_time = 0,
        backtrack_origin = { x = 0, y = 0, z = 0 },
        backtrack_angles = { pitch = 0, yaw = 0 },
        backtrack_velocity = { x = 0, y = 0, z = 0 },
        backtrack_is_valid = false,
        backtrack_score = 0,
        backtrack_is_interpolated = false,
        backtrack_is_extrapolated = false,
        backtrack_is_cubic = false,
        backtrack_is_spline = false,
        backtrack_interp_factor = 0,
        
        -- Interpolation & Extrapolation State
        prev_origin = { x = 0, y = 0, z = 0 },
        prev_velocity = { x = 0, y = 0, z = 0 },
        prev_prev_origin = { x = 0, y = 0, z = 0 },
        prev_prev_velocity = { x = 0, y = 0, z = 0 },
        acceleration = { x = 0, y = 0, z = 0 },
        prev_acceleration = { x = 0, y = 0, z = 0 },
        avg_acceleration = { x = 0, y = 0, z = 0 },
        velocity_delta = 0,
        origin_delta = 0,
        prev_sim_time = 0,
        
        -- Ground & Air State
        is_on_ground = true,
        was_on_ground = true,
        ground_entity = -1,
        fall_velocity = 0,
        jump_time = 0,
        
        -- Movement Prediction
        predicted_origin = { x = 0, y = 0, z = 0 },
        predicted_velocity = { x = 0, y = 0, z = 0 },
        predicted_head_pos = { x = 0, y = 0, z = 0 },
        extrapolation_confidence = 0,
        
        -- Choke Analysis
        choke_pattern = {},
        avg_choke = 0,
        last_choke = 0,
        is_choking = false,
        
        -- LC Break
        lc_break_detected = false,
        
        -- Cloud Resolver State
        cloud_angle = nil,
        cloud_confidence = nil,
        cloud_last_update = 0,
        cloud_used = false,
        
        -- Flags
        is_jitter = false,
        is_freestanding = false,
        is_moving = false,
        is_resolved = false,
        is_spinning = false,
        is_extended = false,
        is_fakewalking = false,
        is_micro_moving = false,
        is_breaking_lc = false,
        is_scoped = false,
        is_crouching = false,
        is_air = false,
        has_roll = false,
        
        -- Timing
        last_plist_update = 0,
        last_update = 0,
        last_shot_time = 0,
        last_record_time = 0,
        
        -- BF State
        bf_state = {
            stage = 1,
            direction = 1,
            smart_mode = false,
            last_angles = {},
            successful_patterns = {}
        }
    }
end

-- ============== UI ==============

local ui_elements = {
    enabled = ui.new_checkbox("RAGE", "Other", "Enable Resolver"),
    
    mode = ui.new_combobox("RAGE", "Other", "Resolver Mode", {
        "Cloud Priority", 
        "Adaptive Pro", 
        "Deep Memory",
        "Animation+",
        "Extended+",
        "Smart BF",
        "Anti-Everything"
    }),
    
    -- Cloud Resolver UI
    cloud_label = ui.new_label("RAGE", "Other", "━━━ Cloud Resolver ━━━"),
    cloud_enabled = ui.new_checkbox("RAGE", "Other", "Enable Cloud Sync"),
    cloud_url = ui.new_textbox("RAGE", "Other", "Server URL"),
    cloud_debug = ui.new_checkbox("RAGE", "Other", "Cloud Debug"),
    cloud_test = ui.new_button("RAGE", "Other", "Test Connection", function()
        if cloud_state.initialized then
            client.log("[Cloud Resolver] SteamID: " .. tostring(cloud_state.my_steamid))
            client.log("[Cloud Resolver] Syncs: " .. cloud_state.sync_count)
            client.log("[Cloud Resolver] Errors: " .. cloud_state.error_count)
        else
            client.log("[Cloud Resolver] Not initialized - join a server first!")
        end
    end),
    
    bf_label = ui.new_label("RAGE", "Other", "━━━ Bruteforce ━━━"),
    bf_mode = ui.new_combobox("RAGE", "Other", "BF Strategy", {
        "Smart Adaptive", 
        "Multi-Stage Pro",
        "Memory Based",
        "Anti-Jitter",
        "Anti-Spin",
        "Extended"
    }),
    bf_delay = ui.new_slider("RAGE", "Other", "BF Delay", 0, 5, 1, true, "shots"),
    bf_smart = ui.new_checkbox("RAGE", "Other", "Smart Angle Selection"),
    
    -- Backtrack UI
    bt_label = ui.new_label("RAGE", "Other", "━━━ Backtrack (Always ON) ━━━"),
    bt_ticks = ui.new_slider("RAGE", "Other", "Max Ticks", 14, 40, 40, true, "ticks"),
    bt_visualize = ui.new_checkbox("RAGE", "Other", "Visualize History"),
    
    -- Interpolation & Extrapolation UI
    ie_label = ui.new_label("RAGE", "Other", "━━━ Interpolation & Extrapolation ━━━"),
    ie_interpolation = ui.new_checkbox("RAGE", "Other", "Cubic Interpolation"),
    ie_spline = ui.new_checkbox("RAGE", "Other", "Catmull-Rom Spline"),
    ie_extrapolation = ui.new_checkbox("RAGE", "Other", "Physics Extrapolation"),
    ie_air_pred = ui.new_checkbox("RAGE", "Other", "Air Trajectory Prediction"),
    ie_subticks = ui.new_slider("RAGE", "Other", "Sub-tick Resolution", 1, 8, 4, true, "steps"),
    ie_extrapolation_ticks = ui.new_slider("RAGE", "Other", "Max Extrapolation", 1, 12, 6, true, "ticks"),
    
    dt_label = ui.new_label("RAGE", "Other", "━━━ Double Tap ━━━"),
    dt_predict = ui.new_checkbox("RAGE", "Other", "DT Prediction"),
    dt_aggression = ui.new_slider("RAGE", "Other", "DT Angle Shift", 0, 30, 15, true, "°"),
    
    adv_label = ui.new_label("RAGE", "Other", "━━━ Settings ━━━"),
    aggression = ui.new_slider("RAGE", "Other", "Aggression", 1, 10, 7, true, "lvl"),
    confidence_min = ui.new_slider("RAGE", "Other", "Min Confidence", 10, 50, 20, true, "%"),
    
    debug_label = ui.new_label("RAGE", "Other", "━━━ Debug ━━━"),
    show_stats = ui.new_checkbox("RAGE", "Other", "Show Statistics"),
    log_hits = ui.new_checkbox("RAGE", "Other", "Log Hits/Misses"),
    
    reset_btn = ui.new_button("RAGE", "Other", "Reset All Data", function()
        player_data = {}
        global_stats = create_stats()
        cloud_state.cloud_data = {}
        client.log("[Resolver v18.3] Data reset")
    end)
}

-- Enable by default
ui.set(ui_elements.dt_predict, true)
ui.set(ui_elements.show_stats, true)
ui.set(ui_elements.bf_smart, true)
ui.set(ui_elements.ie_interpolation, true)
ui.set(ui_elements.ie_spline, true)
ui.set(ui_elements.ie_extrapolation, true)
ui.set(ui_elements.ie_air_pred, true)
ui.set(ui_elements.cloud_enabled, true)
ui.set(ui_elements.cloud_url, "https://cloud-resolver-for-gamesense-csgo.onrender.com/api")

local global_stats = create_stats()
local player_data = {}

-- ============== CONSTANTS ==============

local SIDES = { LEFT = -1, CENTER = 0, RIGHT = 1 }

local BF_PATTERNS = {
    Smart_Adaptive = { 
        { angle = 60, weight = 1.0 }, { angle = -60, weight = 1.0 },
        { angle = 58, weight = 0.9 }, { angle = -58, weight = 0.9 },
        { angle = 90, weight = 0.85 }, { angle = -90, weight = 0.85 },
        { angle = 45, weight = 0.8 }, { angle = -45, weight = 0.8 },
        { angle = 120, weight = 0.75 }, { angle = -120, weight = 0.75 }
    },
    Multi_Stage_Pro = {
        { 60, -60, 58, -58, 0 },
        { 90, -90, 75, -75, 105, -105 },
        { 120, -120, 135, -135, 150, -150 },
        { 45, -45, 30, -30, 52, -52 },
        { 165, -165, 150, -150, 175, -175 }
    },
    Anti_Jitter = { 58, -58, 62, -62, 55, -55, 65, -65 },
    Anti_Spin = { 90, -90, 0, 180, 60, -60, 120, -120 },
    Extended = { 90, -90, 120, -120, 150, -150, 165, -165 }
}

-- ============== UTILITIES ==============

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

local function get_data(ent)
    if not player_data[ent] then
        player_data[ent] = create_player_data()
    end
    return player_data[ent]
end

local function lerp(a, b, t)
    return a + (b - a) * clamp(t, 0, 1)
end

local function vec_length(x, y, z)
    return math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2)
end

local function vec_distance(x1, y1, z1, x2, y2, z2)
    local dx = (x1 or 0) - (x2 or 0)
    local dy = (y1 or 0) - (y2 or 0)
    local dz = (z1 or 0) - (z2 or 0)
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function vec_length_2d(x, y)
    return math.sqrt((x or 0)^2 + (y or 0)^2)
end

local function time_to_ticks(t)
    return math.floor(t / CONFIG.TICK_INTERVAL + 0.5)
end

local function ticks_to_time(ticks)
    return ticks * CONFIG.TICK_INTERVAL
end

-- ============== ADVANCED INTERPOLATION FUNCTIONS ==============

local function hermite_basis_00(t)
    return 2*t*t*t - 3*t*t + 1
end

local function hermite_basis_10(t)
    return t*t*t - 2*t*t + t
end

local function hermite_basis_01(t)
    return -2*t*t*t + 3*t*t
end

local function hermite_basis_11(t)
    return t*t*t - t*t
end

local function cubic_hermite_interp(p0, p1, m0, m1, t)
    t = clamp(t, 0, 1)
    return hermite_basis_00(t) * p0 + 
           hermite_basis_10(t) * m0 + 
           hermite_basis_01(t) * p1 + 
           hermite_basis_11(t) * m1
end

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

local function interpolate_position_cubic(rec1, rec2, t, dt)
    dt = dt or CONFIG.TICK_INTERVAL
    
    local m0x = rec1.velocity.x * dt
    local m0y = rec1.velocity.y * dt
    local m0z = rec1.velocity.z * dt
    
    local m1x = rec2.velocity.x * dt
    local m1y = rec2.velocity.y * dt
    local m1z = rec2.velocity.z * dt
    
    return {
        x = cubic_hermite_interp(rec1.origin.x, rec2.origin.x, m0x, m1x, t),
        y = cubic_hermite_interp(rec1.origin.y, rec2.origin.y, m0y, m1y, t),
        z = cubic_hermite_interp(rec1.origin.z, rec2.origin.z, m0z, m1z, t)
    }
end

local function interpolate_position_spline(rec_prev, rec0, rec1, rec_next, t)
    return {
        x = catmull_rom_spline(rec_prev.origin.x, rec0.origin.x, rec1.origin.x, rec_next.origin.x, t),
        y = catmull_rom_spline(rec_prev.origin.y, rec0.origin.y, rec1.origin.y, rec_next.origin.y, t),
        z = catmull_rom_spline(rec_prev.origin.z, rec0.origin.z, rec1.origin.z, rec_next.origin.z, t)
    }
end

-- ============== ADVANCED EXTRAPOLATION FUNCTIONS ==============

local function is_on_ground(ent, data)
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local on_ground = bit.band(flags, 1) ~= 0
    
    data.was_on_ground = data.is_on_ground
    data.is_on_ground = on_ground
    
    return on_ground
end

local function calculate_acceleration(data, vel_x, vel_y, vel_z, dt)
    dt = dt or CONFIG.TICK_INTERVAL
    if dt <= 0 then return data.acceleration end
    
    local new_acc = {
        x = (vel_x - data.prev_velocity.x) / dt,
        y = (vel_y - data.prev_velocity.y) / dt,
        z = (vel_z - data.prev_velocity.z) / dt
    }
    
    data.prev_acceleration = { x = data.acceleration.x, y = data.acceleration.y, z = data.acceleration.z }
    data.acceleration = {
        x = lerp(data.acceleration.x, new_acc.x, CONFIG.ACCELERATION_SMOOTHING),
        y = lerp(data.acceleration.y, new_acc.y, CONFIG.ACCELERATION_SMOOTHING),
        z = lerp(data.acceleration.z, new_acc.z, CONFIG.ACCELERATION_SMOOTHING)
    }
    
    data.avg_acceleration = {
        x = (data.acceleration.x + data.prev_acceleration.x) * 0.5,
        y = (data.acceleration.y + data.prev_acceleration.y) * 0.5,
        z = (data.acceleration.z + data.prev_acceleration.z) * 0.5
    }
    
    return data.acceleration
end

local function extrapolate_ground(origin, velocity, acceleration, ticks, data)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    local dt = CONFIG.TICK_INTERVAL
    local friction = CONFIG.GROUND_FRICTION
    
    for i = 1, ticks do
        local speed = vec_length_2d(vel.x, vel.y)
        if speed > 0 then
            local drop = speed * friction * dt
            local new_speed = math.max(speed - drop, 0)
            local factor = new_speed / speed
            
            vel.x = vel.x * factor
            vel.y = vel.y * factor
        end
        
        if acceleration then
            vel.x = vel.x + acceleration.x * dt
            vel.y = vel.y + acceleration.y * dt
        end
        
        local new_speed = vec_length_2d(vel.x, vel.y)
        if new_speed > 250 then
            local factor = 250 / new_speed
            vel.x = vel.x * factor
            vel.y = vel.y * factor
        end
        
        result.x = result.x + vel.x * dt
        result.y = result.y + vel.y * dt
    end
    
    return result, vel
end

local function extrapolate_air(origin, velocity, ticks, duck_amount)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    local dt = CONFIG.TICK_INTERVAL
    local gravity = CONFIG.GRAVITY
    local air_accel = CONFIG.AIR_ACCELERATION
    
    local duck_factor = 1.0 - (duck_amount or 0) * 0.2
    
    for i = 1, ticks do
        vel.z = vel.z - gravity * dt * duck_factor
        vel.z = math.max(vel.z, -350)
        
        local wish_speed = 30
        local current_speed = vec_length_2d(vel.x, vel.y)
        
        if current_speed < wish_speed then
            local accel_dir = { x = vel.x, y = vel.y }
            local len = vec_length_2d(accel_dir.x, accel_dir.y)
            if len > 0.1 then
                accel_dir.x = accel_dir.x / len
                accel_dir.y = accel_dir.y / len
                
                local add_speed = wish_speed - current_speed
                local accel_speed = math.min(air_accel * dt * wish_speed, add_speed)
                
                vel.x = vel.x + accel_dir.x * accel_speed
                vel.y = vel.y + accel_dir.y * accel_speed
            end
        end
        
        local air_speed = vec_length_2d(vel.x, vel.y)
        if air_speed > 30 then
            local factor = 30 / air_speed
            vel.x = vel.x * factor
            vel.y = vel.y * factor
        end
        
        result.x = result.x + vel.x * dt
        result.y = result.y + vel.y * dt
        result.z = result.z + vel.z * dt
    end
    
    return result, vel
end

local function extrapolate_position(origin, velocity, acceleration, ticks, is_grounded, duck)
    if is_grounded then
        return extrapolate_ground(origin, velocity, acceleration, ticks)
    else
        return extrapolate_air(origin, velocity, ticks, duck)
    end
end

local function predict_head_position(origin, velocity, duck, is_grounded, ticks)
    local head_height = 64
    
    local future_duck = duck
    if velocity.z > 0 and not is_grounded then
        future_duck = math.max(0, duck - ticks * 0.1)
    elseif is_grounded then
        future_duck = duck
    end
    
    if future_duck > 0.5 then
        head_height = 46
    else
        head_height = lerp(64, 46, future_duck)
    end
    
    local dt = ticks * CONFIG.TICK_INTERVAL
    local future_origin = {
        x = origin.x + velocity.x * dt,
        y = origin.y + velocity.y * dt,
        z = origin.z + velocity.z * dt
    }
    
    return {
        x = future_origin.x,
        y = future_origin.y,
        z = future_origin.z + head_height
    }
end

-- ============== PLIST ==============

local function plist_set_force_angle(ent, angle)
    local steam64 = entity.get_steam64(ent)
    if not steam64 or steam64 == 0 then return false end
    plist.set(steam64, "Force bodyyaw", true)
    plist.set(steam64, "Force bodyyaw value", angle)
    return true
end

local function plist_clear_force(ent)
    local steam64 = entity.get_steam64(ent)
    if not steam64 or steam64 == 0 then return false end
    plist.set(steam64, "Force bodyyaw", false)
    plist.set(steam64, "Force bodyyaw value", 0)
    return true
end

-- ============== BACKTRACK RECORDING ==============

local function record_backtrack(ent, data)
    if not entity.is_alive(ent) then return end
    
    local sim_time = entity.get_prop(ent, "m_flSimulationTime")
    local origin_x, origin_y, origin_z = entity.get_prop(ent, "m_vecOrigin")
    
    if not sim_time or not origin_x then return end
    
    local vel_x = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vel_y = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vel_z = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    
    local eye_offset_z = entity.get_prop(ent, "m_vecViewOffset[2]") or 64
    local yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local pitch = entity.get_prop(ent, "m_angEyeAngles[0]") or 0
    
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local duck = entity.get_prop(ent, "m_flDuckAmount") or 0
    
    local speed = vec_length(vel_x, vel_y, vel_z)
    local current_tick = globals.tickcount()
    
    local is_grounded = is_on_ground(ent, data)
    
    local dt = sim_time - (data.prev_sim_time or sim_time)
    if dt <= 0 then dt = CONFIG.TICK_INTERVAL end
    
    calculate_acceleration(data, vel_x, vel_y, vel_z, dt)
    
    data.velocity_delta = vec_distance(
        data.prev_velocity.x, data.prev_velocity.y, data.prev_velocity.z,
        vel_x, vel_y, vel_z
    )
    
    data.origin_delta = vec_distance(
        data.prev_origin.x, data.prev_origin.y, data.prev_origin.z,
        origin_x, origin_y, origin_z
    )
    
    data.lc_break_detected = data.origin_delta > 64 or data.velocity_delta > 200
    
    local expected_ticks = math.floor(dt / CONFIG.TICK_INTERVAL + 0.5)
    if expected_ticks > 1 then
        data.is_choking = true
        data.last_choke = expected_ticks - 1
        table.insert(data.choke_pattern, data.last_choke)
        while #data.choke_pattern > 20 do table.remove(data.choke_pattern, 1) end
    else
        data.is_choking = false
    end
    
    local head_z = origin_z + (duck > 0.5 and 46 or 64)
    
    local max_extrap = ui.get(ui_elements.ie_extrapolation_ticks)
    local predicted, pred_vel
    if ui.get(ui_elements.ie_extrapolation) then
        predicted, pred_vel = extrapolate_position(
            { x = origin_x, y = origin_y, z = origin_z },
            { x = vel_x, y = vel_y, z = vel_z },
            data.avg_acceleration,
            max_extrap,
            is_grounded,
            duck
        )
    else
        predicted = { x = origin_x, y = origin_y, z = origin_z }
        pred_vel = { x = vel_x, y = vel_y, z = vel_z }
    end
    
    data.predicted_origin = predicted
    data.predicted_velocity = pred_vel
    
    if ui.get(ui_elements.ie_air_pred) then
        data.predicted_head_pos = predict_head_position(
            { x = origin_x, y = origin_y, z = origin_z },
            { x = vel_x, y = vel_y, z = vel_z },
            duck, is_grounded, max_extrap
        )
    else
        data.predicted_head_pos = { x = origin_x, y = origin_y, z = head_z }
    end
    
    if #data.velocity_history >= 5 then
        local var = 0
        for i = #data.velocity_history - 4, #data.velocity_history do
            var = var + data.velocity_history[i].speed
        end
        var = var / 5
        local avg_var = 0
        for i = #data.velocity_history - 4, #data.velocity_history do
            avg_var = avg_var + (data.velocity_history[i].speed - var)^2
        end
        data.extrapolation_confidence = math.max(0.3, 1 - math.sqrt(avg_var / 5) / 100)
    else
        data.extrapolation_confidence = 0.5
    end
    
    local record = {
        sim_time = sim_time,
        tick_count = time_to_ticks(sim_time),
        origin = { x = origin_x, y = origin_y, z = origin_z },
        head_pos = { x = origin_x, y = origin_y, z = head_z },
        eye_pos = { x = origin_x, y = origin_y, z = origin_z + eye_offset_z },
        angles = { pitch = pitch, yaw = yaw },
        velocity = { x = vel_x, y = vel_y, z = vel_z },
        acceleration = { x = data.acceleration.x, y = data.acceleration.y, z = data.acceleration.z },
        flags = flags,
        duck = duck,
        speed = speed,
        time = globals.realtime(),
        is_grounded = is_grounded,
        body_yaw = entity.get_prop(ent, "m_flPoseParameter", CONFIG.POSE_BODY_YAW),
        is_lc_break = data.lc_break_detected,
        velocity_delta = data.velocity_delta,
        origin_delta = data.origin_delta,
        is_choking = data.is_choking,
        choke_amount = data.last_choke,
        predicted_origin = predicted,
        predicted_velocity = pred_vel,
        predicted_head = data.predicted_head_pos,
        extrapolation_confidence = data.extrapolation_confidence,
        predicted_side = data.predicted_side,
        resolve_angle = data.last_resolve,
        confidence = data.confidence,
        valid = true,
        score = 0
    }
    
    while #data.backtrack_records > 0 do
        local oldest = data.backtrack_records[1]
        if oldest and oldest.tick_count and current_tick - oldest.tick_count > CONFIG.BACKTRACK_HISTORY_SIZE then
            table.remove(data.backtrack_records, 1)
        else
            break
        end
    end
    
    for i, rec in ipairs(data.backtrack_records) do
        if math.abs(rec.sim_time - sim_time) < 0.001 then
            data.backtrack_records[i] = record
            data.prev_origin = { x = origin_x, y = origin_y, z = origin_z }
            data.prev_velocity = { x = vel_x, y = vel_y, z = vel_z }
            data.prev_sim_time = sim_time
            return
        end
    end
    
    table.insert(data.backtrack_records, record)
    
    data.prev_origin = { x = origin_x, y = origin_y, z = origin_z }
    data.prev_velocity = { x = vel_x, y = vel_y, z = vel_z }
    data.prev_prev_origin = { x = data.prev_origin.x, y = data.prev_origin.y, z = data.prev_origin.z }
    data.prev_prev_velocity = { x = data.prev_velocity.x, y = data.prev_velocity.y, z = data.prev_velocity.z }
    data.prev_sim_time = sim_time
end

-- ============== BACKTRACK SCORING ==============

local function get_best_backtrack_record(ent, data)
    local lp = entity.get_local_player()
    if not lp then return nil, 0, 0, nil end
    
    local lx, ly, lz = entity.get_prop(lp, "m_vecOrigin")
    if not lx then return nil, 0, 0, nil end
    
    local max_ticks = ui.get(ui_elements.bt_ticks)
    local current_tick = globals.tickcount()
    
    local best_record = nil
    local best_score = -math.huge
    local best_tick = 0
    local best_interp_record = nil
    
    for i, rec in ipairs(data.backtrack_records) do
        if rec.valid and rec.tick_count then
            local tick_diff = current_tick - rec.tick_count
            
            if tick_diff > 0 and tick_diff <= max_ticks then
                local dist = vec_distance(lx, ly, lz, rec.origin.x, rec.origin.y, rec.origin.z)
                
                local score = 100 - tick_diff * 2
                
                score = score + math.max(0, 100 - dist/15) * CONFIG.WEIGHT_DISTANCE
                
                if rec.speed > 0 then
                    score = score + math.min(rec.speed/5, 20) * CONFIG.WEIGHT_VELOCITY
                end
                
                if rec.is_lc_break then
                    score = score + 100 * CONFIG.WEIGHT_LC_BREAK
                    global_stats.backtrack_lc_breaks = global_stats.backtrack_lc_breaks + 1
                end
                
                if rec.extrapolation_confidence > 0.7 then
                    score = score + 15 * CONFIG.WEIGHT_PREDICTION_CONF
                end
                
                score = score + rec.confidence * 20
                
                if score > best_score then
                    best_score = score
                    best_record = rec
                    best_tick = tick_diff
                end
            end
        end
    end
    
    -- Interpolation between records
    if ui.get(ui_elements.ie_interpolation) and #data.backtrack_records >= 2 and best_record then
        for i = 2, #data.backtrack_records do
            local rec1 = data.backtrack_records[i-1]
            local rec2 = data.backtrack_records[i]
            
            if rec1.valid and rec2.valid and rec1.tick_count and rec2.tick_count then
                local tick1 = current_tick - rec1.tick_count
                local tick2 = current_tick - rec2.tick_count
                
                if tick1 <= max_ticks and tick2 <= max_ticks then
                    local t = 0.5
                    local interp_origin
                    
                    if ui.get(ui_elements.ie_spline) and i >= 3 and i < #data.backtrack_records then
                        local rec_prev = data.backtrack_records[i-2]
                        local rec_next = data.backtrack_records[i+1]
                        if rec_prev and rec_next then
                            interp_origin = interpolate_position_spline(rec_prev, rec1, rec2, rec_next, t)
                        end
                    end
                    
                    if not interp_origin then
                        interp_origin = interpolate_position_cubic(rec1, rec2, t)
                    end
                    
                    if interp_origin then
                        local interp_dist = vec_distance(lx, ly, lz, interp_origin.x, interp_origin.y, interp_origin.z)
                        local interp_score = 100 - (tick1 + tick2)/2 * 2 + math.max(0, 100 - interp_dist/15)
                        interp_score = interp_score * CONFIG.WEIGHT_INTERPOLATED
                        
                        if interp_score > best_score then
                            best_score = interp_score
                            best_interp_record = {
                                origin = interp_origin,
                                head_pos = { x = interp_origin.x, y = interp_origin.y, z = interp_origin.z + (rec1.duck > 0.5 and 46 or 64) },
                                tick_count = math.floor((rec1.tick_count + rec2.tick_count) / 2),
                                sim_time = (rec1.sim_time + rec2.sim_time) / 2,
                                is_interpolated = true,
                                is_cubic = rec.is_cubic,
                                is_spline = rec.is_spline or false,
                                resolve_angle = (rec1.resolve_angle + rec2.resolve_angle) / 2,
                                confidence = (rec1.confidence + rec2.confidence) / 2,
                                valid = true
                            }
                            best_tick = math.floor((tick1 + tick2) / 2)
                        end
                    end
                end
            end
        end
    end
    
    if best_interp_record then
        return best_interp_record, best_tick, best_score, best_interp_record
    end
    
    return best_record, best_tick, best_score, nil
end

local function apply_backtrack(cmd, record, tick_diff)
    if not record then return false end
    cmd.tickcount = record.tick_count
    return true
end

-- ============== ANALYSIS FUNCTIONS ==============

local function analyze_jitter(data)
    if #data.angle_history < 5 then return end
    
    local changes = {}
    local last_dir = 0
    local oscillations = 0
    
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
    for _, v in ipairs(changes) do
        avg = avg + math.abs(v)
    end
    avg = avg / #changes
    
    local variance = 0
    for _, v in ipairs(changes) do
        variance = variance + (math.abs(v) - avg)^2
    end
    
    data.jitter_score = math.sqrt(variance / #changes)
    data.avg_angle_change = avg
    
    data.is_jitter = data.jitter_score > CONFIG.JITTER_THRESHOLD or oscillations > 4
end

local function analyze_spin(data)
    if #data.angle_history < 6 then return false end
    
    local total_change = 0
    local samples = 0
    local votes = { left = 0, right = 0 }
    
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            total_change = total_change + math.abs(diff)
            samples = samples + 1
            
            if diff > 0 then
                votes.right = votes.right + 1
            else
                votes.left = votes.left + 1
            end
        end
    end
    
    if samples == 0 then return false end
    
    data.spin_speed = total_change / samples
    data.spin_direction = votes.right > votes.left and 1 or -1
    data.is_spinning = data.spin_speed > CONFIG.SPIN_THRESHOLD
    
    return data.is_spinning
end

local function analyze_velocity(ent, data)
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    
    local speed = math.sqrt(vx*vx + vy*vy)
    
    table.insert(data.velocity_history, { speed = speed, time = globals.realtime() })
    while #data.velocity_history > CONFIG.MAX_VELOCITY do
        table.remove(data.velocity_history, 1)
    end
    
    data.is_moving = speed > 10
    data.is_air = bit.band(entity.get_prop(ent, "m_fFlags") or 0, 1) == 0
    
    -- Moving resolver
    if speed > 35 then
        local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
        if eye_yaw then
            local move_yaw = math.deg(math.atan2(vy, vx))
            local diff = angle_diff(move_yaw, eye_yaw)
            
            if diff > 22 and diff < 158 then
                return SIDES.RIGHT, 0.78
            elseif diff < -22 and diff > -158 then
                return SIDES.LEFT, 0.78
            end
        end
    end
    
    return SIDES.CENTER, 0.18
end

local function analyze_memory(data)
    if #data.successful_resolves < 2 then
        return SIDES.CENTER, 0
    end
    
    local left_weight = 0
    local right_weight = 0
    local total_weight = 0
    
    for _, resolve in ipairs(data.successful_resolves) do
        local age = globals.realtime() - resolve.time
        local weight = (resolve.confidence or 0.5) * math.pow(CONFIG.PREDICTION_DECAY, age)
        
        total_weight = total_weight + weight
        
        if resolve.side == SIDES.LEFT then
            left_weight = left_weight + weight
        elseif resolve.side == SIDES.RIGHT then
            right_weight = right_weight + weight
        end
    end
    
    if total_weight < 0.25 then
        return SIDES.CENTER, 0
    end
    
    local left_ratio = left_weight / total_weight
    local right_ratio = right_weight / total_weight
    
    if left_ratio > 0.55 then
        return SIDES.LEFT, left_ratio * 0.92
    elseif right_ratio > 0.55 then
        return SIDES.RIGHT, right_ratio * 0.92
    end
    
    return SIDES.CENTER, 0.18
end

local function recognize_pattern(data)
    if data.is_spinning then
        return "spin", 0.90
    end
    
    if data.is_jitter then
        return "jitter", 0.85
    end
    
    if data.is_extended then
        return "extended", 0.82
    end
    
    return "unknown", 0.25
end

-- ============== DT PREDICTION ==============

local function detect_doubletap(ent, data)
    if not ui.get(ui_elements.dt_predict) then return end
    
    local weapon = entity.get_player_weapon(ent)
    if not weapon then return end
    
    local ammo = entity.get_prop(weapon, "m_iClip1") or 0
    
    if data.last_ammo ~= -1 and ammo < data.last_ammo then
        local fire_time = globals.realtime()
        table.insert(data.dt_shots, fire_time)
        
        while #data.dt_shots > 10 do
            table.remove(data.dt_shots, 1)
        end
        
        local recent_shots = 0
        for _, t in ipairs(data.dt_shots) do
            if fire_time - t < CONFIG.DT_TIME_THRESHOLD then
                recent_shots = recent_shots + 1
            end
        end
        
        if recent_shots >= CONFIG.DT_SHOT_THRESHOLD then
            data.dt_detected = true
            data.dt_confidence = math.min(recent_shots / 5, 1.0)
            data.dt_firing_speed = recent_shots / CONFIG.DT_TIME_THRESHOLD
            
            local dt_shift = ui.get(ui_elements.dt_aggression)
            data.dt_angle_offset = data.dt_detected and (math.random() > 0.5 and dt_shift or -dt_shift) or 0
        end
    end
    
    data.last_ammo = ammo
end

-- ============== MAIN PREDICTION ==============

local function get_prediction(ent)
    local data = get_data(ent)
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    
    if not eye_yaw then
        return 60, 0.35
    end
    
    local predictions = {}
    local base_weight = 1.5
    
    -- Cloud data first
    if ui.get(ui_elements.cloud_enabled) then
        local cloud_data = cloud_resolver.get_data(ent)
        if cloud_data and cloud_data.confidence >= CONFIG.CLOUD_MIN_CONFIDENCE then
            table.insert(predictions, {
                side = cloud_data.angle > 0 and SIDES.LEFT or SIDES.RIGHT,
                conf = cloud_data.confidence,
                weight = base_weight * CONFIG.CLOUD_WEIGHT,
                source = "cloud"
            })
            data.cloud_used = true
        end
    end
    
    -- Velocity analysis
    local v_side, v_conf = analyze_velocity(ent, data)
    if v_conf > 0.25 then
        table.insert(predictions, {
            side = v_side,
            conf = v_conf,
            weight = base_weight * 1.15,
            source = "velocity"
        })
    end
    
    -- Pattern recognition
    local pattern, p_conf = recognize_pattern(data)
    if p_conf > 0.25 then
        local side = SIDES.CENTER
        
        if pattern == "spin" then
            side = data.spin_direction * -1
        elseif pattern == "jitter" then
            side = (data.predicted_side ~= 0 and data.predicted_side or SIDES.LEFT) * -1
        end
        
        table.insert(predictions, {
            side = side,
            conf = p_conf,
            weight = base_weight * 1.4,
            source = "pattern"
        })
    end
    
    -- Memory analysis
    local m_side, m_conf = analyze_memory(data)
    if m_conf > 0.30 then
        table.insert(predictions, {
            side = m_side,
            conf = m_conf,
            weight = base_weight * 1.7,
            source = "memory"
        })
    end
    
    -- DT prediction
    if data.dt_detected and data.dt_confidence > 0.5 then
        table.insert(predictions, {
            side = data.dt_angle_offset > 0 and SIDES.LEFT or SIDES.RIGHT,
            conf = data.dt_confidence * 0.8,
            weight = base_weight * 1.3,
            source = "dt"
        })
    end
    
    if #predictions == 0 then
        return 60, 0.35
    end
    
    -- Calculate weighted average
    local total_weight = 0
    local weighted_side = 0
    
    for _, pred in ipairs(predictions) do
        weighted_side = weighted_side + (pred.side * pred.conf * pred.weight)
        total_weight = total_weight + (pred.conf * pred.weight)
    end
    
    local final_side = total_weight > 0 and weighted_side / total_weight or 0
    local final_conf = total_weight > 0 and total_weight / #predictions or 0.35
    
    -- Determine final side
    if final_side > 0.18 then
        final_side = SIDES.LEFT
    elseif final_side < -0.18 then
        final_side = SIDES.RIGHT
    else
        final_side = SIDES.CENTER
    end
    
    -- Calculate angle
    local aggression = ui.get(ui_elements.aggression)
    local angle = final_side * CONFIG.EXTENDED_DESYNC_MAX * final_conf * (aggression / 5)
    angle = clamp(angle, -165, 165)
    
    data.predicted_side = final_side
    data.confidence = final_conf
    
    return angle, final_conf
end

-- ============== APPLY RESOLVE ==============

local function apply_resolve(ent, angle, conf)
    if not entity.is_alive(ent) then return end
    
    local data = get_data(ent)
    
    if globals.realtime() - data.last_plist_update < CONFIG.SAMPLE_RATE then
        return
    end
    
    data.last_plist_update = globals.realtime()
    
    plist_set_force_angle(ent, angle)
end

-- ============== MAIN RESOLVER ==============

local function resolve(ent)
    if not ui.get(ui_elements.enabled) then
        return 60, 0.35
    end
    
    if not entity.is_alive(ent) then
        return 60, 0.35
    end
    
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then
        return 60, 0.35
    end
    
    local data = get_data(ent)
    
    -- Record angle history
    table.insert(data.angle_history, {
        angle = eye_yaw,
        time = globals.realtime()
    })
    while #data.angle_history > CONFIG.MAX_HISTORY do
        table.remove(data.angle_history, 1)
    end
    
    -- Analyze
    analyze_jitter(data)
    analyze_spin(data)
    detect_doubletap(ent, data)
    record_backtrack(ent, data)
    
    local angle = 60
    local conf = 0.35
    local mode = ui.get(ui_elements.mode)
    
    if mode == "Cloud Priority" then
        if ui.get(ui_elements.cloud_enabled) then
            local cloud_data = cloud_resolver.get_data(ent)
            if cloud_data and cloud_data.confidence >= 0.6 then
                angle = cloud_data.angle
                conf = cloud_data.confidence
                data.cloud_used = true
                global_stats.cloud_resolves = global_stats.cloud_resolves + 1
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
    
    apply_resolve(ent, angle, conf)
    
    global_stats.total_resolves = global_stats.total_resolves + 1
    
    return angle, conf
end

-- ============== EVENTS ==============

client.set_event_callback("setup_command", function(cmd)
    if not ui.get(ui_elements.enabled) then return end
    
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    -- Cloud sync
    if ui.get(ui_elements.cloud_enabled) then
        if not cloud_state.initialized then
            cloud_resolver.init()
        end
        
        local url = ui.get(ui_elements.cloud_url)
        if url and url ~= "" then
            CLOUD_CONFIG.SERVER_URL = url
        end
        CLOUD_CONFIG.DEBUG = ui.get(ui_elements.cloud_debug)
        
        cloud_resolver.poll()
        
        if globals.tickcount() % 100 == 0 then
            cloud_resolver.clean()
        end
    end
    
    -- Resolve all enemies
    local players = entity.get_players(true)
    if not players then return end
    
    for _, ent in ipairs(players) do
        if entity.is_alive(ent) then
            resolve(ent)
        end
    end
end)

client.set_event_callback("aim_fire", function(e)
    if not ui.get(ui_elements.enabled) then return end
    
    local ent = e.target
    if not ent then return end
    
    local data = get_data(ent)
    data.shots = data.shots + 1
    global_stats.shots = global_stats.shots + 1
    
    -- Backtrack
    local record, tick_diff, score, interp_record = get_best_backtrack_record(ent, data)
    
    if record then
        apply_backtrack(e, record, tick_diff)
        
        data.backtrack_is_valid = true
        data.backtrack_target_tick = tick_diff
        data.backtrack_score = score
        data.backtrack_origin = record.origin
        
        global_stats.backtrack_shots = global_stats.backtrack_shots + 1
        global_stats.backtrack_ticks_used = global_stats.backtrack_ticks_used + tick_diff
        global_stats.backtrack_avg_tick = global_stats.backtrack_avg_tick + (tick_diff - global_stats.backtrack_avg_tick) / global_stats.backtrack_shots
        
        if score > global_stats.backtrack_best_score then
            global_stats.backtrack_best_score = score
        end
        
        if interp_record then
            global_stats.backtrack_interpolated_hits = global_stats.backtrack_interpolated_hits + 1
            if interp_record.is_cubic then
                global_stats.backtrack_cubic_hits = global_stats.backtrack_cubic_hits + 1
            end
            if interp_record.is_spline then
                global_stats.backtrack_spline_hits = global_stats.backtrack_spline_hits + 1
            end
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[FIRE] T:%d | BT:%d ticks | Score:%.1f%s", 
            ent, tick_diff or 0, score or 0, data.cloud_used and " [CLOUD]" or ""))
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
    
    if data.backtrack_is_valid then
        global_stats.backtrack_hits = global_stats.backtrack_hits + 1
    end
    
    if data.cloud_used then
        global_stats.cloud_hits = global_stats.cloud_hits + 1
    end
    
    -- Record successful resolve
    table.insert(data.successful_resolves, {
        side = data.last_resolve > 0 and SIDES.LEFT or SIDES.RIGHT,
        angle = data.last_resolve,
        confidence = data.confidence,
        time = globals.realtime()
    })
    
    while #data.successful_resolves > 50 do
        table.remove(data.successful_resolves, 1)
    end
    
    -- Sync to cloud
    if ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            cloud_resolver.report_data(steam64, data.last_resolve, data.confidence, true, data.detected_pattern)
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[HIT] T:%d | Streak:%d | Angle:%.1f%s", 
            ent, data.consecutive_hits, data.last_resolve, data.cloud_used and " [CLOUD]" or ""))
    end
    
    data.backtrack_is_valid = false
    data.cloud_used = false
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(ui_elements.enabled) then return end
    
    local ent = e.target
    if not ent then return end
    
    local reason = e.reason or ""
    if reason ~= "prediction error" and reason ~= "resolver" then
        return
    end
    
    local data = get_data(ent)
    
    data.misses = data.misses + 1
    data.consecutive_misses = data.consecutive_misses + 1
    data.consecutive_hits = 0
    
    global_stats.misses = global_stats.misses + 1
    global_stats.streak_current = 0
    
    -- Report miss to cloud
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
    data.cloud_used = false
end)

client.set_event_callback("paint", function()
    if not ui.get(ui_elements.enabled) or not ui.get(ui_elements.show_stats) then return end
    
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    local x, y = 10, 200
    
    renderer.text(x, y, 255, 255, 255, 255, "", 0, "══════ RESOLVER v18.3 ══════")
    y = y + 12
    
    -- Cloud status
    if ui.get(ui_elements.cloud_enabled) then
        local status = cloud_state.initialized and "CONNECTED" or "CONNECTING..."
        local r, g, b = cloud_state.initialized and 100 or 255, cloud_state.initialized and 255 or 100, 100
        renderer.text(x, y, r, g, b, 255, "", 0, string.format("CLOUD: %s | Syncs: %d | Err: %d", 
            status, cloud_state.sync_count, cloud_state.error_count))
        y = y + 12
    end
    
    -- Stats
    local hitrate = global_stats.shots > 0 and (global_stats.hits / global_stats.shots * 100) or 0
    renderer.text(x, y, 200, 200, 200, 255, "", 0, string.format("S:%d H:%d M:%d | %.1f%%", 
        global_stats.shots, global_stats.hits, global_stats.misses, hitrate))
    y = y + 12
    
    -- Backtrack
    local bt_rate = global_stats.backtrack_shots > 0 and (global_stats.backtrack_hits / global_stats.backtrack_shots * 100) or 0
    renderer.text(x, y, 100, 200, 255, 255, "", 0, string.format("BT: %d/%d (%.1f%%) | Avg: %.1f ticks", 
        global_stats.backtrack_hits, global_stats.backtrack_shots, bt_rate, global_stats.backtrack_avg_tick))
    y = y + 12
    
    -- Interpolation stats
    if global_stats.backtrack_interpolated_hits > 0 then
        renderer.text(x, y, 150, 200, 255, 255, "", 0, string.format("Interp: %d | Cubic: %d | Spline: %d", 
            global_stats.backtrack_interpolated_hits, global_stats.backtrack_cubic_hits, global_stats.backtrack_spline_hits))
        y = y + 12
    end
    
    -- Cloud stats
    if ui.get(ui_elements.cloud_enabled) then
        renderer.text(x, y, 100, 255, 200, 255, "", 0, string.format("Cloud: %d resolves, %d hits", 
            global_stats.cloud_resolves, global_stats.cloud_hits))
    end
end)

client.set_event_callback("player_death", function(e)
    local victim = client.userid_to_entindex(e.userid)
    if victim and player_data[victim] then
        plist_clear_force(victim)
        player_data[victim] = nil
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
        data.cloud_used = false
    end
    global_stats.streak_current = 0
    client.log("[Resolver v18.3] Round start - Cloud Ready!")
end)

client.log("[Forward HVH Resolver v18.3] Loaded - Cloud Sync Enabled!")
