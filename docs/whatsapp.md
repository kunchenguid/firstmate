# Ponte local WhatsApp

A ponte de texto recebe pedidos da WhatsApp Agent Platform, preserva entradas e respostas em SQLite e usa a entrada suportada do Firstmate.
O serviço é separado das sessões e não controla o Herdr, os agentes ou os projetos.
Python 3 com biblioteca padrão acompanha os registros Python existentes, mantém inteiros de 64 bits exatos e oferece SQLite transacional sem servidor ou dependências de nuvem.
Não há AWS, TTS ou modelo adicional na etapa de texto.
Com `media` desligado, anexos continuam só registrados.
Com `media` ligado, a ponte baixa imagens, documentos, áudio e vídeo autenticados para arquivos privados e entrega prévias visuais, texto extraído e transcrições ao principal; a resposta continua em texto.
A API WhatsApp é externa; a inferência do Firstmate continua usando os provedores já configurados nos seus harnesses.

O contrato de referência e a distinção entre fonte fornecida, PDF e verificação ao vivo estão em [Referência](whatsapp-reference/README.md).
A matriz de cobertura e o backlog estão em [Verificação](verification/whatsapp.md).

## Limite de disponibilidade

Esta versão integra o principal no seu próximo checkpoint, usando a prova de sessão de `fm-session-lock-lib.sh`.
Uma sessão viva não prova que existe supervisão contínua, e nenhum comando da ponte inicia uma sessão ausente.
O diagnóstico informa `checkpoint` ou `unavailable`, e sempre `unattended_wake_verified:false`.
Pedidos ficam preservados enquanto o principal está ausente; confirmações de execução só vêm de eventos explícitos do principal.
Consultar `/status` ou `/tarefas` seleciona pedidos pelos estados persistidos antes de limitar a apresentação, incluindo recebidos, enfileirados e reivindicados sem início confirmado.
Respostas conversacionais encerradas não contam como trabalho ativo; havendo mais de um pedido ativo, a consulta segue ao principal pelo mesmo fluxo durável dos demais pedidos.
Cada resumo de pedido tem no máximo 180 caracteres, incluindo o rótulo de estado e reticências quando necessário; o resultado integral persistido e suas partes de envio permanecem intactos.
Uma consulta citada segue ao principal com correlação por `context.id`, sem substituir a tarefa citada pelo andamento global.
Perguntas naturais de andamento chegam ao principal com histórico e correlação; cabe ao principal esclarecer a ambiguidade entre tarefas.
Por decisão explícita, `/tarefas` permanece como alias de `/status`, e `/ajuda` e `ajuda` mantêm a resposta local curta, disponível sem modelo mesmo quando o principal está indisponível.

## Configuração local

Copie [whatsapp.json](examples/whatsapp.json) para `FM_HOME/config/whatsapp.json` e substitua os caminhos absolutos e identificadores localmente.
O exemplo é uma alternativa JSON segura a `.env`, sem valores reais; não use `source` nem coloque o token no JSON.
`FM_WA_CONFIG` pode apontar para esse arquivo em um terminal local; não altera variáveis do sistema.
Mantenha o arquivo com modo 600 e o diretório `state_dir` com modo 700.
`fm_home`, `agent_id`, `creator_id`, modo e política inicial ficam vinculados ao banco; uma alteração de identidade exige um novo estado após reconciliação local, preservando o anterior.
Não eleja o primeiro remetente como proprietário e não converta o identificador em telefone.
O identificador completo deve ser confirmado no ambiente local confiável a partir de uma entrada recente e associado ao criador; `doctor` nunca faz descoberta automática da conta.

O manual fornecido descreve WhatsApp → Settings → Agents → Create an agent e Chat info → API key.
Confirme a presença desse menu na própria conta antes da ativação; não há prova de acesso universal ou de elegibilidade nesta entrega.
Configure `token_file` com um caminho privado e execute somente em um terminal local interativo:

```sh
python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" configure-token
python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" doctor
```

