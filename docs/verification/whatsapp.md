# Verificação WhatsApp

## Execução registrada e cobertura

Em 2026-09-14, a suíte offline foi executada em Darwin/arm64 com Python 3.12.14, Pillow 12.3.0, pypdfium2 5.13.0 e FFmpeg/ffprobe disponíveis.
Comando de reprodução, com esse ambiente Python no PATH: `bin/fm-test-run.sh tests/fm-whatsapp.test.sh --jobs 1`.
Resultado observado: `Ran 61 tests in 49.894s`, `OK` e `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=50098`.
Esse resultado identifica a execução da suíte nessa revisão; testes acrescentados posteriormente precisam de nova evidência.
A cobertura descrita abaixo acompanha a suíte mantida em [fm_whatsapp_test.py](../../tests/fm_whatsapp_test.py); resultados de validação da revisão atual pertencem às evidências do gate ou do PR.
Os testes executam interfaces públicas Python e CLI, o `fm-inbox.sh` real, SQLite real, processos locais de fixture e, no Darwin, `plutil -lint` da plist gerada.
A suíte usa decodificadores locais reais quando as dependências opcionais estão presentes e transcrição injetada; não usa conta WhatsApp, credencial real, modelo, instalação de serviço ou ciclo de vida Herdr.
Casos opcionais anunciam skip quando as dependências não existem; esse resultado não pode ser apresentado como validação de mídia.
O processo com identidade de harness é uma fixture estrutural para a biblioteca de sessão existente; não é uma execução de Codex ou prova de comportamento de UI do fornecedor.
O teste de parada/reinício encerra somente o processo que ele próprio criou e verifica que seu principal de fixture continua vivo.
Regressões determinísticas exercitam o handler de SIGTERM registrado pela entrada CLI durante polling e envio simulados, além da parada após uma nota persistida pelo `fm-inbox.sh` real, impedindo operações posteriores.
Um transporte com relógio simulado avança pelo timeout solicitado de cada poll: com configuração de 25 segundos e resultado de 49 partes, verifica progresso sem long polling enquanto há saída pronta, status/recibos intercalados, cotas móveis preservadas e retorno ao timeout configurado quando ocioso.
Casos separados verificam a escolha do timeout com saída ausente, não autorizada, bloqueada, em backoff ou sem cota, além de halt e parada.

A autenticação do principal usa [fm-whatsapp-auth.sh](../../bin/fm-whatsapp-auth.sh) e os proprietários existentes de identidade e lock da sessão.
O transporte e a extração não introduzem um adaptador de harness nem de runtime; a capacidade de abrir imagens precisa ser verificada na sessão instalada.
Esta integração não amplia o escopo da voz nem reutiliza o transporte X/Discord como se fosse WhatsApp.
O teste real da API e da sessão principal instalada continua pendente e pertence ao principal, após a validação local do candidato.

## Entrega ao principal depois da transcrição

