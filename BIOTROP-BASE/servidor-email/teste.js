/**
 * Teste manual, antes de ligar o worker.
 *
 *   node teste.js token   -> so pede o token (valida tenant/client/secret)
 *   node teste.js envio seu.email@biotrop.com.br
 *
 * Fazer isso primeiro separa dois problemas que se confundem: permissao
 * do Entra e SQL da fila.
 */
const { obterToken, enviarEmail } = require("./graph");

const cfg = {
  tenantId: process.env.ENTRA_TENANT_ID,
  clientId: process.env.ENTRA_CLIENT_ID,
  clientSecret: process.env.ENTRA_CLIENT_SECRET,
  remetente: process.env.EMAIL_REMETENTE,
};

const modo = process.argv[2];

(async () => {
  if (modo === "token") {
    const t = await obterToken(cfg);
    console.log("token obtido, tamanho", t.length);
    console.log("se chegou aqui, tenant, client e secret estao certos.");
    return;
  }

  if (modo === "envio") {
    const para = process.argv[3];
    if (!para) {
      console.error("uso: node teste.js envio destino@biotrop.com.br");
      process.exit(1);
    }
    const r = await enviarEmail(cfg, {
      para,
      assunto: "[Manutencao] teste do worker de e-mail",
      texto:
        "Se voce recebeu isto, o caminho Entra ID -> Graph -> caixa de comunicacao esta funcionando.\n\n" +
        "Remetente configurado: " + cfg.remetente,
    });
    console.log(r.ok ? "enviado (202)" : "falhou: " + r.erro);
    if (!r.ok) process.exit(1);
    return;
  }

  console.error("uso: node teste.js token | node teste.js envio destino@biotrop.com.br");
  process.exit(1);
})().catch((e) => {
  console.error("erro:", e.message);
  process.exit(1);
});
