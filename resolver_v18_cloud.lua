--[[
    FORWARD HVH RESOLVER v18.1 - CLOUD SYNC (FIXED)
    Professional resolver with cloud-based data sharing between teammates
    
    v18.1 Fix:
    - Added HTTP availability check
    - Graceful fallback when HTTP unavailable
    
    v18 Features:
    - Cloud data synchronization between teammates
    - Hit/Miss data sharing in real-time
    - Collective resolver learning
    - Automatic angle propagation
    - SteamID-based player identification
    - All v17 features (Backtrack, Interpolation, Extrapolation)
    
    by Super Z
]]

-- ============== HTTP CHECK ==============

local http_available = http ~= nil and type(http.get) == "function"

if not http_available then
    client.log("[Cloud Resolver] HTTP not available in this Gamesense version")
    client.log("[Cloud Resolver] Cloud sync disabled - using local resolver only")
end

-- ============== CLOUD RESOLVER MODULE ==============

local cloud_resolver = {}

-- Cloud Configuration
local CLOUD_CONFIG = {
    SERVER_URL = "http://localhost:3000/api",
    POLL_INTERVAL = 2.0,
    DATA_TIMEOUT = 60.0,
    MIN_CONFIDENCE = 0.5,
    SYNC_ON_HIT = true,
    SYNC_ON_MISS = true,
    DEBUG = true
}

-- Cloud State
local cloud_state = {
    initialized = false,
    enabled = http_available,
    my_steamid = nil,
    my_steam64 = nil,
    last_poll = 0,
    cloud_data = {},
    pending_requests = 0,
    last_sync = 0,
    sync_count = 0,
    error_count = 0,
    last_error = nil
}

-- JSON Parser (Simple implementation for Gamesense)
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
        
        if s:sub(i, i+3) == "null" then
            return nil, i + 4
        end
        
        if s:sub(i, i+3) == "true" then
            return true, i + 4
        end
        if s:sub(i, i+4) == "false" then
            return false, i + 5
        end
        
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
                if s:sub(j,j) == '"' then
                    return result, j + 1
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
        if val == math.huge or val == -math.huge then return "null" end
        return tostring(val)
    elseif t == "string" then
        local escaped = val:gsub('[%z\1-\31\\"]', function(c)
            return string.format("\\u%04x", c:byte())
        end)
        escaped = escaped:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
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
            for _, v in ipairs(val) do
                table.insert(parts, json.encode(v))
            end
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

-- Initialize cloud resolver
function cloud_resolver.init()
    if not http_available then
        return false
    end
    
    local lp = entity.get_local_player()
    if not lp then 
        return false
    end
    
    cloud_state.my_steam64 = entity.get_steam64(lp)
    if not cloud_state.my_steam64 or cloud_state.my_steam64 == 0 then
        return false
    end
    
    cloud_state.my_steamid = tostring(cloud_state.my_steam64)
    cloud_state.initialized = true
    
    if CLOUD_CONFIG.DEBUG then
        client.log("[Cloud Resolver] Initialized with SteamID: " .. cloud_state.my_steamid)
    end
    
    return true
end

-- Send data to cloud
function cloud_resolver.report_data(enemy_steam64, angle, confidence, hit, pattern)
    if not http_available then return false end
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return false end
    end
    
    if not enemy_steam64 or enemy_steam64 == 0 then return false end
    
    angle = tonumber(angle) or 60
    confidence = tonumber(confidence) or 0.5
    confidence = math.max(0, math.min(1, confidence))
    
    local payload = json.encode({
        reporter_steamid = cloud_state.my_steamid,
        enemy_steam64 = tostring(enemy_steam64),
        angle = angle,
        confidence = confidence,
        hit = hit or false,
        pattern = pattern or "unknown",
        timestamp = globals.realtime()
    })
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/update"
    
    http.post(url, {["Content-Type"] = "application/json"}, payload, function(data, err)
        if err and err ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP " .. tostring(err)
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver] Send error: " .. tostring(err))
            end
            return
        end
        
        cloud_state.sync_count = cloud_state.sync_count + 1
        cloud_state.last_sync = globals.realtime()
        
        if CLOUD_CONFIG.DEBUG then
            client.log("[Cloud Resolver] Data sent successfully")
        end
    end)
    
    return true
end

-- Request data from cloud
function cloud_resolver.poll()
    if not http_available then return end
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return end
    end
    
    local current_time = globals.realtime()
    if current_time - cloud_state.last_poll < CLOUD_CONFIG.POLL_INTERVAL then
        return
    end
    cloud_state.last_poll = current_time
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/get"
    
    http.get(url, function(data, err)
        if err and err ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP " .. tostring(err)
            return
        end
        
        if not data or data == "" then return end
        
        local decoded = json.parse(data)
        if not decoded then 
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver] Failed to parse response")
            end
            return 
        end
        
        for steam64, entry in pairs(decoded) do
            if steam64 ~= cloud_state.my_steamid then
                cloud_state.cloud_data[steam64] = {
                    angle = entry.angle,
                    confidence = entry.confidence,
                    timestamp = entry.timestamp,
                    reporter = entry.reporter,
                    pattern = entry.pattern,
                    hit = entry.hit
                }
            end
        end
        
        if CLOUD_CONFIG.DEBUG then
            local count = 0
            for _ in pairs(cloud_state.cloud_data) do count = count + 1 end
            client.log("[Cloud Resolver] Updated data: " .. count .. " players")
        end
    end)
end

-- Get cloud data for enemy
function cloud_resolver.get_data(enemy)
    if not http_available then return nil end
    if not cloud_state.initialized then return nil end
    
    local steam64 = entity.get_steam64(enemy)
    if not steam64 or steam64 == 0 then return nil end
    
    local steam_str = tostring(steam64)
    local data = cloud_state.cloud_data[steam_str]
    
    if not data then return nil end
    
    local age = globals.realtime() - (data.timestamp or 0)
    if age > CLOUD_CONFIG.DATA_TIMEOUT then
        cloud_state.cloud_data[steam_str] = nil
        return nil
    end
    
    if data.reporter == cloud_state.my_steamid then
        return nil
    end
    
    if (data.confidence or 0) < CLOUD_CONFIG.MIN_CONFIDENCE then
        return nil
    end
    
    return {
        angle = data.angle,
        confidence = data.confidence,
        pattern = data.pattern,
        hit = data.hit,
        age = age,
        reporter = data.reporter
    }
end

-- Get status for UI
function cloud_resolver.get_status()
    return {
        initialized = cloud_state.initialized,
        enabled = cloud_state.enabled,
        http_available = http_available,
        steamid = cloud_state.my_steamid,
        sync_count = cloud_state.sync_count,
        error_count = cloud_state.error_count,
        last_sync = cloud_state.last_sync,
        last_error = cloud_state.last_error,
        data_count = #cloud_state.cloud_data
    }
end

-- Clean old data
function cloud_resolver.clean()
    if not http_available then return end
    
    local current_time = globals.realtime()
    local cleaned = 0
    
    for steam64, data in pairs(cloud_state.cloud_data) do
        if current_time - (data.timestamp or 0) > CLOUD_CONFIG.DATA_TIMEOUT then
            cloud_state.cloud_data[steam64] = nil
            cleaned = cleaned + 1
        end
    end
    
    if CLOUD_CONFIG.DEBUG and cleaned > 0 then
        client.log("[Cloud Resolver] Cleaned " .. cleaned .. " expired entries")
    end
end

-- ============== MAIN RESOLVER ==============

