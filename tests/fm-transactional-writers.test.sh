#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-transactional-writers)
PORTABLE_BIN="$TMP_ROOT/portable-bin"
ORIGINAL_PATH=$PATH
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
mkdir -p "$PORTABLE_BIN" "$TMP_ROOT/records"
cat > "$PORTABLE_BIN/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = -- ] && exit 97
done
exec "$REAL_MV" "\$@"
SH
cat > "$PORTABLE_BIN/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" = -- ] && exit 97
done
exec "$REAL_RM" "\$@"
SH
chmod 700 "$PORTABLE_BIN/mv" "$PORTABLE_BIN/rm"

FM_BACKEND_LIB_DIR="$ROOT/bin"
FM_ROOT="$ROOT"
FM_HOME="$TMP_ROOT/home"
export FM_BACKEND_LIB_DIR FM_ROOT FM_HOME
. "$ROOT/bin/backends/tmux.sh"
. "$ROOT/bin/backends/zellij.sh"
. "$ROOT/bin/backends/cmux.sh"
. "$ROOT/bin/backends/herdr.sh"
PATH="$PORTABLE_BIN:$PATH"
export PATH

FM_BACKEND_ACQUISITION_FILE="$TMP_ROOT/records/tmux.record"
fm_backend_tmux_acquisition_record firstmate @tmuxwid fm-tmux || fail 'tmux acquisition record failed'
FM_BACKEND_ACQUISITION_FILE="$TMP_ROOT/records/zellij.record"
fm_backend_zellij_acquisition_record firstmate fm-zellij 7 8 || fail 'zellij acquisition record failed'
FM_BACKEND_ACQUISITION_FILE="$TMP_ROOT/records/cmux.record"
fm_backend_cmux_acquisition_record fm-cmux ws-cmux sf-cmux || fail 'cmux acquisition record failed'
FM_BACKEND_ACQUISITION_TASK_ID=writer-herdr
export FM_BACKEND_ACQUISITION_TASK_ID
FM_BACKEND_ACQUISITION_FILE="$TMP_ROOT/records/herdr.record"
fm_backend_herdr_acquisition_record firstmate ws-herdr tab-herdr fm-herdr pane-herdr || fail 'herdr acquisition record failed'

for record in "$TMP_ROOT"/records/*.record; do
  [ -s "$record" ] || fail "transactional acquisition record is empty: $record"
done

(
  cd "$TMP_ROOT" || exit 1
  FM_BACKEND_ACQUISITION_FILE=-dash.record
  fm_backend_tmux_acquisition_record firstmate @dash fm-dash
  [ -f ./-dash.record ]
) || fail 'option-shaped acquisition paths were not handled safely'

PATH="$ORIGINAL_PATH"
export PATH
pass 'transactional backend writers publish atomically with BSD-safe command arguments'
echo 'ALL TESTS PASSED'
