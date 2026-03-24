--[[
    FORWARD HVH RESOLVER v18.3 - CLOUD SYNC
    Fixed HTTP callback format for Gamesense
    
    by Super Z
]]

-- ============== HTTP MODULE ==============
local http_ok, http = pcall(function() return require("gamesense/http") end)
if not http_ok then
    client.log("[Cloud Resolver] HTTP module not available!")
end

-- ============== CLOUD RESOLVER ==============

local cloud_resolver = {}

local CLOUD_CONFIG = {
    SERVER_URL = "https://cloud-resolver-for-gamesense-csgo.onrender.com/api",
    POLL_INTERVAL = 3.0,
    DATA_TIMEOUT = 60.0,
    MIN_CONFIDENCE = 0.5,
    DEBUG = true,
    RETRY_COUNT = 3
}

local cloud_state = {
    initialized = false,
    my_steamid = nil,
    my_steam64 = nil,
    last_poll = 0,
    cloud_data = {},
    sync_count = 0,
    error_count = 0,
    last_error = nil,
    is_connected = false
}

-- Simple JSON
local json = {}

function json.parse(str)
    if type(str) ~= "string" then return nil end
    
    local function parse_value(s, i)
        -- Skip whitespace
        while i <= #s and (s:sub(i,i) == " " or s:sub(i,i) == "\t" or s:sub(i,i) == "\n" or s:sub(i,i) == "\r") do
            i = i + 1
        end
        
        if i > #s then return nil, i end
        local c = s:sub(i,i)
        
        -- Null
        if s:sub(i, i+3) == "null" then return nil, i + 4 end
        -- Booleans
        if s:sub(i, i+3) == "true" then return true, i + 4 end
        if s:sub(i, i+4) == "false" then return false, i + 5 end
        -- Numbers
        if c == "-" or (c >= "0" and c <= "9") then
            local j = i
            while j <= #s and ((s:sub(j,j) >= "0" and s:sub(j,j) <= "9") or s:sub(j,j) == "." or s:sub(j,j) == "-" or s:sub(j,j) == "e" or s:sub(j,j) == "E" or s:sub(j,j) == "+") do
                j = j + 1
            end
            return tonumber(s:sub(i, j-1)), j
        end
        -- Strings
        if c == '"' then
            local j, result = i + 1, ""
            while j <= #s do
                if s:sub(j,j) == '"' then return result, j + 1
                elseif s:sub(j,j) == "\\" and j < #s then
                    local n = s:sub(j+1, j+1)
                    if n == "n" then result = result .. "\n"
                    elseif n == "t" then result = result .. "\t"
                    elseif n == "r" then result = result .. "\r"
                    else result = result .. n end
                    j = j + 2
                else
                    result = result .. s:sub(j,j)
                    j = j + 1
                end
            end
            return result, j
        end
        -- Arrays
        if c == "[" then
            local arr, i = {}, i + 1
            while i <= #s and s:sub(i,i) ~= "]" do
                local val
                val, i = parse_value(s, i)
                if val ~= nil then table.insert(arr, val) end
                while i <= #s and (s:sub(i,i) == "," or s:sub(i,i) == " " or s:sub(i,i) == "\n") do i = i + 1 end
            end
            return arr, (i <= #s and i + 1 or i)
        end
        -- Objects
        if c == "{" then
            local obj, i = {}, i + 1
            while i <= #s and s:sub(i,i) ~= "}" do
                local key, val
                key, i = parse_value(s, i)
                while i <= #s and s:sub(i,i) ~= ":" do i = i + 1 end
                i = i + 1
                val, i = parse_value(s, i)
                if key then obj[key] = val end
                while i <= #s and (s:sub(i,i) == "," or s:sub(i,i) == " " or s:sub(i,i) == "\n") do i = i + 1 end
            end
            return obj, (i <= #s and i + 1 or i)
        end
        return nil, i + 1
    end
    
    local ok, result = pcall(function() return (parse_value(str, 1)) end)
    return ok and result or nil
end

function json.encode(val)
    local t = type(val)
    if val == nil then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            table.insert(parts, json.encode(tostring(k)) .. ":" .. json.encode(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
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
    if not http then return false end
    if not cloud_state.initialized and not cloud_resolver.init() then return false end
    if not enemy_steam64 or enemy_steam64 == 0 then return false end
    
    local payload = json.encode({
        reporter_steamid = cloud_state.my_steamid,
        enemy_steam64 = tostring(enemy_steam64),
        angle = tonumber(angle) or 60,
        confidence = math.max(0, math.min(1, tonumber(confidence) or 0.5)),
        hit = hit or false,
        pattern = pattern or "unknown",
        timestamp = globals.realtime()
    })
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/update"
    
    -- Gamesense http.post format: url, headers_table, body, callback
    http.post(url, {["Content-Type"] = "application/json"}, payload, function(response)
        if response and response.status == 200 then
            cloud_state.sync_count = cloud_state.sync_count + 1
            cloud_state.is_connected = true
            if CLOUD_CONFIG.DEBUG then
                client.log("[Cloud Resolver] Synced!")
            end
        else
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.last_error = "HTTP Error"
        end
    end)
    
    return true
end

function cloud_resolver.poll()
    if not http then return end
    if not cloud_state.initialized and not cloud_resolver.init() then return end
    
    local current_time = globals.realtime()
    if current_time - cloud_state.last_poll < CLOUD_CONFIG.POLL_INTERVAL then return end
    cloud_state.last_poll = current_time
    
    local url = CLOUD_CONFIG.SERVER_URL .. "/resolver/get"
    
    -- Gamesense http.get format: url, callback
    http.get(url, function(response)
        if not response or response.status ~= 200 then
            cloud_state.error_count = cloud_state.error_count + 1
            cloud_state.is_connected = false
            return
        end
        
        cloud_state.is_connected = true
        
        if not response.body or response.body == "" then return end
        
        local decoded = json.parse(response.body)
        if not decoded then return end
        
        for steam64, entry in pairs(decoded) do
            if steam64 ~= cloud_state.my_steamid then
                cloud_state.cloud_data[steam64] = entry
            end
        end
        
        if CLOUD_CONFIG.DEBUG then
            local count = 0
            for _ in pairs(cloud_state.cloud_data) do count = count + 1 end
            if count > 0 then
                client.log("[Cloud Resolver] Got " .. count .. " entries")
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
    
    if globals.realtime() - (data.timestamp or 0) > CLOUD_CONFIG.DATA_TIMEOUT then
        cloud_state.cloud_data[tostring(steam64)] = nil
        return nil
    end
    
    if data.reporter == cloud_state.my_steamid then return nil end
    if (data.confidence or 0) < CLOUD_CONFIG.MIN_CONFIDENCE then return nil end
    
    return data
end

function cloud_resolver.test_connection()
    if not http then
        client.log("[Cloud Resolver] HTTP not available")
        return
    end
    
    client.log("[Cloud Resolver] Testing connection...")
    
    http.get(CLOUD_CONFIG.SERVER_URL .. "/resolver/status", function(response)
        if response and response.status == 200 then
            client.log("[Cloud Resolver] ✅ Connected!")
            cloud_state.is_connected = true
            
            local data = json.parse(response.body)
            if data then
                client.log("[Cloud Resolver] Server uptime: " .. tostring(data.uptime) .. "s")
            end
        else
            client.log("[Cloud Resolver] ❌ Connection failed")
            cloud_state.is_connected = false
        end
    end)
end

function cloud_resolver.clean()
    local current_time = globals.realtime()
    for steam64, data in pairs(cloud_state.cloud_data) do
        if current_time - (data.timestamp or 0) > CLOUD_CONFIG.DATA_TIMEOUT then
            cloud_state.cloud_data[steam64] = nil
        end
    end
end

if http then
    client.log("[Cloud Resolver] HTTP module loaded!")
else
    client.log("[Cloud Resolver] HTTP not available - cloud disabled")
end

-- ============== RESOLVER CORE ==============

local CONFIG = {
    MAX_HISTORY = 200, MAX_ANGLES = 100, MAX_VELOCITY = 120,
    JITTER_THRESHOLD = 18, SPIN_THRESHOLD = 75,
    DESYNC_MAX = 60, EXTENDED_DESYNC_MAX = 120,
    POSE_BODY_YAW = 11, BACKTRACK_MAX_TICKS = 40,
    BACKTRACK_HISTORY_SIZE = 65, TICK_INTERVAL = 0.015625,
    CLOUD_WEIGHT = 2.5, CLOUD_MIN_CONFIDENCE = 0.5
}

local function create_stats()
    return {shots=0, hits=0, misses=0, streak_best=0, streak_current=0,
        total_resolves=0, backtrack_shots=0, backtrack_hits=0, cloud_resolves=0, cloud_hits=0}
end

local function create_player_data()
    return {
        angle_history={}, velocity_history={}, backtrack_records={},
        bf_index=1, predicted_side=0, confidence=0.35, last_resolve=60,
        jitter_score=0, spin_speed=0, spin_direction=0,
        is_jitter=false, is_spinning=false, is_extended=false, is_moving=false,
        shots=0, hits=0, misses=0, consecutive_hits=0, consecutive_misses=0,
        successful_resolves={}, best_tick_history={}, backtrack_is_valid=false,
        backtrack_target_tick=0, cloud_used=false, last_plist_update=0
    }
end

local ui_elements = {
    enabled = ui.new_checkbox("RAGE", "Other", "Enable Resolver"),
    mode = ui.new_combobox("RAGE", "Other", "Mode", {"Cloud Priority", "Adaptive", "Memory", "Smart BF"}),
    cloud_label = ui.new_label("RAGE", "Other", "━━━ Cloud Resolver ━━━"),
    cloud_enabled = ui.new_checkbox("RAGE", "Other", "Enable Cloud Sync"),
    cloud_url = ui.new_textbox("RAGE", "Other", "Server URL"),
    cloud_debug = ui.new_checkbox("RAGE", "Other", "Debug Mode"),
    cloud_test = ui.new_button("RAGE", "Other", "Test Connection", function()
        cloud_resolver.test_connection()
    end),
    bt_label = ui.new_label("RAGE", "Other", "━━━ Backtrack ━━━"),
    bt_ticks = ui.new_slider("RAGE", "Other", "Max Ticks", 14, 40, 40, true, "ticks"),
    stats_label = ui.new_label("RAGE", "Other", "━━━ Stats ━━━"),
    show_stats = ui.new_checkbox("RAGE", "Other", "Show Statistics"),
    log_hits = ui.new_checkbox("RAGE", "Other", "Log Hits/Misses"),
    reset_btn = ui.new_button("RAGE", "Other", "Reset Data", function()
        player_data = {}
        global_stats = create_stats()
        cloud_state.cloud_data = {}
        client.log("[Resolver] Reset!")
    end)
}

ui.set(ui_elements.show_stats, true)
ui.set(ui_elements.log_hits, true)
ui.set(ui_elements.cloud_enabled, true)
ui.set(ui_elements.cloud_url, "https://cloud-resolver-for-gamesense-csgo.onrender.com/api")

local global_stats = create_stats()
local player_data = {}
local SIDES = {LEFT=-1, CENTER=0, RIGHT=1}

local function clamp(v, min, max) return math.max(min, math.min(max, type(v)=="number" and v or min)) end
local function normalize_angle(a)
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
local function vec_dist(x1,y1,z1,x2,y2,z2) return math.sqrt((x1-x2)^2 + (y1-y2)^2 + (z1-z2)^2) end
local function time_to_ticks(t) return math.floor(t / CONFIG.TICK_INTERVAL + 0.5) end

local function plist_set(ent, angle)
    local s64 = entity.get_steam64(ent)
    if s64 and s64 ~= 0 then
        plist.set(s64, "Force bodyyaw", true)
        plist.set(s64, "Force bodyyaw value", angle)
    end
end

local function plist_clear(ent)
    local s64 = entity.get_steam64(ent)
    if s64 and s64 ~= 0 then
        plist.set(s64, "Force bodyyaw", false)
        plist.set(s64, "Force bodyyaw value", 0)
    end
end

-- Backtrack
local function record_backtrack(ent, data)
    if not entity.is_alive(ent) then return end
    local sim = entity.get_prop(ent, "m_flSimulationTime")
    local ox, oy, oz = entity.get_prop(ent, "m_vecOrigin")
    if not sim or not ox then return end
    
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local vz = entity.get_prop(ent, "m_vecVelocity[2]") or 0
    local yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    
    local rec = {
        sim_time = sim, tick_count = time_to_ticks(sim),
        origin = {x=ox, y=oy, z=oz}, velocity = {x=vx, y=vy, z=vz},
        yaw = yaw, speed = vec_length(vx, vy, vz), valid = true
    }
    
    for _, r in ipairs(data.backtrack_records) do
        if math.abs(r.sim_time - sim) < 0.001 then return end
    end
    
    table.insert(data.backtrack_records, rec)
    while #data.backtrack_records > CONFIG.BACKTRACK_HISTORY_SIZE do table.remove(data.backtrack_records, 1) end
end

local function get_best_record(ent, data)
    local lp = entity.get_local_player()
    if not lp then return nil, 0 end
    local lx, ly, lz = entity.get_prop(lp, "m_vecOrigin")
    if not lx then return nil, 0 end
    
    local max_t = ui.get(ui_elements.bt_ticks)
    local cur_t = globals.tickcount()
    local best, best_score, best_tick = nil, -1, 0
    
    for _, r in ipairs(data.backtrack_records) do
        if r.valid and r.tick_count then
            local diff = cur_t - r.tick_count
            if diff > 0 and diff <= max_t then
                local dist = vec_dist(lx, ly, lz, r.origin.x, r.origin.y, r.origin.z)
                local score = 100 - diff * 2 - dist / 20
                if score > best_score then
                    best_score, best, best_tick = score, r, diff
                end
            end
        end
    end
    return best, best_tick
end

-- Analysis
local function analyze_jitter(data)
    if #data.angle_history < 5 then return end
    local changes = {}
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            table.insert(changes, angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle))
        end
    end
    if #changes < 3 then return end
    local avg = 0
    for _, v in ipairs(changes) do avg = avg + math.abs(v) end
    avg = avg / #changes
    local var = 0
    for _, v in ipairs(changes) do var = var + (math.abs(v) - avg)^2 end
    data.jitter_score = math.sqrt(var / #changes)
    data.is_jitter = data.jitter_score > CONFIG.JITTER_THRESHOLD
end

local function analyze_spin(data)
    if #data.angle_history < 6 then return end
    local total, n = 0, 0
    for i = #data.angle_history, math.max(1, #data.angle_history - 20), -1 do
        if i > 1 and data.angle_history[i] and data.angle_history[i-1] then
            total = total + math.abs(angle_diff(data.angle_history[i].angle, data.angle_history[i-1].angle))
            n = n + 1
        end
    end
    if n == 0 then return end
    data.spin_speed = total / n
    data.is_spinning = data.spin_speed > CONFIG.SPIN_THRESHOLD
end

local function analyze_velocity(ent, data)
    local vx, vy = entity.get_prop(ent, "m_vecVelocity[0]") or 0, entity.get_prop(ent, "m_vecVelocity[1]") or 0
    local speed = math.sqrt(vx*vx + vy*vy)
    data.is_moving = speed > 10
    
    if speed > 35 then
        local yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
        if yaw then
            local diff = angle_diff(math.deg(math.atan2(vy, vx)), yaw)
            if diff > 22 then return SIDES.RIGHT, 0.7
            elseif diff < -22 then return SIDES.LEFT, 0.7 end
        end
    end
    return SIDES.CENTER, 0.2
end

local function get_prediction(ent)
    local data = get_data(ent)
    local predictions = {}
    
    -- Cloud
    if ui.get(ui_elements.cloud_enabled) then
        local cd = cloud_resolver.get_data(ent)
        if cd and cd.confidence >= CONFIG.CLOUD_MIN_CONFIDENCE then
            table.insert(predictions, {side = cd.angle > 0 and SIDES.LEFT or SIDES.RIGHT, conf = cd.confidence, w = CONFIG.CLOUD_WEIGHT})
            data.cloud_used = true
        end
    end
    
    local vs, vc = analyze_velocity(ent, data)
    if vc > 0.2 then table.insert(predictions, {side=vs, conf=vc, w=1.2}) end
    
    -- Memory
    if #data.successful_resolves >= 2 then
        local lw, rw, tw = 0, 0, 0
        for _, r in ipairs(data.successful_resolves) do
            local w = r.confidence or 0.5
            tw = tw + w
            if r.side == SIDES.LEFT then lw = lw + w else rw = rw + w end
        end
        if tw > 0.25 then
            local lr, rr = lw/tw, rw/tw
            if lr > 0.55 then table.insert(predictions, {side=SIDES.LEFT, conf=lr*0.9, w=1.5})
            elseif rr > 0.55 then table.insert(predictions, {side=SIDES.RIGHT, conf=rr*0.9, w=1.5}) end
        end
    end
    
    if #predictions == 0 then return 60, 0.35 end
    
    local tw, ws = 0, 0
    for _, p in ipairs(predictions) do
        ws = ws + p.side * p.conf * p.w
        tw = tw + p.conf * p.w
    end
    
    local side = tw > 0 and ws/tw or 0
    local conf = tw > 0 and tw/#predictions or 0.35
    
    if side > 0.18 then side = SIDES.LEFT
    elseif side < -0.18 then side = SIDES.RIGHT
    else side = SIDES.CENTER end
    
    local angle = side * CONFIG.EXTENDED_DESYNC_MAX * conf
    data.predicted_side, data.confidence = side, conf
    
    return clamp(angle, -165, 165), conf
end

local function resolve(ent)
    if not ui.get(ui_elements.enabled) or not entity.is_alive(ent) then return 60, 0.35 end
    
    local yaw = entity.get_prop(ent, "m_angEyeAngles[1]")
    if not yaw then return 60, 0.35 end
    
    local data = get_data(ent)
    table.insert(data.angle_history, {angle=yaw, time=globals.realtime()})
    while #data.angle_history > CONFIG.MAX_HISTORY do table.remove(data.angle_history, 1) end
    
    analyze_jitter(data)
    analyze_spin(data)
    record_backtrack(ent, data)
    
    local angle, conf = 60, 0.35
    local mode = ui.get(ui_elements.mode)
    
    if mode == "Cloud Priority" and ui.get(ui_elements.cloud_enabled) then
        local cd = cloud_resolver.get_data(ent)
        if cd and cd.confidence >= 0.6 then
            angle, conf, data.cloud_used = cd.angle, cd.confidence, true
            global_stats.cloud_resolves = global_stats.cloud_resolves + 1
        else
            angle, conf = get_prediction(ent)
        end
    else
        angle, conf = get_prediction(ent)
    end
    
    data.last_resolve = angle
    if globals.realtime() - data.last_plist_update > 0.01 then
        plist_set(ent, angle)
        data.last_plist_update = globals.realtime()
    end
    
    global_stats.total_resolves = global_stats.total_resolves + 1
    return angle, conf
end

-- Events
client.set_event_callback("setup_command", function()
    if not ui.get(ui_elements.enabled) then return end
    local lp = entity.get_local_player()
    if not lp or not entity.is_alive(lp) then return end
    
    if http and ui.get(ui_elements.cloud_enabled) then
        if not cloud_state.initialized then cloud_resolver.init() end
        local url = ui.get(ui_elements.cloud_url)
        if url and url ~= "" then CLOUD_CONFIG.SERVER_URL = url end
        CLOUD_CONFIG.DEBUG = ui.get(ui_elements.cloud_debug)
        cloud_resolver.poll()
        if globals.tickcount() % 200 == 0 then cloud_resolver.clean() end
    end
    
    local players = entity.get_players(true)
    if players then
        for _, ent in ipairs(players) do
            if entity.is_alive(ent) then resolve(ent) end
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
    
    local rec, tick = get_best_record(ent, data)
    if rec then
        e.tickcount = rec.tick_count
        data.backtrack_is_valid = true
        data.backtrack_target_tick = tick
        global_stats.backtrack_shots = global_stats.backtrack_shots + 1
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[FIRE] T:%d | BT:%d%s", ent, tick or 0, data.cloud_used and " [CLOUD]" or ""))
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
        local s64 = entity.get_steam64(ent)
        if s64 and s64 ~= 0 then
            cloud_resolver.report_data(s64, data.last_resolve, data.confidence, true, "hit")
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[HIT] T:%d | Streak:%d%s", ent, data.consecutive_hits, data.cloud_used and " [CLOUD]" or ""))
    end
    
    data.backtrack_is_valid = false
    data.cloud_used = false
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(ui_elements.enabled) then return end
    local ent = e.target
    local reason = e.reason or ""
    if not ent or (reason ~= "prediction error" and reason ~= "resolver") then return end
    
    local data = get_data(ent)
    data.misses = data.misses + 1
    data.consecutive_misses = data.consecutive_misses + 1
    data.consecutive_hits = 0
    global_stats.misses = global_stats.misses + 1
    global_stats.streak_current = 0
    
    if ui.get(ui_elements.cloud_enabled) then
        local s64 = entity.get_steam64(ent)
        if s64 and s64 ~= 0 then
            cloud_resolver.report_data(s64, data.last_resolve, math.max(0.1, data.confidence - 0.2), false, "miss")
        end
    end
    
    if ui.get(ui_elements.log_hits) then
        client.log(string.format("[MISS] T:%d | %s", ent, reason))
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
    
    if ui.get(ui_elements.cloud_enabled) then
        local status = cloud_state.is_connected and "CONNECTED" or "CONNECTING..."
        local r, g, b = cloud_state.is_connected and 100 or 255, cloud_state.is_connected and 255 or 100, 100
        renderer.text(x, y, r, g, b, 255, "", 0, string.format("CLOUD: %s | Syncs: %d", status, cloud_state.sync_count))
        y = y + 12
    end
    
    local hr = global_stats.shots > 0 and (global_stats.hits / global_stats.shots * 100) or 0
    renderer.text(x, y, 200, 200, 200, 255, "", 0, string.format("S:%d H:%d M:%d | %.1f%%", global_stats.shots, global_stats.hits, global_stats.misses, hr))
    y = y + 12
    
    local br = global_stats.backtrack_shots > 0 and (global_stats.backtrack_hits / global_stats.backtrack_shots * 100) or 0
    renderer.text(x, y, 100, 200, 255, 255, "", 0, string.format("BT: %d/%d (%.1f%%)", global_stats.backtrack_hits, global_stats.backtrack_shots, br))
end)

client.set_event_callback("player_death", function(e)
    local v = client.userid_to_entindex(e.userid)
    if v and player_data[v] then plist_clear(v); player_data[v] = nil end
end)

client.set_event_callback("round_start", function()
    for _, d in pairs(player_data) do
        d.angle_history, d.backtrack_records, d.consecutive_hits, d.consecutive_misses = {}, {}, 0, 0
        d.backtrack_is_valid, d.cloud_used = false, false
    end
    global_stats.streak_current = 0
    client.log("[Resolver v18.3] Round start")
end)

client.log("[Resolver v18.3] Loaded - Cloud Sync Ready!")
