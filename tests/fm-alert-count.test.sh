#!/usr/bin/env bash
# tests/fm-alert-count.test.sh - executable behavior coverage for live advisory accounting.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_repository() {
  local dir=$1 base_lock=$2 head_lock=$3
  mkdir -p "$dir/repo" "$dir/fakebin"
  git init -q "$dir/repo"
  git -C "$dir/repo" config user.email 'alerts-test@example.invalid'
  git -C "$dir/repo" config user.name 'alerts test'
  git -C "$dir/repo" remote add origin https://github.com/acme/widget.git
  printf '%s\n' "$base_lock" >"$dir/repo/package-lock.json"
  git -C "$dir/repo" add -A
  git -C "$dir/repo" commit -qm base
  git -C "$dir/repo" branch integration
  git -C "$dir/repo" checkout -qb security
  printf '%s\n' "$head_lock" >"$dir/repo/package-lock.json"
  git -C "$dir/repo" commit -qam head --allow-empty
}

write_gh_axi() {
  local file=$1 payload=$2
  cat >"$file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *'/repos/acme/widget/dependabot/alerts?state=open&per_page=100'*)
    printf 'api_response:\n  body: %s\n  truncated: false\n' '$payload'
    ;;
  *) printf 'unexpected gh-axi request: %s\n' "\$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$file"
}

# alert <number> <package> <manifest> <vulnerable range> <first_patched_version JSON> [extra advisory vulnerability JSON]
alert() {
  local number=$1 package=$2 manifest=$3 range=$4 patched=$5 extra=${6:-} vulnerability
  vulnerability=$(printf '{"package":{"ecosystem":"npm","name":"%s"},"vulnerable_version_range":"%s","first_patched_version":%s}' "$package" "$range" "$patched")
  printf '{"number":%s,"dependency":{"package":{"ecosystem":"npm","name":"%s"},"manifest_path":"%s"},"security_vulnerability":%s,"security_advisory":{"vulnerabilities":[%s%s]}}' \
    "$number" "$package" "$manifest" "$vulnerability" "$vulnerability" "${extra:+,$extra}"
}

page() {
  local IFS=,
  printf '[%s]' "$*" | base64 | tr -d '\n'
}

