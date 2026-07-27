#!/usr/bin/env bash
# fm-decide-page.sh - Generate a local captain-facing decision page.
#
# Reads a JSON file describing open decisions, starts a local HTTP server on
# 127.0.0.1, outputs the URL, and arms the watcher check so firstmate wakes when
# the captain submits choices.
# The captain opens the URL, reads all decisions with their evidence and
# recommendations, selects one option per decision (with an optional note), and
# submits once.
# Responses are written to state/decide-<run-id>/responses/<key>.json and a
# state/decide-<run-id>/ready marker is written.
# The watcher check state/decide.check.sh wakes firstmate when any pending
# decide run has a ready marker without a processed marker.
# Firstmate reads the responses, routes each choice, and writes
# state/decide-<run-id>/processed when done.
#
# Usage:
#   fm-decide-page.sh [--timeout SECONDS] <decisions.json>
#
# Input JSON schema (see docs/decide-page.md for the full schema):
#   {
#     "decisions": [
#       {
#         "key": "slug",
#         "title": "Human-readable title",
#         "context": "Evidence and context",
#         "options": [
#           {"id": "slug", "label": "Label", "description": "Optional"}
#         ],
#         "recommendation": "slug"
#       }
#     ]
#   }
#
# Security invariants:
#   - Server listens on 127.0.0.1 only; never on all interfaces.
#   - Port is ephemeral (OS-assigned); never a fixed port.
#   - Each invocation generates a one-time secret; submissions without it are
#     rejected with 403.
#   - Only keys declared in the input decisions are accepted; unknown keys yield
#     400.
#   - Server shuts down after one valid complete submission or when timeout elapses.
#   - state/decide-<run-id>/ is removed only when firstmate marks it processed;
#     the script itself does not delete run state on exit.
#   - The page carries the run secret as an anti-CSRF token in a hidden field;
#     no absolute path and no external resource is embedded in the page.
#
# Environment:
#   FM_HOME            Firstmate home root (default: repo root from script location)
#   FM_STATE_OVERRIDE  Override state dir (tests)
#   FM_ROOT_OVERRIDE   Override repo root (tests)
#   FM_DECIDE_TIMEOUT  Default timeout in seconds (default 1800)

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

DEFAULT_TIMEOUT="${FM_DECIDE_TIMEOUT:-1800}"
TIMEOUT="$DEFAULT_TIMEOUT"
INPUT_JSON=

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

fail() {
  printf 'fm-decide-page: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -ge 2 ] || fail "--timeout requires a value"
      TIMEOUT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [ -z "$INPUT_JSON" ] || fail "too many arguments; only one decisions JSON allowed"
      INPUT_JSON=$1
      shift
      ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) fail "timeout must be a positive integer: $TIMEOUT" ;;
esac
[ "$TIMEOUT" -gt 0 ] || fail "timeout must be a positive integer: $TIMEOUT"

[ -n "$INPUT_JSON" ] || { usage; exit 1; }
[ -f "$INPUT_JSON" ] || fail "decisions file not found: $INPUT_JSON"

command -v python3 >/dev/null 2>&1 || fail "python3 is required but not found"

