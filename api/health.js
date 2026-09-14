const { Pool } = require('pg');

let pool;
function getPool() {
  if (!process.env.DATABASE_URL) return null;
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 2,
      connectionTimeoutMillis: 5000,
      ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined
    });
  }
  return pool;
}

module.exports = async function handler(_req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const db = getPool();
  if (!db) {
    res.statusCode = 200;
    return res.end(JSON.stringify({ ok: true, databaseConfigured: false, databaseConnected: false, realtimeMode: 'local-fallback' }));
  }
  try {
    await db.query('SELECT 1');
    res.statusCode = 200;
    return res.end(JSON.stringify({ ok: true, databaseConfigured: true, databaseConnected: true, realtimeMode: 'polling-3s' }));
  } catch (error) {
    console.error('[BIOTROP HEALTH]', error);
    res.statusCode = 200;
    return res.end(JSON.stringify({ ok: true, databaseConfigured: true, databaseConnected: false, realtimeMode: 'local-fallback' }));
  }
};