O primeiro comando oculta a digitação e não deve ser executado por agentes nem receber chave pelo chat.
A ponte lê o arquivo por chamada, sem exportar a chave a subprocessos, prompts ou logs.
Para rotação, regenere a chave no aplicativo e repita esse comando; a chave anterior é invalidada segundo o manual.
Se houver um halt de autenticação, siga a sequência de [Recuperação](#recuperação), preservando o banco.

Antes de habilitar tráfego real, obtenha a autorização para o destino e conteúdo exatos do teste.
Então defina localmente `mode:"live"`, `enabled:true` e `outbound_authorized:true` em um novo estado de ativação.
Habilitar `enabled` permite polling; `outbound_authorized` é uma autorização local separada para respostas ao criador.
O token nunca muda o destinatário permitido e a ponte não amplia as permissões do Firstmate.

`poll_timeout` 0-25, máximo de 100 entradas por poll, texto até 4096 caracteres e as cotas máximas do exemplo vêm do manual.
Exigir `poll_limit` entre 1 e 100 localmente, sem aceitar os valores que a API normaliza, é uma decisão de implementação.
`send_timeout` de 90 segundos por padrão (configurável entre 30 e 300), backoff com jitter, limite local de 200000 caracteres por resposta, política `new-only`, bloqueio após 409 e retenção local sem limpeza automática também são decisões de implementação.
As cotas configuradas podem ser reduzidas, nunca aumentadas além do manual, e cada bucket usa uma janela móvel persistida de 60 segundos.
`typing`, `read_receipts`, `tts` e `external_llm` devem permanecer falsos; habilitá-los falha explicitamente.
`media` permanece falso até uma ativação local reversível; ligá-lo habilita o recebimento de anexos, nunca envio de mídia ou TTS.
A ponte não seleciona um provedor novo: a extração e a transcrição descritas abaixo são locais e as prévias são interpretadas pela ferramenta de imagem do principal, no provedor já autorizado para aquela sessão.

## Recebimento de anexos

Os formatos aceitos e sua cobertura são concretos; aceitar um arquivo não significa interpretar todos os formatos ou conteúdos possíveis.

| Entrada | Interpretação disponível |
| --- | --- |
| JPEG/PNG | Decodificação e prévia visual; o principal precisa abrir a imagem. |
| PDF | Texto extraível e prévias de todas as páginas aceitas, inclusive páginas digitalizadas; não há OCR automático nem execução de JavaScript/formulários. |
| TXT UTF-8 | Texto integral dentro do limite de extração. |
| DOCX/XLSX/PPTX | Texto de documento/slides e valores armazenados das células; fórmulas não são calculadas, macros não são executadas, imagens incorporadas e layout não são interpretados. |
| Ogg/Opus mono, AAC ADTS, M4A/AAC, MP3, AMR-NB | Decodificação local e transcrição; `audio.voice:true` distingue a nota de voz do anexo de áudio. |
| MP4/3GPP H.264, com até uma faixa AAC | Prévias amostradas com tempo aproximado e transcrição da faixa de áudio; eventos entre amostras podem ser perdidos. |

Sticker/WebP, reações, Office binário antigo (`.doc`, `.xls`, `.ppt`), arquivos com macros, arquivos compactados genéricos, executáveis, binários genéricos e PDFs criptografados são recusados para interpretação.
Áudio sem fala reconhecível não produz uma transcrição inventada.
Um vídeo com áudio exige a mesma configuração de transcrição que uma nota de voz; sem ela, o processamento falha explicitamente.
O download usa GET autenticado de metadados e em seguida a URL HTTPS devolvida, só no host `lookaside.fbsbx.com`, sem redirect e sem Bearer antes dessa validação.
Os limites de MIME, bytes, pixels, caption e checksum são mantidos em [fm_whatsapp_media.py](../bin/fm_whatsapp_media.py); o limite em bytes usa MB decimal de forma conservadora.
Os limites de duração, páginas, quadros e texto extraído são mantidos em [fm_whatsapp_extract.py](../bin/fm_whatsapp_extract.py).
Os subprocessos têm ambiente sem credenciais herdadas, carregamento de modelo offline e limites de tempo, saída, CPU, memória e tamanho por arquivo conforme [fm_whatsapp_process.py](../bin/fm_whatsapp_process.py); isso é contenção de recursos, não uma sandbox de segurança do sistema operacional.
Arquivos ficam em `state_dir/media/<pedido>/` modo 600, com retenção explícita e sem exclusão remota ou local automática.
O orçamento local de armazenamento recusa novos anexos quando falta espaço reservado, preservando os anteriores; backups devem incluir esse diretório além do banco e das notas.
Falha de download ou extração gera aviso honesto e não vira análise concluída.
O serviço processa um anexo por vez em uma thread com conexão SQLite própria, enquanto texto e recibos continuam; a parada mantém o lock até esse processamento limitado terminar.
Reinícios retomam anexos pendentes pela mesma identidade; download pronto e nota enfileirada ainda não comprovam interpretação pelo principal.
Legendas, transcrições, conteúdo dos arquivos e instruções visíveis em imagens são dados não confiáveis; o claim marca `input_scope:interpret_attachment` e não autoriza comandos, aprovação ou operações externas.

### Preparar as dependências e verificar antes da ativação

Use Python 3.12 em um ambiente local separado e instale [requirements-whatsapp-media.txt](../bin/requirements-whatsapp-media.txt), além de FFmpeg/ffprobe no PATH do serviço.
O transporte de texto continua usando apenas a biblioteca padrão.
Configure `media_python` com o caminho absoluto do Python desse ambiente.
Para transcrição, escolha exatamente uma das opções:

- `media_stt_model`: diretório absoluto de um modelo faster-whisper/CTranslate2 já disponibilizado localmente; a ponte usa CPU/int8 e não baixa modelos.
- `media_stt_command`: executável local autorizado, pertencente ao usuário e sem escrita por terceiros, que recebe um WAV mono de 16 kHz e imprime somente a transcrição UTF-8.

Instalar dependências ou indicar um comando não autoriza enviar dados privados a um novo provedor.
`media-doctor` confere dependências e presença da configuração de STT, sem ler token nem acessar rede; `ready:true` não comprova decodificação, qualidade da transcrição, capacidade visual do principal ou entrega WhatsApp.
Teste cada tipo com fixtures controladas e depois obtenha prova real da conta autorizada, preservando o único consumidor e a correlação dos pedidos.

Ativação reversível, após essa validação e com autorização para o serviço existente:

1. Em `config/whatsapp.json`, defina `media` como `true`.
2. Configure `media_python` e uma das opções locais de STT acima.
3. Execute `python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" media-doctor`.
4. Atualize somente a ponte existente para o checkout estável aprovado, preservando banco, cursor, identidade, arquivos e notas; nunca inicie um segundo consumidor.

Para desligar, volte `media` a `false`, omita `media_stt_model` e `media_stt_command` e reinicie só a ponte; arquivos e anexos pendentes permanecem preservados.

## Operar no macOS

O comando `service-render` detecta Darwin e os caminhos reais do Python, código e configuração, grava uma plist desabilitada e imprime os comandos exatos de instalação, início, parada, reinício e logs.
Ele não chama `launchctl`, instala serviço, altera sessões nem ativa tráfego.
Escolha um checkout estável após a integração local aprovada; não instale um serviço apontando para um worktree descartável.
Para renderizar com o modo `simulated` do exemplo, acrescente à configuração `simulator_file` com o caminho absoluto de uma fixture JSON no formato indicado em [Simulação sem credenciais](#simulação-sem-credenciais); sem esse campo, `service-render` recusa a geração.

```sh
python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" service-render --output ./whatsapp.plist
plutil -lint ./whatsapp.plist
```

Revise a configuração e execute localmente os comandos impressos quando a ativação for autorizada.
Crie `~/Library/LaunchAgents` caso ainda não exista antes do `install` impresso.
`enable` seguido de `bootstrap` inicia; `bootout` para; `disable` impede novos inícios; `kickstart -k` reinicia exclusivamente o job da ponte.
A máquina precisa permanecer ligada, acordada e com a sessão de usuário disponível para o LaunchAgent atender.
O serviço usa polling de saída e não abre porta, webhook ou socket público.
O Firstmate principal continua precisando alcançar checkpoints para executar novos pedidos e publicar resultados.
Cada ciclo tenta no máximo um envio, voltando ao polling de entradas e recibos antes da próxima parte, sujeito às cotas e ao backoff persistidos.
Quando a primeira parte na ordem da fila está pendente, vencida, autorizada e com cota de envio disponível, o poll usa `timeout=0` para não atrasar sua saída; essa consulta não reserva cota de mensagens e continua respeitando a cota de updates.
Sem saída pronta, o poll mantém o timeout configurado; uma parte posterior pronta não ultrapassa uma parte bloqueada ou ainda em backoff.
A ordem da fila permanece sequencial; a resposta a uma consulta pode continuar aguardando as partes anteriores, mesmo quando a consulta já foi registrada e tratada.
`SIGTERM` permite terminar e persistir a operação em andamento e sair, verificando a parada antes das próximas operações e entre encaminhamentos de notas; uma interrupção forçada preserva a janela incerta de envio para reconciliação.

```sh
python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" status
```

`status` mostra estado local, não chama modelo nem consulta terminais.
As linhas `accepted`, `delivered` e `read` representam fases diferentes da entrega WhatsApp.
Resultados de trabalho são os eventos explícitos `completed`/`failed`, não essas fases de transporte.
O serviço não despeja corpos de mensagens continuamente em logs; o banco contém os textos privados, e deve ser protegido e incluído na política de backup local.

## Recuperação

`run` mantém a trava exclusiva mesmo durante um halt; `resume`, `resolve-send` e `redeliver` exigem essa mesma trava.
Para recuperar, siga esta ordem:

1. Pare somente esta ponte e aguarde sua saída: no LaunchAgent, use o comando `stop` (`launchctl bootout`) impresso por `service-render`; em execução manual, envie `SIGTERM` apenas ao PID desse `run` e aguarde seu término.
2. Corrija a causa e, com a ponte parada, execute `resume` para limpar o halt e/ou `resolve-send` e `redeliver` para os envios específicos, conforme os critérios abaixo.
3. Inicie somente esta ponte novamente: depois de `bootout`, use o comando `start` (`launchctl bootstrap`) impresso por `service-render`; em execução manual, repita o mesmo `run`, mantendo configuração e estado.

`kickstart` não substitui `bootstrap` depois de `bootout`; não pare nem reinicie o Firstmate principal, seus trabalhadores ou o Herdr para recuperar a ponte.
Se ainda houver partes pendentes que precisam ser enviadas antes de `redeliver`, retome a ponte para processá-las e repita a sequência de parada antes de autorizar a reentrega.

Reinícios retomam o cursor exato e deduplicam pelo agente/wamid antes dos efeitos externos.
Na primeira ativação `offset=0` preserva o backlog, mas `new-only` não executa entradas anteriores ao instante persistido de ativação.
Esse instante é gravado pelo primeiro `run` habilitado, antes do primeiro poll, e preservado nos reinícios; `doctor`, `status` e abertura do banco não ativam a ponte.
A resolução do timestamp de entrada é de segundos; a fração do segundo inicial é conservadoramente excluída.
Não derive cursor do relógio e não repita chamadas sem offset após 204.
Somente `startup_policy:"new-only"` é suportado; `replay` e outras políticas são rejeitados explicitamente, e os registros históricos são preservados sem execução.
O encaminhamento usa as notas idempotentes de [fm_inbox_key.py](../bin/fm_inbox_key.py); preserve seus recibos e notas em `handled`.

Uma trava exclusiva impede consumidores locais concorrentes do mesmo agente/usuário de sistema.
Em outra máquina ou conta de sistema, 409/1752041 interrompe o polling de forma persistente; identifique e pare a outra ponte antes de `resume`.
429 e 503/131016 usam backoff; erros permanentes interrompem a repetição do envio, mesmo quando uma resposta 4xx não contém JSON.
HTTP e `Retry-After` já recebidos continuam valendo quando o corpo não contém JSON ou sua leitura é interrompida.
Sem resposta HTTP decisiva, reset, timeout, sucesso malformado sem wamid, 5xx sem o código recuperável de 503 e queda após iniciar envio ficam `delivery_unknown` e bloqueiam partes posteriores para preservar a ordem.
Não há promessa de entrega exatamente uma vez.
Depois de verificar o aplicativo e os registros, `resolve-send --seq N --disposition accepted --wamid ID` associa uma aceitação comprovada e aplica recibos já persistidos, preservando `read` sobre `delivered`; `--disposition abandoned` abandona conscientemente aquela parte e libera a fila.
Não há reenvio automático de um resultado incerto nem inferência de um wamid perdido.
Para um resultado `completed` ou `failed`, resolva todas as partes pendentes ou incertas antes de autorizar localmente `redeliver --event EVENTO_ORIGINAL --key CHAVE_DA_AUTORIZACAO`.
O comando exige ao menos uma parte explicitamente abandonada na entrega anterior e enfileira o texto integral da resposta persistida, em ordem, podendo duplicar partes já aceitas.
Repita a mesma chave para consultar a mesma autorização sem duplicar envios, inclusive após reinício; uma chave não pode ser reutilizada para outro resultado.
A reentrega não emite um novo resultado, não altera o estado terminal, não concede decisões e não executa a tarefa novamente.
Falha incerta dessa nova entrega volta a exigir reconciliação explícita; o comando não transmite pela rede e a saída continua dependente do `run` com `outbound_authorized`.

`backup --output CAMINHO` faz um backup consistente de SQLite sem imprimir os textos.
Pare apenas a ponte para um backup/restauro conjunto do banco, notas e recibos idempotentes de `FM_HOME/state/inbox` que lhe pertencem.
Não drene a entrada real para fazer backup e não restaure sobre pedidos concorrentes sem reconciliá-los.
Preserve o backup anterior e copie os registros completos, incluindo eventos, decisões, outbox e timestamps de rate limiting.
Não remova o banco, o cursor ou recibos para tentar novamente.
Não há limpeza automática de documentos, mídia remota ou histórico local.

## Simulação sem credenciais

```sh
bash tests/fm-whatsapp.test.sh
```

A suíte cria seus próprios `FM_HOME`, metadados de tarefa, processos de principal de fixture, script de API e saídas locais.
Ela usa o `fm-inbox.sh` real, autentica o comando do principal pelo contrato de sessão existente e verifica um resultado real de análise de arquivo com envio simulado.
Não chama modelos, API WhatsApp, Herdr ou `launchctl`, e não lê tokens reais.
Para uma simulação persistente personalizada, configure modo `simulated`, habilite a ponte e saídas simuladas, e execute `run --fixture ARQUIVO.json`.
O formato do script é propriedade de [fm_whatsapp_transport.py](../bin/fm_whatsapp_transport.py); `run --once` executa um ciclo.

## Respostas do principal

A skill [whatsapp-respond](../.agents/skills/whatsapp-respond/SKILL.md) integra checkpoints, entrada natural, respostas e decisões aos procedimentos existentes.
O contrato JSON e seus campos exatos pertencem a [fm_whatsapp_main.py](../bin/fm_whatsapp_main.py).
Exemplo de resultado, enviado por stdin ao subcomando `main` pela sessão principal autenticada:

```json
{"op":"emit","event":"analysis-result-1","request":"wa-REQUEST","kind":"completed","body":"A análise encontrou três linhas no arquivo.","evidence":["/absolute/path/to/result.txt"]}
```

O pedido precisa ter sido reivindicado com seu `note_id` exato, e o principal precisa verificar o resultado antes desse evento.
As referências de tarefa apontam para o home/id/revisão canônicos, inclusive quando o trabalho pertence a um secondmate.
Uma resposta genérica ou uma reação não aprova decisões, e o transporte nunca executa a ação aprovada.
Enquanto houver uma decisão pendente ainda vigente, confirmações genéricas como “sim” e “ok” recebem um pedido de código.
Sem decisão pendente vigente, essas confirmações seguem como texto conversacional ao principal no próximo checkpoint, mesmo que existam decisões expiradas ainda registradas como pendentes.
Uma resposta explícita com código expirado continua recusada, sem aprovar a ação nem encaminhar essa resposta ao principal.