[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory unavailable: $STATE"

# Validate input JSON via Python (canonical validator); exits non-zero on any
# schema violation. Output is discarded; we only need the exit code.
python3 - "$INPUT_JSON" >/dev/null <<'PYVALIDATE' || fail "invalid decisions JSON"
import json, sys, re

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

SLUG_RE = re.compile(r'^[A-Za-z0-9._-]+$')

if not isinstance(data, dict):
    print("top-level value must be an object", file=sys.stderr)
    sys.exit(1)
decisions = data.get("decisions")
if not isinstance(decisions, list) or len(decisions) == 0:
    print("decisions must be a non-empty array", file=sys.stderr)
    sys.exit(1)

seen_keys = set()
for i, d in enumerate(decisions):
    if not isinstance(d, dict):
        print(f"decisions[{i}] must be an object", file=sys.stderr)
        sys.exit(1)
    key = d.get("key", "")
    if not isinstance(key, str) or not SLUG_RE.match(key):
        print(f"decisions[{i}].key must be a non-empty slug [A-Za-z0-9._-]: {key!r}", file=sys.stderr)
        sys.exit(1)
    if key in seen_keys:
        print(f"duplicate key: {key}", file=sys.stderr)
        sys.exit(1)
    seen_keys.add(key)
    title = d.get("title", "")
    if not isinstance(title, str) or not title.strip():
        print(f"decisions[{i}].title must be a non-empty string", file=sys.stderr)
        sys.exit(1)
    context = d.get("context", "")
    if not isinstance(context, str) or not context.strip():
        print(f"decisions[{i}].context must be a non-empty string", file=sys.stderr)
        sys.exit(1)
    options = d.get("options")
    if not isinstance(options, list) or len(options) < 2:
        print(f"decisions[{i}].options must be an array of at least 2 items", file=sys.stderr)
        sys.exit(1)
    seen_opts = set()
    for j, opt in enumerate(options):
        if not isinstance(opt, dict):
            print(f"decisions[{i}].options[{j}] must be an object", file=sys.stderr)
            sys.exit(1)
        oid = opt.get("id", "")
        if not isinstance(oid, str) or not SLUG_RE.match(oid):
            print(f"decisions[{i}].options[{j}].id must be a non-empty slug: {oid!r}", file=sys.stderr)
            sys.exit(1)
        if oid in seen_opts:
            print(f"decisions[{i}]: duplicate option id: {oid}", file=sys.stderr)
            sys.exit(1)
        seen_opts.add(oid)
        label = opt.get("label", "")
        if not isinstance(label, str) or not label.strip():
            print(f"decisions[{i}].options[{j}].label must be a non-empty string", file=sys.stderr)
            sys.exit(1)
    rec = d.get("recommendation")
    if rec is not None:
        if not isinstance(rec, str) or rec not in seen_opts:
            print(f"decisions[{i}].recommendation must be a valid option id: {rec!r}", file=sys.stderr)
            sys.exit(1)

PYVALIDATE

# Generate run id: timestamp + random suffix (uses Python for portability).
RUN_ID=$(python3 -c "
import secrets, time
ts = int(time.time())
rand = secrets.token_hex(4)
print(f'decide-{ts}-{rand}')
")

SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

RUN_DIR="$STATE/$RUN_ID"
(umask 077 && mkdir -p "$RUN_DIR/responses")

# Write the watcher check script.
# This file is always identical across invocations; re-writing and re-registering
# is idempotent because fm-check-register.sh overwrites the trust file atomically.
CHECK_SH="$STATE/decide.check.sh"
CHECK_TMP=$(umask 077 && mktemp "$STATE/.decide.check.sh.XXXXXX") || fail "cannot create check temp file"
trap 'rm -f -- "$CHECK_TMP"' EXIT HUP INT TERM
cat > "$CHECK_TMP" <<'CHECKEOF'
#!/usr/bin/env bash
# Watcher check: prints one line when a decide run has unread responses.
# Prints nothing otherwise. Exits after the first match.
FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
for ready in "$FM_HOME/state"/decide-*/ready; do
  [ -f "$ready" ] || continue
  dir=$(dirname "$ready")
  [ ! -f "$dir/processed" ] || continue
  run_id=$(basename "$dir")
  printf 'responses-ready: %s\n' "$run_id"
  break
done
CHECKEOF
chmod 0700 "$CHECK_TMP"
mv -f -- "$CHECK_TMP" "$CHECK_SH" || fail "cannot install $CHECK_SH"
trap - EXIT HUP INT TERM

# Bind check bytes before the watcher can execute it.
"$SCRIPT_DIR/fm-check-register.sh" decide || fail "failed to register decide check"

# Write the embedded Python HTTP server to the run directory.
SERVER_PY="$RUN_DIR/server.py"
cat > "$SERVER_PY" <<'PYEOF'
#!/usr/bin/env python3
"""Firstmate decide-page server.
Serves a self-contained decision page at GET /, accepts one batch POST at
/submit, writes per-key response files, and self-terminates.
"""
import json, os, re, signal, sys, threading, time
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

os.umask(0o077)

STATE_DIR = sys.argv[1]
RUN_ID    = sys.argv[2]
INPUT_JSON= sys.argv[3]
TIMEOUT   = int(sys.argv[4])
SECRET    = os.environ.pop("FM_DECIDE_SECRET", "")
if not SECRET:
    print("fm-decide-page: FM_DECIDE_SECRET is required", file=sys.stderr)
    sys.exit(1)

with open(INPUT_JSON) as fh:
    DECISIONS = json.load(fh)["decisions"]

VALID_KEYS   = {d["key"] for d in DECISIONS}
RUN_DIR      = os.path.join(STATE_DIR, RUN_ID)
RESPONSES_DIR= os.path.join(RUN_DIR, "responses")
os.makedirs(RESPONSES_DIR, exist_ok=True)

_server_ref = None
_submitted  = False
_submit_lock = threading.Lock()

HTML_PAGE = r"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Decisões pendentes - Firstmate</title>
<style>
:root {
  --bg: #f5f5f5;
  --surface: #fff;
  --border: #d1d5db;
  --text: #111;
  --muted: #555;
  --accent: #1a56db;
  --rec-bg: #eff6ff;
  --rec-border: #3b82f6;
  --rec-text: #1e40af;
  --success-bg: #ecfdf5;
  --success-border: #10b981;
  --success-text: #065f46;
  --err-bg: #fef2f2;
  --err-border: #ef4444;
  --err-text: #7f1d1d;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111;
    --surface: #1e1e1e;
    --border: #374151;
    --text: #e5e7eb;
    --muted: #9ca3af;
    --accent: #60a5fa;
    --rec-bg: #1e3a5f;
    --rec-border: #3b82f6;
    --rec-text: #93c5fd;
    --success-bg: #064e3b;
    --success-border: #10b981;
    --success-text: #6ee7b7;
    --err-bg: #450a0a;
    --err-border: #ef4444;
    --err-text: #fca5a5;
  }
}
:root[data-theme="light"] {
  --bg: #f5f5f5; --surface: #fff; --border: #d1d5db; --text: #111;
  --muted: #555; --accent: #1a56db; --rec-bg: #eff6ff;
  --rec-border: #3b82f6; --rec-text: #1e40af;
  --success-bg: #ecfdf5; --success-border: #10b981; --success-text: #065f46;
  --err-bg: #fef2f2; --err-border: #ef4444; --err-text: #7f1d1d;
}
:root[data-theme="dark"] {
  --bg: #111; --surface: #1e1e1e; --border: #374151; --text: #e5e7eb;
  --muted: #9ca3af; --accent: #60a5fa; --rec-bg: #1e3a5f;
  --rec-border: #3b82f6; --rec-text: #93c5fd;
  --success-bg: #064e3b; --success-border: #10b981; --success-text: #6ee7b7;
  --err-bg: #450a0a; --err-border: #ef4444; --err-text: #fca5a5;
}
*, *::before, *::after { box-sizing: border-box; }
body {
  margin: 0; padding: 2rem 1rem;
  background: var(--bg); color: var(--text);
  font: 15px/1.5 system-ui, -apple-system, sans-serif;
}
.container { max-width: 760px; margin: 0 auto; }
h1 { font-size: 1.3rem; margin: 0 0 0.25rem; }
.subtitle { color: var(--muted); font-size: 0.9rem; margin: 0 0 2rem; }
.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 8px; padding: 1.25rem; margin-bottom: 1.5rem;
}
.card-title { font-size: 1rem; font-weight: 600; margin: 0 0 0.75rem; }
.card-num {
  display: inline-block; background: var(--accent); color: #fff;
  border-radius: 50%; width: 1.4rem; height: 1.4rem;
  font-size: 0.75rem; font-weight: 700; text-align: center; line-height: 1.4rem;
  margin-right: 0.5rem; vertical-align: middle;
}
.context {
  background: var(--bg); border: 1px solid var(--border);
  border-radius: 4px; padding: 0.75rem 1rem;
  font-size: 0.875rem; color: var(--muted);
  margin-bottom: 1rem; white-space: pre-wrap; word-break: break-word;
  max-height: 200px; overflow-y: auto;
}
.options { display: flex; flex-direction: column; gap: 0.5rem; margin-bottom: 1rem; }
.option {
  display: flex; align-items: flex-start; gap: 0.75rem;
  border: 1px solid var(--border); border-radius: 6px;
  padding: 0.75rem; cursor: pointer; transition: border-color 0.15s;
}
.option:hover { border-color: var(--accent); }
.option.recommended {
  border-color: var(--rec-border); background: var(--rec-bg);
}
.option input[type=radio] { margin-top: 2px; flex-shrink: 0; accent-color: var(--accent); }
.option-body { flex: 1; }
.option-label { font-size: 0.9rem; font-weight: 500; }
.option-desc { font-size: 0.8rem; color: var(--muted); margin-top: 2px; }
.rec-badge {
  display: inline-block; font-size: 0.7rem; font-weight: 600;
  background: var(--rec-border); color: #fff;
  border-radius: 3px; padding: 1px 5px; margin-left: 6px; vertical-align: middle;
}
.note-label { font-size: 0.8rem; color: var(--muted); display: block; margin-bottom: 0.3rem; }
.note-field {
  width: 100%; border: 1px solid var(--border); border-radius: 4px;
  background: var(--surface); color: var(--text);
  padding: 0.5rem 0.75rem; font: inherit; font-size: 0.85rem;
  resize: vertical; min-height: 60px;
}
.note-field:focus { outline: 2px solid var(--accent); border-color: transparent; }
.submit-bar {
  position: sticky; bottom: 0;
  background: var(--surface); border-top: 1px solid var(--border);
  padding: 1rem; margin: 0 -1rem; border-radius: 0 0 8px 8px;
  text-align: right;
}
.btn {
  background: var(--accent); color: #fff;
  border: none; border-radius: 6px;
  padding: 0.6rem 1.5rem; font: inherit; font-weight: 600;
  cursor: pointer; font-size: 0.95rem;
}
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.banner {
  border-radius: 6px; padding: 1rem 1.25rem; margin-bottom: 1.5rem;
  font-size: 0.9rem;
}
.banner.success { background: var(--success-bg); border: 1px solid var(--success-border); color: var(--success-text); }
.banner.error   { background: var(--err-bg); border: 1px solid var(--err-border); color: var(--err-text); }
#submitted-notice { display: none; }
</style>
</head>
<body>
<div class="container">
  <h1>Decisões pendentes</h1>
  <p class="subtitle">Leia a evidência, escolha uma opção por decisão e clique em Confirmar.</p>
  <div id="banner" class="banner" style="display:none"></div>
  <div id="submitted-notice" class="banner success">
    Suas escolhas foram recebidas. O firstmate será notificado.
  </div>
  <form id="decide-form">
    <input type="hidden" name="__secret" value="__SECRET__">
    __CARDS__
    <div class="submit-bar">
      <button type="submit" class="btn" id="submit-btn">Confirmar todas as escolhas</button>
    </div>
  </form>
