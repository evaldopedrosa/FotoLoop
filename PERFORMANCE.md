# Desempenho e validação — FotoLoop 0.2.0

Medições de 18 de outubro de 2026, neste Mac Apple Silicon (M4), macOS 27.0.1, Swift 6.4 e FFmpeg 9.0.2. Somente imagens sintéticas. Nenhuma foto pessoal foi importada ou exportada nos testes.

## Gargalos encontrados e decisões

| Caminho anterior, confirmado no código | Alteração | Impacto e limite |
| --- | --- | --- |
| `NSImage(contentsOf:)` criado no corpo da view em cada atualização | ImageIO fora do main actor, prévia até 960 px e cache LRU de 64 MiB/128 entradas | Evita ler/decodificar novamente durante ciclos que cabem no cache. A primeira passagem e sequências maiores continuam mais caras. |
| Timer publicava o quadro no mesmo modelo observado por toda a interface; `previewOrder` era remontado a cada consulta | Estado e relógio monotônico na pequena view da prévia; ordem calculada ao mudar a sequência | Controles e miniaturas não precisam atualizar a cada quadro. Não foi medida a taxa de quadros apresentada pelo compositor. |
| Enumeração completa da pasta e ordenação no caminho da interface | Enumeração incremental e ordenação em tarefa de fundo, com cancelamento por sessão | Mantém a interface disponível. Não foi medida aceleração do tempo total de importação. |
| Exportador decodificava até 16.384 px, mesmo para uma saída de 720/1080/1920 px | Decodificação no tamanho necessário ao enquadramento; `autoreleasepool` por foto | Menor buffer por imagem. Cortes extremos podem exigir decodificação maior para manter detalhe. |
| Ping-pong preparava novamente as fotos da volta | Cada foto é preparada uma vez; hard links para a volta; FFmpeg repete a entrada | Evita repetir a transformação e escrita de JPEGs. Não elimina o custo de codificar os quadros finais. |
| `stderr` em pipe só era lido após `waitUntilExit()` | Log temporário em arquivo, leitura de cauda limitada em falha | Remove o risco de bloqueio por pipe cheio. |
| O destino era escrito diretamente | Saída intermediária no mesmo diretório, substituição após sucesso | Falhas preservam um arquivo anterior e removem temporários. |

A arquitetura continua SwiftUI + modelo observável + exportador. Foram extraídos apenas o carregamento de imagens e a lógica compartilhada de sequência/geometria. Não há pacote Swift de terceiros.

## Ensaio controlado de imagens

Corpus: 24 JPEGs distintos de **6000 × 4000 px**, gerados com gradiente e formas geométricas. Três passagens (72 operações por modo), processos separados, sem compilação concorrente. O sistema continuou executando outras atividades normais; os valores são amostras locais, não garantias.

A ferramenta `scripts/measure-performance.swift` compara carregar/decodificar e desenhar em um contexto de **1080 × 720 px**. O modo de prévia anterior usa `NSImage`, como a view original. A comparação de exportação isola o limite de decodificação ImageIO de 16.384 versus 1080 px. Os modos de exportação usam a mesma função de leitura para controlar as demais variáveis. Não incluem escrita dos JPEGs, geração de paleta, FFmpeg, painéis ou renderização SwiftUI.

| Operação | Mediana | p95 | Buffer decodificado por imagem |
| --- | ---: | ---: | ---: |
| Prévia sem cache (`NSImage`, três passagens) | 24,81 ms | 33,63 ms | 96,00 MB |
| Prévia em cache, passagens 2 e 3 | 6,83 ms | 8,69 ms | 2,46 MB |
| Prévia nova, incluindo a primeira passagem | 8,03 ms | 51,16 ms | 2,46 MB |
| ImageIO com teto antigo de 16.384 px | 190,10 ms | 260,95 ms | 96,00 MB |
| ImageIO limitado a 1080 px | 42,77 ms | 68,38 ms | 3,11 MB |

A prévia com cache aquecido reduziu a mediana deste ensaio em aproximadamente **72%**. A comparação de limites de decodificação reduziu a mediana em aproximadamente **78%**. Essas porcentagens não representam redução equivalente no tempo total de exportação.

O cache fez **24 decodificações e 48 reutilizações**. Armazenou **58.982.400 bytes (56,25 MiB)**, abaixo do limite de 64 MiB. Após `removeAll()`, o custo registrado foi **zero**.

### Memória: a troca observada

O pico de RSS dos processos isolados foi de **129,1 MiB** na prévia sem cache e **154,5 MiB** na prévia com cache. Armazenar imagens para reutilização tem custo; não foi demonstrada uma redução geral da memória do aplicativo. A alteração reduz buffers individuais, evita imagens grandes na interface e impõe um teto ao cache, preservando a reutilização em ciclos comuns.

