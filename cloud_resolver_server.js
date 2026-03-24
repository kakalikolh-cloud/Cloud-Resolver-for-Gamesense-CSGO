/**
 * Cloud Resolver Server v1.0
 * 
 * Lightweight HTTP server for sharing resolver data between teammates
 * 
 * Features:
 * - SteamID-based player tracking
 * - Hit/Miss data sharing
 * - Automatic data expiration
 * - Simple REST API
 * 
 * Installation:
 *   npm install express body-parser
 *   node cloud_resolver_server.js
 * 
 * Usage:
 *   POST /api/resolver/update - Send resolver data
 *   GET /api/resolver/get - Get all resolver data
 *   GET /api/resolver/status - Server status
 */

const http = require('http');
const url = require('url');

// Configuration
const CONFIG = {
    PORT: 3000,
    DATA_EXPIRATION: 60000,      // 60 seconds
    CLEANUP_INTERVAL: 30000,     // 30 seconds
    MAX_ENTRIES: 1000,           // Maximum stored entries
    DEBUG: true
};

// In-memory storage
const resolverData = {};
const stats = {
    totalUpdates: 0,
    totalRequests: 0,
    startTime: Date.now()
};

// Utility functions
function log(message) {
    if (CONFIG.DEBUG) {
        const timestamp = new Date().toISOString();
        console.log(`[${timestamp}] ${message}`);
    }
}

function sendJSON(res, statusCode, data) {
    res.writeHead(statusCode, {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type'
    });
    res.end(JSON.stringify(data));
}

function sendError(res, statusCode, message) {
    sendJSON(res, statusCode, { error: message });
}

// Parse JSON body
function parseBody(req, callback) {
    let body = '';
    req.on('data', chunk => {
        body += chunk.toString();
    });
    req.on('end', () => {
        try {
            const data = body ? JSON.parse(body) : {};
            callback(null, data);
        } catch (e) {
            callback(e, null);
        }
    });
}

// Clean expired data
function cleanupExpiredData() {
    const now = Date.now();
    let cleaned = 0;
    
    for (const steam64 in resolverData) {
        const entry = resolverData[steam64];
        if (now - entry.timestamp > CONFIG.DATA_EXPIRATION) {
            delete resolverData[steam64];
            cleaned++;
        }
    }
    
    if (cleaned > 0) {
        log(`Cleaned ${cleaned} expired entries`);
    }
}

// Update resolver data
function updateResolverData(data) {
    if (!data.enemy_steam64) return false;
    
    const steam64 = data.enemy_steam64;
    const existing = resolverData[steam64];
    
    // Update only if:
    // 1. No existing data
    // 2. New data has higher confidence
    // 3. New data is a hit (hits are more valuable)
    // 4. Existing data is too old
    const now = Date.now();
    const shouldUpdate = !existing || 
                         data.confidence > existing.confidence ||
                         data.hit === true ||
                         (now - existing.timestamp) > CONFIG.DATA_EXPIRATION / 2;
    
    if (shouldUpdate) {
        resolverData[steam64] = {
            angle: data.angle,
            confidence: data.confidence,
            hit: data.hit,
            pattern: data.pattern,
            reporter: data.reporter_steamid,
            timestamp: now,
            gameTime: data.timestamp
        };
        return true;
    }
    
    return false;
}

