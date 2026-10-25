#!/usr/bin/env bash
# E2E: fleet-contract-check passes on working callers and names the caller that breaks.
# Fixture fork home with stub callers and a throwaway HOME: nothing real is touched.
set -euo pipefail
unset FM_MAIN_HOME FM_HOME
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
fork=$d/fork
mkdir -p "$fork/bin" "$fork/config" "$d/guard"
printf '{"rules":[]}\n' > "$fork/config/crew-dispatch.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fork/bin/fm-dispatch-resolve.sh"
printf '#!/usr/bin/env bash\necho "checks-lint: PASS: fixture"\n' > "$d/legacy.sh"
printf '#!/usr/bin/env bash\n%s/guard/owner-guard merge-gate "$@" || exit $?\n' "$d" > "$fork/config/merge-gate"
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/guard/owner-guard"
chmod +x "$fork/bin/fm-dispatch-resolve.sh" "$d/legacy.sh" "$d/guard/owner-guard"
export FM_MAIN_HOME=$fork FM_DONE_DONE_BIN=$d/no-such-done-done FM_LEGACY_CHECKS_LINT=$d/legacy.sh
run() { bash "$ROOT/fleet-contract-check/fleet-contract-check" "$@" 2>&1; }

out=$(run) || { echo "FAIL healthy fleet: $out"; exit 1; }
for c in dispatch-resolve owner-guard checks-lint limit-prompt-move; do grep -qx "ok $c" <<<"$out" || { echo "FAIL no 'ok $c': $out"; exit 1; }; done

# A broken caller makes the check exit non-zero and name that caller, and only that one.
chmod -x "$d/guard/owner-guard"
rc=0; out=$(run) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL owner-guard: ' <<<"$out" && grep -qx 'ok dispatch-resolve' <<<"$out" || { echo "FAIL broken owner-guard: rc=$rc $out"; exit 1; }
chmod +x "$d/guard/owner-guard"

printf '#!/usr/bin/env bash\necho "malformed rules file" >&2; exit 2\n' > "$fork/bin/fm-dispatch-resolve.sh"
rc=0; out=$(run dispatch-resolve) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL dispatch-resolve: .*malformed rules file' <<<"$out" || { echo "FAIL broken dispatch-resolve: rc=$rc $out"; exit 1; }

# A candidate package that omits the library the installed mover loads fails the check, without a core library to fall back on.
cp -R "$ROOT" "$d/addons"
sed -i '/account-pool-lib.sh/d' "$d/addons/limit-prompt-move/install.sh"
rc=0; out=$(FM_ADDONS_DIR=$d/addons run limit-prompt-move) || rc=$?
[ "$rc" -eq 1 ] && grep -q '^FAIL limit-prompt-move: ' <<<"$out" || { echo "FAIL package missing the pool lib: rc=$rc $out"; exit 1; }

rc=0; out=$(run no-such-caller) || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL unknown caller: rc=$rc $out"; exit 1; }
echo "PASS fleet-contract-check"
