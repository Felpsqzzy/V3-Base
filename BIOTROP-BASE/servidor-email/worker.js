/**
 * Worker da fila de e-mail.
 *
 * Consome core.email_fila e envia pelo Microsoft Graph. Roda como serviço
 * (systemd) ou por cron; os dois funcionam, e o README explica a escolha.
 *
 * Por que fila e não envio direto no momento da ação:
 *   - se o Graph estiver fora, o aviso não se perde;
 *   - a ação do usuário não espera a rede (devolver uma SCI para revisão
 *     não pode demorar 3 s por causa de um e-mail);
 *   - fica registro de tentativa, erro e reenvio.
 *
 * Concorrência: o SELECT usa FOR UPDATE SKIP LOCKED. Sem isso, duas
 * instâncias do worker (ou um restart no meio) mandam o mesmo e-mail
 * duas vezes. SKIP LOCKED faz cada instância pegar linhas diferentes.
 */

const { Client } = require("pg");
const { enviarEmail } = require("./graph");

const cfg = {
  tenantId: process.env.ENTRA_TENANT_ID,
  clientId: process.env.ENTRA_CLIENT_ID,
  clientSecret: process.env.ENTRA_CLIENT_SECRET,
  remetente: process.env.EMAIL_REMETENTE || "manutencao@biotrop.com.br",
  responderPara: process.env.EMAIL_RESPONDER_PARA || "",
  lote: Number(process.env.EMAIL_LOTE || 20),
  intervaloMs: Number(process.env.EMAIL_INTERVALO_MS || 60000),
  maxTentativas: Number(process.env.EMAIL_MAX_TENTATIVAS || 5),
  db: process.env.DATABASE_URL,
};

function exigir(nome, valor) {
  if (!valor) {
    console.error(`[email-worker] falta a variável ${nome}. Veja .env.example.`);
    process.exit(1);
  }
}
exigir("ENTRA_TENANT_ID", cfg.tenantId);
exigir("ENTRA_CLIENT_ID", cfg.clientId);
exigir("ENTRA_CLIENT_SECRET", cfg.clientSecret);
exigir("DATABASE_URL", cfg.db);

const log = (...a) => console.log(new Date().toISOString(), "[email-worker]", ...a);
const erro = (...a) => console.error(new Date().toISOString(), "[email-worker]", ...a);

/**
 * Espera exponencial entre tentativas: 1, 2, 4, 8, 16 minutos.
 * Reenviar de imediato contra um serviço instável só multiplica a falha.
 */
function proximaTentativaEm(tentativas) {
  const minutos = Math.pow(2, Math.max(0, tentativas - 1));
  return `now() + interval '${Math.min(minutos, 60)} minutes'`;
}

async function processarLote(db) {
  // A transação abre e fecha por lote: se o processo morrer no meio, as
  // linhas voltam a ficar disponíveis (o lock cai com a conexão).
  await db.query("BEGIN");
  let pendentes;
  try {
    pendentes = await db.query(
      `SELECT id, destinatario, cc, assunto, corpo_texto, corpo_html, tentativas, referencia
         FROM core.email_fila
        WHERE status = 'pendente'
          AND (proxima_tentativa_em IS NULL OR proxima_tentativa_em <= now())
        ORDER BY criado_em
        LIMIT $1
        FOR UPDATE SKIP LOCKED`,
      [cfg.lote]
    );
  } catch (e) {
    await db.query("ROLLBACK");
    throw e;
  }

  if (pendentes.rows.length === 0) {
    await db.query("COMMIT");
    return 0;
  }

  log(`${pendentes.rows.length} mensagem(ns) na fila`);
  let enviadas = 0;

  for (const m of pendentes.rows) {
    const r = await enviarEmail(cfg, {
      para: m.destinatario,
      cc: m.cc,
      assunto: m.assunto,
      texto: m.corpo_texto,
      html: m.corpo_html,
      responderPara: cfg.responderPara,
    }).catch((e) => ({ ok: false, repetir: true, erro: e.message }));

    if (r.ok) {
      await db.query(
        `UPDATE core.email_fila
            SET status = 'enviado', enviado_em = now(), erro = NULL,
                tentativas = tentativas + 1
          WHERE id = $1`,
        [m.id]
      );
      enviadas++;
      log(`enviado: ${m.assunto} -> ${m.destinatario}${m.referencia ? ` (${m.referencia})` : ""}`);
      continue;
    }

    const tentativas = (m.tentativas || 0) + 1;
    const desiste = !r.repetir || tentativas >= cfg.maxTentativas;

    await db.query(
      `UPDATE core.email_fila
          SET status = $2, tentativas = $3, erro = $4,
              proxima_tentativa_em = ${desiste ? "NULL" : proximaTentativaEm(tentativas)}
        WHERE id = $1`,
      [m.id, desiste ? "erro" : "pendente", tentativas, String(r.erro).slice(0, 1000)]
    );

    erro(
      `${desiste ? "desistiu" : "vai repetir"} (${tentativas}/${cfg.maxTentativas}): ` +
        `${m.assunto} -> ${m.destinatario} · ${r.erro}`
    );
  }

  await db.query("COMMIT");
  return enviadas;
}

/** Registra a execução para dar para responder "a rotina rodou hoje?" com uma query. */
async function registrarExecucao(db, ok, detalhe) {
  await db
    .query(
      `INSERT INTO core.rotina_execucao (rotina, executado_em, sucesso, detalhe)
       VALUES ('email_worker', now(), $1, $2)`,
      [ok, String(detalhe || "").slice(0, 1000)]
    )
    .catch(() => {
      /* a rotina não deve morrer porque o log dela falhou */
    });
}

async function umaPassada() {
  const db = new Client({ connectionString: cfg.db });
  await db.connect();
  try {
    const n = await processarLote(db);
    await registrarExecucao(db, true, `${n} enviada(s)`);
    return n;
  } catch (e) {
    erro("falha no lote:", e.message);
    await registrarExecucao(db, false, e.message);
    throw e;
  } finally {
    await db.end().catch(() => {});
  }
}

async function principal() {
  const umaVez = process.argv.includes("--uma-vez");
  log(
    `iniciando · remetente ${cfg.remetente} · lote ${cfg.lote} · ` +
      (umaVez ? "execução única" : `a cada ${cfg.intervaloMs / 1000}s`)
  );

  if (umaVez) {
    await umaPassada();
    return;
  }

  let rodando = true;
  const parar = (sinal) => {
    log(`recebeu ${sinal}, encerrando depois do lote atual`);
    rodando = false;
  };
  process.on("SIGTERM", () => parar("SIGTERM"));
  process.on("SIGINT", () => parar("SIGINT"));

  while (rodando) {
    await umaPassada().catch(() => {
      /* já registrado; o laço continua para não morrer por falha passageira */
    });
    if (!rodando) break;
    await new Promise((r) => setTimeout(r, cfg.intervaloMs));
  }
  log("encerrado");
}

principal().catch((e) => {
  erro("erro fatal:", e);
  process.exit(1);
});
