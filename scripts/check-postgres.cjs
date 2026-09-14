const { Client } = require('pg');

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error('DATABASE_URL não configurado.');
  process.exit(1);
}

const client = new Client({
  connectionString: databaseUrl,
  ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined
});

(async () => {
  try {
    await client.connect();
    const result = await client.query(`
      SELECT
        current_database() AS database_name,
        current_user AS database_user,
        current_schema() AS current_schema,
        to_regclass('app.sync_registro') AS sync_table,
        to_regclass('core.usuario') AS user_table
    `);

    const row = result.rows[0];
    if (!row.sync_table || !row.user_table) {
      throw new Error('Schema Biotrop incompleto: tabelas principais não encontradas.');
    }

    console.log(JSON.stringify({ ok: true, ...row }, null, 2));
  } catch (error) {
    console.error(`[BIOTROP DB CHECK] ${error.message}`);
    process.exit(1);
  } finally {
    await client.end().catch(() => {});
  }
})();
