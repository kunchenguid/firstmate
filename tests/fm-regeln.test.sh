#!/usr/bin/env bash
# tests/fm-regeln.test.sh - bin/fm-regeln's own bootstrap contract:
#
#   1. Without `uv` on PATH and no venv yet bootstrapped, the wrapper refuses
#      loudly with "WRIT_FM: MISSING uv" on stderr and a nonzero exit - it
#      never silently no-ops or delegates to a binary that was never built.
#   2. tools/writ-fm/src/writ_light/paths.py resolves WRIT_DATA_DIR,
#      WRIT_MODEL_DIR and WRIT_RULES_DIR the way fm-regeln's header
#      documents: each env var wins outright, and with FM_HOME set but no
#      override, data/rules follow FM_HOME while the model dir stays fixed
#      at ~/.local/share/writ-fm/model. Run directly against whatever venv
#      already has writ_light importable (tools/writ-fm/.venv-test, built by
#      the vendored pytest suite's own setup, or the venv fm-regeln itself
#      would bootstrap) - built fresh only if the wrapper's own bootstrap
#      needs to run first; otherwise the case is a documented skip, never a
#      silent pass.
#
# Isolation: every case runs against a throwaway FM_HOME under mktemp; PATH
# is trimmed to the standard system dirs (no ~/.local/bin) to make `uv`
# genuinely absent without touching the real PATH or the real state/.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_REGELN="$REPO/bin/fm-regeln"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }
skip() { echo "skip: $1"; }

# --- 1. Missing uv refuses loudly, before any bootstrap side effect --------
HOME_A="$TMP/home-a"
mkdir -p "$HOME_A"
NARROW_PATH="/usr/bin:/bin"
if PATH="$NARROW_PATH" command -v uv >/dev/null 2>&1; then
  fail "test setup: uv must not resolve on the narrowed PATH ($NARROW_PATH)"
fi

out=$(FM_HOME="$HOME_A" PATH="$NARROW_PATH" "$FM_REGELN" doctor 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^WRIT_FM: MISSING uv'; then
  ok "fm-regeln refuses with WRIT_FM: MISSING uv when uv is unavailable"
else
  fail "fm-regeln must refuse naming 'WRIT_FM: MISSING uv' (rc=$rc out=$out)"
fi
[ ! -e "$HOME_A/state/writ-fm/venv" ] || fail "a refused bootstrap must not leave a partial venv behind"

# --- 2. paths.py honors WRIT_DATA_DIR / WRIT_MODEL_DIR / WRIT_RULES_DIR ----
VENV_PY=""
for candidate in "$REPO/tools/writ-fm/.venv-test/bin/python" "$HOME_A/state/writ-fm/venv/bin/python3"; do
  [ -x "$candidate" ] && { VENV_PY="$candidate"; break; }
done

if [ -z "$VENV_PY" ]; then
  skip "paths env-override check: no venv with writ_light installed found (looked for tools/writ-fm/.venv-test and a fm-regeln-bootstrapped venv) - build one (uv venv --python 3.12 .venv-test && uv pip install -e .) to exercise this case"
else
  CHECK_PY="$TMP/check_paths.py"
  cat > "$CHECK_PY" <<'PYEOF'
import os
import sys

os.environ["WRIT_DATA_DIR"] = "/override/data"
os.environ["WRIT_MODEL_DIR"] = "/override/model"
os.environ["WRIT_RULES_DIR"] = "/override/rules"
from writ_light import paths

assert str(paths.data_dir()) == "/override/data", paths.data_dir()
assert str(paths.model_dir()) == "/override/model", paths.model_dir()
assert str(paths.rules_dir()) == "/override/rules", paths.rules_dir()

os.environ.pop("WRIT_DATA_DIR")
os.environ.pop("WRIT_MODEL_DIR")
os.environ.pop("WRIT_RULES_DIR")
os.environ["FM_HOME"] = "/fm-home-fixture"
assert str(paths.data_dir()) == "/fm-home-fixture/state/writ-fm", paths.data_dir()
assert str(paths.rules_dir()) == "/fm-home-fixture/regeln", paths.rules_dir()
assert str(paths.model_dir()) == str(paths.Path.home() / ".local/share/writ-fm/model"), paths.model_dir()

print("paths-overrides-ok")
PYEOF
  out=$("$VENV_PY" "$CHECK_PY" 2>&1)
  py_rc=$?
  if [ "$py_rc" -eq 0 ] && printf '%s' "$out" | grep -q "paths-overrides-ok"; then
    ok "paths.py resolves WRIT_DATA_DIR/WRIT_MODEL_DIR/WRIT_RULES_DIR overrides and the FM_HOME-relative defaults (via $VENV_PY)"
  else
    fail "paths.py env-override resolution failed: $out"
  fi
fi

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all fm-regeln checks passed"
