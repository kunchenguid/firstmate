## Captain's intent
Pedido de 03/10/2026: "live game é sempre nossa prioridade, tipo acabou de dar um warning no console, precisamos ver oq foi e se é algum crash possibility".
O captain quer poder mandar "caiu negócio no live, bora investigar" e ter essa investigação na frente do que está em construção, sem parar o resto.
Contexto para ler o pedido: o watchdog do live enviou a nota de inbox {NOTE_ID} em {NOTE_AT} com este texto: {NOTE_BODY}
O alerta só conta assinaturas novas. O detalhe (qual erro, qual script, quais jogadores) existe só no log do jogo no host do live.

## Firstmate spec
Objetivo: descobrir (1) qual é a causa provável do alerta, (2) se há possibilidade de crash do servidor, sim ou não e por quê, (3) se há perda de dado de jogador, (4) qual é a correção mínima, sem aplicá-la, e (5) qual prova a confirmaria.
Janela do log: 15 minutos em torno da nota, de {WINDOW_SINCE} até {WINDOW_UNTIL} (UTC).
Ler o log, somente leitura: ssh lloegrys-linux 'sudo -n docker logs --since {WINDOW_SINCE} --until {WINDOW_UNTIL} lloegrys-game 2>&1'
Confirme que a saída existe antes de concluir "sem erro": um sudo que falha devolve vazio.
Se a janela não mostra a assinatura nova, alargue só a leitura (a mesma linha de comando, outro --since) até achar a primeira ocorrência, e diga no relatório qual janela usou.
Fontes documentadas, sem inventar caminho: /home/shiv/Projects/firstmate/data/acessos-lloegrys.md (seções 1, 2 e 6: host, container lloegrys-game, como ler o log).
O que o live carrega agora: deploy/linux/release/remote.sh lloegrys-linux hoststate --target live, na sua cópia do repositório, somente leitura.
O código do live é o da tag que o hoststate informa; leia o arquivo e a linha citados pelo log nessa tag, não na main.
Limites: SOMENTE LEITURA.
Não reinicie o container, não recarregue scripts, não rode /reload, não escreva no host, não use docker exec, não faça deploy.
Os únicos comandos permitidos no host são docker logs, docker inspect e o hoststate acima.
Não aplique correção: proponha.
Entregue o relatório com: causa provável e grau de certeza, risco de crash sim ou não e por quê, perda de dado sim ou não e por quê, se o erro voltou a aparecer depois da primeira ocorrência, o arquivo e a linha do código, a correção mínima proposta, a prova que a confirmaria (teste que falha antes e passa depois) e o que você não conseguiu verificar.
Comece o relatório pela conclusão em uma linha: "crash: sim|não; perda de dado: sim|não; causa: <uma frase>".
