# FotoLoop — instruções para agentes

- Antes de alterar código, leia `README.md` e, se existir neste Mac, `HANDOFF.md` (arquivo local fora do Git).
- Preserve o escopo pequeno: ferramenta offline para animar sequências de fotos e exportar GIF/MP4.
- Não publique no GitHub nem faça commit sem pedido explícito do usuário.
- Não use fotos pessoais já carregadas na interface como material de teste. Para validações, gere imagens sintéticas em `Desenvolvimento/work/`.
- Execute comandos Swift na pasta `Desenvolvimento/`. Depois de mudanças Swift, rode `swift build -c debug`. Para validar o pacote do app, rode `./scripts/build-app.sh`.
- Não afirme que um fluxo foi testado pela interface quando só a compilação ou os comandos FFmpeg foram verificados.
