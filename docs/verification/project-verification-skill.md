# Project-verification skill exercise

Audience: maintainer verification.

This record supports the active guarantee that the internal [`project-verification` skill](../../.agents/skills/project-verification/SKILL.md) leads to a discoverable project recipe whose drive, evidence, and maintenance rules work against a real user surface.
The skill owns the procedure; this record supplies dated evidence from one bounded exercise and makes no claim beyond it.

## What ran

On 2026-09-29 UTC on `optimus0` (Linux 6.8.0-139-generic x86_64, python 3.12.3, curl 8.5.0) the procedure was applied to `ledgerbox`, a stdlib-only CLI and HTTP service, and the generated recipe and feature map were driven live.
Two entry points were driven independently - the `add` CLI write path and the `GET /balance` service path - so one smoke could not stand in for the map.
The same run then exercised drift and gaps: a stale Drive command in the recipe, a helper that refused `doctor` and `stop`, a mapped path whose `sqlite3` prerequisite is absent, and a `summary` feature added after the map was written.
`bin/fm-doc-audience-check.sh` and `tests/fm-documentation-audiences.test.sh` consume this prose structurally; they are not behavioral evidence and are reported separately from the outcomes below.

## Fixture

These files are byte-identical to the revision exercised (fixture `88c401c243ceaba3`, corrected helper `00d3c2e4677c848b`).

```bash
mkdir -p ledgerbox-exercise/fixture ledgerbox-exercise/generated/helpers
cat >ledgerbox-exercise/fixture/ledgerbox <<'FIXTURE_EOF'
#!/usr/bin/env python3
"""ledgerbox - a tiny ledger with a CLI and an HTTP service (stdlib only)."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOME = os.environ.get("LEDGERBOX_HOME") or os.path.join(os.path.expanduser("~"), ".ledgerbox")
DB = os.path.join(HOME, "ledger.json")


def load():
    try:
        with open(DB, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return []


def save(rows):
    os.makedirs(HOME, exist_ok=True)
    with open(DB, "w", encoding="utf-8") as fh:
        json.dump(rows, fh)


def total(rows):
    return sum(row["amount"] for row in rows)


def usage():
    print("usage: ledgerbox add <amount> <memo> | balance | import <sqlite-file> | serve <port>",
          file=sys.stderr)
    return 2


def cmd_add(argv):
    if len(argv) != 2:
        return usage()
    try:
        amount = int(argv[0])
    except ValueError:
        return usage()
    rows = load()
    rows.append({"amount": amount, "memo": argv[1]})
    save(rows)
    print(json.dumps({"balance": total(rows)}))
    return 0


def cmd_balance(_argv):
    print(json.dumps({"balance": total(load())}))
    return 0


def cmd_import(argv):
    """Import rows from a sqlite3 database using the sqlite3 CLI."""
    if len(argv) != 1:
        return usage()
    import shutil
    import subprocess
    if shutil.which("sqlite3") is None:
        print("ledgerbox: import requires the sqlite3 CLI, which is not installed", file=sys.stderr)
        return 127
    out = subprocess.run(["sqlite3", "-json", argv[0], "select amount, memo from ledger"],
                         check=True, capture_output=True, text=True).stdout
    rows = load()
    for row in json.loads(out or "[]"):
        rows.append({"amount": int(row["amount"]), "memo": row["memo"]})
    save(rows)
    print(json.dumps({"imported": True, "balance": total(rows)}))
    return 0


def cmd_summary(_argv):
    """Print per-memo totals."""
    totals = {}
    for row in load():
        totals[row["memo"]] = totals.get(row["memo"], 0) + row["amount"]
    print(json.dumps({"by_memo": totals}))
    return 0


def cmd_serve(argv):
    if len(argv) != 1:
        return usage()
    port = int(argv[0])

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/balance":
                payload = {"balance": total(load())}
            elif self.path == "/summary":
                totals = {}
                for row in load():
                    totals[row["memo"]] = totals.get(row["memo"], 0) + row["amount"]
                payload = {"by_memo": totals}
            else:
                self.send_error(404)
                return
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
    return 0


COMMANDS = {"add": cmd_add, "balance": cmd_balance, "import": cmd_import, "serve": cmd_serve,
            "summary": cmd_summary}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        return usage()
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
FIXTURE_EOF
chmod +x ledgerbox-exercise/fixture/ledgerbox
cat >ledgerbox-exercise/generated/helpers/ledgerbox-instance.sh <<'HELPER_EOF'
#!/usr/bin/env bash
# ledgerbox-instance.sh - start, doctor, or stop one isolated ledgerbox service instance.
#
# Usage:
#   LEDGERBOX_FIXTURE=<fixture-root> ledgerbox-instance.sh start  <instance-dir> [port]
#   ledgerbox-instance.sh doctor <instance-dir>
#   ledgerbox-instance.sh stop   <instance-dir>
#
# start records the launched PID in <instance-dir>/service.pid and only returns once
# the HTTP endpoint answers. stop signals exactly that recorded PID; it never matches
# processes by name, so it cannot kill an unrelated instance.
set -eu

ACTION=${1:?usage: ledgerbox-instance.sh start|doctor|stop <instance-dir> [port]}
DIR=${2:?usage: ledgerbox-instance.sh start|doctor|stop <instance-dir> [port]}
PORT=${3:-8781}
PIDFILE="$DIR/service.pid"
LOGFILE="$DIR/service.log"

case "$ACTION" in
  start)
    FIXTURE=${LEDGERBOX_FIXTURE:?set LEDGERBOX_FIXTURE to the fixture root}
    mkdir -p "$DIR"
    [ -e "$PIDFILE" ] && { echo "instance already recorded at $PIDFILE" >&2; exit 2; }
    LEDGERBOX_HOME="$DIR/state" python3 "$FIXTURE/ledgerbox" serve "$PORT" >"$LOGFILE" 2>&1 &
    echo $! >"$PIDFILE"
    for _ in $(seq 1 50); do
      if curl -fsS "http://127.0.0.1:$PORT/balance" >/dev/null 2>&1; then
        echo "ready port=$PORT pid=$(cat "$PIDFILE")"
        exit 0
      fi
      sleep 0.1
    done
    echo "instance did not become ready; see $LOGFILE" >&2
    exit 1
    ;;
  doctor)
    [ -s "$PIDFILE" ] || { echo "health=unknown detail=no-recorded-pid"; exit 1; }
    pid=$(cat "$PIDFILE")
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "health=down detail=pid $pid is not running"
      exit 1
    fi
    if curl -fsS "http://127.0.0.1:$PORT/balance" >/dev/null 2>&1; then
      echo "health=ok pid=$pid port=$PORT"
      exit 0
    fi
    echo "health=degraded detail=process alive but the endpoint does not answer"
    exit 1
    ;;
  stop)
    [ -s "$PIDFILE" ] || { echo "nothing to stop: no $PIDFILE"; exit 0; }
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$PIDFILE"
    echo "stopped pid=$pid"
    ;;
  *)
    echo "usage: ledgerbox-instance.sh start|doctor|stop <instance-dir> [port]" >&2
    exit 2
    ;;
esac
HELPER_EOF
chmod +x ledgerbox-exercise/generated/helpers/ledgerbox-instance.sh
```

