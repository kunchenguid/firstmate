# Verificação WhatsApp

## Evidência atual

Em 2026-09-13, a suíte offline foi executada em Darwin/arm64 com Python 3.14.7 e SQLite da biblioteca padrão.
Comando de reprodução: `bash tests/fm-whatsapp.test.sh`.
Resultado observado: `Ran 21 tests` e `OK`.
Os testes executam interfaces públicas Python e CLI, o `fm-inbox.sh` real, SQLite real, processos locais de fixture e, no Darwin, `plutil -lint` da plist gerada.
Nenhum teste usa conta WhatsApp, credencial real, modelo, instalação de serviço ou ciclo de vida Herdr.
O processo com identidade de harness é uma fixture estrutural para a biblioteca de sessão existente; não é uma execução de Codex ou prova de comportamento de UI do fornecedor.
O teste de parada/reinício encerra somente o processo que ele próprio criou e verifica que seu principal de fixture continua vivo.

O código foi inspecionado no checkout de base `b182d0f908b78d08c7ccb8dce3775bdca8c5d657`, incluindo `fm-inbox.sh`, `fm_voice_records.py`, voz, configuração, arquitetura, protocolo Herdr e os proprietários de lock, eventos, decisões e respostas públicas.
Esta integração não amplia o escopo da voz nem reutiliza o transporte X/Discord como se fosse WhatsApp.
A compatibilidade do backend instalado foi lida com `herdr --version` e `herdr status --json --session default`: versão `0.9.0`, protocolo `22`, `compatible:true`, `restart_needed:false`.
Nenhuma operação de ciclo de vida Herdr foi necessária.
O teste real da API e da sessão principal instalada continua pendente de ativação e autorização exata.

## Critérios de aceitação

| Critério da especificação | Evidência e limite |
| --- | --- |
| 1. Texto ao principal correto e resposta no WhatsApp | Implementado; entrada real, claim autenticado e retorno simulados de ponta a ponta; WhatsApp real pendente. |
| 2. Tarefa pequena com resultado associado | Testado com contagem real de linhas em arquivo de fixture, evento `completed` com evidência e texto na saída simulada; não é raciocínio de um modelo. |
| 3. Andamento durante tarefa longa | Testado com dois pedidos em estado iniciado, resposta de último evento e pergunta de desambiguação; a execução longa é simulada. |
| 4. Duplicação e reinício entre persistir/encaminhar/confirmar | Testados rollback antes do cursor, chave repetida, recibo anterior à publicação, retorno perdido, nota já movida para handled e claim repetido. |
| 5. 204, recibos, inteiro de 64 bits e opcionais | Testados sem parsing do corpo 204, cursor acima de 2^53 devolvido exato, contatos sem profile e read que não regride a delivered. |
| 6. Backlog antigo e cursor durável | Testados `new-only`, reinício e rejeição de troca de identidade do banco; replay é opção explícita de banco novo. |
| 7. Instâncias concorrentes e 409 | Testados flock exclusivo e halt persistente após 409; concorrência em máquinas distintas requer resolução operacional. |
| 8. Rajadas, divisão e digitação | Testadas cotas móveis independentes, persistência, ordem e preservação Unicode; digitação não habilitada, pendente etapa 2. |
| 9. Políticas de envio | Testados 2xx, 429/Retry-After, 503/131016, 500, reset, timeout, queda após preparar envio e bloqueio de partes posteriores em estado incerto. |
| 10. Desconhecidos, citações, reações e anexos | Testadas quarentena de remetente desconhecido e ausência de execução/autorização por reação, attachment ou context.from; correlação por wamid conhecido é somente contexto. |
| 11. Shell e credenciais | Testado texto literal com substituições de shell, autenticação local recusada fora do principal, token sintético privado, rejeição de symlink e ausência do sentinela na saída; nenhum token real lido. |
| 12. Principal indisponível | Testado principal de fixture encerrado, pedido preservado e confirmação sem início falso; disponibilidade anunciada apenas como checkpoint. |
| 13. Decisões | Testados dois pedidos, "sim" ambíguo, remetente errado, revisão errada, alteração de tarefa, expiração e consumo único; a execução da ação permanece com os proprietários do Firstmate. |
| 14. Mídia | Pendente etapa 2/3; MIME, tamanho, integridade, expiração, bytes autenticados, filename e caption não foram exercitados contra a API. |
| 15. Teste ao vivo | Pendente de conta habilitada, identidade vinculada localmente, token privado e autorização de destino/conteúdo; não realizado. |

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
| 8.5 Entrada | Páginas 11-14 | Texto implementado; context.id conhecido auxilia correlação; demais tipos são registrados sem executar nem baixar. |
| 8.6 Recibos | Página 14 | Persistência e progressão monotônica implementadas/testadas. |
| 8.7 Leitura/digitação | Páginas 16-18 | Pendente etapa 2; nenhum status POST enviado; bucket independente reservado no contrato. |
| 8.8 Upload, MIME e limites | Páginas 18-21 | Referência completa preservada; implementação pendente. |
| 8.9 Metadados | Páginas 21-22 | Referência completa preservada; implementação pendente. |
| 8.10 Download | Página 23 | Referência completa preservada; implementação pendente; nenhum Bearer enviado a URL de mensagem. |
| 8.11 Exclusão/retenção | Páginas 23-24 | Sem limpeza automática; implementação de mídia pendente. |
| 8.12 Erros | Páginas 24-28 | Classificação por endpoint/HTTP/code para texto implementada; erros de mídia pendentes; message/details não são usados como contrato. |
| 8.13 Cotas | Página 28 | Cotas de texto testadas em janela móvel; cotas das futuras operações de mídia separadas na configuração; nenhum limite oficial inventado para bytes. |

