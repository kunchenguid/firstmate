#!/usr/bin/env bash
# Portable regression for the SQLite WAL cross-process locking detection.
#
# The host capability itself is kernel-dependent, so proving it needs the real
# kernel and belongs to tests/fm-sqlite-wal-lock-live-e2e.test.sh. This file
# pins everything that must hold on EVERY host: the gate that decides whether
# the probe is worth spending, the probe's own two-process machinery, and the
# mapping from a probe verdict to the single VALIDATION_UNAVAILABLE line
# bin/fm-bootstrap.sh publishes.
#
# The verdict legs are driven through real executable stubs on the
# FM_SQLITE_WAL_PROBE_BIN seam rather than a mocked shell function, so the
# classifier is exercised through the same process boundary it uses in
# production. A stub can only prove the mapping; it deliberately proves nothing
# about the host, which is why the live guard exists.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-sqlite-wal-lock)

# shellcheck source=bin/fm-sqlite-wal-lib.sh disable=SC1091
. "$ROOT/bin/fm-sqlite-wal-lib.sh"

# --- host gate: three independent signals, each sufficient on its own --------
#
# The gate must not rest on a single vendor spelling, so each signal is driven
# in isolation with the other two held at a plain-Linux value. The plain-Linux
# case is asserted in the same table, so a gate that silently became
# always-true cannot pass this block vacuously.

# Each case runs in a real separate process, the way bin/fm-bootstrap.sh calls
# the gate, rather than in a subshell whose environment edits only look isolated.
suspect_with() { # <kernel> <fstype> <WSL_DISTRO_NAME> <WSL_INTEROP>
  # Both WSL env signals are cleared first and then re-set only when the case
  # wants them, so an absent signal is genuinely absent in the child.
  local -a assigns=(FM_FAKE_KERNEL_RELEASE="$1" FM_FAKE_ROOT_FSTYPE="$2")
  [ -n "$3" ] && assigns+=(WSL_DISTRO_NAME="$3")
  [ -n "$4" ] && assigns+=(WSL_INTEROP="$4")
  # shellcheck disable=SC2016 # The inner bash, not this shell, expands $1.
  env -u WSL_DISTRO_NAME -u WSL_INTEROP "${assigns[@]}" bash -c '
    . "$1" || exit 1
    fm_sqlite_wal_host_suspect && echo suspect || echo clear
  ' _ "$ROOT/bin/fm-sqlite-wal-lib.sh"
}

LINUX_KERNEL=6.1.0-generic
LINUX_FS=ext2/ext3

while read -r label kernel fstype distro interop want; do
  [ -n "$label" ] || continue
  case "$label" in \#*) continue ;; esac
  [ "$kernel" = - ] && kernel=$LINUX_KERNEL
  [ "$fstype" = - ] && fstype=$LINUX_FS
  [ "$distro" = - ] && distro=''
  [ "$interop" = - ] && interop=''
  got=$(suspect_with "$kernel" "$fstype" "$distro" "$interop")
  [ "$got" = "$want" ] || fail "host gate $label: want $want, got $got"
done <<'TABLE'
plain-linux            -                                  -      -        -            clear
wsl1-kernel            4.4.0-22621-Microsoft              -      -        -            suspect
wsl2-kernel            5.15.167.4-microsoft-standard-WSL2 -      -        -            suspect
wslfs-rootfs-only      -                                  wslfs  -        -            suspect
lxfs-rootfs-only       -                                  lxfs   -        -            suspect
distro-env-only        -                                  -      Ubuntu   -            suspect
interop-env-only       -                                  -      -        /run/x       suspect
TABLE
pass "host gate: each WSL signal is independently sufficient and a plain Linux host stays clear"

# Losing any single signal must not lose a genuine WSL1 host.
for drop in kernel fstype env; do
  k=4.4.0-22621-Microsoft f=wslfs d=Ubuntu
  case "$drop" in
    kernel) k=$LINUX_KERNEL ;;
    fstype) f=$LINUX_FS ;;
    env) d='' ;;
  esac
  got=$(suspect_with "$k" "$f" "$d" '')
  [ "$got" = suspect ] || fail "host gate survived losing $drop: want suspect, got $got"
done
pass "host gate: verdict survives losing any one signal"

# --- probe machinery: real second process, real sqlite ----------------------
#
# This runs on every host, WSL1 included, because it deliberately has no
# concurrent holder: a WAL database nobody else holds must open from a separate
# process everywhere. It is what separates "this host cannot share WAL" from
# "the probe is broken", so an unsupported verdict elsewhere cannot be vacuous.

PROBE="$ROOT/bin/fm-sqlite-wal-probe.py"
[ -x "$PROBE" ] || fail "probe helper is not executable: $PROBE"

if command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' 2>/dev/null; then
  uncontended="$TMP_ROOT/uncontended.db"
  python3 - "$uncontended" <<'PY' || fail "could not build the uncontended WAL fixture"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("pragma journal_mode=wal")