Fixture sha256 `88c401c243ceaba3e9fc20d91bf2cfd875a66b39a16ec07293d58a9bcd272c43`; helper sha256 `00d3c2e4677c848b887b263054acb50ce8157c74e98cd921cff2111e6c41364b`.

## Entry-point outcomes

| Entry point | Invocation | Outcome | Observed result |
| --- | --- | --- | --- |
| ledger CLI write | `ledgerbox add 250 coffee` | verified | exit 0, `{"balance": 250}` |
| ledger CLI read | `ledgerbox balance` | verified | exit 0, `{"balance": 250}` |
| balance service | `curl 127.0.0.1:8781/balance` | verified | exit 0, `{"balance": 250}`; unknown route 404 |
| memo summary CLI | `ledgerbox summary` | verified | exit 0, `{"by_memo": {"coffee": 250}}` |
| memo summary service | `curl 127.0.0.1:8782/summary` | verified | exit 0, `{"by_memo": {"fare": 75}}` |
| sqlite import | `ledgerbox import <db>` | blocked | exit 127, `sqlite3` CLI absent; no other path counted for it |

Each verified row was driven against its own `LEDGERBOX_HOME`, and the two instances held different balances, so the isolation the recipe relies on was observed rather than assumed.

## Failure and maintenance loops

**Stale Drive command.** The recipe's CLI drive was changed to `ledgerbox add --amount 250 --memo coffee`, an interface the app never accepted. The drive exited 2 with the usage line while `ledgerbox balance` still answered, which classifies the failure as recipe drift rather than a product regression; the failed iteration left no state, and re-driving the restored invocation exited 0 with `{"balance": 250}`.

**Helper gap.** `ledgerbox-instance.sh doctor` and `stop` exited 1 with `LEDGERBOX_FIXTURE: set LEDGERBOX_FIXTURE to the fixture root`, leaving the service running. The helper read that variable before dispatching, so it required a value only `start` needs; after moving the requirement into the `start` branch, `doctor` reported `health=ok pid=3475584 port=8781`, `stop` reported `stopped pid=3475584`, and the recorded PID was gone.

**Completeness.** A surface scan of the fixture's registered subcommands and routes against the map found `summary` and `/summary` uncited, so full coverage was refused; after adding `features/memo-summary.md` and its index row the same scan reported full coverage. Both passes are recorded, and the added surface was driven live before it was recorded as verified.

**Cleanup.** Instances were stopped only through the PID each recorded for itself, never by process name; both ports then refused connections and every artifact remained readable.

## Limits

One fixture on one platform, generated and driven by the same agent rather than a separate cold consumer.
No filesystem or network confinement is exercised, and this is not evidence for web, desktop, mobile, or sandboxed surfaces.
The blocked `import` path is recorded as blocked with its prerequisite and was not counted as coverage.
Exact raw transcripts of each command above live in the exercise directory outside this repository; this record reproduces the fixture and every command needed to repeat them.