Os processos do ensaio de ImageIO registraram picos de 1538,5 MiB com o teto antigo e 121,4 MiB com 1080 px. Isso depende também do ciclo de vida das alocações e do ImageIO dentro da ferramenta; não usar esses valores como picos medidos do app antigo e novo.

O limite do cache não inclui imagens ainda exibidas, buffers transitórios de decodificação, SwiftUI/AppKit, WindowServer ou FFmpeg. Liberar referências também não obriga o alocador do macOS a devolver imediatamente todo o RSS ao sistema.

### Cache frio e velocidade

A primeira passagem é mais cara e pode perder quadros na prévia a 24/30 fotos/s. A decodificação ocorre fora da interface, e o relógio mantém a cadência em vez de acumular atraso. A exportação prepara todos os quadros e não depende dos quadros efetivamente apresentados na prévia.

O GIF tem intervalos em centésimos de segundo. O MP4 mantém 30 fps de saída; fotos a 24 fps, por exemplo, ocupam quantidades alternadas de quadros de vídeo. A duração aproximada exibida é a quantidade de quadros do ciclo completo × repetições ÷ fotos/s.

## Reproduzir as medições

Na raiz do projeto, com Swift e SDK do macOS:

```sh
cd Desenvolvimento
mkdir -p work/ModuleCache
swiftc -O -module-cache-path work/ModuleCache \
  -target "$(uname -m)-apple-macos13.0" \
  Sources/FotoLoop/PhotoPipeline.swift scripts/measure-performance.swift \
  -o work/measure-performance

work/measure-performance generate
work/measure-performance preview-before
work/measure-performance export-before
work/measure-performance export-after
work/measure-performance cached-preview
```

`generate` produz somente o corpus sintético em `Desenvolvimento/work/performance/photos/`. Cada modo imprime JSON com mediana, p95, tempo acumulado, bytes de imagem e pico de RSS do processo via `getrusage`. O modo de cache também imprime acertos, decodificações e custo antes/depois de limpar. As saídas locais desta execução estão em `Desenvolvimento/work/performance/*.json`, ignoradas pelo Git.

## Testes automatizados

A suíte de dez testes usa Swift Testing e FFmpeg/ffprobe locais. Cobre:

- Ordenação natural, pasta recursiva, formatos aceitos e deduplicação dentro do lote/contra a sessão.
- Decodificação de HEIC sintético e orientação EXIF de JPEG.
- Ping-pong com zero, uma, duas e quatro fotos; ausência de extremos duplicados; duração e repetições.
- As seis proporções, dimensões pares, resolução máxima, ajustar/preencher e preservação das proporções da imagem.
- Reutilização/limite/limpeza do cache; encerrar, cancelar importação, reimportar e ignorar drop de sessão antiga.
- Pasteboard nativo da tabela, inserção na posição escolhida, seleção estável e rejeição de tokens de outra sessão/entradas externas.
- **42 combinações de arquivos exportados:** 6 proporções × 2 enquadramentos × GIF/MP4; mais 9 velocidades × GIF/MP4 com ping-pong e 4x.
- Codec, dimensões, duração, H.264/30 fps/yuv420p/faixa de vídeo, ordem dos 24 quadros GIF e loop infinito independente das quatro repetições.
- Margens versus corte, substituição de destino existente e preservação do destino após erro.

A suíte passou novamente depois da reorganização das pastas. A leitura HEIC foi verificada com uma imagem HEIC sintética real.

## Verificação pela interface

Foram usadas apenas fotografias sintéticas em cópias locais do app. A interface confirmou:

- Importação de 24 imagens e de uma pasta com quatro imagens, miniaturas, seleção e prévia em reprodução.
- Controle até 30 fotos/s, ping-pong e 4 repetições, com duração exibida de 6,13 s para 24 fotos a 30 fotos/s.
- Seis proporções, prévia vertical, corte central e modos claro, escuro e automático.
- Reordenação por arrastar e soltar na tabela nativa. O gesto também foi confirmado manualmente pelo usuário.
- Exportação pelos painéis do macOS. `ffprobe` confirmou um GIF de 4 quadros e um MP4 de 12 quadros, ambos com 1080 × 720 px e 0,40 s.
- Encerramento da sessão e reimportação das quatro imagens sem reiniciar o app.

As 42 combinações de proporção, enquadramento, formato e velocidade foram verificadas pela suíte automatizada, não repetidas individualmente na interface.

## Limites de distribuição

A versão foi compilada e validada neste Mac Apple Silicon. Ainda não houve validação em Intel, em um macOS 13 físico, nem assinatura ou notarização para distribuição. O FFmpeg precisa estar instalado no Mac que exporta. O pacote local gerado fica em `Aplicativo/FotoLoop.app`; os artefatos temporários são ignorados pelo Git.