c.execute("create table probe(x)")
c.execute("insert into probe values(1)")
c.commit()
c.close()
PY
  out=$("$PROBE" --read "$uncontended" 2>&1) \
    || fail "second-process read of an unheld WAL database failed: $out"
  [ "$out" = ok ] || fail "second-process read of an unheld WAL database: want ok, got $out"
  pass "probe: its second-process reader opens an unheld WAL database on this host"

  out=$("$PROBE" --read "$TMP_ROOT/absent.db" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "probe reader reported success for a database with no table"
  pass "probe: its second-process reader reports failure rather than passing blindly"
else
  pass "probe: skipped second-process fixtures (no python3 sqlite3 on this host)"
fi

# --- verdict mapping: probe exit status to the published line ----------------

stub() { # <name> <exit> <line>
  local path="$TMP_ROOT/$1"
  cat > "$path" <<STUB
#!/usr/bin/env bash
echo '$3'
exit $2
STUB
  chmod +x "$path"
  printf '%s\n' "$path"
}

SUPPORTED=$(stub probe-supported 0 'supported')
UNSUPPORTED=$(stub probe-unsupported 1 'unsupported: a second process could not open the WAL database (OperationalError: locking protocol)')
UNVERIFIED=$(stub probe-unverified 2 'unverified: python3 has no sqlite3 module')

for case in "supported:0:supported" "unsupported:1:a second process could not open the WAL database (OperationalError: locking protocol)" "unverified:2:python3 has no sqlite3 module"; do
  name=${case%%:*}; rest=${case#*:}; want_rc=${rest%%:*}; want_detail=${rest#*:}
  bin=$SUPPORTED
  [ "$name" = unsupported ] && bin=$UNSUPPORTED
  [ "$name" = unverified ] && bin=$UNVERIFIED
  rc=0
  ( FM_SQLITE_WAL_PROBE_BIN=$bin
    # shellcheck source=bin/fm-sqlite-wal-lib.sh disable=SC1091
    . "$ROOT/bin/fm-sqlite-wal-lib.sh"
    fm_sqlite_wal_probe "$TMP_ROOT" 1
    probe_rc=$?
    printf '%s\n%s\n' "$probe_rc" "$(fm_sqlite_wal_probe_detail)"
  ) > "$TMP_ROOT/verdict.$name" || rc=$?
  got_rc=$(sed -n 1p "$TMP_ROOT/verdict.$name")
  got_detail=$(sed -n 2p "$TMP_ROOT/verdict.$name")
  [ "$got_rc" = "$want_rc" ] || fail "probe verdict $name: want exit $want_rc, got $got_rc"
  [ "$got_detail" = "$want_detail" ] || fail "probe detail $name: want '$want_detail', got '$got_detail'"
done
pass "probe: each exit status maps to its verdict and one-line detail"

# --- published line: only an OBSERVED failure is reported --------------------
#
# Driven through bin/fm-bootstrap.sh itself, so the contract pinned here is the
# line a session start actually prints.

# tests/lib.sh skips the probe suite-wide for hermeticity; this file owns the
# behavior, so it opts each case back in explicitly.
SKIP_PROBE=0
bootstrap_line() { # <probe-bin>
  local home="$TMP_ROOT/home.$$"
  rm -rf "$home"; mkdir -p "$home"/{data,state,config,projects}
  ( cd "$ROOT" || exit 1
    FM_HOME="$home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_SQLITE_WAL_PROBE_BIN="$1" \
    FM_SKIP_WAL_LOCK_PROBE="$SKIP_PROBE" \
    FM_FAKE_KERNEL_RELEASE=4.4.0-22621-Microsoft \
    FM_FAKE_ROOT_FSTYPE=wslfs \
    timeout 240 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
  ) | grep '^VALIDATION_UNAVAILABLE:' || true
}

if command -v no-mistakes >/dev/null 2>&1; then
  line=$(bootstrap_line "$UNSUPPORTED")
  [ -n "$line" ] || fail "bootstrap printed no VALIDATION_UNAVAILABLE line for an observed WAL locking failure"
  case "$line" in
    "VALIDATION_UNAVAILABLE: no-mistakes (kernel 4.4.0-22621-Microsoft cannot share a SQLite WAL database across processes: "*") - the no-mistakes delivery mode is unavailable on this host; ship affected work direct-PR until the host is repaired") ;;
    *) fail "bootstrap VALIDATION_UNAVAILABLE line does not match its published contract: $line" ;;
  esac
  case "$line" in
    *"locking protocol"*) ;;
    *) fail "bootstrap line dropped the probe's observed detail: $line" ;;
  esac
  pass "bootstrap: an observed WAL locking failure prints its published VALIDATION_UNAVAILABLE line"

  for quiet in "$SUPPORTED" "$UNVERIFIED"; do
    line=$(bootstrap_line "$quiet")
    [ -z "$line" ] || fail "bootstrap reported a WAL locking failure it did not observe ($quiet): $line"
  done
  pass "bootstrap: a working host and an unrunnable probe both stay silent"

  SKIP_PROBE=1
  line=$(bootstrap_line "$UNSUPPORTED")
  SKIP_PROBE=0
  [ -z "$line" ] || fail "FM_SKIP_WAL_LOCK_PROBE=1 did not suppress the probe: $line"
  pass "bootstrap: FM_SKIP_WAL_LOCK_PROBE=1 suppresses the probe"
else
  pass "bootstrap: skipped published-line cases (no-mistakes is not installed on this host)"
fi
