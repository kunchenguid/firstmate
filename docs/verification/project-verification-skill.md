# Project-verification skill exercise

Audience: maintainer verification.

This record supports the active guarantee that the internal [`project-verification` skill](../../.agents/skills/project-verification/SKILL.md) leads to a discoverable project recipe whose drive, evidence, and maintenance rules work against a real user surface.
The skill owns the procedure; this record supplies dated evidence from bounded exercises and makes no claim beyond them.

## What ran

On 2026-09-29 UTC on `optimus0` (Linux 6.8.0-139-generic x86_64, python 3.12.3, curl 8.5.0) the procedure was applied to `ledgerbox`, a stdlib-only CLI and HTTP service, and the generated recipe and feature map were driven live.
Two entry points were driven independently - the `add` CLI write path and the `GET /balance` service path - so one smoke could not stand in for the map.
The same run then exercised drift and gaps: a stale Drive command in the recipe, a helper that refused `doctor` and `stop`, a mapped path whose `sqlite3` prerequisite is absent, and a `summary` feature added after the map was written.
A later review pass found two instance-ownership defects in the helper, reproduced and fixed on 2026-09-30 in the isolated lab described below.
`bin/fm-doc-audience-check.sh` and `tests/fm-documentation-audiences.test.sh` consume this prose structurally; they are not behavioral evidence and are reported separately from the outcomes below.

## Fixture

These files are byte-identical to the revision exercised (fixture `88c401c243ceaba3`, helper `c58e1523282760`).

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
# Each instance owns the state it needs to be inspected later: start records the launched PID
# and the port it was given inside <instance-dir>, so doctor and stop never guess a default.
# start refuses a port that is already served, so it can never report readiness borrowed from
# another process, and it only reports ready once the listening socket on that port belongs to
# the process it launched. stop signals only the recorded PID, and only while that PID owns the
# port; it never matches processes by name.
set -eu

ACTION=${1:?usage: ledgerbox-instance.sh start|doctor|stop <instance-dir> [port]}
DIR=${2:?usage: ledgerbox-instance.sh start|doctor|stop <instance-dir> [port]}
PIDFILE="$DIR/service.pid"
PORTFILE="$DIR/service.port"
LOGFILE="$DIR/service.log"

# port_owner <port> prints the PID listening on that TCP port, or "free", or "unknown".
port_owner() {
  python3 - "$1" <<'PY'
import glob, os, sys
port = int(sys.argv[1])
inode = None
for line in open('/proc/net/tcp'):
    fields = line.split()
    if len(fields) > 9 and fields[1].endswith(':%04X' % port) and fields[3] == '0A':
        inode = fields[9]
if inode is None:
    print('free')
    raise SystemExit
for path in glob.glob('/proc/[0-9]*/fd/*'):
    try:
        target = os.readlink(path)
    except OSError:
        continue
    if target == 'socket:[%s]' % inode:
        print(path.split('/')[2])
        raise SystemExit
print('unknown')
PY
}

case "$ACTION" in
  start)
    FIXTURE=${LEDGERBOX_FIXTURE:?set LEDGERBOX_FIXTURE to the fixture root}
    PORT=${3:-8781}
    mkdir -p "$DIR"
    [ -e "$PIDFILE" ] && { echo "instance already recorded at $PIDFILE" >&2; exit 2; }
    owner=$(port_owner "$PORT")
    [ "$owner" = free ] || { echo "port $PORT is already served by pid $owner; refusing to start" >&2; exit 2; }
    LEDGERBOX_HOME="$DIR/state" python3 "$FIXTURE/ledgerbox" serve "$PORT" >"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" >"$PIDFILE"
    echo "$PORT" >"$PORTFILE"
    for _ in $(seq 1 100); do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "instance exited before taking port $PORT; see $LOGFILE" >&2
        exit 1
      fi
      if [ "$(port_owner "$PORT")" = "$pid" ]; then
        echo "ready port=$PORT pid=$pid"
        exit 0
      fi
      sleep 0.1
    done
    echo "instance never took ownership of port $PORT; see $LOGFILE" >&2
    exit 1
    ;;
  doctor)
    [ -s "$PIDFILE" ] || { echo "health=unknown detail=no-recorded-pid"; exit 1; }
    [ -s "$PORTFILE" ] || { echo "health=unknown detail=no-recorded-port"; exit 1; }
    pid=$(cat "$PIDFILE")
    port=$(cat "$PORTFILE")
    kill -0 "$pid" 2>/dev/null || { echo "health=down detail=pid $pid is not running"; exit 1; }
    owner=$(port_owner "$port")
    if [ "$owner" = "$pid" ]; then
      echo "health=ok pid=$pid port=$port"
      exit 0
    fi
    echo "health=degraded detail=pid $pid is alive but port $port is served by $owner"
    exit 1
    ;;
  stop)
    [ -s "$PIDFILE" ] || { echo "nothing to stop: no $PIDFILE"; exit 0; }
    [ -s "$PORTFILE" ] || { echo "refusing to signal recorded pid: no $PORTFILE" >&2; exit 1; }
    pid=$(cat "$PIDFILE")
    port=$(cat "$PORTFILE")
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "refusing to signal pid $pid: recorded process is not running" >&2
      exit 1
    fi
    owner=$(port_owner "$port")
    if [ "$owner" != "$pid" ]; then
      echo "refusing to signal pid $pid: port $port is served by $owner" >&2
      exit 1
    fi
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    rm -f "$PIDFILE" "$PORTFILE"
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

