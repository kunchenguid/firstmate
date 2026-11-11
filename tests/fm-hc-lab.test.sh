#!/usr/bin/env bash
# Public lab CLI regressions. Oracle: roots must exclude untrusted writers,
# sessions must never be adopted, and incomplete inventories cannot verify.
# Command stubs inject filesystem failures, not expected inventory contents.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hc-lab-tests)
LAB=${1:-$ROOT/bin/fm-hc-lab.sh}
export FM_HC_LAB_DIR="$TMP_ROOT/lab" FM_HC_LAB_SOCK_DIR="$TMP_ROOT/sockets"
export XDG_STATE_HOME="$TMP_ROOT/state" XDG_RUNTIME_DIR="$TMP_ROOT/runtime"
mkdir -p "$TMP_ROOT/fakebin" "$XDG_STATE_HOME/herdr-core"
printf 'real state\n' > "$XDG_STATE_HOME/herdr-core/state"
export REAL_FIND REAL_CAT
REAL_FIND=$(command -v find)
REAL_CAT=$(command -v cat)
cat > "$TMP_ROOT/fakebin/hc" <<'SH'
#!/usr/bin/env bash
printf '{"pid":123}\n'
SH
cat > "$TMP_ROOT/fakebin/find" <<'SH'
#!/usr/bin/env bash
[ "${FAIL_READ:-}" != find ] || exit 1
if [ "${FAIL_READ:-}" = metadata ]; then
  # Simulate a file disappearing between inventory and metadata collection.
  printf '%s/missing-file\n' "$1"
  exit 0
fi
exec "$REAL_FIND" "$@"
SH
cat > "$TMP_ROOT/fakebin/cat" <<'SH'
#!/usr/bin/env bash
case "${FAIL_READ:-}:$*" in
  roots:*/fleet-roots.txt|baseline:*/fleet-state.txt) exit 1 ;;
esac
exec "$REAL_CAT" "$@"
SH
# No real Core processes exist in these tests.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/fakebin/ps"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/fakebin/sleep"
chmod +x "$TMP_ROOT/fakebin/"*
export FM_HC_BIN="$TMP_ROOT/fakebin/hc" PATH="$TMP_ROOT/fakebin:$PATH"

refuse() {
  local diagnostic=$1
  shift
  if "$@" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "unexpected success: $*"
  fi
  grep -q "$diagnostic" "$TMP_ROOT/err" || fail "missing diagnostic: $diagnostic"
}

for root in "$FM_HC_LAB_DIR" "$FM_HC_LAB_SOCK_DIR"; do
  mkdir -m 777 "$root"
  chmod 777 "$root"
  for command in provision run stop teardown; do
    refuse 'unsafe root' bash "$LAB" "$command" fm-hclab-unsafe ls
  done
  [ ! -e "$FM_HC_LAB_DIR/fm-hclab-unsafe" ] || fail 'unsafe root accepted'
  rm -rf "$root"
  mkdir -m 700 "$TMP_ROOT/redirect"
  ln -s "$TMP_ROOT/redirect" "$root"
  refuse 'unsafe root' bash "$LAB" provision fm-hclab-redirected
  [ ! -e "$TMP_ROOT/redirect/fm-hclab-redirected" ] || fail 'symlink root accepted'
  rm "$root"
  rmdir "$TMP_ROOT/redirect"
done

bash "$LAB" provision fm-hclab-good
# The filesystem's permission bits are the owned output contract here.
python3 - "$FM_HC_LAB_DIR" "$FM_HC_LAB_SOCK_DIR" <<'PY'
import os, stat, sys
for path in sys.argv[1:]:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o700, path
PY
printf 'do not overwrite\n' > "$FM_HC_LAB_DIR/fm-hclab-good/sentinel"
refuse 'refusing to adopt or overwrite' bash "$LAB" provision fm-hclab-good
[ "$(cat "$FM_HC_LAB_DIR/fm-hclab-good/sentinel")" = 'do not overwrite' ] || fail 'existing session overwritten'

for failure in find metadata roots baseline; do
  refuse 'refusing unverified teardown' env FAIL_READ=$failure bash "$LAB" teardown fm-hclab-good
  [ -d "$FM_HC_LAB_DIR/fm-hclab-good" ] || fail 'failed verification removed evidence'
done
refuse 'could not record the fleet-state tripwire' env FAIL_READ=find bash "$LAB" provision fm-hclab-incomplete
[ ! -e "$FM_HC_LAB_DIR/fm-hclab-incomplete" ] || fail 'incomplete provision retained'
bash "$LAB" teardown fm-hclab-good
[ ! -e "$FM_HC_LAB_DIR/fm-hclab-good" ] || fail 'successful teardown retained session'
printf 'ok - private roots, exclusive sessions, and fail-closed tripwire\n'