As regressões `test_inbox_arrival_reaches_handling_successor` e `test_inbox_and_process_results_share_check_delivery` em [fm-watch-triage.test.sh](../../tests/fm-watch-triage.test.sh) publicam notas pelo `fm-inbox.sh` real depois de iniciar um watcher sucessor.
Elas verificam anúncio de texto comum e nota com chave, deduplicação sem consumo pelo watcher, coexistência com eventos de processo e preservação de uma obrigação de retorno independente.
O caso sucessor falha no watcher anterior, que só anuncia eventos `procevent` explicitamente e suprime a recuperação genérica enquanto trata o evento predecessor.
Uma inicialização comum pode anunciar a mesma nota via recuperação genérica e por isso não basta como regressão.
A prova com Pi e modelo reais, incluindo uma chegada durante trabalho controlado, está em [Verificação de runtimes](runtime-backends.md#pi-native-inbox-delivery).
Ela não usa API WhatsApp nem prova resposta pela sessão instalada do usuário.

A prova de resposta substantiva no destinatário segue o [plano de aceitação na conta instalada](#plano-de-aceitação-na-conta-instalada).

## Critérios de aceitação

| Critério da especificação | Evidência e limite |
| --- | --- |
| 1. Texto ao principal correto e resposta no WhatsApp | Implementado; inbox local real, claim autenticado e transporte simulado; WhatsApp real pendente. |
| 2. Tarefa pequena com resultado associado | Testado com contagem real de linhas em arquivo de fixture, evento `completed` com evidência e texto na saída simulada; não é raciocínio de um modelo. |
| 3. Andamento durante tarefa longa | Regressões cobrem tarefa ativa anterior a onze conclusões, reply encerrado, pedidos recebidos/enfileirados/reivindicados e encaminhamento de consultas ambíguas ao principal, inclusive com dois pedidos enfileirados sem resposta e com A concluída enquanto B está ativa; consulta após completed de 200000 caracteres verifica resumo limitado, cursor avançado, reinício e resultado integral preservado; a execução longa é simulada. |
| 4. Duplicação e reinício entre persistir/encaminhar/confirmar | Testados rollback antes do cursor, chave repetida, recibo anterior à publicação, retorno perdido, nota já movida para handled, claim repetido, Retry-After de mídia persistido e repetição idempotente de evento failed do principal após reinício. |
| 5. 204, recibos, inteiro de 64 bits e opcionais | Testados sem parsing do corpo 204, cursor acima de 2^53 devolvido exato e contatos sem profile; regressão adicional cobre read anterior ao resolve-send e delivered posterior sem regressão. |
| 6. Backlog antigo e cursor durável | Regressões cobrem doctor/status antes da ativação, run desabilitado recusado, instante persistido antes do primeiro poll habilitado, backlog preservado sem execução, cursor no reinício e rejeição explícita de replay. |
| 7. Instâncias concorrentes e 409 | Testados flock exclusivo e halt persistente após 409; concorrência em máquinas distintas requer resolução operacional. |
| 8. Rajadas, divisão e digitação | Testadas cotas móveis independentes, persistência, ordem e preservação Unicode; um resultado de 49 partes com envios de seis segundos no relógio simulado permite registrar/tratar status e recibo entre partes, antes de esvaziar a fila; digitação não habilitada, pendente etapa 2. |
| 9. Políticas de envio | Testados 2xx, 429/Retry-After, 503/131016, 500, reset, timeout e queda após preparar envio; regressões HTTP com opener mockado cobrem corpos não JSON e leituras interrompidas por timeout, reset e IncompleteRead, preservando HTTP decisivo, backoff e redação segura, sem rede; a CLI de reentrega cobre autorização deduplicada, texto integral e estado terminal preservado. |
| 10. Desconhecidos, citações, reações e anexos | Testadas quarentena e ausência de autorização por reação, attachment ou context.from; regressão de consulta citada encaminha ao principal a correlação da tarefa A mesmo com B ativa, incluindo citação desconhecida sem associação inventada. |
| 11. Shell e credenciais | Testado texto literal com substituições de shell, autenticação local recusada fora do principal, token sintético privado, rejeição de symlink e ausência do sentinela na saída; nenhum token real lido. |
| 12. Principal indisponível | Testado principal de fixture encerrado, pedido preservado e confirmação sem início falso; disponibilidade anunciada apenas como checkpoint. |
| 13. Decisões | Testados dois pedidos, "sim" ambíguo, remetente errado, revisão errada, alteração de tarefa, expiração e consumo único; regressões mantidas também exercitam invalidação no encerramento, rollback conjunto e preservação de recibos consumidos; a execução da ação permanece com os proprietários do Firstmate. |
| 14. Mídia | JPEG/PNG, PDF comprimido/digitalizado, TXT, DOCX/XLSX/PPTX, áudio e MP4: extração local real, transporte simulado, checksum Base64/hex, URL hostil, tamanho, hash errado, expiração, filename sanitizado, transcrição injetada e recusa sem STT; também corrupção, duração, páginas, macros, expansão XML, subprocessos limitados e processamento paralelo a texto/recibos; sem prova contra a API real. |
| 15. Teste ao vivo | Não realizado; o principal deve instalar o candidato validado para teste controlado na conta e sessão existentes, registrar interpretação e resposta por modalidade e concluir a aceitação antes da ativação permanente. |

## Conferência da referência

O [PDF original](../whatsapp-reference/whatsapp-agent-platform-v1.pdf) de 28 páginas é uma fonte fornecida pelo usuário, não obtida de uma página oficial verificável nesta execução.
PDFKit detectou as páginas, mas a extração textual nativa só encontrou imagens; Vision OCR foi aplicado a todas as páginas, com leitura do texto completo e inspeção visual das páginas 9, 10, 19, 20, 21, 22, 24 e 28.
As tabelas, MIME, checksum, erros e rate limits foram comparados às imagens, evitando tratar artefatos de OCR como divergência do contrato.
Nenhuma divergência substantiva foi identificada entre as seções de referência da especificação fornecida e o manual recebido.
Na tabela resumida de erro 500 da página 26, a sugestão genérica de retry aponta à seção específica de envio na página 9; a implementação segue a política específica de resultado incerto, também exigida pelo usuário.
O tamanho decimal/binário de MB/KB, um TTL separado para URL de download e hosts legítimos adicionais continuam não especificados.
Buscas públicas pelos termos `WhatsApp Agent Platform` e `whatsapp_agent_platform` em domínios oficiais foram inconclusivas; resultados de produtos diferentes não foram usados para inventar regras.

| Seção integral da especificação | Conferência do PDF | Implementação/estado |
| --- | --- | --- |
| 8.1 Criação e autenticação | Páginas 3-4 | Bearer implementado com fixture sintética; menu, chave e elegibilidade da conta pendentes ao vivo. |
| 8.2 Identificadores e destinatário | Páginas 4-6, 25 | Comparação integral, vínculo local obrigatório e destinatário fixo implementados/testados; revinculação exige estado novo e reconciliação. |
| 8.3 Envio | Páginas 5-9 | Texto, limite, ordenação, wamid e políticas de falha implementados/testados; mídia e citação de saída pendentes. |
| 8.4 Updates | Páginas 9-16 | Cursor, bootstrap, limites, 204, 409 e backoff implementados/testados. |
| 8.5 Entrada | Páginas 11-14 | Texto implementado; com `media` ligado, imagens, documentos, áudio e vídeo autenticados do criador são preparados conforme os formatos e limites do guia; sticker e reação continuam só registrados. |
| 8.6 Recibos | Página 14 | Persistência e progressão monotônica implementadas/testadas. |
| 8.7 Leitura/digitação | Páginas 16-18 | Pendente etapa 2; nenhum status POST enviado; bucket independente reservado no contrato. |
| 8.8 Upload, MIME e limites | Páginas 18-21 | MIME/limites de entrada usados no recebimento; upload de saída pendente. |
| 8.9 Metadados | Páginas 21-22 | GET autenticado de metadados implementado para anexos de entrada. |
| 8.10 Download | Página 23 | Download autenticado da URL devolvida, host permitido e checksum; Bearer não é enviado a URL de mensagem. |
| 8.11 Exclusão/retenção | Páginas 23-24 | Sem limpeza automática nem DELETE remoto. |
| 8.12 Erros | Páginas 24-28 | Classificação por endpoint/HTTP/code para texto e falhas permanentes de mídia; message/details não são usados como contrato. |
| 8.13 Cotas | Página 28 | Cotas em janela móvel persistida; metadados e download de entrada consomem conservadoramente dois slots de GET de mídia; o guia aponta os limites locais de bytes. |

## Limites de validação e trabalho posterior

A implementação de entrada combina texto, imagens, documentos, áudio e vídeo, com respostas somente em texto.
A prova local de decodificação ou transcrição não demonstra a entrega de mensagens do aplicativo, a interpretação do principal instalado ou o recebimento da resposta pelo destinatário.
Registros de prova controlada e evidências da conta real pertencem ao relatório privado da tarefa ou ao PR; não transformam esta matriz em atestado automático de produção.
A sequência de validação, publicação, instalação controlada e ativação permanente está no [plano de aceitação na conta instalada](#plano-de-aceitação-na-conta-instalada); aprovação local não satisfaz a aceitação integral.
As regressões locais incluem AAC silencioso com STT de fixture concluindo vazio, vídeo sem áudio, falha real de processo transcritor, recusa de áudio isolado sem transcrição, pixels RGBA/paleta, ordem reordenada de PPTX e nomes/ordem das abas XLSX por relações internas.
Casos de Office verificam conteúdo dividido em trechos de formatação, fronteiras de parágrafos/células e valores numéricos armazenados; os casos de encerramento incluem `reply`, rollback e preservação de recibos consumidos.
Esses casos usam decodificadores reais quando disponíveis, mas não comprovam um modelo STT instalado: a prova desse modelo exige áudio representativo e resultado observado separado da transcrição injetada.

### Plano de aceitação na conta instalada

| Etapa | Responsável e condição de conclusão |
| --- | --- |
| Validação local e publicação do candidato | O executor externo conduz as fases de validação e publicação; os resultados locais e nativos isolados registrados acima não comprovam a conta instalada, cuja aceitação permanece pendente. |
| Instalação controlada e aceitação real | Após validação e publicação, o principal instala o candidato e executa os ensaios abaixo na conta e sessão existentes, registrando a entrega real. |
| Ativação permanente e conclusão da integração | O principal só efetiva a ativação já autorizada e declara a integração concluída após aprovação de todos os ensaios reais; não há dispensa dessa prova. |

Antes da instalação controlada, o principal deve conferir e preservar as alterações locais de supervisão ainda não incorporadas ao candidato (delta do supervisor principal), sem sobrescrevê-las; uma dependência não conciliada impede a instalação.
O principal é responsável pela execução controlada e pelos registros privados de cada linha, preservando conta, histórico, sessão, banco, cursor, pedidos pendentes, mídia e transcrição local existentes, sem repetir o backlog nem criar consumidor adicional.
Agentes dos gates não devem editar a instalação principal, iniciar consumidor real, instalar ou ativar produção, nem reiniciar o pipeline para produzir essa evidência.

| Modalidade | Evidência real ainda pendente |
| --- | --- |
| Texto | Entrada nova do proprietário com o principal ocioso e ocupado, pedido/nota vinculados, claim pelo principal instalado, interpretação e resposta textual substantiva recebida pelo destinatário em ambos os ensaios, sem intervenção no chat separado. |
| Áudio e nota de voz | Fala real nova com o principal ocioso e ocupado, download e decodificação, transcrição pelo STT local autorizado, interpretação e resposta textual substantiva recebida pelo destinatário em ambos os ensaios, sem intervenção no chat separado. |
| Imagem | Abertura efetiva da prévia pelo principal, incluindo PNG transparente, interpretação visual e resposta textual. |
| Vídeo | Abertura dos quadros, fala transcrita quando detectada, interpretação visual sem áudio e com AAC silencioso, resposta textual. |
| Arquivos | TXT, PDF e Office aceitos pelo guia, leitura do conteúdo e das prévias aplicáveis, ordem de PPTX conferida e resposta textual. |

Cada registro deve correlacionar mensagem de entrada, pedido, mídia e transcrição quando aplicáveis, publicação da nota/evento, entrada e claim do principal, resultado substantivo, enqueue da resposta textual, wamid de saída e recibo `delivered` do destinatário, distinguindo aceitação pela API de recebimento pelo destinatário.
Registre a duração observada de cada fase e os limites da prova, sem prometer resposta instantânea ou um prazo não medido; a confirmação automática de recebimento não conta como resposta substantiva.
O principal deve preservar também a evidência das recusas esperadas e da continuidade do serviço; nenhum novo destino de modelo ou dados faz parte desse plano.

| Área | Gate de validação ou limite |
| --- | --- |
| Conta e serviço existentes | Prova autorizada de mensagem real, principal autenticado, interpretação e resposta com wamid/recibo por tipo; preservar o único consumidor e o estado existente. |
| Disponibilidade contínua | Verificar wake direcionado no harness instalado; até lá anunciar checkpoint-only. |
| Transcrição local instalada | `media-doctor` é diagnóstico de dependências; confirmar resultado com fala representativa no modelo/comando escolhido e sem novo destino de dados. |
| Visão no principal | Abrir efetivamente as prévias na ferramenta de imagem do harness; caminho ou caption isolados não provam visão. |
| Formatos e cobertura | O [guia](../whatsapp.md#recebimento-de-anexos) distingue formatos recusados, limites locais e perda entre amostras de vídeo. |
| Recursos posteriores | Status de leitura/digitação, citação de saída, stickers/reações, envio de mídia/TTS, agendamentos e integrações adicionais estão fora desta entrega. |
