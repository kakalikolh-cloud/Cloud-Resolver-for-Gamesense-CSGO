--[[
    FORWARD HVH RESOLVER v18.3 - CLOUD SYNC
    Professional resolver with cloud-based data sharing between teammates
    
    v18.3:
    - Fixed Gamesense HTTP API callback format
    - Proper error handling for HTTP requests
    
    by Super Z
]]

-- ============== HTTP MODULE ==============
local http = require("gamesense/http")

-- ============== CLOUD RESOLVER MODULE ==============

local cloud_resolver = {}

local CLOUD_CONFIG = {
    SERVER_URL = "https://cloud-resolver-for-gamesense-csgo.onrender.com/api",
    POLL_INTERVAL = 2.0,
    DATA_TIMEOUT = 60.0,
    MIN_CONFIDENCE = 0.5,
    DEBUG = true
}

local cloud_state = {
    initialized = false,
    my_steamid = nil,
    my_steam64 = nil,
    last_poll = 0,
    cloud_data = {},
    sync_count = 0,
    error_count = 0,
    last_error = nil
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

function cloud_resolver.init()
    local lp = entity.get_local_player()
    if not lp then return false end
    
    cloud_state.my_steam64 = entity.get_steam64(lp)
    if not cloud_state.my_steam64 or cloud_state.my_steam64 == 0 then return false end
    
    cloud_state.my_steamid = tostring(cloud_state.my_steam64)
    cloud_state.initialized = true
    
    if CLOUD_CONFIG.DEBUG then
        client.log("[Cloud Resolver] Initialized: " .. cloud_state.my_steamid)
    end
    
    return true
end

function cloud_resolver.report_data(enemy_steam64, angle, confidence, hit, pattern)
    if not cloud_state.initialized then
        if not cloud_resolver.init() then return false end
    end
    
    if not enemy_steam64 or enemy_steam64 == 0 then return false end
    
    angle = tonumber(angle) or 60
    confidence = math.max(0, math.min(1, tonumber(confidence) or 0.5))
    
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
    
    -- Gamesense HTTP API: http.post(url, {body, headers}, callback)
    http.post(url, {
        body = payload,
        headers = {["Content-Type"] = "application/json"}
    }, function(success, response)
        if not success then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "Request failed"
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver] POST failed")
            end
            return
        end
        
        if response and response.status and response.status ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP " .. tostring(response.status)
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver] Error: " .. tostring(response.status))
            end
            return
        end
        
        cloud_state.sync_count = cloud_state.sync_count + 1
        if CLOUD_CONFIG.DEBUG then
            client.log("[Cloud Resolver] Synced!")
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
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/get"
    
    -- Gamesense HTTP API: http.get(url, callback)
    -- callback(success, response) where response.status and response.body
    http.get(url, function(success, response)
        if not success then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "Request failed"
            return
        end
        
        if not response then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "No response"
            return
        end
        
        if response.status and response.status ~= 200 then
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
            if count > 0 then
                client.log("[Cloud Resolver] Updated: " .. count .. " players")
            end
        end
    end)
end

function cloud_resolver.get_data(enemy)
    if not cloud_state.initialized then return nil end
    
    local steam64 = entity.get_steam64(enemy)
    if not steam64 or steam64 == 0 then return nil end
    
    local data = cloud_state.cloud_data[tostring(steam64)]
    if not data then return nil end
    
    local age = globals.realtime() - (data.timestamp or 0)
    if age > CLOUD_CONFIG.DATA_TIMEOUT then
        cloud_state.cloud_data[tostring(steam64)] = nil
        return nil
    end
    
    if data.reporter == cloud_state.my_steamid then return nil end
    if (data.confidence or 0) < CLOUD_CONFIG.MIN_CONFIDENCE then return nil end
    
    return {
        angle = data.angle,
        confidence = data.confidence,
        pattern = data.pattern,
        hit = data.hit,
        age = age
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
    MAX_HISTORY = 200, MAX_ANGLES = 100, MAX_VELOCITY = 120,
    PREDICTION_DECAY = 0.90, CONFIDENCE_THRESHOLD = 0.20,
    JITTER_THRESHOLD = 18, SPIN_THRESHOLD = 75,
    EXTENDED_DESYNC_THRESHOLD = 48, DESYNC_MAX = 60,
    EXTENDED_DESYNC_MAX = 120, POSE_BODY_YAW = 11, POSE_BODY_PITCH = 12,
    SAMPLE_RATE = 0.012, DT_TIME_THRESHOLD = 0.22, DT_SHOT_THRESHOLD = 2,
    MEMORY_DECAY_TIME = 45, BACKTRACK_MAX_TICKS = 40,
    BACKTRACK_HISTORY_SIZE = 65, TICK_INTERVAL = 0.015625,
    CLOUD_WEIGHT = 2.5, CLOUD_MIN_CONFIDENCE = 0.5
}