## Backlog explícito

| Etapa | Trabalho pendente | Gate de validação |
| --- | --- | --- |
| Ativação de texto | Confirmar menu/conta, associar os IDs localmente, configurar segredo, aprovar o teste exato e instalar o serviço no checkout estável aprovado. | Mensagem real do aplicativo, pequena análise autorizada e resposta com wamid/recibo; preservar evidências sem segredo. |
| Disponibilidade contínua | Integrar e verificar wake direcionado ao principal no harness instalado, sem digitação cega ou alterações de ciclo de vida Herdr. | Provar sessão viva, sessão ausente, checkpoint e rearm/restart; até lá anunciar checkpoint-only. |
| 2 | POST statuses para leitura/digitação e renovação somente enquanto prepara resposta. | Persistir antes de read; compartilhar bucket de statuses; falhas 500/503 e expiração de indicador. |
| 2 | Citação de saída e UX de histórico extenso. | Validar wamid da mesma conversa; citação nunca concede autoridade. |
| 2 | Imagem/documento/PDF, upload/download autenticado, streaming e retenção local explícita. | MIME/tipo, limite conservador de bytes, pixel count, Base64 vs hex, checksum, filename sanitizado, expiração, caption 1024, HTTPS/host/redirect; nenhum documento executado ou removido por consulta. |
| 2 | Áudio recebido e transcrição opcional; áudio de saída como anexo. | Provedor e custo autorizados, Ogg/Opus e codecs, `voice` opcional; sem inventar envio de nota de voz nativa. |
| 2 | Notificações proativas independentes de pedidos já vinculados. | Somente criador, consentimento explícito e eventos verificados; resultados/decisões dos pedidos atuais já têm outbox durável. |
| 3 | Vídeo, sticker, reações recebidas e conversões configuráveis. | Codecs/perfis, moov/mdat, canvas/tamanho, preservação do original e ausência de type reaction no envio. |
| 3 | Resposta por áudio/TTS. | Provedor configurado e custo autorizado; sem dependência no texto inicial. |
| 3 | Agendamentos, relatórios, CRM/calendário. | Permissões próprias por integração e correlação durável das ações. |
| 3 | Observabilidade, retenção, recuperação ampliada e custo/latência. | Métricas sem conteúdo/segredos, backups/restauros em fixtures e avaliação antes de alterar limites. |