// Handle HTTP requests
const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);
    const pathname = parsedUrl.pathname;
    const method = req.method;
    
    // Handle CORS preflight
    if (method === 'OPTIONS') {
        res.writeHead(200, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type'
        });
        res.end();
        return;
    }
    
    stats.totalRequests++;
    
    // Status endpoint
    if (pathname === '/api/resolver/status' && method === 'GET') {
        sendJSON(res, 200, {
            status: 'online',
            uptime: Math.floor((Date.now() - stats.startTime) / 1000),
            entries: Object.keys(resolverData).length,
            stats: stats
        });
        return;
    }
    
    // Get all resolver data
    if (pathname === '/api/resolver/get' && method === 'GET') {
        // Convert timestamp to relative time for client
        const responseData = {};
        for (const steam64 in resolverData) {
            responseData[steam64] = {
                ...resolverData[steam64],
                age: Date.now() - resolverData[steam64].timestamp
            };
        }
        sendJSON(res, 200, responseData);
        log(`GET /api/resolver/get - ${Object.keys(responseData).length} entries`);
        return;
    }
    
    // Update resolver data
    if (pathname === '/api/resolver/update' && method === 'POST') {
        parseBody(req, (err, data) => {
            if (err) {
                sendError(res, 400, 'Invalid JSON');
                return;
            }
            
            // Validate required fields
            if (!data.reporter_steamid || !data.enemy_steam64) {
                sendError(res, 400, 'Missing required fields');
                return;
            }
            
            // Validate angle
            if (typeof data.angle !== 'number' || isNaN(data.angle)) {
                data.angle = 60;
            }
            
            // Validate confidence
            if (typeof data.confidence !== 'number' || isNaN(data.confidence)) {
                data.confidence = 0.5;
            }
            data.confidence = Math.max(0, Math.min(1, data.confidence));
            
            // Update data
            const updated = updateResolverData(data);
            
            stats.totalUpdates++;
            
            sendJSON(res, 200, {
                success: true,
                updated: updated,
                entryCount: Object.keys(resolverData).length
            });
            
            log(`POST /api/resolver/update - Reporter: ${data.reporter_steamid}, ` +
                `Target: ${data.enemy_steam64}, Angle: ${data.angle.toFixed(1)}, ` +
                `Conf: ${data.confidence.toFixed(2)}, Hit: ${data.hit}`);
        });
        return;
    }
    
    // Clear all data (for testing)
    if (pathname === '/api/resolver/clear' && method === 'POST') {
        const count = Object.keys(resolverData).length;
        for (const key in resolverData) {
            delete resolverData[key];
        }
        sendJSON(res, 200, { success: true, cleared: count });
        log('POST /api/resolver/clear - Cleared all data');
        return;
    }
    
    // Get data for specific player
    if (pathname.startsWith('/api/resolver/player/') && method === 'GET') {
        const steam64 = pathname.replace('/api/resolver/player/', '');
        const entry = resolverData[steam64];
        
        if (entry) {
            sendJSON(res, 200, {
                steam64: steam64,
                ...entry,
                age: Date.now() - entry.timestamp
            });
        } else {
            sendError(res, 404, 'Player not found');
        }
        return;
    }
    
    // Default: 404
    sendError(res, 404, 'Not found');
});

// Start server
server.listen(CONFIG.PORT, () => {
    console.log('╔════════════════════════════════════════════╗');
    console.log('║     Cloud Resolver Server v1.0             ║');
    console.log('╠════════════════════════════════════════════╣');
    console.log(`║  Port: ${CONFIG.PORT}`);
    console.log(`║  Data Expiration: ${CONFIG.DATA_EXPIRATION / 1000}s`);
    console.log(`║  Max Entries: ${CONFIG.MAX_ENTRIES}`);
    console.log('╠════════════════════════════════════════════╣');
    console.log('║  Endpoints:                                ║');
    console.log('║  GET  /api/resolver/status  - Server info  ║');
    console.log('║  GET  /api/resolver/get     - Get all data ║');
    console.log('║  POST /api/resolver/update  - Send data    ║');
    console.log('║  POST /api/resolver/clear   - Clear data   ║');
    console.log('║  GET  /api/resolver/player/:steam64        ║');
    console.log('╚════════════════════════════════════════════╝');
    console.log('');
    log('Server started');
});

// Cleanup interval
setInterval(cleanupExpiredData, CONFIG.CLEANUP_INTERVAL);

// Handle shutdown
process.on('SIGINT', () => {
    console.log('\nShutting down server...');
    server.close(() => {
        console.log('Server closed');
        process.exit(0);
    });
});

module.exports = { server, resolverData, stats };