local function create_stats()
    return {shots = 0, hits = 0, misses = 0, resolved = 0, streak_best = 0, streak_current = 0,
        total_resolves = 0, backtrack_shots = 0, backtrack_hits = 0, backtrack_ticks_used = 0,
        backtrack_avg_tick = 0, cloud_resolves = 0, cloud_hits = 0}
end

local function create_player_data()
    return {
        angle_history = {}, velocity_history = {}, backtrack_records = {},
        bf_index = 1, predicted_side = 0, confidence = 0.35, last_resolve = 60,
        jitter_score = 0, spin_speed = 0, spin_direction = 0, desync_amount = 60,
        extended_desync_amount = 0, bodyyaw_side = 0, avg_angle_change = 0, angle_variance = 0,
        pose_body_yaw_angle = 0, detected_pattern = "unknown", pattern_confidence = 0,
        shots = 0, hits = 0, misses = 0, consecutive_hits = 0, consecutive_misses = 0,
        successful_resolves = {}, best_tick_history = {}, dt_shots = {}, dt_detected = false,
        dt_confidence = 0, dt_angle_offset = 0, dt_predicted_side = 0, last_ammo = -1,
        backtrack_is_valid = false, backtrack_score = 0, backtrack_target_tick = 0,
        prev_origin = {x=0,y=0,z=0}, prev_velocity = {x=0,y=0,z=0}, acceleration = {x=0,y=0,z=0},
        is_on_ground = true, predicted_origin = {x=0,y=0,z=0}, predicted_velocity = {x=0,y=0,z=0},
        extrapolation_confidence = 0.5, lc_break_detected = false, velocity_delta = 0, origin_delta = 0,
        cloud_used = false, is_jitter = false, is_spinning = false, is_extended = false,
        is_moving = false, is_air = false, last_plist_update = 0
    }
end