</div>
<script>
(function () {
  var form = document.getElementById("decide-form");
  var banner = document.getElementById("banner");
  var notice = document.getElementById("submitted-notice");
  var btn = document.getElementById("submit-btn");

  function showBanner(type, msg) {
    banner.className = "banner " + type;
    banner.textContent = msg;
    banner.style.display = "";
    banner.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var data = { secret: form.__secret.value, choices: {} };
    var missing = [];
    form.querySelectorAll("[data-decision-key]").forEach(function (card) {
      var key = card.dataset.decisionKey;
      var sel = card.querySelector("input[type=radio]:checked");
      if (!sel) { missing.push(key); return; }
      var note = card.querySelector("textarea");
      data.choices[key] = { choice: sel.value, note: note ? note.value : "" };
    });
    if (missing.length) {
      showBanner("error", "Escolha uma opção para: " + missing.join(", "));
      return;
    }
    btn.disabled = true;
    btn.textContent = "Enviando...";
    fetch("/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data)
    })
    .then(function (r) {
      if (!r.ok) return r.text().then(function(t) { throw new Error(t || r.statusText); });
      return r.json();
    })
    .then(function () {
      form.style.display = "none";
      notice.style.display = "block";
      banner.style.display = "none";
    })
    .catch(function (err) {
      showBanner("error", "Erro ao enviar: " + err.message);
      btn.disabled = false;
      btn.textContent = "Confirmar todas as escolhas";
    });
  });
})();
</script>
</body>
</html>
"""

def _build_card(decision, index):
    key = decision["key"]
    title = _esc(decision["title"])
    context = _esc(decision["context"])
    rec = decision.get("recommendation", "")
    options_html = ""
    for opt in decision["options"]:
        oid   = _esc(opt["id"])
        label = _esc(opt["label"])
        desc  = _esc(opt.get("description", ""))
        badge = '<span class="rec-badge">Recomendado</span>' if opt["id"] == rec else ""
        cls   = ' recommended' if opt["id"] == rec else ""
        desc_html = f'<div class="option-desc">{desc}</div>' if desc else ""
        options_html += (
            f'<label class="option{cls}">'
            f'<input type="radio" name="{key}" value="{oid}">'
            f'<div class="option-body">'
            f'<div class="option-label">{label}{badge}</div>'
            f'{desc_html}'
            f'</div></label>'
        )
    return (
        f'<div class="card" data-decision-key="{key}">'
        f'<div class="card-title"><span class="card-num">{index+1}</span>{title}</div>'
        f'<div class="context">{context}</div>'
        f'<div class="options">{options_html}</div>'
        f'<label class="note-label" for="note-{key}">Observação (opcional)</label>'
        f'<textarea class="note-field" id="note-{key}" name="note-{key}" rows="2" placeholder="Contexto adicional..."></textarea>'
        f'</div>'
    )

def _esc(s):
    return str(s).replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;")

def _build_page():
    cards = "".join(_build_card(d, i) for i, d in enumerate(DECISIONS))
    return HTML_PAGE.replace("__SECRET__", SECRET).replace("__CARDS__", cards)

_PAGE_CACHE = _build_page()

class Handler(BaseHTTPRequestHandler):
    timeout = 30

    def do_GET(self):
        if self.path == "/" and not _submitted:
            body = _PAGE_CACHE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/" and _submitted:
            msg = b"Choices already received."
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/submit":
            self.send_error(404)
            return
        with _submit_lock:
            self._do_submit()

    def _do_submit(self):
        global _submitted
        if _submitted:
            self._json_error(409, "already submitted")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._json_error(400, "invalid Content-Length")
            return
        if length < 0:
            self._json_error(400, "invalid Content-Length")
            return
        if length > 512 * 1024:
            self._json_error(413, "payload too large")
            return
        raw = self.rfile.read(length)
        if len(raw) != length:
            self._json_error(400, "incomplete request body")
            return
        try:
            body = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._json_error(400, "invalid JSON")
            return

        if not isinstance(body, dict):
            self._json_error(400, "body must be an object")
            return
        if body.get("secret") != SECRET:
            self._json_error(403, "invalid secret")
            return

        choices = body.get("choices")
        if not isinstance(choices, dict):
            self._json_error(400, "choices must be an object")
            return

        unknown = set(choices.keys()) - VALID_KEYS
        if unknown:
            self._json_error(400, "unknown decision keys: " + ", ".join(sorted(unknown)))
            return

        missing = VALID_KEYS - set(choices.keys())
        if missing:
            self._json_error(400, "missing decision keys: " + ", ".join(sorted(missing)))
            return

        # Validate each choice against allowed option IDs.
        valid_options = {d["key"]: {o["id"] for o in d["options"]} for d in DECISIONS}
        now_iso = datetime.now(timezone.utc).isoformat()
        for key, val in choices.items():
            if not isinstance(val, dict):
                self._json_error(400, f"choices[{key!r}] must be an object")
                return
            choice = val.get("choice", "")
            if choice not in valid_options[key]:
                self._json_error(400, f"choices[{key!r}].choice is not a valid option id: {choice!r}")
                return
            note = val.get("note", "")
            if not isinstance(note, str):
                self._json_error(400, f"choices[{key!r}].note must be a string")
                return

        # Write individual response files atomically.
        for key, val in choices.items():
            record = {
                "key": key,
                "choice": val["choice"],
                "note": val.get("note", ""),
                "timestamp": now_iso,
                "run_id": RUN_ID,
            }
            tmp_path = os.path.join(RESPONSES_DIR, f".{key}.tmp")
            dst_path = os.path.join(RESPONSES_DIR, f"{key}.json")
            with open(tmp_path, "w") as fh:
                json.dump(record, fh, indent=2)
                fh.write("\n")
            os.replace(tmp_path, dst_path)

        # Write ready marker.
        ready_path = os.path.join(RUN_DIR, "ready")
        with open(ready_path, "w") as fh:
            fh.write(now_iso + "\n")

        _submitted = True
        payload = json.dumps({"ok": True, "run_id": RUN_ID}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

        # Shut down after a short delay so the response is flushed.
        threading.Thread(target=_shutdown, daemon=True).start()

    def _json_error(self, code, msg):
        body = json.dumps({"error": msg}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

def _shutdown():
    time.sleep(0.3)
    if _server_ref:
        _server_ref.shutdown()

def main():
    global _server_ref
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    _server_ref = srv
    port = srv.server_address[1]
    port_path = os.path.join(RUN_DIR, "port")
    with open(port_path, "w") as fh:
        fh.write(str(port) + "\n")

    # Timeout watchdog.
    def _watchdog():
        time.sleep(TIMEOUT)
        if not _submitted:
            if _server_ref:
                _server_ref.shutdown()
    threading.Thread(target=_watchdog, daemon=True).start()

    srv.serve_forever()

if __name__ == "__main__":
    main()
PYEOF

# Start the Python server in the background.
INPUT_ABS=$(cd "$(dirname "$INPUT_JSON")" && pwd)/$(basename "$INPUT_JSON")
FM_DECIDE_SECRET="$SECRET" python3 "$SERVER_PY" "$STATE" "$RUN_ID" "$INPUT_ABS" "$TIMEOUT" >/dev/null 2>&1 &

# Wait for port file (up to 5 seconds).
TRIES=0
while [ ! -f "$RUN_DIR/port" ]; do
  TRIES=$((TRIES + 1))
  [ "$TRIES" -le 50 ] || fail "server did not start within 5 seconds"
  sleep 0.1
done

PORT=$(tr -d '[:space:]' < "$RUN_DIR/port")

printf 'Decisões prontas: http://127.0.0.1:%s/\n' "$PORT"
printf 'Firstmate será notificado quando as escolhas forem submetidas (run: %s).\n' "$RUN_ID"
printf 'Servidor encerrará automaticamente em %s segundos ou após envio.\n' "$TIMEOUT"