test_verified_remediation_and_exclusions_are_explicit() {
  local dir base_lock head_lock semver_7 first second out rc
  dir=$(fm_test_tmproot fm-alert-count)
  base_lock='{"lockfileVersion":3,"packages":{"node_modules/foo":{"version":"1.0.0"},"node_modules/already":{"version":"2.0.0"},"node_modules/rejected":{"version":"1.0.0"},"node_modules/major":{"version":"1.0.0"},"node_modules/taken":{"version":"1.0.0"},"node_modules/semver":{"version":"5.7.1"},"node_modules/unpatched":{"version":"3.0.0"},"node_modules/aliased":{"version":"1.0.0"},"node_modules/aliased-cjs":{"name":"aliased","version":"1.0.0"},"node_modules/malware":{"version":"1.0.0"},"node_modules/returned":{"version":"1.0.1"}}}'
  head_lock='{"lockfileVersion":3,"packages":{"node_modules/foo":{"version":"1.0.1"},"node_modules/already":{"version":"2.0.0"},"node_modules/rejected":{"version":"1.0.0"},"node_modules/major":{"version":"1.0.0"},"node_modules/taken":{"version":"2.0.0"},"node_modules/semver":{"version":"7.0.0"},"node_modules/unpatched":{"version":"3.0.0"},"node_modules/aliased":{"version":"1.0.1"},"node_modules/aliased-cjs":{"name":"aliased","version":"1.0.0"},"node_modules/malware":{"version":"1.0.0"},"node_modules/returned":{"version":"1.0.0"}}}'
  make_repository "$dir" "$base_lock" "$head_lock"
  semver_7='{"package":{"ecosystem":"npm","name":"semver"},"vulnerable_version_range":">= 7.0.0, < 7.5.2","first_patched_version":{"identifier":"7.5.2"}}'
  first=$(page \
    "$(alert 101 foo package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 102 already package-lock.json '< 2.0.0' '{"identifier":"2.0.0"}')" \
    "$(alert 103 rejected package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 104 major package-lock.json '< 2.0.0' '{"identifier":"2.0.0"}')")
  second=$(page \
    "$(alert 105 taken package-lock.json '< 2.0.0' '{"identifier":"2.0.0"}')" \
    "$(alert 106 semver package-lock.json '>= 2.0.0-alpha, < 5.7.2' '{"identifier":"5.7.2"}' "$semver_7")" \
    "$(alert 107 unpatched package-lock.json '<= 3.0.0' null)" \
    "$(alert 108 aliased package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 109 malware package-lock.json '> 0' null)" \
    "$(alert 111 returned package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')")
  write_gh_axi "$dir/fakebin/gh-axi" "\"$first\\n$second\""
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "complete evidence should succeed: $out"
  printf '%s\n' "$out" | grep -F 'BY PACKAGE' >/dev/null && fail "per-package tally must not be printed: $out"
  printf '%s\n' "$out" | grep -F 'PER-ADVISORY' >/dev/null && fail "duplicate verdict section must not be printed: $out"
  printf '%s\n' "$out" | grep -Fx 'VERIFIED BRANCH REMEDIATION COUNT: 2 (#101 foo (package-lock.json), #105 taken (package-lock.json))' >/dev/null || fail "wrong verified count: $out"
  printf '%s\n' "$out" | grep -F '#108 aliased (package-lock.json): security does not reach a patched version' >/dev/null || fail "an aliased vulnerable copy was ignored: $out"
  printf '%s\n' "$out" | grep -F '#109 malware (package-lock.json): no patched version published' >/dev/null || fail "missing zero-bound no-patch exclusion: $out"
  printf '%s\n' "$out" | grep -F '#111 returned (package-lock.json): security reintroduces a vulnerable copy' >/dev/null || fail "a reintroduced copy was labeled resolved: $out"
  printf '%s\n' "$out" | grep -F '#102 already (package-lock.json): already resolved on integration' >/dev/null || fail "missing already-resolved exclusion: $out"
  printf '%s\n' "$out" | grep -F '#103 rejected (package-lock.json): security does not reach a patched version' >/dev/null || fail "missing unpatched-branch exclusion: $out"
  printf '%s\n' "$out" | grep -F '#104 major (package-lock.json): rejected major, patch requires 2.0.0' >/dev/null || fail "missing rejected-major exclusion: $out"
  printf '%s\n' "$out" | grep -F '#106 semver (package-lock.json): security does not reach a patched version' >/dev/null || fail "a version inside another advisory range was counted: $out"
  printf '%s\n' "$out" | grep -F '#107 unpatched (package-lock.json): no patched version published' >/dev/null || fail "missing no-patch exclusion: $out"
  printf '%s\n' "$out" | grep -F 'close none now' >/dev/null || fail "missing default-branch caveat: $out"
  printf '%s\n' "$out" | grep -Fx 'NOT CHECKED: none' >/dev/null || fail "missing checked-scope statement: $out"
  pass "alert count checks every advisory range across pages and labels each exclusion"
}

test_empty_live_list_is_silent() {
  local dir lock out
  dir=$(fm_test_tmproot fm-alert-count-empty)
  lock='{"lockfileVersion":3,"packages":{}}'
  make_repository "$dir" "$lock" "$lock"
  write_gh_axi "$dir/fakebin/gh-axi" "W10="
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  [ -z "$out" ] || fail "an empty live alert list must be silent: $out"
  pass "alert count is silent when the default branch has no open alerts"
}

test_live_list_failure_is_not_a_count() {
  local dir lock out rc
  dir=$(fm_test_tmproot fm-alert-count-failure)
  lock='{"lockfileVersion":3,"packages":{}}'
  make_repository "$dir" "$lock" "$lock"
  cat >"$dir/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf 'error: insufficient permissions\n' >&2
exit 1
EOF
  chmod +x "$dir/fakebin/gh-axi"
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an inaccessible live list must fail"
  printf '%s\n' "$out" | grep -F 'NOT CHECKED:' >/dev/null || fail "failure claimed a count: $out"
  pass "alert count reports an inaccessible live list as not checked"
}