-- ============== CONFIGURATION ==============

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
    
    BACKTRACK_MAX_TICKS = 40,
    BACKTRACK_HISTORY_SIZE = 65,
    TICK_INTERVAL = 0.015625,
    
    INTERPOLATION_ENABLED = true,
    CUBIC_INTERPOLATION = true,
    CATMULL_ROM_SPLINE = true,
    INTERPOLATION_STEPS = 4,
    
    EXTRAPOLATION_ENABLED = true,
    MAX_EXTRAPOLATION_TICKS = 8,
    GRAVITY = 800,
    AIR_ACCELERATION = 1000,
    GROUND_FRICTION = 4,
    STOP_SPEED = 100,
    VELOCITY_DAMPING = 0.85,
    ACCELERATION_SMOOTHING = 0.3,
    
    WEIGHT_DISTANCE = 1.0,
    WEIGHT_VELOCITY = 0.85,
    WEIGHT_LC_BREAK = 2.0,
    WEIGHT_INTERPOLATED = 1.2,
    WEIGHT_EXTRAPOLATED = 0.9,
    WEIGHT_PREDICTION_CONF = 1.1,
    
    CLOUD_WEIGHT = 2.5,
    CLOUD_MIN_CONFIDENCE = 0.5
}

-- ============== DATA STRUCTURES ==============

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
        angle_history = {},
        velocity_history = {},
        shot_history = {},
        resolve_history = {},
        backtrack_records = {},
        
        bf_index = 1,
        bf_stage = 1,
        bf_angle = 60,
        predicted_side = 0,
        predicted_angle = 60,
        confidence = 0.35,
        last_resolve = 60,
        force_angle = 60,
        best_angle = 60,
        
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
        
        pose_body_yaw = 0,
        pose_body_yaw_angle = 0,
        pose_body_pitch = 0,
        roll_angle = 0,
        
        detected_pattern = "unknown",
        pattern_confidence = 0,
        
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
        
        learned_side = 0,
        learned_confidence = 0,
        side_weights = { left = 0, right = 0, center = 0 },
        pattern_memory = {},
        best_tick_history = {},
        
        dt_shots = {},
        dt_detected = false,
        dt_confidence = 0,
        dt_angle_offset = 0,
        dt_predicted_side = 0,
        dt_firing_speed = 0,
        last_ammo = -1,
        
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
        
        is_on_ground = true,
        was_on_ground = true,
        ground_entity = -1,
        fall_velocity = 0,
        jump_time = 0,
        
        predicted_origin = { x = 0, y = 0, z = 0 },
        predicted_velocity = { x = 0, y = 0, z = 0 },
        predicted_head_pos = { x = 0, y = 0, z = 0 },
        extrapolation_confidence = 0,
        
        choke_pattern = {},
        avg_choke = 0,
        last_choke = 0,
        is_choking = false,
        
        lc_break_detected = false,
        
        cloud_angle = nil,
        cloud_confidence = nil,
        cloud_last_update = 0,
        cloud_used = false,
        
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
        
        last_plist_update = 0,
        last_update = 0,
        last_shot_time = 0,
        last_record_time = 0,
        
        bf_state = {
            stage = 1,
            direction = 1,
            smart_mode = false,
            last_angles = {},
            successful_patterns = {}
        },
        
        shot_correlation = {
            total = 0,
            hit_angles = {},
            miss_angles = {},
            best_angle = 60
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
    
    cloud_label = ui.new_label("RAGE", "Other", "━━━ Cloud Resolver ━━━"),
    cloud_enabled = ui.new_checkbox("RAGE", "Other", "Enable Cloud Sync"),
    cloud_url = ui.new_textbox("RAGE", "Other", "Server URL"),
    cloud_debug = ui.new_checkbox("RAGE", "Other", "Cloud Debug"),
    cloud_status = ui.new_label("RAGE", "Other", "HTTP: " .. (http_available and "Available" or "Unavailable")),
    cloud_test = ui.new_button("RAGE", "Other", "Test Connection", function()
        if not http_available then
            client.log("[Cloud Resolver] HTTP not available in this Gamesense version")
            client.log("[Cloud Resolver] Cloud sync disabled")
            return
        end
        
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
    
    method_label = ui.new_label("RAGE", "Other", "━━━ Method ━━━"),
    resolve_method = ui.new_combobox("RAGE", "Other", "Resolve Method", {
        "PList Force",
        "Hybrid (All)"
    }),
    
    bt_label = ui.new_label("RAGE", "Other", "━━━ Backtrack (Always ON) ━━━"),
    bt_ticks = ui.new_slider("RAGE", "Other", "Max Ticks", 14, 40, 40, true, "ticks"),
    bt_visualize = ui.new_checkbox("RAGE", "Other", "Visualize History"),
    
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
    
    override_key = ui.new_hotkey("RAGE", "Other", "Manual Override", true),
    override_mode = ui.new_combobox("RAGE", "Other", "Override Side", {"Left", "Right", "Auto", "Opposite"}),
    
    debug_label = ui.new_label("RAGE", "Other", "━━━ Debug ━━━"),
    debug_mode = ui.new_checkbox("RAGE", "Other", "Debug Output"),
    show_stats = ui.new_checkbox("RAGE", "Other", "Show Statistics"),
    log_hits = ui.new_checkbox("RAGE", "Other", "Log Hits/Misses"),
    
    reset_btn = ui.new_button("RAGE", "Other", "Reset All Data", function()
        player_data = {}
        global_stats = create_stats()
        cloud_state.cloud_data = {}
        client.log("[Resolver v18.1] Data reset")
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
if http_available then
    ui.set(ui_elements.cloud_enabled, true)
end
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

local function get_steam64(ent)
    return entity.get_steam64(ent)
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

-- ============== INTERPOLATION ==============

local function hermite_basis_00(t) return 2*t*t*t - 3*t*t + 1 end
local function hermite_basis_10(t) return t*t*t - 2*t*t + t end
local function hermite_basis_01(t) return -2*t*t*t + 3*t*t end
local function hermite_basis_11(t) return t*t*t - t*t end

local function cubic_hermite_interp(p0, p1, m0, m1, t)
    t = clamp(t, 0, 1)
    return hermite_basis_00(t) * p0 + hermite_basis_10(t) * m0 + 
           hermite_basis_01(t) * p1 + hermite_basis_11(t) * m1
end

local function catmull_rom_spline(p0, p1, p2, p3, t)
    t = clamp(t, 0, 1)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2*p0 - 5*p1 + 4*p2 - p3) * t2 + (-p0 + 3*p1 - 3*p2 + p3) * t3)
end

local function interpolate_position_cubic(rec1, rec2, t, dt)
    dt = dt or CONFIG.TICK_INTERVAL
    return {
        x = cubic_hermite_interp(rec1.origin.x, rec2.origin.x, rec1.velocity.x * dt, rec2.velocity.x * dt, t),
        y = cubic_hermite_interp(rec1.origin.y, rec2.origin.y, rec1.velocity.y * dt, rec2.velocity.y * dt, t),
        z = cubic_hermite_interp(rec1.origin.z, rec2.origin.z, rec1.velocity.z * dt, rec2.velocity.z * dt, t)
    }
end

local function interpolate_position_spline(rec_prev, rec0, rec1, rec_next, t)
    return {
        x = catmull_rom_spline(rec_prev.origin.x, rec0.origin.x, rec1.origin.x, rec_next.origin.x, t),
        y = catmull_rom_spline(rec_prev.origin.y, rec0.origin.y, rec1.origin.y, rec_next.origin.y, t),
        z = catmull_rom_spline(rec_prev.origin.z, rec0.origin.z, rec1.origin.z, rec_next.origin.z, t)
    }
end

-- ============== EXTRAPOLATION ==============

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
    
    data.prev_acceleration = { x = data.acceleration.x, y = data.acceleration.y, z = data.acceleration.z }
    data.acceleration = {
        x = lerp(data.acceleration.x, (vel_x - data.prev_velocity.x) / dt, CONFIG.ACCELERATION_SMOOTHING),
        y = lerp(data.acceleration.y, (vel_y - data.prev_velocity.y) / dt, CONFIG.ACCELERATION_SMOOTHING),
        z = lerp(data.acceleration.z, (vel_z - data.prev_velocity.z) / dt, CONFIG.ACCELERATION_SMOOTHING)
    }
    data.avg_acceleration = {
        x = (data.acceleration.x + data.prev_acceleration.x) * 0.5,
        y = (data.acceleration.y + data.prev_acceleration.y) * 0.5,
        z = (data.acceleration.z + data.prev_acceleration.z) * 0.5
    }
    return data.acceleration
end

local function extrapolate_ground(origin, velocity, acceleration, ticks)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    
    for i = 1, ticks do
        local speed = vec_length_2d(vel.x, vel.y)
        if speed > 0 then
            local factor = math.max(speed - speed * CONFIG.GROUND_FRICTION * CONFIG.TICK_INTERVAL, 0) / speed
            vel.x, vel.y = vel.x * factor, vel.y * factor
        end
        if acceleration then
            vel.x, vel.y = vel.x + acceleration.x * CONFIG.TICK_INTERVAL, vel.y + acceleration.y * CONFIG.TICK_INTERVAL
        end
        local new_speed = vec_length_2d(vel.x, vel.y)
        if new_speed > 250 then
            local factor = 250 / new_speed
            vel.x, vel.y = vel.x * factor, vel.y * factor
        end
        result.x, result.y = result.x + vel.x * CONFIG.TICK_INTERVAL, result.y + vel.y * CONFIG.TICK_INTERVAL
    end
    return result, vel
end

local function extrapolate_air(origin, velocity, ticks, duck_amount)
    local result = { x = origin.x, y = origin.y, z = origin.z }
    local vel = { x = velocity.x, y = velocity.y, z = velocity.z }
    local duck_factor = 1.0 - (duck_amount or 0) * 0.2
    
    for i = 1, ticks do
        vel.z = math.max(vel.z - CONFIG.GRAVITY * CONFIG.TICK_INTERVAL * duck_factor, -350)
        result.x = result.x + vel.x * CONFIG.TICK_INTERVAL
        result.y = result.y + vel.y * CONFIG.TICK_INTERVAL
        result.z = result.z + vel.z * CONFIG.TICK_INTERVAL
    end
    return result, vel
end

local function extrapolate_position(origin, velocity, acceleration, ticks, is_grounded, duck)
    if is_grounded then return extrapolate_ground(origin, velocity, acceleration, ticks)
    else return extrapolate_air(origin, velocity, ticks, duck) end
end

-- ============== PLIST ==============

local function plist_set_force_angle(ent, angle)
    local steam64 = get_steam64(ent)
    if not steam64 or steam64 == 0 then return false end
    plist.set(steam64, "Force bodyyaw", true)
    plist.set(steam64, "Force bodyyaw value", angle)
    return true
end

local function plist_clear_force(ent)
    local steam64 = get_steam64(ent)
    if not steam64 or steam64 == 0 then return false end
    plist.set(steam64, "Force bodyyaw", false)
    plist.set(steam64, "Force bodyyaw value", 0)
    return true
end

-- ============== BACKTRACK ==============

local function record_backtrack(ent, data)
    if not entity.is_alive(ent) then return end
    
    local sim_time = entity.get_prop(ent, "m_flSimulationTime")
    local origin_x, origin_y, origin_z = entity.get_prop(ent, "m_vecOrigin")
    if not sim_time or not origin_x then return end
    
    local vel_x, vel_y, vel_z = entity.get_prop(ent, "m_vecVelocity[0]") or 0, 
                                 entity.get_prop(ent, "m_vecVelocity[1]") or 0,
                                 entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local eye_offset_z = entity.get_prop(ent, "m_vecViewOffset[2]") or 64
    local yaw, pitch = entity.get_prop(ent, "m_angEyeAngles[1]") or 0, entity.get_prop(ent, "m_angEyeAngles[0]") or 0
    local flags, duck = entity.get_prop(ent, "m_fFlags") or 0, entity.get_prop(ent, "m_flDuckAmount") or 0
    local speed = vec_length(vel_x, vel_y, vel_z)
    local current_tick = globals.tickcount()
    local is_grounded = is_on_ground(ent, data)
    
    local dt = sim_time - (data.prev_sim_time or sim_time)
    if dt <= 0 then dt = CONFIG.TICK_INTERVAL end
    
    calculate_acceleration(data, vel_x, vel_y, vel_z, dt)
    
    data.velocity_delta = vec_distance(data.prev_velocity.x, data.prev_velocity.y, data.prev_velocity.z, vel_x, vel_y, vel_z)
    data.origin_delta = vec_distance(data.prev_origin.x, data.prev_origin.y, data.prev_origin.z, origin_x, origin_y, origin_z)
    data.lc_break_detected = data.origin_delta > 64 or data.velocity_delta > 200
    
    local expected_ticks = math.floor(dt / CONFIG.TICK_INTERVAL + 0.5)
    data.is_choking = expected_ticks > 1
    data.last_choke = data.is_choking and (expected_ticks - 1) or 0
    
    local head_z = origin_z + (duck > 0.5 and 46 or 64)
    local max_extrap = ui.get(ui_elements.ie_extrapolation_ticks)
    local predicted, pred_vel
    if ui.get(ui_elements.ie_extrapolation) then
        predicted, pred_vel = extrapolate_position({ x = origin_x, y = origin_y, z = origin_z },
            { x = vel_x, y = vel_y, z = vel_z }, data.avg_acceleration, max_extrap, is_grounded, duck)
    else
        predicted, pred_vel = { x = origin_x, y = origin_y, z = origin_z }, { x = vel_x, y = vel_y, z = vel_z }
    end
    data.predicted_origin, data.predicted_velocity = predicted, pred_vel
    data.extrapolation_confidence = #data.velocity_history >= 5 and 
        math.max(0.3, 1 - math.sqrt((function() local v = 0; for i = #data.velocity_history - 4, #data.velocity_history do 
            v = v + (data.velocity_history[i].speed)^2 end; return v/5 end)()) / 100) or 0.5
    
    local record = {
        sim_time = sim_time, tick_count = time_to_ticks(sim_time),
        origin = { x = origin_x, y = origin_y, z = origin_z },
        head_pos = { x = origin_x, y = origin_y, z = head_z },
        angles = { pitch = pitch, yaw = yaw },
        velocity = { x = vel_x, y = vel_y, z = vel_z },
        acceleration = { x = data.acceleration.x, y = data.acceleration.y, z = data.acceleration.z },
        flags = flags, duck = duck, speed = speed, time = globals.realtime(), is_grounded = is_grounded,
        body_yaw = entity.get_prop(ent, "m_flPoseParameter", CONFIG.POSE_BODY_YAW),
        is_lc_break = data.lc_break_detected, is_choking = data.is_choking, choke_amount = data.last_choke,
        predicted_origin = predicted, predicted_velocity = pred_vel,
        extrapolation_confidence = data.extrapolation_confidence,
        predicted_side = data.predicted_side, resolve_angle = data.last_resolve,
        confidence = data.confidence, valid = true, score = 0
    }
    
    while #data.backtrack_records > 0 and current_tick - data.backtrack_records[1].tick_count > CONFIG.BACKTRACK_HISTORY_SIZE do
        table.remove(data.backtrack_records, 1)
    end
    
    for _, rec in ipairs(data.backtrack_records) do
        if math.abs(rec.sim_time - sim_time) < 0.001 then
            data.prev_prev_origin, data.prev_prev_velocity = { x = data.prev_origin.x, y = data.prev_origin.y, z = data.prev_origin.z },
                { x = data.prev_velocity.x, y = data.prev_velocity.y, z = data.prev_velocity.z }
            data.prev_origin, data.prev_velocity, data.prev_sim_time = { x = origin_x, y = origin_y, z = origin_z },
                { x = vel_x, y = vel_y, z = vel_z }, sim_time
            return
        end
    end
    
    table.insert(data.backtrack_records, record)
    while #data.backtrack_records > CONFIG.BACKTRACK_HISTORY_SIZE do table.remove(data.backtrack_records, 1) end
    
    data.prev_prev_origin, data.prev_prev_velocity = { x = data.prev_origin.x, y = data.prev_origin.y, z = data.prev_origin.z },
        { x = data.prev_velocity.x, y = data.prev_velocity.y, z = data.prev_velocity.z }
    data.prev_origin, data.prev_velocity, data.prev_sim_time = { x = origin_x, y = origin_y, z = origin_z },
        { x = vel_x, y = vel_y, z = vel_z }, sim_time
end

-- ============== SCORING ==============

local function calculate_backtrack_score(ent, data, record, tick_diff, lp_origin, interpolated_pos, extrapolated_pos)
    local score = 0
    local optimal_tick = #data.best_tick_history > 5 and (function() local s = 0; for _, t in ipairs(data.best_tick_history) do s = s + t end; return s / #data.best_tick_history end)() or 20
    score = score + math.max(0, 100 - math.abs(tick_diff - optimal_tick) * 2)
    local dist = vec_distance(lp_origin.x, lp_origin.y, lp_origin.z, record.origin.x, record.origin.y, record.origin.z)
    score = score + math.max(0, 100 - dist / 15) * CONFIG.WEIGHT_DISTANCE + math.max(0, 100 - record.speed / 2.5) * CONFIG.WEIGHT_VELOCITY
    if record.is_lc_break then score = score + 200 * CONFIG.WEIGHT_LC_BREAK end
    if record.is_choking then score = score + math.min(record.choke_amount * 20, 100) end
    if interpolated_pos then
        local interp_dist = vec_distance(lp_origin.x, lp_origin.y, lp_origin.z, interpolated_pos.x, interpolated_pos.y, interpolated_pos.z)
        if interp_dist < dist then score = score + 50 * CONFIG.WEIGHT_INTERPOLATED end
    end
    if extrapolated_pos and record.extrapolation_confidence > 0.5 then
        local extrap_dist = vec_distance(lp_origin.x, lp_origin.y, lp_origin.z, extrapolated_pos.x, extrapolated_pos.y, extrapolated_pos.z)
        if extrap_dist < dist then score = score + 40 * CONFIG.WEIGHT_EXTRAPOLATED * record.extrapolation_confidence end
    end
    return score
end

-- ============== BEST RECORD ==============

local function get_best_backtrack_record(ent, data)
    local lp = entity.get_local_player()
    if not lp then return nil, 0, 0 end
    local lx, ly, lz = entity.get_prop(lp, "m_vecOrigin")
    if not lx then return nil, 0, 0 end
    
    local lp_origin, max_ticks, current_tick = { x = lx, y = ly, z = lz }, ui.get(ui_elements.bt_ticks), globals.tickcount()
    local best_record, best_score, best_tick = nil, -math.huge, 0
    local best_interp_pos, best_extrap_pos, best_interpolated, best_extrapolated, best_cubic, best_spline, best_interp_factor = nil, nil, false, false, false, false, 0
    
    local sorted = {}
    for _, rec in ipairs(data.backtrack_records) do
        if rec.valid and rec.tick_count then
            local tick_diff = current_tick - rec.tick_count
            if tick_diff > 0 and tick_diff <= max_ticks then table.insert(sorted, { record = rec, tick_diff = tick_diff }) end
        end
    end
    table.sort(sorted, function(a, b) return a.tick_diff < b.tick_diff end)
    
    local subtick_steps = ui.get(ui_elements.ie_subticks)
    for i, entry in ipairs(sorted) do
        local record, tick_diff = entry.record, entry.tick_diff
        local prev_rec, next_rec = sorted[i + 1] and sorted[i + 1].record, sorted[i - 1] and sorted[i - 1].record
        local prev_prev_rec, next_next_rec = sorted[i + 2] and sorted[i + 2].record, sorted[i - 2] and sorted[i - 2].record
        
        if ui.get(ui_elements.ie_interpolation) and next_rec then
            for step = 1, subtick_steps do
                local t = step / (subtick_steps + 1)
                local interp_pos, is_cubic, is_spline = nil, false, false
                if ui.get(ui_elements.ie_spline) and prev_rec and next_next_rec then
                    interp_pos, is_spline = interpolate_position_spline(prev_rec, record, next_rec, next_next_rec, t), true
                elseif ui.get(ui_elements.ie_interpolation) then
                    interp_pos, is_cubic = interpolate_position_cubic(record, next_rec, t, (next_rec.tick_count - record.tick_count) * CONFIG.TICK_INTERVAL), true
                end
                if interp_pos then
                    local score = calculate_backtrack_score(ent, data, record, tick_diff - t, lp_origin, interp_pos, nil)
                    if score > best_score then
                        best_score, best_record, best_tick = score, record, tick_diff - t
                        best_interp_pos, best_interpolated, best_cubic, best_spline, best_interp_factor = interp_pos, true, is_cubic, is_spline, t
                    end
                end
            end
        end
        
        local extrap_pos = ui.get(ui_elements.ie_extrapolation) and record.extrapolation_confidence > 0.5 and record.predicted_origin or nil
        local score = calculate_backtrack_score(ent, data, record, tick_diff, lp_origin, nil, extrap_pos)
        if score > best_score then
            best_score, best_record, best_tick = score, record, tick_diff
            best_extrap_pos, best_extrapolated, best_interpolated, best_cubic, best_spline, best_interp_factor = extrap_pos, extrap_pos ~= nil, false, false, false, 0
        end
    end
    
    if best_tick > 0 then
        table.insert(data.best_tick_history, math.floor(best_tick))
        while #data.best_tick_history > 20 do table.remove(data.best_tick_history, 1) end
    end
    
    return best_record, best_tick, best_score, best_interp_pos, best_extrap_pos, best_interpolated, best_extrapolated, best_cubic, best_spline, best_interp_factor
end

-- ============== APPLY BACKTRACK ==============

local function apply_backtrack(cmd, ent, data, record, tick_diff, score, interp_pos, extrap_pos, is_interpolated, is_extrapolated, is_cubic, is_spline, interp_factor)
    if not record then return false end
    
    local final_origin = is_interpolated and interp_pos or (is_extrapolated and extrap_pos or record.origin)
    cmd.tickcount = record.tick_count + (is_interpolated and math.floor(interp_factor) or 0)
    
    data.backtrack_target_tick, data.backtrack_sim_time, data.backtrack_origin = tick_diff, record.sim_time, final_origin
    data.backtrack_angles, data.backtrack_velocity, data.backtrack_is_valid, data.backtrack_score = 
        { pitch = record.angles.pitch, yaw = record.angles.yaw }, record.velocity, true, score
    data.backtrack_is_interpolated, data.backtrack_is_extrapolated = is_interpolated, is_extrapolated
    data.backtrack_is_cubic, data.backtrack_is_spline, data.backtrack_interp_factor = is_cubic, is_spline, interp_factor
    
    global_stats.backtrack_shots = global_stats.backtrack_shots + 1
    global_stats.backtrack_ticks_used = global_stats.backtrack_ticks_used + tick_diff
    global_stats.backtrack_best_score = math.max(global_stats.backtrack_best_score, score)
    if record.is_lc_break then global_stats.backtrack_lc_breaks = global_stats.backtrack_lc_breaks + 1 end
    if is_interpolated then global_stats.backtrack_interpolated_hits = global_stats.backtrack_interpolated_hits + 1
        if is_cubic then global_stats.backtrack_cubic_hits = global_stats.backtrack_cubic_hits + 1 end
        if is_spline then global_stats.backtrack_spline_hits = global_stats.backtrack_spline_hits + 1 end
    end
    if is_extrapolated then global_stats.backtrack_extrapolated_hits = global_stats.backtrack_extrapolated_hits + 1
        if not record.is_grounded then global_stats.backtrack_air_pred_hits = global_stats.backtrack_air_pred_hits + 1 end
    end
    if global_stats.backtrack_shots > 0 then global_stats.backtrack_avg_tick = global_stats.backtrack_ticks_used / global_stats.backtrack_shots end
    return true
end

-- ============== ANALYSIS FUNCTIONS ==============

local function read_pose(ent, data)
    local body_yaw = entity.get_prop(ent, "m_flPoseParameter", CONFIG.POSE_BODY_YAW)
    if body_yaw then data.pose_body_yaw, data.pose_body_yaw_angle = body_yaw, (body_yaw - 0.5) * 360 end
    local body_pitch = entity.get_prop(ent, "m_flPoseParameter", CONFIG.POSE_BODY_PITCH)
    if body_pitch then data.pose_body_pitch, data.has_roll = body_pitch, math.abs((body_pitch - 0.5) * 360) > 45 end
end

local function analyze_anim_layers(ent, data)
    local layer3_w, layer4_w = entity.get_prop(ent, "m_flLayerWeight", 3) or 0, entity.get_prop(ent, "m_flLayerWeight", 4) or 0
    local total = layer3_w + layer4_w
    if total > 0.7 then
        data.is_extended, data.extended_desync_amount, data.bodyyaw_side = true, total * 120, layer3_w > layer4_w and SIDES.LEFT or SIDES.RIGHT
        return true
    end
    data.is_extended = false
    return false
end

local function analyze_jitter(data, eye_yaw)
    if #data.angle_history < 5 then return end
    local changes, oscillations, last_dir = {}, 0, 0
    for i = #data.angle_history, math.max(1, #data.angle_history - 30), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            table.insert(changes, diff)
            local dir = diff > 0 and 1 or -1
            if last_dir ~= 0 and dir ~= last_dir then oscillations = oscillations + 1 end
            last_dir = dir
        end
    end
    if #changes < 3 then return end
    local avg = 0; for _, v in ipairs(changes) do avg = avg + math.abs(v) end; avg = avg / #changes
    local variance = 0; for _, v in ipairs(changes) do variance = variance + (math.abs(v) - avg) ^ 2 end; variance = math.sqrt(variance / #changes)
    data.jitter_score, data.avg_angle_change, data.angle_variance, data.jitter_phase = variance, avg, variance, oscillations
    data.is_jitter = variance > CONFIG.JITTER_THRESHOLD or oscillations > 5
end

local function analyze_spin(data, eye_yaw)
    if #data.angle_history < 6 then return false end
    local total_rotation, samples, dir_votes = 0, 0, { left = 0, right = 0 }
    for i = #data.angle_history, math.max(1, #data.angle_history - 25), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            total_rotation, samples = total_rotation + math.abs(diff), samples + 1
            if diff > 0 then dir_votes.right = dir_votes.right + 1 else dir_votes.left = dir_votes.left + 1 end
        end
    end
    if samples == 0 then return false end
    local avg_speed = total_rotation / samples
    data.spin_speed, data.spin_direction = avg_speed, dir_votes.right > dir_votes.left and 1 or -1
    if avg_speed > CONFIG.SPIN_THRESHOLD and math.abs(dir_votes.right - dir_votes.left) / samples > 0.55 then
        data.is_spinning = true; return true
    end
    data.is_spinning = false; return false
end

local function analyze_extended_desync(ent, data)
    if data.pose_body_yaw_angle and math.abs(data.pose_body_yaw_angle) > CONFIG.EXTENDED_DESYNC_THRESHOLD then
        data.is_extended, data.extended_desync_amount, data.bodyyaw_side = true, math.abs(data.pose_body_yaw_angle), data.pose_body_yaw_angle > 0 and SIDES.LEFT or SIDES.RIGHT
        return true
    end
    return analyze_anim_layers(ent, data)
end

local function analyze_velocity(ent, data)
    local vx, vy, vz = entity.get_prop(ent, "m_vecVelocity[0]") or 0, entity.get_prop(ent, "m_vecVelocity[1]") or 0, entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local speed = math.sqrt(vx*vx + vy*vy)
    table.insert(data.velocity_history, { x = vx, y = vy, z = vz, speed = speed, time = globals.realtime() })
    while #data.velocity_history > CONFIG.MAX_VELOCITY do table.remove(data.velocity_history, 1) end
    data.is_moving = speed > 10
    
    if speed > 35 then
        local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
        if eye_yaw then
            local diff = angle_diff(math.deg(math.atan2(vy, vx)), eye_yaw)
            if diff > 22 and diff < 158 then return SIDES.RIGHT, 0.78
            elseif diff < -22 and diff > -158 then return SIDES.LEFT, 0.78
            elseif math.abs(diff) <= 22 then return SIDES.CENTER, 0.65 end
        end
    end
    if speed > 2 and speed < 18 then data.is_micro_moving = true; return data.predicted_side * -1, 0.52
    else data.is_micro_moving = false end
    
    data.is_crouching = (entity.get_prop(ent, "m_flDuckAmount") or 0) > 0.5
    data.is_air = bit.band(entity.get_prop(ent, "m_fFlags") or 0, 1) == 0
    return SIDES.CENTER, 0.18
end

local function analyze_freestand(ent, data)
    local lp = entity.get_local_player()
    if not lp then return SIDES.CENTER, 0 end
    local lx, ly, ex, ey = entity.get_prop(lp, "m_vecOrigin"), entity.get_prop(ent, "m_vecOrigin")
    if not lx or not ex then return SIDES.CENTER, 0 end
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return SIDES.CENTER, 0 end
    local diff = angle_diff(math.deg(math.atan2(ly - ey, lx - ex)), eye_yaw)
    if math.abs(diff) > 70 then
        data.is_freestanding, data.freestand_side = true, diff > 0 and SIDES.LEFT or SIDES.RIGHT
        return data.freestand_side, 0.75
    end
    data.is_freestanding = false
    return SIDES.CENTER, 0.12
end

local function analyze_memory(data)
    if #data.successful_resolves < 2 then return SIDES.CENTER, 0 end
    local current_time, left_w, right_w, total_w = globals.realtime(), 0, 0, 0
    for _, res in ipairs(data.successful_resolves) do
        local weight = math.exp(-(current_time - res.time) / CONFIG.MEMORY_DECAY_TIME) * (res.confidence or 0.5)
        if current_time - res.time < 5 then weight = weight * 1.5 end
        total_w = total_w + weight
        if res.side == SIDES.LEFT then left_w = left_w + weight
        elseif res.side == SIDES.RIGHT then right_w = right_w + weight end
    end
    if total_w < 0.25 then return SIDES.CENTER, 0 end
    local left_ratio, right_ratio = left_w / total_w, right_w / total_w
    if left_ratio > 0.55 then return SIDES.LEFT, left_ratio * 0.92
    elseif right_ratio > 0.55 then return SIDES.RIGHT, right_ratio * 0.92 end
    return SIDES.CENTER, 0.18
end

local function detect_dt(data)
    if not ui.get(ui_elements.dt_predict) then return false end
    local ct = globals.realtime()
    for i = #data.dt_shots, 1, -1 do if ct - data.dt_shots[i].time > 1.0 then table.remove(data.dt_shots, i) end end
    if #data.dt_shots < CONFIG.DT_SHOT_THRESHOLD then return false end
    
    local total_int, ints = 0, {}
    for i = 2, #data.dt_shots do
        local int = data.dt_shots[i].time - data.dt_shots[i-1].time
        if int < CONFIG.DT_TIME_THRESHOLD then total_int, ints = total_int + int, ints + 1 end
    end
    if #ints == 0 then return false end
    local avg = total_int / #ints
    if avg < 0.10 then data.dt_confidence = 0.92
    elseif avg < 0.15 then data.dt_confidence = 0.80
    elseif avg < CONFIG.DT_TIME_THRESHOLD then data.dt_confidence = 0.60
    else data.dt_detected = false; return false end
    data.dt_detected, data.dt_firing_speed = true, 1.0 / avg
    data.dt_predicted_side = data.predicted_side ~= 0 and data.predicted_side or SIDES.LEFT
    data.dt_angle_offset = data.dt_predicted_side * ui.get(ui_elements.dt_aggression)
    return true
end

local function track_shot(data)
    table.insert(data.dt_shots, { time = globals.realtime() })
    while #data.dt_shots > 25 do table.remove(data.dt_shots, 1) end
    detect_dt(data)
end

local function recognize_pattern(data)
    if data.is_spinning then return "spin", 0.90 end
    if data.is_jitter then return "jitter", 0.85 end
    if data.is_extended then return "extended", 0.82 end
    if data.is_fakewalking then return "fakewalk", 0.70 end
    if data.avg_angle_change < 3 and data.angle_variance < 15 then return "static", 0.78 end
    if data.avg_angle_change > 10 and data.avg_angle_change < 60 and data.jitter_phase > 2 then return "sway", 0.65 end
    return "unknown", 0.25
end

-- ============== PREDICTION ==============

local function get_prediction(ent)
    local data = get_data(ent)
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return 60, 0.35 end
    
    local predictions, base_weight = {}, 1.5
    
    -- Cloud data check
    if http_available and ui.get(ui_elements.cloud_enabled) then
        local cloud_data = cloud_resolver.get_data(ent)
        if cloud_data and cloud_data.confidence >= CONFIG.CLOUD_MIN_CONFIDENCE then
            data.cloud_angle, data.cloud_confidence, data.cloud_last_update = cloud_data.angle, cloud_data.confidence, globals.realtime()
            table.insert(predictions, { side = cloud_data.angle > 0 and SIDES.LEFT or SIDES.RIGHT, 
                conf = cloud_data.confidence, weight = base_weight * CONFIG.CLOUD_WEIGHT, source = "cloud" })
        end
    end
    
    local v_side, v_conf = analyze_velocity(ent, data)
    if v_conf > 0.25 then table.insert(predictions, { side = v_side, conf = v_conf, weight = base_weight * 1.15 }) end
    
    local pattern, p_conf = recognize_pattern(data)
    if p_conf > 0.25 then
        local side = SIDES.CENTER
        if pattern == "spin" then side, p_conf = data.spin_direction * -1, p_conf * 0.88
        elseif pattern == "jitter" then side, p_conf = (data.predicted_side ~= 0 and data.predicted_side or SIDES.LEFT) * -1, p_conf * 0.82
        elseif pattern == "extended" then side = data.bodyyaw_side end
        table.insert(predictions, { side = side, conf = p_conf, weight = base_weight * 1.4 })
    end
    
    local m_side, m_conf = analyze_memory(data)
    if m_conf > 0.30 then table.insert(predictions, { side = m_side, conf = m_conf, weight = base_weight * 1.7 }) end
    
    local f_side, f_conf = analyze_freestand(ent, data)
    if f_conf > 0.25 then table.insert(predictions, { side = f_side, conf = f_conf, weight = base_weight * 1.25 }) end
    
    if analyze_extended_desync(ent, data) then table.insert(predictions, { side = data.bodyyaw_side, conf = 0.80, weight = base_weight * 1.5 }) end
    if detect_dt(data) then table.insert(predictions, { side = data.dt_predicted_side, conf = data.dt_confidence * 0.85, weight = base_weight * 1.9 }) end
    
    if #predictions == 0 then return 60, 0.35 end
    
    local total_w, weighted_side, has_cloud = 0, 0, false
    for _, p in ipairs(predictions) do
        weighted_side, total_w = weighted_side + (p.side * p.conf * p.weight), total_w + (p.conf * p.weight)
        if p.source == "cloud" then has_cloud = true end
    end
    
    local final_side = total_w > 0 and weighted_side / total_w or 0
    local final_conf = total_w > 0 and total_w / #predictions or 0.35
    
    if final_side > 0.18 then final_side = SIDES.LEFT
    elseif final_side < -0.18 then final_side = SIDES.RIGHT
    else final_side = SIDES.CENTER end
    
    local angle = final_side * CONFIG.EXTENDED_DESYNC_MAX * final_conf * (ui.get(ui_elements.aggression) / 5)
    if data.is_jitter then angle = angle * 0.82 end
    if data.is_spinning then angle = angle + data.spin_direction * data.spin_speed * 0.25 end
    if data.is_extended then angle = angle * 1.15 end
    if data.dt_detected then angle = angle + data.dt_angle_offset end
    
    angle = clamp(angle, -165, 165)
    data.predicted_side, data.confidence, data.cloud_used = final_side, final_conf, has_cloud
    return angle, final_conf
end

-- ============== BRUTEFORCE ==============

local function get_bf_angle(data)
    local strategy = ui.get(ui_elements.bf_mode)
    if strategy == "Smart Adaptive" then
        local entry = BF_PATTERNS.Smart_Adaptive[((data.bf_index - 1) % #BF_PATTERNS.Smart_Adaptive) + 1]
        return clamp(entry.angle + math.random(-4, 4), -165, 165), 0.35 + entry.weight * 0.1
    elseif strategy == "Multi-Stage Pro" then
        local angles = BF_PATTERNS.Multi_Stage_Pro[data.bf_state.stage] or BF_PATTERNS.Multi_Stage_Pro[1]
        return angles[((data.bf_index - 1) % #angles) + 1] + math.random(-5, 5), 0.32 + data.bf_state.stage * 0.06
    elseif strategy == "Anti-Jitter" then return BF_PATTERNS.Anti_Jitter[((data.bf_index - 1) % #BF_PATTERNS.Anti_Jitter) + 1], 0.42
    elseif strategy == "Anti-Spin" then return BF_PATTERNS.Anti_Spin[((data.bf_index - 1) % #BF_PATTERNS.Anti_Spin) + 1] + data.spin_direction * 35, 0.45
    elseif strategy == "Extended" then return BF_PATTERNS.Extended[((data.bf_index - 1) % #BF_PATTERNS.Extended) + 1], 0.50 end
    return 60, 0.35
end

local function advance_bf(data, hit)
    if hit then table.insert(data.hit_angles, data.bf_angle); if #data.hit_angles > 20 then table.remove(data.hit_angles, 1) end; return end
    if data.consecutive_misses < ui.get(ui_elements.bf_delay) then return end
    data.bf_index = data.bf_index + 1
    if ui.get(ui_elements.bf_mode) == "Multi-Stage Pro" and data.bf_index > #(BF_PATTERNS.Multi_Stage_Pro[data.bf_state.stage] or {}) then
        data.bf_index, data.bf_state.stage = 1, (data.bf_state.stage % 5) + 1
    end
end

-- ============== APPLY ==============

local function apply_resolve(ent, angle, conf)
    if not entity.is_alive(ent) then return end
    local data = get_data(ent)
    if globals.realtime() - data.last_plist_update < CONFIG.SAMPLE_RATE then return end
    data.last_plist_update = globals.realtime()
    if ui.get(ui_elements.resolve_method) == "PList Force" or ui.get(ui_elements.resolve_method) == "Hybrid (All)" then
        plist_set_force_angle(ent, angle)
        data.force_angle, data.is_resolved = angle, true
    end
end

-- ============== MAIN RESOLVER ==============

local function resolve(ent)
    if not ui.get(ui_elements.enabled) then return 60, 0.35 end
    if not entity.is_alive(ent) then return 60, 0.35 end
    
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return 60, 0.35 end
    
    local data = get_data(ent)
    local ct = globals.realtime()
    
    table.insert(data.angle_history, { angle = eye_yaw, time = ct })
    while #data.angle_history > CONFIG.MAX_HISTORY do table.remove(data.angle_history, 1) end
    
    read_pose(ent, data)
    analyze_jitter(data, eye_yaw)
    analyze_spin(data, eye_yaw)
    analyze_extended_desync(ent, data)
    analyze_velocity(ent, data)
    record_backtrack(ent, data)
    
    local angle, conf, mode = 60, 0.35, ui.get(ui_elements.mode)
    
    if ui.get(ui_elements.override_key) then
        local ov = ui.get(ui_elements.override_mode)
        angle = ov == "Left" and CONFIG.DESYNC_MAX or ov == "Right" and -CONFIG.DESYNC_MAX or 
            ov == "Opposite" and -data.predicted_side * CONFIG.DESYNC_MAX or (data.predicted_side or 1) * CONFIG.DESYNC_MAX
        apply_resolve(ent, angle, 1.0)
        return angle, 1.0
    end
    
    if mode == "Cloud Priority" then
        if http_available and ui.get(ui_elements.cloud_enabled) then
            local cloud_data = cloud_resolver.get_data(ent)
            if cloud_data and cloud_data.confidence >= 0.6 then
                angle, conf, data.cloud_used = cloud_data.angle, cloud_data.confidence, true
                global_stats.cloud_resolves = global_stats.cloud_resolves + 1
            else angle, conf = get_prediction(ent) end
        else angle, conf = get_prediction(ent) end
    elseif mode == "Adaptive Pro" then local p_angle, p_conf = get_prediction(ent); if p_conf > 0.30 then angle, conf = p_angle, p_conf else angle, conf = get_bf_angle(data) end
    elseif mode == "Deep Memory" then local m_side, m_conf = analyze_memory(data); if m_conf > 0.40 then angle, conf = m_side * CONFIG.DESYNC_MAX, m_conf else angle, conf = get_prediction(ent) end
    elseif mode == "Animation+" then if analyze_extended_desync(ent, data) then angle, conf = data.bodyyaw_side * CONFIG.EXTENDED_DESYNC_MAX, 0.78 else angle, conf = get_prediction(ent) end
    elseif mode == "Extended+" then if data.is_extended then angle, conf = data.bodyyaw_side * math.min(data.extended_desync_amount * 1.25, 165), 0.82 else angle, conf = get_bf_angle(data) end
    elseif mode == "Smart BF" then angle, conf = get_bf_angle(data)
    elseif mode == "Anti-Everything" then local p_angle, p_conf = get_prediction(ent)
        if data.is_spinning then angle, conf = data.spin_direction * -90, 0.75
        elseif data.is_jitter then angle, conf = p_angle * 0.85, p_conf
        elseif data.is_extended then angle, conf = data.bodyyaw_side * CONFIG.EXTENDED_DESYNC_MAX, 0.80
        else angle, conf = p_angle, p_conf end
    end
    
    angle, conf = clamp(tonumber(angle) or 60, -165, 165), clamp(tonumber(conf) or 0.35, 0, 1)
    local min_conf = ui.get(ui_elements.confidence_min) / 100
    if conf < min_conf then conf = min_conf end
    
    data.last_resolve, data.bf_angle, data.last_update = angle, angle, ct
    apply_resolve(ent, angle, conf)
    global_stats.total_resolves = global_stats.total_resolves + 1
    return angle, conf
end

-- ============== SETUP COMMAND ==============

client.set_event_callback("setup_command", function(cmd)
    if not ui.get(ui_elements.enabled) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    -- Cloud resolver
    if http_available and ui.get(ui_elements.cloud_enabled) then
        if not cloud_state.initialized then cloud_resolver.init() end
        local url = ui.get(ui_elements.cloud_url)
        if url and url ~= "" then CLOUD_CONFIG.SERVER_URL = url end
        cloud_resolver.poll()
        if globals.tickcount() % 100 == 0 then cloud_resolver.clean() end
    end
    
    local players = entity.get_players(true)
    if not players then return end
    
    for _, ent in ipairs(players) do
        if entity.is_alive(ent) then
            resolve(ent)
            local data = get_data(ent)
            local wpn = entity.get_player_weapon(ent)
            if wpn then
                local ammo = entity.get_prop(wpn, "m_iClip1") or 0
                if data.last_ammo > ammo and ammo >= 0 then track_shot(data) end
                data.last_ammo = ammo
            end
        end
    end
end)

-- ============== EVENTS ==============

client.set_event_callback("aim_fire", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    if not ent then return end
    
    local data = get_data(ent)
    data.shots, data.last_shot_time = data.shots + 1, globals.realtime()
    global_stats.shots = global_stats.shots + 1
    
    local angle, conf = resolve(ent)
    local record, tick_diff, score, interp_pos, extrap_pos, is_interp, is_extrap, is_cubic, is_spline, interp_factor = get_best_backtrack_record(ent, data)
    
    if record then
        apply_backtrack(e, ent, data, record, tick_diff, score, interp_pos, extrap_pos, is_interp, is_extrap, is_cubic, is_spline, interp_factor)
        if ui.get(ui_elements.log_hits) then
            local flags = is_interp and (is_spline and "SPLINE" or is_cubic and "CUBIC" or "") or is_extrap and (not record.is_grounded and "AIR" or "EXTRAP") or ""
            client.log(string.format("[FIRE] T:%d | BT:%.1f (%.0f) | %s%s", ent, tick_diff, score, flags, data.cloud_used and " [CLOUD]" or ""))
        end
    elseif ui.get(ui_elements.log_hits) then client.log(string.format("[FIRE] T:%d | BT:N/A", ent)) end
end)

client.set_event_callback("aim_hit", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    if not ent then return end
    
    local data = get_data(ent)
    data.hits, data.consecutive_hits, data.consecutive_misses = data.hits + 1, data.consecutive_hits + 1, 0
    global_stats.hits, global_stats.streak_current = global_stats.hits + 1, global_stats.streak_current + 1
    global_stats.streak_best = math.max(global_stats.streak_best, global_stats.streak_current)
    if data.backtrack_is_valid then global_stats.backtrack_hits = global_stats.backtrack_hits + 1 end
    if data.cloud_used then global_stats.cloud_hits = global_stats.cloud_hits + 1 end
    
    table.insert(data.successful_resolves, { side = data.last_resolve > 0 and SIDES.LEFT or SIDES.RIGHT,
        angle = data.last_resolve, confidence = data.confidence, time = globals.realtime() })
    if #data.successful_resolves > CONFIG.MAX_ANGLES then table.remove(data.successful_resolves, 1) end
    
    if http_available and ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then cloud_resolver.report_data(steam64, data.last_resolve, data.confidence, true, data.detected_pattern) end
    end
    
    global_stats.resolved = global_stats.resolved + 1
    if data.is_extended then global_stats.extended_hits = global_stats.extended_hits + 1 end
    if data.is_spinning then global_stats.spin_hits = global_stats.spin_hits + 1 end
    if data.is_jitter then global_stats.jitter_hits = global_stats.jitter_hits + 1 end
    if global_stats.shots > 0 then global_stats.prediction_accuracy = global_stats.hits / global_stats.shots end
    
    advance_bf(data, true)
    if ui.get(ui_elements.log_hits) then
        local bt_info = data.backtrack_is_valid and string.format(" | BT:%.1f%s", data.backtrack_target_tick,
            data.backtrack_is_spline and " [SPLINE]" or data.backtrack_is_cubic and " [CUBIC]" or 
            data.backtrack_is_extrapolated and " [EXTRAP]" or "") or ""
        client.log(string.format("[HIT] T:%d | Streak:%d%s%s", ent, data.consecutive_hits, bt_info, data.cloud_used and " [CLOUD]" or ""))
    end
    data.backtrack_is_valid, data.cloud_used = false, false
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent, reason = e.target, e.reason or ""
    if not ent or (reason ~= "prediction error" and reason ~= "resolver") then return end
    
    local data = get_data(ent)
    data.misses, data.consecutive_misses, data.consecutive_hits = data.misses + 1, data.consecutive_misses + 1, 0
    global_stats.misses, global_stats.streak_current = global_stats.misses + 1, 0
    
    if http_available and ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then cloud_resolver.report_data(steam64, data.last_resolve, math.max(0.1, data.confidence - 0.2), false, data.detected_pattern) end
    end
    
    advance_bf(data, false)
    if ui.get(ui_elements.log_hits) then client.log(string.format("[MISS] T:%d | %s", ent, reason)) end
    data.backtrack_is_valid, data.cloud_used = false, false
end)

-- ============== VISUALIZATION ==============

client.set_event_callback("paint", function()
    if not ui.get(ui_elements.enabled) then return end
    
    if ui.get(ui_elements.bt_visualize) then
        local players = entity.get_players(true)
        if players then
            for _, ent in ipairs(players) do
                if entity.is_alive(ent) then
                    local data = get_data(ent)
                    for _, record in ipairs(data.backtrack_records) do
                        if record.valid then
                            local x, y = renderer.world_to_screen(record.origin.x, record.origin.y, record.origin.z + 5)
                            if x and y then
                                local tick_diff, alpha = globals.tickcount() - record.tick_count, math.max(50, 255 - (globals.tickcount() - record.tick_count) * 5)
                                local r, g, b = tick_diff > 30 and 255 or tick_diff > 20 and 255 or 100, 
                                    tick_diff > 30 and 100 or tick_diff > 20 and 255 or 255, tick_diff > 30 and 100 or tick_diff > 20 and 100 or 100
                                if record.is_lc_break then r, g, b = 255, 0, 255 end
                                if not record.is_grounded then r, g, b = 0, 255, 255 end
                                renderer.circle(x, y, r, g, b, alpha, nil, 3, 0, 1)
                            end
                        end
                    end
                end
            end
        end
    end
    
    if not ui.get(ui_elements.show_stats) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    local x, y = 10, 200
    renderer.text(x, y, 255, 255, 255, 255, "", 0, "══════ RESOLVER v18.1 ══════")
    y = y + 12
    
    if http_available and ui.get(ui_elements.cloud_enabled) then
        local cloud_status = cloud_state.initialized and "CONNECTED" or "CONNECTING..."
        local r, g, b = cloud_state.initialized and 100 or 255, cloud_state.initialized and 255 or 100, 100
        renderer.text(x, y, r, g, b, 255, "", 0, string.format("CLOUD: %s | Syncs: %d", cloud_status, cloud_state.sync_count))
        y = y + 12
    elseif not http_available then
        renderer.text(x, y, 255, 100, 100, 255, "", 0, "HTTP: Unavailable - Cloud disabled")
        y = y + 12
    end
    
    local hitrate = global_stats.shots > 0 and (global_stats.hits / global_stats.shots * 100) or 0
    renderer.text(x, y, 200, 200, 200, 255, "", 0, string.format("S:%d H:%d M:%d | %.1f%%", global_stats.shots, global_stats.hits, global_stats.misses, hitrate))
    y = y + 12
    
    local bt_hitrate = global_stats.backtrack_shots > 0 and (global_stats.backtrack_hits / global_stats.backtrack_shots * 100) or 0
    renderer.text(x, y, 100, 200, 255, 255, "", 0, 
        string.format("BT: %d/%d (%.1f%%) | Avg:%.1f ticks", global_stats.backtrack_hits, global_stats.backtrack_shots, bt_hitrate, global_stats.backtrack_avg_tick))
    y = y + 12
    
    if http_available and ui.get(ui_elements.cloud_enabled) then
        renderer.text(x, y, 100, 255, 200, 255, "", 0, 
            string.format("Cloud: %d resolves, %d hits", global_stats.cloud_resolves, global_stats.cloud_hits))
        y = y + 12
    end
    
    renderer.text(x, y, 150, 200, 255, 255, "", 0, 
        string.format("Ext:%d Spin:%d Jit:%d", global_stats.extended_hits, global_stats.spin_hits, global_stats.jitter_hits))
end)

-- ============== CLEANUP ==============

client.set_event_callback("player_death", function(e)
    local victim = client.userid_to_entindex(e.userid)
    if victim and player_data[victim] then plist_clear_force(victim); player_data[victim] = nil end
end)

client.set_event_callback("round_start", function()
    local players = entity.get_players()
    if players then for _, ent in ipairs(players) do plist_clear_force(ent) end end
    
    for _, data in pairs(player_data) do
        data.bf_index, data.bf_state.stage = 1, 1
        data.angle_history, data.velocity_history, data.backtrack_records = {}, {}, {}
        data.consecutive_hits, data.consecutive_misses = 0, 0
        data.is_jitter, data.is_spinning, data.is_extended = false, false, false
        data.dt_detected, data.dt_shots = false, {}
        data.detected_pattern, data.backtrack_is_valid = "unknown", false
        data.acceleration, data.prev_acceleration = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
        data.cloud_used, data.cloud_angle, data.cloud_confidence = false, nil, nil
    end
    global_stats.streak_current = 0
    client.log("[Resolver v18.1] Round start" .. (http_available and " - Cloud Ready" or " - Local Only"))
end)

client.log("[Forward HVH Resolver v18.1] Loaded - HTTP: " .. (http_available and "Available" or "Unavailable"))
