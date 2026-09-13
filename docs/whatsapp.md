# Ponte local WhatsApp

A ponte de texto recebe pedidos da WhatsApp Agent Platform, preserva entradas e respostas em SQLite e usa a entrada suportada do Firstmate.
O serviço é separado das sessões e não controla o Herdr, os agentes ou os projetos.
Python 3 com biblioteca padrão acompanha os registros Python existentes, mantém inteiros de 64 bits exatos e oferece SQLite transacional sem servidor ou dependências de nuvem.
Não há AWS, transcrição, TTS ou modelo adicional na etapa de texto.
A API WhatsApp é externa; a inferência do Firstmate continua usando os provedores já configurados nos seus harnesses.

O contrato de referência e a distinção entre fonte fornecida, PDF e verificação ao vivo estão em [Referência](whatsapp-reference/README.md).
A matriz de cobertura e o backlog estão em [Verificação](verification/whatsapp.md).

## Limite de disponibilidade

Esta versão integra o principal no seu próximo checkpoint, usando a prova de sessão de `fm-session-lock-lib.sh`.
Uma sessão viva não prova que existe supervisão contínua, e nenhum comando da ponte inicia uma sessão ausente.
O diagnóstico informa `checkpoint` ou `unavailable`, e sempre `unattended_wake_verified:false`.
Pedidos ficam preservados enquanto o principal está ausente; confirmações de execução só vêm de eventos explícitos do principal.
Consultar `/status`, `/tarefas` e algumas perguntas naturais lê os últimos eventos tipados mesmo durante tarefas longas.
Outras perguntas naturais chegam ao principal com histórico e correlação; ambiguidade entre tarefas exige uma pergunta.

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
Se houver um halt de autenticação, corrija a configuração e execute `resume`, preservando o banco.

Antes de habilitar tráfego real, obtenha a autorização para o destino e conteúdo exatos do teste.
Então defina localmente `mode:"live"`, `enabled:true` e `outbound_authorized:true` em um novo estado de ativação.
Habilitar `enabled` permite polling; `outbound_authorized` é uma autorização local separada para respostas ao criador.
O token nunca muda o destinatário permitido e a ponte não amplia as permissões do Firstmate.

`poll_timeout` 0-25, `poll_limit` 1-100, texto até 4096 caracteres e as cotas máximas do exemplo vêm do manual.
`send_timeout` de 90 segundos, backoff com jitter, limite local de 200000 caracteres por resposta, política `new-only`, bloqueio após 409 e retenção local sem limpeza automática são decisões de implementação.
As cotas configuradas podem ser reduzidas, nunca aumentadas além do manual, e cada bucket usa uma janela móvel persistida de 60 segundos.
Os campos opcionais de mídia/digitação/modelos devem permanecer falsos; habilitá-los falha explicitamente.

## Operar no macOS

O comando `service-render` detecta Darwin e os caminhos reais do Python, código e configuração, grava uma plist desabilitada e imprime os comandos exatos de instalação, início, parada, reinício e logs.
Ele não chama `launchctl`, instala serviço, altera sessões nem ativa tráfego.
Escolha um checkout estável após a integração local aprovada; não instale um serviço apontando para um worktree descartável.

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
`SIGTERM` permite terminar a chamada em andamento e sair; uma interrupção forçada preserva a janela incerta de envio para reconciliação.

```sh
python3 bin/fm-whatsapp.py --config "$FM_HOME/config/whatsapp.json" status
```

`status` mostra estado local, não chama modelo nem consulta terminais.
As linhas `accepted`, `delivered` e `read` representam fases diferentes da entrega WhatsApp.
Resultados de trabalho são os eventos explícitos `completed`/`failed`, não essas fases de transporte.
O serviço não despeja corpos de mensagens continuamente em logs; o banco contém os textos privados, e deve ser protegido e incluído na política de backup local.

## Recuperação

Reinícios retomam o cursor exato e deduplicam pelo agente/wamid antes dos efeitos externos.
Na primeira ativação `offset=0` preserva o backlog, mas `new-only` não executa entradas anteriores ao instante persistido de ativação.
A resolução do timestamp de entrada é de segundos; a fração do segundo inicial é conservadoramente excluída.
Não derive cursor do relógio e não repita chamadas sem offset após 204.
`replay` só é permitido como escolha explícita ao criar um novo estado, nunca como troca silenciosa do banco existente.
O encaminhamento usa as notas idempotentes de [fm_inbox_key.py](../bin/fm_inbox_key.py); preserve seus recibos e notas em `handled`.

Uma trava exclusiva impede consumidores locais concorrentes do mesmo agente/usuário de sistema.
Em outra máquina ou conta de sistema, 409/1752041 interrompe o polling de forma persistente; identifique e pare a outra ponte antes de `resume`.
429 e 503/131016 usam backoff; erros permanentes interrompem a repetição do envio.
500, reset, timeout e queda após iniciar envio ficam `delivery_unknown` e bloqueiam partes posteriores para preservar a ordem.
Não há promessa de entrega exatamente uma vez.
Depois de verificar o aplicativo e os registros, `resolve-send --seq N --disposition accepted --wamid ID` associa uma aceitação comprovada; `--disposition abandoned` abandona conscientemente aquela parte e libera a fila.
Não há reenvio automático de um resultado incerto nem inferência de um wamid perdido.
Depois de abandonar uma parte, um novo envio do seu conteúdo exige decisão explícita e um novo evento do principal.

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
Não chama modelos, API WhatsApp, Herdr ou `launchctl`, e não lê tokens.
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
