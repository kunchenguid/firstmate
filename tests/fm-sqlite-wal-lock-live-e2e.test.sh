#!/usr/bin/env bash
# Default-on live guard for cross-process SQLite WAL support on THIS host.
#
# Whether two processes can hold one WAL database at once is a kernel fact that
# no fixture can prove, so the portable regression
# (tests/fm-sqlite-wal-lock.test.sh) pins only the gate, the probe machinery and
# the verdict mapping. This guard measures the real capability with real
# processes and a real SQLite, and fails naming the kernel release and root
# filesystem rather than degrading quietly.
#
# It also pins the finding that keeps operators from chasing a remedy that does
# not work: the failure is kernel-level, not filesystem-level, so every
# filesystem this host offers must return the SAME verdict. A host where the
# data directory's filesystem and tmpfs disagree would make "relocate the
# no-mistakes data directory" a real fix, and this guard is what would catch
# that change.
#
# A run spends no model tokens, so the shared live gate runs it by default
# wherever python3 exists. Run it after any host migration (notably WSL1 to
# WSL2) and before trusting a refreshed
# docs/verification/runtime-backends.md "SQLite WAL cross-process locking" entry.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_SQLITE_WAL python3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-sqlite-wal-live)
PROBE="$ROOT/bin/fm-sqlite-wal-probe.py"

# shellcheck source=bin/fm-sqlite-wal-lib.sh disable=SC1091
. "$ROOT/bin/fm-sqlite-wal-lib.sh"

KERNEL=$(fm_sqlite_wal_kernel)
ROOTFS=$(fm_sqlite_wal_root_fstype)
HOST="kernel=$KERNEL rootfs=$ROOTFS"

python3 -c 'import sqlite3' 2>/dev/null \
  || fail "python3 has no sqlite3 module, so nothing could be measured ($HOST)"
[ -x "$PROBE" ] || fail "probe helper is not executable: $PROBE ($HOST)"

# A generous bound: this guard is not on the session-start path, and the real
# SQLITE_PROTOCOL verdict only surfaces after SQLite exhausts its WAL-index
# recovery retries, which takes about ten seconds.
BOUND=45

# --- control: the probe is sound on this host -------------------------------
#
# A WAL database nobody holds must open from a separate process on every host.
# Without this, an "unsupported" verdict below could just mean a broken probe.
control="$TMP_ROOT/control.db"
python3 - "$control" <<'PY' || fail "could not build the uncontended WAL fixture ($HOST)"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
mode = c.execute("pragma journal_mode=wal").fetchone()[0]
assert mode == "wal", mode
c.execute("create table probe(x)")
c.execute("insert into probe values(1)")
c.commit()
c.close()
PY
out=$("$PROBE" --read "$control" 2>&1) \
  || fail "this host cannot open an UNHELD WAL database from a second process, so its SQLite is broken beyond the locking question: $out ($HOST)"
[ "$out" = ok ] || fail "uncontended WAL read returned '$out', want 'ok' ($HOST)"
pass "control: an unheld WAL database opens from a second process ($HOST)"

# --- the measurement, on every filesystem this host offers -------------------

probe_dir() { # <dir> -> "<rc> <detail>"
  local dir=$1 out rc=0
  out=$("$PROBE" "$dir" --timeout "$BOUND" 2>&1) || rc=$?
  printf '%s %s\n' "$rc" "$out"
}

DATA_DIR=${FM_NO_MISTAKES_HOME:-$HOME/.no-mistakes}
[ -d "$DATA_DIR" ] && [ -w "$DATA_DIR" ] || DATA_DIR=$TMP_ROOT

declare -a NAMES=() VERDICTS=()
for spec in "no-mistakes-data-dir:$DATA_DIR" "tmpfs:/dev/shm" "tmp:${TMPDIR:-/tmp}"; do
  name=${spec%%:*}
  dir=${spec#*:}
  [ -d "$dir" ] && [ -w "$dir" ] || continue
  result=$(probe_dir "$dir")
  rc=${result%% *}
  detail=${result#* }
  case "$rc" in
    0 | 1) ;;
    *) fail "probe could not run in $dir ($name): $detail ($HOST)" ;;
  esac
  NAMES+=("$name($(stat -f -c %T "$dir" 2>/dev/null || echo '?'))")
  VERDICTS+=("$rc")
  printf '# %s -> %s\n' "$name" "$detail"
done

[ "${#VERDICTS[@]}" -gt 0 ] || fail "no writable directory was available to probe ($HOST)"

# --- every filesystem must agree: the condition is kernel-level -------------
first=${VERDICTS[0]}
for i in "${!VERDICTS[@]}"; do
  [ "${VERDICTS[$i]}" = "$first" ] && continue
  fail "filesystems disagree on cross-process WAL support - ${NAMES[0]}=${VERDICTS[0]} ${NAMES[$i]}=${VERDICTS[$i]}; relocating the no-mistakes data directory may now be a real remedy and docs/verification/runtime-backends.md must be re-taken ($HOST)"
done
pass "every probed filesystem agrees (${NAMES[*]}), so the verdict is kernel-level ($HOST)"

# --- the verdict must match the host class ----------------------------------
#
# WSL1 is the known-failing class. Asserting both directions is what makes a
# host migration visible here instead of silently leaving a stale claim.
case "$KERNEL" in
  *microsoft-standard-WSL2* | *WSL2*) class=wsl2 ;;
  *[Mm]icrosoft*) class=wsl1 ;;
  *) class=other ;;
esac
[ "$class" = other ] && [ "$ROOTFS" = wslfs ] && class=wsl1
[ "$class" = other ] && [ "$ROOTFS" = lxfs ] && class=wsl1

case "$class" in
  wsl1)
    [ "$first" = 1 ] || fail "WSL1 host reported WORKING cross-process WAL locking; if this host was migrated, re-take docs/verification/runtime-backends.md and revisit the no-mistakes delivery mode ($HOST)"
    pass "WSL1 host cannot share a WAL database across processes, as recorded ($HOST)"
    ;;
  *)
    [ "$first" = 0 ] || fail "this host cannot share a SQLite WAL database across processes, so the no-mistakes delivery mode is unavailable here ($HOST)"
    pass "cross-process WAL locking works on this host ($HOST)"
    ;;
esac
