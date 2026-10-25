#!/usr/bin/env bash
# Fixture proof for the daily scan: two local bare repos (one holding made-up
# details, one clean) plus a temp patterns file. The due run returns at once
# with no output and starts the loop detached; a later run prints the wake
# line with the right counts once and the private report holds them; the run
# after that prints nothing; a clean-only set prints nothing. The raw patterns
# never reach stdout. Also drives install-scan.sh (dry-run plus a real install).
# Usage: owner-guard/tests/scan-e2e.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_NOSYSTEM=1
unset FM_HOME
FM=$d/fm
mkdir -p "$HOME" "$FM/config" "$FM/state" "$FM/data" "$FM/bin"
export FM_MAIN_HOME=$FM
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else printf 'FAIL: %s\n  want text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
missing() { if printf '%s' "$2" | grep -qF -- "$3"; then printf 'FAIL: %s\n  unwanted text: %s\n  got: %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); else echo "ok: $1"; fi; }
seed() { # seed <bare>: an empty main branch ready to receive the push
  git init -q --bare -b main "$1"
}
commit_push() { # commit_push <workdir>: commit everything and push main
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.test add -A
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.test commit -q -m base
  git -C "$1" push -q origin main
}
printf '%s\n' '# fixture-only patterns' '' 'scane2e-fake-surname' 'scanprobe[0-9]{3}@example\.test' >"$FM/config/owner-details-patterns"
seed "$d/hit.git"
seed "$d/clean.git"
git clone -q "$d/hit.git" "$d/hit-push" 2>/dev/null
printf 'reach scane2e-fake-surname here\n' >"$d/hit-push/hit-details.txt"
printf 'contact scanprobe042@example.test\nclean line\n' >"$d/hit-push/hit-more.txt"
commit_push "$d/hit-push"
git clone -q "$d/clean.git" "$d/clean-push" 2>/dev/null
printf 'nothing to see here\n' >"$d/clean-push/readme.md"
commit_push "$d/clean-push"
printf '%s\n' "$d/hit.git" "$d/clean.git" >"$FM/config/owner-guard-repos"

out=$("$SRC/scan-check")
check "due scan returns at once with no output" "$out" ""
check "due scan records the run" "$(test -f "$FM/state/.owner-details-scan.last" && echo yes || echo no)" yes
wait_result() { # poll until the background loop finishes (result file or lock gone)
  local end=$(( $(date +%s) + 5 ))
  while [ ! -f "$FM/state/.owner-details-scan.result" ] && [ ! -d "$FM/state/.owner-details-scan.lock" ] && [ "$(date +%s)" -lt "$end" ]; do
    sleep 0.2
  done
  end=$(( $(date +%s) + 60 ))
  while [ ! -f "$FM/state/.owner-details-scan.result" ] && [ -d "$FM/state/.owner-details-scan.lock" ] && [ "$(date +%s)" -lt "$end" ]; do
    sleep 0.2
  done
}
wait_result
out=$("$SRC/scan-check")
has "later run wakes with the hit repo and count" "$out" "hit (2)"
missing "clean repo is not named" "$out" "clean"
missing "raw patterns stay off stdout" "$out" 'scanprobe[0-9]'
missing "plain pattern stays off stdout" "$out" "scane2e-fake-surname"
rep=$(printf '%s' "$out" | sed -n 's/.*full file:line report: //p')
check "report path sits under the home data dir" "${rep#"$FM"/data/owner-details-scan/}" "$(basename "$rep")"
check "report file exists" "$(test -f "$rep" && echo yes || echo no)" yes
check "report is owner-only" "$(stat -c %a "$rep")" 600
has "report holds the first file:line" "$(cat "$rep")" "hit-details.txt:1"
has "report holds the second file:line" "$(cat "$rep")" "hit-more.txt:1"

out=$("$SRC/scan-check")
check "run after the wake prints nothing" "$out" ""

printf '%s\n' "$d/clean.git" >"$FM/config/owner-guard-repos"
rm -f "$FM/state/.owner-details-scan.last"
out=$("$SRC/scan-check")
check "clean scan returns at once with no output" "$out" ""
wait_result
out=$("$SRC/scan-check")
check "clean-only set prints nothing" "$out" ""

out=$("$SRC/install-scan.sh" --dry-run "$FM")
has "install dry-run prints the plan" "$out" "dry-run"
check "dry-run writes nothing" "$(test -e "$FM/state/owner-details-scan.check.sh" && echo yes || echo no)" no
printf '#!/bin/sh\necho prior scan\n' >"$FM/state/owner-details-scan.check.sh"
cat >"$FM/bin/fm-check-register.sh" <<EOF
#!/usr/bin/env bash
printf 'registered: %s\n' "\$1" >>"$d/registered.log"
EOF
cat >"$FM/bin/fm-check-unregister.sh" <<EOF
#!/usr/bin/env bash
printf 'unregistered: %s\\n' "\$1" >>"$d/unregistered.log"
EOF
chmod +x "$FM/bin/fm-check-register.sh" "$FM/bin/fm-check-unregister.sh"
export XDG_DATA_HOME=$d/data
"$SRC/install-scan.sh" "$FM" >/dev/null
check "install writes the shim" "$(test -x "$FM/state/owner-details-scan.check.sh" && echo yes || echo no)" yes
check "install keeps the previous shim backup" "$(find "$FM/state" -name 'owner-details-scan.check.sh.bak-owner-guard-scan-*' | wc -l)" 1
check "install registers the check" "$(cat "$d/registered.log")" "registered: owner-details-scan"
check "installed check is executable" "$(test -x "$d/data/fm-owner-guard-scan/scan-check" && echo yes || echo no)" yes
"$SRC/uninstall.sh" "$FM" >/dev/null
check "owner uninstall restores previous scan shim" "$(cat "$FM/state/owner-details-scan.check.sh")" "$(printf '#!/bin/sh\necho prior scan')"
check "owner uninstall consumes its backup" "$(find "$FM/state" -name 'owner-details-scan.check.sh.bak-owner-guard-scan-*' | wc -l)" 0
check "owner uninstall removes scan executable" "$(test -e "$d/data/fm-owner-guard-scan/scan-check" && echo yes || echo no)" no
"$SRC/uninstall.sh" "$FM" >/dev/null
check "second owner uninstall is a no-op" "$(cat "$FM/state/owner-details-scan.check.sh")" "$(printf '#!/bin/sh\necho prior scan')"

if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAILED: $fails"; exit 1; fi