Fixture sha256 `88c401c243ceaba3e9fc20d91bf2cfd875a66b39a16ec07293d58a9bcd272c43`; helper sha256 `c58e15232827602c6b85f4dbcc1573690a9f6050b456327687f2413fc4ad26cf`.
The entry-point drives below ran with the earlier helper revision `00d3c2e4677c848b`, before the ownership defects recorded further down were found; every ownership claim made here is re-proven against the current helper revision.

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

**First helper gap.** `ledgerbox-instance.sh doctor` and `stop` exited 1 with `LEDGERBOX_FIXTURE: set LEDGERBOX_FIXTURE to the fixture root`, leaving the service running. The helper read that variable before dispatching, so it required a value only `start` needs; after moving the requirement into the `start` branch, `doctor` reported `health=ok pid=3475584 port=8781`, `stop` reported `stopped pid=3475584`, and the recorded PID was gone.

**Completeness.** A surface scan of the fixture's registered subcommands and routes against the map found `summary` and `/summary` uncited, so full coverage was refused; after adding `features/memo-summary.md` and its index row the same scan reported full coverage. Both passes are recorded, and the added surface was driven live before it was recorded as verified.

## Instance-ownership defects found in review

Both were reproduced on 2026-09-30 in an isolated lab directory outside any project checkout, with an unrelated `ledgerbox` service started independently of the helper.

**Defect: `doctor` guessed the default port.** With an instance started on 8782 the documented invocation `ledgerbox-instance.sh doctor <instance-dir>` exited 1 reporting `health=degraded detail=process alive but the endpoint does not answer`, while `curl http://127.0.0.1:8782/balance` returned `{"balance": 0}` from the same healthy instance. `start` persisted only `service.pid`, so `doctor` fell back to 8781.
After the fix `start` also persists `service.port`, and the same sequence reports `health=ok pid=1604999 port=8782` with exit 0.

**Defect: an occupied port was accepted as readiness.** With an unrelated service already answering on 8791, `start <instance-dir> 8791` exited 0 printing `ready port=8791 pid=1601976`. The launched process died within about half a second with `OSError: [Errno 98] Address already in use`, the recorded PID owned nothing, and port 8791 was owned by the unrelated PID 1601794; a later `stop` merely signalled the dead recorded PID. The unrelated service was neither adopted nor killed, but the helper's ownership claim and the stop expectation were both wrong.
After the fix the same command exits 2 with `port 8791 is already served by pid 1605151; refusing to start`, records nothing, and leaves the unrelated service answering.

**Defect: `stop` signalled when the recorded port was free.** With an instance started on 18982, the service was killed outside the helper, a separate `sleep` process was written into `service.pid` to simulate a stale record whose PID had been reused, and the recorded port was left free.
Before the fix, `stop` would pass the free-port guard and signal the unrelated live PID.
After the fix `stop` exits 1 with `refusing to signal pid 1775034: port 18982 is served by free`, and the unrelated process remains alive.

**Fixed behaviour, re-proven in the same lab.** `start` refuses an occupied port before launching anything; it reports ready only once the listening socket on that port belongs to the process it launched; `doctor` reads the persisted port and reports `health=degraded` when a live PID does not own it; `stop` signals the recorded PID only while that PID owns the port.
Two instances then ran at once on 8781 and 8782 with separate state (`{"balance": 40}` and `{"balance": 0}`), both reported `health=ok`, and both were stopped by their recorded PIDs with both ports closed afterwards.
A stale stop run against the current helper started on 18982, killed the service outside the helper, rewrote `service.pid` to the unrelated live PID 1775034, observed `refusing to signal pid 1775034: port 18982 is served by free`, and left that unrelated process alive.

The commands to repeat these cases, in order, are: create the fixture above; start an unrelated `ledgerbox serve 8791` yourself; run `ledgerbox-instance.sh start <dir> 8791` and observe the refusal; run `start <dir> 8782` then `doctor <dir>` and observe `health=ok ... port=8782`; run a second `start <other-dir> 8781` and confirm both report `health=ok`; kill one recorded service outside the helper, write an unrelated live PID into its `service.pid`, and observe `stop` refuse because the recorded port is `free`; then `stop` each healthy instance and confirm both ports refuse connections.

## Limits

One fixture on one platform, generated and driven by the same agent rather than a separate cold consumer.
Ownership is established from `/proc/net/tcp` plus `/proc/<pid>/fd` on Linux, so the helper's ownership checks are Linux-specific; the recipe's claims are not extended to other platforms on this evidence.
No filesystem or network confinement is exercised, and this is not evidence for web, desktop, mobile, or sandboxed surfaces.
The blocked `import` path is recorded as blocked with its prerequisite and was not counted as coverage.
Raw transcripts of every command above live in exercise directories outside this repository; this record reproduces the fixture and the commands needed to repeat them.
