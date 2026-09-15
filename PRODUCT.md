# BIOTROP · Manutenção

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Técnicos, PCM, almoxarifes, líderes/coordenadores, administradores e perfil de visualização. Cargo/grupo e perfil de acesso são conceitos distintos. Grupos têm responsável direto.

## Product Purpose

Registrar consumos de utilidades, solicitar cadastro e compra de materiais, acompanhar aprovações e revisões e realizar treinamentos. A reconstrução preserva as funções e as regras existentes, com prioridade para os ciclos SCI/SCM e uso pelo celular.

## Operating Context

Plataforma interna da BIOTROP utilizada no computador e no celular. Solicitações são avaliadas dentro do sistema. Técnicos devem encontrar as próprias SCI e SCM em Minhas solicitações e corrigir pedidos devolvidos.

## Capabilities and Constraints

- Técnico: Início, Treinamentos, Apontar consumo, Nova solicitação SCI, Nova ordem de compra SCM, Minhas solicitações.
- Gestão de SCI/SCM, aprovação, famílias e medidores aparecem conforme permissão.
- Código do item obrigatório para concluir cadastro de SCI. Identificador 4MDG separado do processo de compra ME.
- Leituras acumulativas respeitam histórico por medidor; medidores inativos não são apontáveis.
- Treinamentos preservam conteúdo misto, tempo mínimo, avaliação, tentativas, bloqueio e comprovantes internos.
- Dados operacionais precisam de persistência compartilhada e autorização no servidor. Cache local não substitui o banco.
- Nenhum segredo será incluído no frontend ou nas instruções dos agentes.
- Site solicitado via Sites. O projeto de origem possui API Node/PostgreSQL/Neon e Microsoft Entra; compatibilidade com a hospedagem Sites precisa ser implementada e verificada antes de afirmar operação online completa.

## Brand Commitments

BIOTROP. Idioma português brasileiro. Visual clean e tecnológico, navegação familiar, animações discretas, uma única navegação inferior no celular, sidebar reconstruída com a lógica atual.

## Evidence on Hand

Repositório público https://github.com/Felpsqzzy/V3-Base e cópia local indicada pelo usuário. Pacotes Graphify, Impeccable, Taste e skills de animação fornecidos como auxiliares. Anexos de imagem de conversas anteriores não estão disponíveis como arquivos utilizáveis.

## Product Principles

- Preservar os fluxos completos, incluindo revisão, rejeição e estados vazios.
- Cada ação deixa claro o resultado e as pendências.
- Permissões são verificadas no servidor, além da apresentação dos menus.
- Não classificar como validada uma regra que não passou por teste.
