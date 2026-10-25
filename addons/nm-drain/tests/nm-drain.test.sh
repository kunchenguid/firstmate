#!/usr/bin/env bash
# End-to-end: drive nm-drain.sh and install.sh against a throwaway firstmate home, HOME and state DB, with a fake
# no-mistakes first on PATH that records every call and fails on --force. Usage: nm-drain/tests/nm-drain.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_CACHE_HOME=$d/cache XDG_DATA_HOME=$d/data TMPDIR=$d PATH=$d/bin:$PATH
unset NM_HOME
NM=$HOME/.no-mistakes FM=$d/fm
mkdir -p "$NM" "$d/bin" "$FM/state" "$FM/bin"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
drain() { "$SRC/nm-drain.sh" "$@" "$FM" 2>&1; }
runs() { sqlite3 "$NM/state.sqlite" "$1"; }

cat > "$d/bin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
R=$HOME/.no-mistakes
echo "$*" >> "$R/calls"
case " $* " in *' --force '*) echo "fake: --force passed" >&2; exit 99 ;; esac
case "$*" in
  --version) echo "no-mistakes version $(cat "$R/version") (fake)" ;;
  'update -y')
    n=$(sqlite3 "$R/state.sqlite" "select count(*) from runs where status in ('pending', 'running')")
    [ "$n" = 0 ] || { echo "refusing update because $n active pipeline runs are in progress"; exit 1; }
    echo v1.84.0 > "$R/version"; echo "updated no-mistakes from v1.79.0 to v1.84.0" ;; # leaves the old daemon pid
  'daemon status') echo "  ● daemon running" ;;
  'daemon restart') echo '{"pid":222,"started_at":"now"}' > "$R/daemon.pid"; echo "  ✓ daemon restarted" ;;
  *) echo "fake: unexpected call: $*" >&2; exit 98 ;;
esac
EOF
chmod +x "$d/bin/no-mistakes"
echo v1.79.0 > "$NM/version"
echo '{"pid":111,"started_at":"then"}' > "$NM/daemon.pid"
echo '{"checked_at":"now","latest_version":"v1.84.0"}' > "$NM/update-check.json"
runs "create table runs (id text, status text, branch text, created_at integer);
  create table step_results (run_id text, step_name text, step_order integer, status text);
  insert into runs values ('R1', 'running', 'fm/one', 1), ('R0', 'completed', 'fm/old', 0);
  insert into step_results values ('R1', 'review', 3, 'completed'), ('R1', 'ci', 9, 'running');"

# (a) no drain: silent.
check "a: no drain -> silent" "$(drain check)" ""

# (b) drain with 1 active run: silent; at 0: one go-request line, then silent again.
has "b: start" "$(drain start)" "drain started"
check "b: 1 active -> silent" "$(drain check)" ""
has "b: status counts the monitoring run" "$(drain status)" "1 active pipeline run(s) (1 only in PR/CI monitoring)"
has "b: go refuses while a run is active" "$(drain go || true)" "refusing: 1 active"
runs "update runs set status = 'completed' where id = 'R1'"
out=$(drain check)
has "b: 0 active -> go request" "$out" "0 active pipeline runs after 0 min of drain; run '$SRC/nm-drain.sh go $FM' now"
check "b: exactly one line" "$(printf '%s\n' "$out" | wc -l)" 1
check "b: asked once only" "$(drain check)" ""

# (c) drain stuck past 60 min (start recorded 61 min ago): one stop line, drain cleared.
drain stop > /dev/null
runs "update runs set status = 'running' where id = 'R1'"
echo "$(($(date +%s) - 3660))" > "$FM/state/.nm-drain"
out=$(drain check)
has "c: stuck -> stop line" "$out" "drain ended after 61 min with no go (1 active pipeline run(s)"
check "c: exactly one line" "$(printf '%s\n' "$out" | wc -l)" 1
check "c: drain cleared" "$([ -e "$FM/state/.nm-drain" ] && echo present || echo cleared)" cleared
check "c: silent after clear" "$(drain check)" ""

# (d) go at 0 runs: update without --force, guarded restart because the update left the old daemon, version verified.
runs "update runs set status = 'completed' where id = 'R1'"
drain start > /dev/null
: > "$NM/calls"
out=$(drain go)
has "d: go reports the new version" "$out" "no-mistakes v1.79.0 -> v1.84.0, daemon restarted (pid 222)"
check "d: calls" "$(grep -v -e '^--version$' -e '^daemon status$' "$NM/calls" | paste -sd ';')" "update -y;daemon restart"
check "d: no --force anywhere" "$(grep -c -- --force "$NM/calls" || true)" 0
check "d: drain cleared" "$([ -e "$FM/state/.nm-drain" ] && echo present || echo cleared)" cleared

# (e) install --dry-run: lists the register and the three unregisters, writes nothing.
for s in fm-check-register.sh fm-check-unregister.sh; do printf '#!/bin/sh\necho stub ran >&2; exit 1\n' > "$FM/bin/$s"; chmod +x "$FM/bin/$s"; done
for old in nm-quiet nm-update nm-upgrade; do : > "$FM/state/$old.check.sh"; done
before=$(find "$d" | sort)
out=$("$SRC/install.sh" --dry-run "$FM" 2>&1)
has "e: register" "$out" "would run: env -u FM_STATE_OVERRIDE FM_HOME=$FM $FM/bin/fm-check-register.sh 0-nm-drain"
for old in nm-quiet nm-update nm-upgrade; do has "e: unregister $old" "$out" "would run: env -u FM_STATE_OVERRIDE FM_HOME=$FM $FM/bin/fm-check-unregister.sh $old"; done
check "e: nothing written" "$(find "$d" | sort)" "$before"

# (f) real install with FM_STATE_OVERRIDE exported empty: the stubs fail if it reaches them, so register and all
#     three unregisters must run without it.
for s in fm-check-register.sh fm-check-unregister.sh; do
  cat > "$FM/bin/$s" <<'EOF'
#!/bin/sh
if [ "${FM_STATE_OVERRIDE+set}" ]; then echo "override leaked" >&2; exit 1; fi
echo "${0##*/} $1" >> "$FM_HOME/calls"
EOF
done
out=$(FM_STATE_OVERRIDE='' "$SRC/install.sh" "$FM" 2>&1) && rc=0 || rc=$?
check "f: install exits 0 with FM_STATE_OVERRIDE=''" "$rc" 0
check "f: register and unregisters ran" "$(cat "$FM/calls" 2>/dev/null)" "$(printf 'fm-check-register.sh 0-nm-drain\nfm-check-unregister.sh nm-quiet\nfm-check-unregister.sh nm-update\nfm-check-unregister.sh nm-upgrade')"
check "f: shim written" "$(sed -n 2p "$FM/state/0-nm-drain.check.sh")" "exec $XDG_DATA_HOME/fm-nm-drain/nm-drain.sh check $FM"

[ "$fails" -eq 0 ] && echo "PASS: nm-drain e2e" || { echo "FAIL: $fails check(s)"; exit 1; }
