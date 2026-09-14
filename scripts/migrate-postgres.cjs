const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error('DATABASE_URL não configurado.');
  process.exit(1);
}

const root = path.resolve(__dirname, '..');
const files = [
  'BIOTROP-BASE/01-base.sql',
  'BIOTROP-BASE/02a-papeis.sql',
  'BIOTROP-BASE/02b-rls-core.sql',
  'BIOTROP-BASE/02c-rls-almox.sql',
  'BIOTROP-BASE/02d-rls-util.sql',
  'BIOTROP-BASE/02e-rls-lms.sql',
  'BIOTROP-BASE/02f-ajustes-base.sql',
  'BIOTROP-BASE/02g-fechamento.sql',
  'BIOTROP-BASE/03-sync.sql'
];

for (const relative of files) {
  const file = path.join(root, relative);
  if (!fs.existsSync(file)) {
    console.error(`Migration ausente: ${relative}`);
    process.exit(1);
  }

  console.log(`\n==> Executando ${relative}`);
  const result = spawnSync('psql', [databaseUrl, '-v', 'ON_ERROR_STOP=1', '-f', file], {
    stdio: 'inherit',
    env: { ...process.env }
  });

  if (result.error) {
    console.error(`Falha ao executar psql: ${result.error.message}`);
    process.exit(1);
  }

  if (result.status !== 0) {
    console.error(`Migration falhou: ${relative}`);
    process.exit(result.status || 1);
  }
}

console.log('\nPostgreSQL Biotrop inicializado/atualizado com sucesso.');
