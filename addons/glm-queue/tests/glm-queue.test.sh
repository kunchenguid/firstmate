#!/usr/bin/env bash
# shellcheck disable=SC2016 # node programs are literal
# Integration check for glm-queue.mjs against a stub upstream that counts concurrent requests.
# Usage: glm-queue.test.sh [glm-queue.mjs]   exit 0 = PASS. Needs node; never reaches Z.AI.
# 1. 20 parallel clients through a queue of N=4: the upstream never sees more than 4 at once, and all 20 complete
#    with the upstream's answer, path and Authorization header unchanged.
# 2. A streamed (SSE) response streams: its first chunk reaches the client before the upstream has sent the last.
# 3. A truncated Content-Length response fails fast: the upstream declares 100 bytes, sends 10, then RSTs; the client
#    sees the failure in milliseconds (never a hang), the queue logs the error with its slot drained, and the next call
#    completes.
Q=${1:-$(dirname "$(readlink -f "$0")")/../glm-queue.mjs}
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
N=4
port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
UPORT=$(port) QPORT=$(port)

# The stub holds each call 300 ms, records the most it ever had open at once, and on /stream sends two SSE
# chunks 800 ms apart.
UPORT=$UPORT node -e '
let open = 0, max = 0;
require("http").createServer((req, res) => {
  if (req.url === "/max") return res.end(String(max));
  open++; max = Math.max(max, open);
  let body = ""; req.on("data", (c) => body += c);
  req.on("end", () => {
    if (req.url === "/stream") {
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write("data: first\n\n");
      setTimeout(() => { open--; res.end("data: last\n\n"); }, 800);
    } else if (req.url === "/truncated") {
      res.writeHead(200, { "content-type": "application/json", "content-length": "100" });
      res.write("1234567890");
      setTimeout(() => { open--; res.socket.destroy(); }, 50);
    } else setTimeout(() => { open--; res.end(`${req.method} ${req.url} ${req.headers.authorization} ${body}`); }, 300);
  });
}).listen(process.env.UPORT, "127.0.0.1");' &
GLM_QUEUE_MAX=$N GLM_QUEUE_PORT=$QPORT GLM_QUEUE_UPSTREAM=http://127.0.0.1:$UPORT node "$Q" > "$T/queue.log" &
for _ in $(seq 50); do grep -q 'glm-queue on' "$T/queue.log" && curl -s "127.0.0.1:$UPORT/max" >/dev/null && break; sleep 0.1; done
fail=0 pids=()

for i in $(seq 20); do
  curl -s -m 10 -H 'Authorization: Bearer test-key' -d "call-$i" "127.0.0.1:$QPORT/api/coding/paas/v4/chat/completions?x=$i" > "$T/out.$i" &
  pids+=($!)
done
wait "${pids[@]}"
ok=0
for i in $(seq 20); do
  [ "$(cat "$T/out.$i")" = "POST /api/coding/paas/v4/chat/completions?x=$i Bearer test-key call-$i" ] && ok=$((ok + 1))
done
max=$(curl -s "127.0.0.1:$UPORT/max")
[ "$ok" = 20 ] && echo "PASS all 20 clients got the upstream answer unchanged" || { echo "FAIL only $ok of 20 completed unchanged"; fail=1; }
[ "$max" -le "$N" ] && [ "$max" -gt 1 ] && echo "PASS upstream saw at most $max at once (N=$N)" \
  || { echo "FAIL upstream saw $max at once (N=$N)"; fail=1; }
[ "$(grep -c '^status=200 ' "$T/queue.log")" = 20 ] && echo "PASS 20 calls logged" || { echo "FAIL log:"; sed 's/^/  /' "$T/queue.log"; fail=1; }

# Time to the first chunk and to the end of the stream, in ms, as the client sees them.
read -r first last < <(QPORT=$QPORT node -e '
const t0 = Date.now(); let first = 0; let said = false; let timer; let r;
const done = (a, b) => { if (said) return; said = true; clearTimeout(timer); if (r) r.destroy(); console.log(a, b); };
r = require("http").get(`http://127.0.0.1:${process.env.QPORT}/stream`, (res) => {
  res.on("data", () => { first ||= Date.now() - t0; });
  res.on("end", () => done(first, Date.now() - t0));
});
r.on("error", () => done(9999, 0));
timer = setTimeout(() => done(9999, 0), 3500);')
[ "${first:-9999}" -lt 600 ] && [ "${last:-0}" -ge 800 ] && echo "PASS stream: first chunk at ${first} ms, end at ${last} ms" \
  || { echo "FAIL stream not streamed: first chunk at ${first:-never} ms, end at ${last:-never} ms"; fail=1; }

# How the client experiences a truncated Content-Length response: verdict (aborted/error/end/hung) and elapsed ms.
read -r verdict ms < <(QPORT=$QPORT node -e '
const t0 = Date.now(); let said = false; let timer; let r;
const done = (how) => { if (said) return; said = true; clearTimeout(timer); if (r) r.destroy(); console.log(how, Date.now() - t0); };
r = require("http").get(`http://127.0.0.1:${process.env.QPORT}/truncated`, (res) => {
  res.on("data", () => {});
  res.on("aborted", () => done("aborted"));
  res.on("end", () => done("end"));
  res.on("error", () => done("error"));
});
r.on("error", () => done("error"));
timer = setTimeout(() => done("hung"), 3500);')
{ [ "${verdict:-}" = aborted ] || [ "${verdict:-}" = error ]; } && [ "${ms:-99999}" -lt 3000 ] \
  && echo "PASS truncated body: client saw $verdict at ${ms} ms" \
  || { echo "FAIL truncated body: client saw ${verdict:-nothing} at ${ms:-never} ms"; fail=1; }
[ "$(curl -s -m 10 -H 'Authorization: Bearer test-key' -d after-truncated "127.0.0.1:$QPORT/api/coding/paas/v4/chat/completions?after")" \
  = "POST /api/coding/paas/v4/chat/completions?after Bearer test-key after-truncated" ] \
  && echo "PASS the call after the truncation completed (slot freed)" || { echo "FAIL slot wedged after truncation"; fail=1; }
grep -q '^status=upstream-error .* in_flight=0 ' "$T/queue.log" && echo "PASS truncation logged with the slot drained" \
  || { echo "FAIL no drained upstream-error line in log:"; sed 's/^/  /' "$T/queue.log"; fail=1; }

grep -q 'Bearer\|test-key\|call-' "$T/queue.log" && { echo "FAIL the queue logged request content"; fail=1; }
exit $fail
