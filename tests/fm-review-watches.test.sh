#!/usr/bin/env bash
# Behavior tests for rendering, registration, and snapshot transitions of the
# colleague-PR watcher checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHES="$ROOT/bin/fm-review-watches.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-watches)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

make_fake_gh() {
  local home=$1
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'api graphql'*) printf '%s\n' "${FAKE_REVIEWED:?}" ;;
  */search/issues\?*) printf '%s\n' "${FAKE_REQUESTS:?}" ;;
  */pulls/*/requested_reviewers*) printf '%s\n' '[{"login":"pedromuller-del"}]' ;;
  *) exit 1 ;;
esac
SH
  chmod 0700 "$home/fakebin/gh-axi"
}

install_home() {
  local home=$1
  "$WATCHES" install "$home" 'Reviews of colleague PRs on artemis' >/dev/null \
    || fail "review watches did not install"
  [ -x "$home/state/reviewed-pr-watch.check.sh" ] \
    || fail "reviewed-pr-watch check was not rendered"
  [ -x "$home/state/review-requests.check.sh" ] \
    || fail "review-requests check was not rendered"
  [ -f "$home/state/reviewed-pr-watch.check-trust" ] \
    || fail "reviewed-pr-watch check was not registered"
  [ -f "$home/state/review-requests.check-trust" ] \
    || fail "review-requests check was not registered"
}

run_reviewed() {
  local home=$1 reviewed=$2
  PATH="$home/fakebin:$PATH" FAKE_REVIEWED="$reviewed" \
    FM_HOME="$home" "$home/state/reviewed-pr-watch.check.sh"
}

run_requests() {
  local home=$1 requests=$2
  PATH="$home/fakebin:$PATH" FAKE_REQUESTS="$requests" \
    FM_HOME="$home" "$home/state/review-requests.check.sh"
}

test_head_change_is_one_self_contained_wake() {
  local home first second
  home=$(make_home head-change)
  make_fake_gh "$home"
  install_home "$home"
  first=$(run_reviewed "$home" "[{'n':42,'h':'oldhead','c':0}]")
  [ -z "$first" ] || fail "first reviewed-pr-watch run was not silent"
  second=$(run_reviewed "$home" "[{'n':42,'h':'newhead','c':0}]")
  [ "$second" = 'colleague PR 42 head moved oldhead->newhead: re-review at the new head' ] \
    || fail "head change wake was wrong: $second"
  [ "$(printf '%s\n' "$second" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "head change emitted more than one line"
  pass "head change emits exactly one self-contained re-review wake"
}

test_entering_reviewed_set_is_silent() {
  local home first second
  home=$(make_home entering-set)
  make_fake_gh "$home"
  install_home "$home"
  first=$(run_reviewed "$home" "[{'n':42,'h':'head42','c':0}]")
  [ -z "$first" ] || fail "entry test first run was not silent"
  second=$(run_reviewed "$home" "[{'n':42,'h':'head42','c':0},{'n':43,'h':'head43','c':0}]")
  [ -z "$second" ] || fail "a PR entering the reviewed set emitted a wake: $second"
  pass "a PR entering the reviewed set stays silent"
}

test_new_review_request_is_self_contained() {
  local home first second
  home=$(make_home review-request)
  make_fake_gh "$home"
  install_home "$home"
  first=$(run_requests "$home" '42')
  [ -z "$first" ] || fail "first review-request run was not silent"
  second=$(run_requests "$home" '42 43')
  [ "$second" = 'review requested on PR 43: start a round' ] \
    || fail "review request wake was wrong: $second"
  pass "new review requests emit a self-contained start-round wake"
}

test_scope_skips_non_review_home() {
  local home out
  home=$(make_home non-review)
  out=$("$WATCHES" install "$home" 'release automation')
  [ "$out" = 'skipped: scope does not own colleague-PR reviews' ] \
    || fail "non-review scope was not skipped: $out"
  [ ! -e "$home/state/reviewed-pr-watch.check.sh" ] \
    || fail "non-review scope rendered reviewed-pr-watch"
  pass "non-review persistent scopes stay unarmed"
}

extract_scope() {
  awk -v wanted="$1" '$1 == "-" && $2 == wanted {
    sub(/^.*; scope: /, "")
    sub(/; projects:.*$/, "")
    print
    exit
  }' "$2"
}

test_secondmates_registry_installs_only_reviews_home() {
  local fixture home id scope out installed=0 refused=0
  fixture="$TMP_ROOT/secondmates.md"
  cp "$ROOT/tests/fixtures/secondmates-b59-scopes.md" "$fixture"
  for id in reviews shipwright shipwright-reviewer artemis-engineer research; do
    scope=$(extract_scope "$id" "$fixture") || fail "missing scope for $id"
    home=$(make_home "registry-$id")
    out=$("$WATCHES" install "$home" "$scope")
    case "$out" in
      installed:*)
        installed=$((installed + 1))
        [ "$id" = reviews ] || fail "unexpected install for $id: $out"
        ;;
      'skipped: scope does not own colleague-PR reviews')
        refused=$((refused + 1))
        [ "$id" = reviews ] && fail "reviews home was refused"
        ;;
      *) fail "unexpected install output for $id: $out" ;;
    esac
  done
  [ "$installed" -eq 1 ] || fail "expected one install, got $installed"
  [ "$refused" -eq 4 ] || fail "expected four refusals, got $refused"
  pass "registry scopes install colleague-PR watches only in reviews"
}

test_head_change_is_one_self_contained_wake
test_entering_reviewed_set_is_silent
test_new_review_request_is_self_contained
test_scope_skips_non_review_home
test_secondmates_registry_installs_only_reviews_home

printf '# all fm-review-watches tests passed\n'