local ui_elements = {
    enabled = ui.new_checkbox("RAGE", "Other", "Enable Resolver"),
    mode = ui.new_combobox("RAGE", "Other", "Resolver Mode", {"Cloud Priority", "Adaptive Pro", "Deep Memory", "Animation+", "Extended+", "Smart BF", "Anti-Everything"}),
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
    bt_label = ui.new_label("RAGE", "Other", "━━━ Backtrack ━━━"),
    bt_ticks = ui.new_slider("RAGE", "Other", "Max Ticks", 14, 40, 40, true, "ticks"),
    bt_visualize = ui.new_checkbox("RAGE", "Other", "Visualize History"),
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

ui.set(ui_elements.show_stats, true)
ui.set(ui_elements.log_hits, true)
ui.set(ui_elements.cloud_enabled, true)
ui.set(ui_elements.cloud_url, "https://cloud-resolver-for-gamesense-csgo.onrender.com/api")

local global_stats = create_stats()
local player_data = {}
local SIDES = {LEFT = -1, CENTER = 0, RIGHT = 1}

local function clamp(v, min, max)
    if type(v) ~= "number" then return min end
    return math.max(min, math.min(max, v))
end

local function normalize_angle(a)
    if type(a) ~= "number" then return 0 end
    while a > 180 do a = a - 360 end
    while a < -180 do a = a + 360 end
    return a
end

local function angle_diff(a, b) return normalize_angle((a or 0) - (b or 0)) end
local function get_data(ent)
    if not player_data[ent] then player_data[ent] = create_player_data() end
    return player_data[ent]
end

local function vec_length(x, y, z) return math.sqrt((x or 0)^2 + (y or 0)^2 + (z or 0)^2) end
local function vec_distance(x1, y1, z1, x2, y2, z2)
    return math.sqrt((x1-x2)^2 + (y1-y2)^2 + (z1-z2)^2)
end
local function time_to_ticks(t) return math.floor(t / CONFIG.TICK_INTERVAL + 0.5) end

-- Interpolation
local function catmull_rom_spline(p0, p1, p2, p3, t)
    t = clamp(t, 0, 1)
    return 0.5 * ((2*p1) + (-p0+p2)*t + (2*p0-5*p1+4*p2-p3)*t*t + (-p0+3*p1-3*p2+p3)*t*t*t)
end

-- PList
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

-- Backtrack
local function record_backtrack(ent, data)
    if not entity.is_alive(ent) then return end
    local sim_time = entity.get_prop(ent, "m_flSimulationTime")
    local ox, oy, oz = entity.get_prop(ent, "m_vecOrigin")
    if not sim_time or not ox then return end
    
    local vx, vy, vz = entity.get_prop(ent, "m_vecVelocity[0]") or 0, entity.get_prop(ent, "m_vecVelocity[1]") or 0, entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local duck = entity.get_prop(ent, "m_flDuckAmount") or 0
    local speed = vec_length(vx, vy, vz)
    local flags = entity.get_prop(ent, "m_fFlags") or 0
    local is_grounded = bit.band(flags, 1) ~= 0
    
    data.velocity_delta = vec_distance(data.prev_velocity.x, data.prev_velocity.y, data.prev_velocity.z, vx, vy, vz)
    data.origin_delta = vec_distance(data.prev_origin.x, data.prev_origin.y, data.prev_origin.z, ox, oy, oz)
    data.lc_break_detected = data.origin_delta > 64 or data.velocity_delta > 200
    
    local record = {
        sim_time = sim_time, tick_count = time_to_ticks(sim_time),
        origin = {x=ox, y=oy, z=oz}, velocity = {x=vx, y=vy, z=vz},
        angles = {yaw = yaw}, duck = duck, speed = speed, is_grounded = is_grounded,
        is_lc_break = data.lc_break_detected, confidence = data.confidence,
        resolve_angle = data.last_resolve, valid = true
    }
    
    for _, rec in ipairs(data.backtrack_records) do
        if math.abs(rec.sim_time - sim_time) < 0.001 then
            data.prev_origin, data.prev_velocity = {x=ox, y=oy, z=oz}, {x=vx, y=vy, z=vz}
            return
        end
    end
    
    table.insert(data.backtrack_records, record)
    while #data.backtrack_records > CONFIG.BACKTRACK_HISTORY_SIZE do table.remove(data.backtrack_records, 1) end
    data.prev_origin, data.prev_velocity = {x=ox, y=oy, z=oz}, {x=vx, y=vy, z=vz}
end

local function get_best_backtrack_record(ent, data)
    local lp = entity.get_local_player()
    if not lp then return nil, 0, 0 end
    local lx, ly, lz = entity.get_prop(lp, "m_vecOrigin")
    if not lx then return nil, 0, 0 end
    
    local max_ticks, current_tick = ui.get(ui_elements.bt_ticks), globals.tickcount()
    local best_record, best_score, best_tick = nil, -math.huge, 0
    
    for _, rec in ipairs(data.backtrack_records) do
        if rec.valid and rec.tick_count then
            local tick_diff = current_tick - rec.tick_count
            if tick_diff > 0 and tick_diff <= max_ticks then
                local dist = vec_distance(lx, ly, lz, rec.origin.x, rec.origin.y, rec.origin.z)
                local score = 100 - tick_diff * 2 + math.max(0, 100 - dist/15)
                if rec.is_lc_break then score = score + 100 end
                if score > best_score then
                    best_score, best_record, best_tick = score, rec, tick_diff
                end
            end
        end
    end
    
    return best_record, best_tick, best_score
end

local function apply_backtrack(cmd, record, tick_diff)
    if not record then return false end
    cmd.tickcount = record.tick_count
    return true
end

-- Analysis
local function analyze_jitter(data)
    if #data.angle_history < 5 then return end
    local changes, last_dir, oscillations = {}, 0, 0
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            table.insert(changes, diff)
            local dir = diff > 0 and 1 or -1
            if last_dir ~= 0 and dir ~= last_dir then oscillations = oscillations + 1 end
            last_dir = dir
        end
    end
    if #changes < 3 then return end
    local avg = 0
    for _, v in ipairs(changes) do avg = avg + math.abs(v) end
    avg = avg / #changes
    local var = 0
    for _, v in ipairs(changes) do var = var + (math.abs(v) - avg)^2 end
    data.jitter_score, data.avg_angle_change = math.sqrt(var/#changes), avg
    data.is_jitter = data.jitter_score > CONFIG.JITTER_THRESHOLD or oscillations > 4
end

local function analyze_spin(data)
    if #data.angle_history < 6 then return false end
    local total, samples, votes = 0, 0, {left=0, right=0}
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            local diff = angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle)
            total, samples = total + math.abs(diff), samples + 1
            if diff > 0 then votes.right = votes.right + 1 else votes.left = votes.left + 1 end
        end
    end
    if samples == 0 then return false end
    data.spin_speed, data.spin_direction = total/samples, votes.right > votes.left and 1 or -1
    data.is_spinning = data.spin_speed > CONFIG.SPIN_THRESHOLD
    return data.is_spinning
end

local function analyze_velocity(ent, data)
    local vx, vy, vz = entity.get_prop(ent, "m_vecVelocity[0]") or 0, entity.get_prop(ent, "m_vecVelocity[1]") or 0, entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local speed = math.sqrt(vx*vx + vy*vy)
    table.insert(data.velocity_history, {speed = speed})
    while #data.velocity_history > CONFIG.MAX_VELOCITY do table.remove(data.velocity_history, 1) end
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
        local weight = (res.confidence or 0.5)
        total_w = total_w + weight
        if res.side == SIDES.LEFT then left_w = left_w + weight
        elseif res.side == SIDES.RIGHT then right_w = right_w + weight end
    end
    if total_w < 0.25 then return SIDES.CENTER, 0 end
    local left_ratio, right_ratio = left_w/total_w, right_w/total_w
    if left_ratio > 0.55 then return SIDES.LEFT, left_ratio * 0.92
    elseif right_ratio > 0.55 then return SIDES.RIGHT, right_ratio * 0.92 end
    return SIDES.CENTER, 0.18
end

local function recognize_pattern(data)
    if data.is_spinning then return "spin", 0.90 end
    if data.is_jitter then return "jitter", 0.85 end
    if data.is_extended then return "extended", 0.82 end
    return "unknown", 0.25
end

-- Prediction
local function get_prediction(ent)
    local data = get_data(ent)
    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not eye_yaw then return 60, 0.35 end
    
    local predictions, base_weight = {}, 1.5
    
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
    
    local v_side, v_conf = analyze_velocity(ent, data)
    if v_conf > 0.25 then table.insert(predictions, {side = v_side, conf = v_conf, weight = base_weight * 1.15}) end
    
    local pattern, p_conf = recognize_pattern(data)
    if p_conf > 0.25 then
        local side = SIDES.CENTER
        if pattern == "spin" then side = data.spin_direction * -1
        elseif pattern == "jitter" then side = (data.predicted_side ~= 0 and data.predicted_side or SIDES.LEFT) * -1 end
        table.insert(predictions, {side = side, conf = p_conf, weight = base_weight * 1.4})
    end
    
    local m_side, m_conf = analyze_memory(data)
    if m_conf > 0.30 then table.insert(predictions, {side = m_side, conf = m_conf, weight = base_weight * 1.7}) end
    
    if #predictions == 0 then return 60, 0.35 end
    
    local total_w, weighted_side = 0, 0
    for _, p in ipairs(predictions) do
        weighted_side = weighted_side + (p.side * p.conf * p.weight)
        total_w = total_w + (p.conf * p.weight)
    end
    
    local final_side = total_w > 0 and weighted_side / total_w or 0
    local final_conf = total_w > 0 and total_w / #predictions or 0.35
    
    if final_side > 0.18 then final_side = SIDES.LEFT
    elseif final_side < -0.18 then final_side = SIDES.RIGHT
    else final_side = SIDES.CENTER end
    
    local angle = final_side * CONFIG.EXTENDED_DESYNC_MAX * final_conf * (ui.get(ui_elements.aggression) / 5)
    angle = clamp(angle, -165, 165)
    
    data.predicted_side, data.confidence = final_side, final_conf
    return angle, final_conf
end

-- Apply
local function apply_resolve(ent, angle, conf)
    if not entity.is_alive(ent) then return end
    local data = get_data(ent)
    if globals.realtime() - data.last_plist_update < CONFIG.SAMPLE_RATE then return end
    data.last_plist_update = globals.realtime()
    plist_set_force_angle(ent, angle)
end

-- Main Resolver
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
    record_backtrack(ent, data)
    
    local angle, conf, mode = 60, 0.35, ui.get(ui_elements.mode)
    
    if mode == "Cloud Priority" then
        if ui.get(ui_elements.cloud_enabled) then
            local cloud_data = cloud_resolver.get_data(ent)
            if cloud_data and cloud_data.confidence >= 0.6 then
                angle, conf, data.cloud_used = cloud_data.angle, cloud_data.confidence, true
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
    
    local record, tick_diff, score = get_best_backtrack_record(ent, data)
    if record then
        apply_backtrack(e, record, tick_diff)
        data.backtrack_is_valid, data.backtrack_target_tick, data.backtrack_score = true, tick_diff, score
        global_stats.backtrack_shots = global_stats.backtrack_shots + 1
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[FIRE] T:%d | BT:%d ticks%s", ent, tick_diff or 0, data.cloud_used and " [CLOUD]" or ""))
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
        angle = data.last_resolve, confidence = data.confidence, time = globals.realtime()
    })
    
    if ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            cloud_resolver.report_data(steam64, data.last_resolve, data.confidence, true, data.detected_pattern)
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[HIT] T:%d | Streak:%d%s", ent, data.consecutive_hits, data.cloud_used and " [CLOUD]" or ""))
    end
    
    data.backtrack_is_valid, data.cloud_used = false, false
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
    
    if ui.get(ui_elements.cloud_enabled) then
        local steam64 = entity.get_steam64(ent)
        if steam64 and steam64 ~= 0 then
            cloud_resolver.report_data(steam64, data.last_resolve, math.max(0.1, data.confidence - 0.2), false, data.detected_pattern)
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[MISS] T:%d | %s", ent, reason))
    end
    
    data.backtrack_is_valid, data.cloud_used = false, false
