#!/usr/bin/env bash
# E2E: compare the pinned done-done adapter with the existing lint verdicts on size fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/bin" "$d/home" "$d/data" "$d/fm/state" "$d/fm/data/evidence" "$d/addons/receipts/bin" "$d/main" "$d/cwd/data/evidence"
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d
cat > "$d/bin/done-done" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != lint ] || printf '%s|%s\n' "$2" "$3" >> "$DONE_DONE_ARGS_LOG"
exec npx --yes --quiet --package=done-done-axi@0.6.4 done-done "$@"
EOF
cat > "$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view'*)
    id=${3##*/}; path=src/change.txt; additions=10
    case "$id" in bad) additions=1000 ;; generated) path=packages/accounts/src/pi/generated.ts; additions=1000 ;; routes) path=packages/accounts/src/routes.json; additions=1000 ;; esac
    printf '{"author":{"login":"umeranjum17"},"body":"## Checks\\noutcome: fixture\\nrepro: n/a: no bug\\nproof: no verify skill - bash fixture\\nevidence: not proven: fixture\\n","title":"feat: fixture","files":[{"path":"%s","additions":%s}],"headRefOid":"%s","headRefName":"fixture/%s","baseRefOid":"base"}\n' "$path" "$additions" "$id" "$id"
    ;;
  'pr diff'*)
    id=${3##*/}; path=src/change.txt; n=10
    case "$id" in bad) n=1000 ;; generated) path=packages/accounts/src/pi/generated.ts; n=1000 ;; routes) path=packages/accounts/src/routes.json; n=1000 ;; esac
    printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +1,%s @@\n' "$path" "$path" "$path" "$path" "$n"
    for ((i=1; i<=n; i++)); do printf '+fixture-line-%s\n' "$i"; done
    ;;
  'api repos/owner/repo/pulls/'*)
    echo 1  # one changed file: the PR fits one page, so done-done's own lint measures it
    ;;
  'api repos/owner/repo') : ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
EOF
cat > "$d/addons/receipts/bin/fm-run-receipt.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(cat "$3")" >> "$FM_MAIN_HOME/revocations"
EOF
cat > "$d/legacy.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in */bad) echo 'checks-lint: FAIL: 1000 added non-generated lines'; exit 1 ;; *) echo 'checks-lint: PASS: fixture' ;; esac
EOF
chmod +x "$d/bin/gh" "$d/bin/done-done" "$d/legacy.sh" "$d/addons/receipts/bin/fm-run-receipt.sh"
export PATH="$d/bin:$PATH" FM_DONE_DONE_BIN="$d/bin/done-done" FM_LEGACY_CHECKS_LINT="$d/legacy.sh" FM_ADDONS_DIR="$d/addons" FM_MAIN_HOME="$d/main" DONE_DONE_ARGS_LOG="$d/done-done-args"
failures=0
for id in good generated routes bad; do
  mkdir -p "$d/fm-$id/state" "$d/fm-$id/data"
  [ "$id" != bad ] || printf 'pr=https://github.com/owner/repo/pull/bad\n' > "$d/fm-$id/state/fixture.meta"
  set +e
  legacy=$(FM_HOME="$d/fm-$id" "$d/legacy.sh" "https://github.com/owner/repo/pull/$id" "$d/fm/data/evidence" 2>&1); legacy_rc=$?
  actual=$(FM_HOME="$d/fm-$id" "$ROOT/merge-on-green/checks-lint.sh" "https://github.com/owner/repo/pull/$id" "$d/fm/data/evidence" 2>&1); actual_rc=$?
  set -e
  logged=$(awk -F '\t' -v src="https://github.com/owner/repo/pull/$id" '$2 == src { verdict = $4 } END { print verdict }' "$d/fm-$id/data/checks-gate.log")
  want=pass; [ "$actual_rc" -eq 0 ] || want=fail
  if [ "$legacy_rc" -ne "$actual_rc" ] || [ "${logged/warn/pass}" != "$want" ]; then printf 'FAIL %s: legacy=%s (%s), done-done=%s (%s), log=%s\n' "$id" "$legacy_rc" "$legacy" "$actual_rc" "$actual" "$logged"; failures=$((failures + 1)); else echo "PASS $id: both verdicts $([ "$actual_rc" -eq 0 ] && echo PASS || echo FAIL)"; fi
done
[ "$failures" -eq 0 ] || exit 1
cat > "$d/bin/old-done-done" <<'EOF'
#!/usr/bin/env bash
echo 'unknown command lint' >&2
exit 2
EOF
chmod +x "$d/bin/old-done-done"
set +e
fallback=$(FM_HOME="$d/fm-good" FM_DONE_DONE_BIN="$d/bin/old-done-done" "$ROOT/merge-on-green/checks-lint.sh" 'https://github.com/owner/repo/pull/good' "$d/fm/data/evidence" 2>&1); fallback_rc=$?
set -e
[ "$fallback_rc" -eq 0 ] && [[ "$fallback" == *'checks-lint: PASS: fixture'* ]] || { echo "FAIL fallback: rc=$fallback_rc ($fallback)"; exit 1; }
[ "$(wc -l < "$FM_MAIN_HOME/revocations")" -eq 1 ] && grep -q '^fixture|FAIL|' "$FM_MAIN_HOME/revocations" || { echo 'FAIL FAIL receipt'; exit 1; }
# A caller-relative evidence directory must survive the adapter's temporary cwd.
printf 'evidence fixture\n' > "$d/cwd/data/evidence/result.txt"
printf 'pr=https://github.com/owner/repo/pull/good\n' > "$d/fm-good/state/fixture.meta"
set +e
relative=$(cd "$d/cwd" && FM_HOME="$d/fm-good" "$ROOT/merge-on-green/checks-lint.sh" 'https://github.com/owner/repo/pull/good' data/evidence 2>&1); relative_rc=$?
set -e
[ "$relative_rc" -eq 0 ] && [[ "$relative" == *'checks-lint: PASS: not-proven:'* ]] || { echo "FAIL relative evidence: rc=$relative_rc ($relative)"; exit 1; }
grep -Fq "https://github.com/owner/repo/pull/good|$d/cwd/data/evidence" "$DONE_DONE_ARGS_LOG" || { echo 'FAIL relative evidence was not made absolute'; exit 1; }
grep -q '^fixture|PASS|' "$FM_MAIN_HOME/revocations" || { echo 'FAIL PASS receipt'; exit 1; }
echo 'PASS: pinned done-done, relative evidence, generated exclusions, legacy fallback, and PASS/FAIL receipts'