test_unverifiable_evidence_is_explicitly_not_checked() {
  local dir base_lock head_lock payload out rc
  dir=$(fm_test_tmproot fm-alert-count-unverifiable)
  mkdir -p "$dir/repo/legacy"
  printf '%s\n' '{"lockfileVersion":1,"dependencies":{"old":{"version":"1.0.0"}}}' >"$dir/repo/legacy/package-lock.json"
  base_lock='{"lockfileVersion":3,"packages":{"node_modules/pre":{"version":"1.0.0"},"node_modules/ranged":{"version":"1.0.0"},"node_modules/partial":{"version":"7.9.0"},"node_modules/above":{"version":"8.0.5"}}}'
  head_lock='{"lockfileVersion":3,"packages":{"node_modules/pre":{"version":"1.0.1-beta.1"},"node_modules/ranged":{"version":"1.0.1"},"node_modules/partial":{"version":"8.0.0"},"node_modules/above":{"version":"9.0.0"}}}'
  make_repository "$dir" "$base_lock" "$head_lock"
  payload=$(page \
    "$(alert 201 java-lib pom.xml '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 202 pre package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 203 ranged package-lock.json '^1.0.0' '{"identifier":"1.0.1"}')" \
    "$(alert 204 old legacy/package-lock.json '< 1.0.1' '{"identifier":"1.0.1"}')" \
    "$(alert 205 ranged package-lock.json '<= 1.3' '{"identifier":"1.4.0"}')" \
    '{"number":206,"dependency":{"package":{"ecosystem":"npm","name":"ranged"},"manifest_path":"package-lock.json"}}' \
    "$(alert 207 partial package-lock.json '>= 7.0, < 8.0' '{"identifier":"8.0.0"}')" \
    "$(alert 208 above package-lock.json '> 8.0, < 9.0' '{"identifier":"9.0.0"}')")
  write_gh_axi "$dir/fakebin/gh-axi" "$payload"
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unverifiable evidence must not produce a complete count: $out"
  printf '%s\n' "$out" | grep -F 'VERIFIED BRANCH REMEDIATION COUNT: 0' >/dev/null || fail "unverifiable evidence was counted: $out"
  printf '%s\n' "$out" | grep -F '#201 java-lib (pom.xml): unsupported manifest' >/dev/null || fail "missing unsupported manifest evidence: $out"
  printf '%s\n' "$out" | grep -F '#202 pre (package-lock.json): non-semver or prerelease package-lock version 1.0.1-beta.1' >/dev/null || fail "missing prerelease evidence: $out"
  printf '%s\n' "$out" | grep -F "#203 ranged (package-lock.json): unparseable advisory range '^1.0.0'" >/dev/null || fail "missing unparseable range evidence: $out"
  printf '%s\n' "$out" | grep -F '#204 old (legacy/package-lock.json): package-lock.json has no packages object' >/dev/null || fail "missing packages-object evidence: $out"
  printf '%s\n' "$out" | grep -F "#205 ranged (package-lock.json): unparseable advisory range '<= 1.3'" >/dev/null || fail "an ambiguous partial bound was accepted: $out"
  printf '%s\n' "$out" | grep -F '#206 malformed live alert record' >/dev/null || fail "malformed record lost its identifier: $out"
  printf '%s\n' "$out" | grep -F "#207 partial (package-lock.json): unparseable advisory range '>= 7.0, < 8.0'" >/dev/null || fail "a non-zero partial bound was accepted: $out"
  printf '%s\n' "$out" | grep -F "#208 above (package-lock.json): unparseable advisory range '> 8.0, < 9.0'" >/dev/null || fail "a non-zero partial lower bound was accepted: $out"
  pass "alert count refuses evidence it cannot verify instead of guessing"
}

test_verified_remediation_and_exclusions_are_explicit
test_empty_live_list_is_silent
test_live_list_failure_is_not_a_count
test_unverifiable_evidence_is_explicitly_not_checked