end)

client.set_event_callback("paint", function()
    if not ui.get(ui_elements.enabled) or not ui.get(ui_elements.show_stats) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    local x, y = 10, 200
    renderer.text(x, y, 255, 255, 255, 255, "", 0, "══════ RESOLVER v18.3 ══════")
    y = y + 12
    
    if ui.get(ui_elements.cloud_enabled) then
        local status = cloud_state.initialized and "CONNECTED" or "CONNECTING..."
        local r, g, b = cloud_state.initialized and 100 or 255, cloud_state.initialized and 255 or 100, 100
        renderer.text(x, y, r, g, b, 255, "", 0, string.format("CLOUD: %s | Syncs: %d | Err: %d", status, cloud_state.sync_count, cloud_state.error_count))
        y = y + 12
    end
    
    local hitrate = global_stats.shots > 0 and (global_stats.hits / global_stats.shots * 100) or 0
    renderer.text(x, y, 200, 200, 200, 255, "", 0, string.format("S:%d H:%d M:%d | %.1f%%", global_stats.shots, global_stats.hits, global_stats.misses, hitrate))
    y = y + 12
    
    local bt_rate = global_stats.backtrack_shots > 0 and (global_stats.backtrack_hits / global_stats.backtrack_shots * 100) or 0
    renderer.text(x, y, 100, 200, 255, 255, "", 0, string.format("BT: %d/%d (%.1f%%)", global_stats.backtrack_hits, global_stats.backtrack_shots, bt_rate))
    y = y + 12
    
    if ui.get(ui_elements.cloud_enabled) then
        renderer.text(x, y, 100, 255, 200, 255, "", 0, string.format("Cloud: %d resolves, %d hits", global_stats.cloud_resolves, global_stats.cloud_hits))
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
        data.angle_history, data.velocity_history, data.backtrack_records = {}, {}, {}
        data.consecutive_hits, data.consecutive_misses = 0, 0
        data.backtrack_is_valid, data.cloud_used = false, false
    end
    global_stats.streak_current = 0
    client.log("[Resolver v18.3] Round start - Cloud Ready!")
end)

client.log("[Forward HVH Resolver v18.3] Loaded - Cloud Sync Enabled!")
