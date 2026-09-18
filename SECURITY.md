# Segurança — BIOTROP Manutenção

## Princípios
- Segredos nunca ficam no HTML, JavaScript do navegador ou Git.
- DATABASE_URL, NEON_DATABASE_URL, SESSION_SECRET e credenciais Microsoft devem existir somente no ambiente do servidor.
- Senhas são verificadas com bcrypt; nunca são armazenadas em texto puro.
- Sessões usam cookie HttpOnly, Secure, SameSite=Lax, assinatura HMAC e expiração.
- APIs de alteração aceitam somente origem autorizada e usam queries parametrizadas.
- Erros internos de PostgreSQL não são devolvidos ao navegador.
- O banco é acessado somente pelas funções server-side.

## Operação
1. Se qualquer segredo for exposto, revogar/rotacionar imediatamente.
2. Alterações de produção devem passar pelos checks de segurança.
3. Não colocar tokens, cookies, connection strings ou senhas em logs.
4. Manter as variáveis de ambiente configuradas no provedor de execução, nunca no repositório.

## Observação
A proteção de secrets depende também das configurações do provedor Git/Vercel/Neon. Criptografar uma chave dentro do frontend não a torna secreta: qualquer chave entregue ao navegador pode ser recuperada pelo usuário.
