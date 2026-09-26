#!/usr/bin/env bash
# tests/fm-backend-t3.test.sh - fake-T3-server tests for the T3 Code GUI-host
# adapter (bin/backends/t3.sh) and the spawn, control, peek, and teardown paths
# that dispatch through it.
#
# The server is tests/t3-fake-server.py, a small HTTP server speaking the
# three orchestration surfaces the adapter drives with the response shapes
# observed on T3 Code v0.0.42; `t3` is a fake CLI that mints bearer tokens the
# server accepts and logs every invocation. Nothing here needs a real T3 Code
# install: the live evidence lives in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found (required by the T3 adapter tests)"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-backend-t3-tests)
FAKE="$TMP_ROOT/fake-t3"
mkdir -p "$FAKE"
: > "$FAKE/tokens"
: > "$FAKE/dispatch.log"
: > "$FAKE/http.log"
python3 "$ROOT/tests/t3-fake-server.py" "$FAKE" &
SERVER_PID=$!
stop_server() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap 'stop_server; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do
  [ -f "$FAKE/origin" ] && break
  sleep 0.1
done
[ -f "$FAKE/origin" ] || { echo "fake T3 server did not start" >&2; exit 1; }
ORIGIN=$(cat "$FAKE/origin")

# A T3 home holding only the model manifest the adapter's default-model
# fallback reads; server discovery is overridden through FM_T3_ORIGIN.
T3HOME="$TMP_ROOT/t3home"
mkdir -p "$T3HOME/userdata"
printf '{"manifest":{"providers":{"claudeAgent":{"defaults":{"chat":"claude-manifest-default"}}}}}\n' \
  > "$T3HOME/userdata/model-manifest.json"

uuid() {
  python3 -c 'import uuid; print(uuid.uuid4())'
}

# --- fake t3 CLI and treehouse -------------------------------------------------

make_t3_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/t3" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_T3_FAKE_LOG:?}"
TOKENS="${FM_T3_FAKE_TOKENS:?}"
{
  printf 't3'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-} ${2:-} ${3:-}" in
  "auth session issue")
    n=$(( $(cat "$TOKENS.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$TOKENS.count"
    tok="tok-$n-$RANDOM$RANDOM$RANDOM"
    printf '%s\n' "$tok" >> "$TOKENS"
    printf '{"sessionId":"sess-%s","token":"%s","expiresAt":"2099-01-01T00:00:00.000Z","scopes":["orchestration:read","orchestration:operate"],"method":"bearer-access-token","subject":"cli-issued-session"}\n' "$n" "$tok"
    exit 0
    ;;
  "auth session revoke")
    exit 0
    ;;
esac
exit 2
SH
  # `treehouse get --lease` creates a real linked worktree of the project the
  # spawn runs it from and prints only its path; `return --force` removes it
  # and keeps <pool>.dispatch-at-return, the commands the fake server had taken
  # by then, so a case can order the endpoint close against the return.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_T3_FAKE_LOG:?}"
{
  printf 'treehouse'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-}" in
  get)
    POOL="${FM_FAKE_TREEHOUSE_POOL:?}"
    mkdir -p "$POOL"
    n=$(( $(ls "$POOL" | wc -l | tr -d ' ') + 1 ))
    if [ -e "$POOL.dirty" ]; then
      # <pool>.dirty hands out a Treehouse-shaped pool slot still holding a
      # crashed worker's uncommitted work and that worker's slot claim.
      printf '{}\n' > "$POOL/treehouse-state.json"
      mkdir -p "$POOL/slot-$n"
      wt="$POOL/slot-$n/$(basename "$PWD")"
      git worktree add --quiet --detach "$wt" >/dev/null 2>&1 || exit 1
      printf 'crashed worker work\n' > "$wt/uncommitted.txt"
      printf 'task=t3crashedz1\nhome=/elsewhere\n' > "$POOL/slot-$n/.fm-slot-owner"
    else
      wt="$POOL/slot-$n"
      git worktree add --quiet --detach "$wt" >/dev/null 2>&1 || exit 1
    fi
    printf '%s\n' "$wt"
    exit 0
    ;;
  return)
    shift
    [ "${1:-}" != --force ] || shift
    cp "${FM_T3_FAKE_DISPATCH:?}" "${FM_FAKE_TREEHOUSE_POOL:?}.dispatch-at-return"
    git worktree remove --force "${1:?}" >/dev/null 2>&1 || rm -rf "${1:?}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/t3" "$fb/treehouse"
  fm_test_fake_no_mistakes "$fb"
  fm_fake_exit0 "$fb" tmux
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

# t3_case <name>: a home, a fakebin, and a T3 log for one case.
t3_case() {
  CASE_DIR="$TMP_ROOT/$1"
  HOME_DIR="$CASE_DIR/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$CASE_DIR/user-home"
  touch "$HOME_DIR/state/.last-watcher-beat"
  T3LOG="$CASE_DIR/t3.log"
  : > "$T3LOG"
  FB=$(make_t3_fakebin "$CASE_DIR")
  : > "$FAKE/dispatch.log"
  rm -f "$FAKE/fail-thread-create" "$FAKE/fail-turn-start" "$FAKE/fail-session-stop" "$FAKE/fail-archive" \
    "$FAKE/fail-runtime-mode-set" "$FAKE/fail-thread-read" "$FAKE/fail-thread-read-once" \
    "$FAKE/on-turn-status" "$FAKE/on-interrupt-status" "$FAKE/no-dispatch-route" \
    "$FAKE/fail-dispatch" "$FAKE/dispatch-thread-not-found" "$FAKE/unlanded-turn-start"
}

# t3_env <cmd...>: the environment every adapter and script call shares.
# FM_T3_ORIGIN_OVERRIDE and T3CODE_HOME_OVERRIDE let one case point the adapter
# at a dead port or an empty T3 home without losing the rest of the wiring.
t3_env() {
  env FM_T3_ORIGIN="${FM_T3_ORIGIN_OVERRIDE:-$ORIGIN}" T3CODE_HOME="${T3CODE_HOME_OVERRIDE:-$T3HOME}" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    HOME="$CASE_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    PATH="$FB:$PATH" FM_T3_FAKE_LOG="$T3LOG" FM_T3_FAKE_TOKENS="$FAKE/tokens" \
    FM_T3_FAKE_DISPATCH="$FAKE/dispatch.log" FM_FAKE_TREEHOUSE_POOL="$CASE_DIR/pool" "$@"
}

# t3_call <fn> [args...]: run one adapter function through the dispatcher.
t3_call() {
  # shellcheck disable=SC2016  # $0 and $@ are the child shell's own positionals.
  t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3 || exit 97; "$@"' "$ROOT" "$@"
}

seed_project() {  # <id> <workspace-root> [title] [repository-key] [created-at] [identity-remote]
  jq --arg id "$1" --arg root "$2" --arg t "${3:-proj}" --arg key "${4:-}" \
    --arg at "${5:-2026-01-01T00:00:00.000Z}" --arg remote "${6:-origin}" '
    .projects[$id] = ({id:$id,title:$t,workspaceRoot:$root,defaultModelSelection:null,createdAt:$at}
      + (if $key == "" then {} else {repositoryIdentity:{canonicalKey:$key,
          locator:{source:"git-remote",remoteName:$remote,remoteUrl:("https://" + $key)}}} end))' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

seed_thread() {  # <id> <project-id> <session-status|none> [worktree]
  jq --arg id "$1" --arg pid "$2" --arg st "$3" --arg wt "${4:-}" '
    .threads[$id] = {
      id:$id, projectId:$pid, title:"fm-seeded", modelSelection:{instanceId:"claudeAgent",model:"m"},
      runtimeMode:"full-access", interactionMode:"default", branch:null,
      worktreePath:(if $wt == "" then null else $wt end),
      messages:[], activities:[], latestTurn:null, archivedAt:null, deletedAt:null,
      session:(if $st == "none" then null else {
        threadId:$id, status:$st, providerName:"claudeAgent", providerInstanceId:"claudeAgent",
        runtimeMode:"full-access",
        activeTurnId:(if $st == "running" or $st == "starting" then "turn-1" else null end),
        lastError:null} end)}' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

set_thread() {  # <id> <jq-filter-on-thread>
  jq --arg id "$1" ".threads[\$id] |= ($2)" "$FAKE/state.json" > "$FAKE/state.json.new" \
    && mv "$FAKE/state.json.new" "$FAKE/state.json"
}

thread_field() {  # <id> <jq-expr>
  jq -r --arg id "$1" ".threads[\$id] | $2" "$FAKE/state.json"
}

dispatch_types() {
  jq -r '.type' "$FAKE/dispatch.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

dispatch_last() {  # <type> <jq-expr>
  jq -r --arg t "$1" "select(.type == \$t) | $2" "$FAKE/dispatch.log" | tail -n 1
}

assert_no_token_leak() {  # <label> <file-or-text>...
  local label=$1 tok what
  shift
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    for what in "$@"; do
      if [ -f "$what" ]; then
        ! grep -qF -- "$tok" "$what" || fail "$label: bearer token leaked into $what"
      else
        case "$what" in *"$tok"*) fail "$label: bearer token leaked into captured output" ;; esac
      fi
    done
  done < "$FAKE/tokens"
}

# --- origin and session ---------------------------------------------------------

test_origin_requires_running_server() {
  local out status
  t3_case origin
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  out=$(env FM_T3_ORIGIN= T3CODE_HOME="$CASE_DIR/no-t3-home" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3; fm_backend_t3_origin' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "origin resolution should fail without server-runtime.json"
  assert_contains "$out" "t3 serve" "the origin refusal should tell the operator how to start the server"
  mkdir -p "$CASE_DIR/t3-home-2/userdata"
  printf '{"version":1,"pid":1,"port":3773,"origin":"%s","serviceManaged":true}\n' "$ORIGIN" \
    > "$CASE_DIR/t3-home-2/userdata/server-runtime.json"
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  out=$(env FM_T3_ORIGIN= T3CODE_HOME="$CASE_DIR/t3-home-2" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3; fm_backend_t3_origin' "$ROOT")
  [ "$out" = "$ORIGIN" ] || fail "origin should come from server-runtime.json, got '$out'"
  pass "fm_backend_t3_origin: reads the running server's origin and refuses loudly without one"
}

test_session_is_minted_once_cached_privately_and_refreshed_on_401() {
  local out hdr issues mode
  t3_case session
  seed_project "$(uuid)" "$CASE_DIR/somewhere"
  out=$(t3_call fm_backend_t3_shell) || fail "shell read should succeed with a freshly minted session"
  printf '%s' "$out" | jq -e '.projects | length >= 1' >/dev/null || fail "shell read returned no projects"
  hdr="$HOME_DIR/state/.t3-session.header"
  assert_present "$hdr" "the bearer header file should be cached under state/"
  assert_present "$HOME_DIR/state/.t3-session" "the session record should be cached under state/"
  mode=$(stat -c %a "$hdr" 2>/dev/null || stat -f %Lp "$hdr")
  [ "$mode" = 600 ] || fail "the header file must be mode 0600, got $mode"
  assert_contains "$(cat "$T3LOG")" $'t3\x1f''auth'$'\x1f''session'$'\x1f''issue'$'\x1f''--ttl'$'\x1f''1h'$'\x1f''--label'$'\x1f''firstmate:'"$HOME_DIR"$'\x1f''--json' \
    "the session should be minted with the default TTL, a home label, and --json"
  t3_call fm_backend_t3_shell >/dev/null || fail "second shell read failed"
  issues=$(grep -c $'auth\x1fsession\x1fissue' "$T3LOG")
  [ "$issues" -eq 1 ] || fail "a valid cached session should be reused, but $issues were minted"
  assert_no_token_leak "session cache" "$T3LOG" "$out" "$HOME_DIR/state/.t3-session"
  # An invalidated token (server-side revocation, restart) is re-minted once
  # and the stale session revoked.
  printf 'Authorization: Bearer stale-token\n' > "$hdr"
  t3_call fm_backend_t3_shell >/dev/null || fail "a 401 should re-mint the session and retry"
  issues=$(grep -c $'auth\x1fsession\x1fissue' "$T3LOG")
  [ "$issues" -eq 2 ] || fail "a 401 should mint exactly one replacement, got $issues mints"
  assert_contains "$(cat "$T3LOG")" $'t3\x1f''auth'$'\x1f''session'$'\x1f''revoke'$'\x1f''sess-1' \
    "the replaced session should be revoked"
  t3_call fm_backend_t3_session_release || fail "release should succeed"
  assert_absent "$hdr" "release should remove the header file"
  assert_contains "$(cat "$T3LOG")" $'revoke\x1f''sess-2' "release should revoke the live session"
  pass "fm_backend_t3 session: minted once, cached 0600 and never logged, re-minted on 401, revoked on release"
}

# --- projects, models, threads ------------------------------------------------------

test_project_ensure_matches_existing_root_or_creates() {
  local pid out root
  t3_case project
  root="$CASE_DIR/repo-a"
  mkdir -p "$root"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$root" && pwd -P)"
  out=$(t3_call fm_backend_t3_project_ensure "$root") || fail "project_ensure failed for a registered root"
  [ "$out" = "$pid" ] || fail "project_ensure should return the registered project id, got '$out'"
  [ -z "$(dispatch_types)" ] || fail "a registered root must not dispatch project.create"
  mkdir -p "$CASE_DIR/repo-b"
  out=$(t3_call fm_backend_t3_project_ensure "$CASE_DIR/repo-b") || fail "project_ensure failed for a new root"
  [ "$(dispatch_types)" = "project.create" ] || fail "an unregistered root should dispatch exactly project.create, got '$(dispatch_types)'"
  [ "$(dispatch_last project.create .projectId)" = "$out" ] || fail "project_ensure should return the id it created"
  [ "$(dispatch_last project.create .workspaceRoot)" = "$(cd "$CASE_DIR/repo-b" && pwd -P)" ] \
    || fail "project.create should carry the physical workspace root"
  [ "$(dispatch_last project.create .title)" = repo-b ] || fail "project.create should title the project by its basename"
  pass "fm_backend_t3_project_ensure: reuses the project owning the root and registers one only when none exists"
}

test_project_find_matches_the_repository_by_origin() {
  local clone captain other out err id created
  t3_case project-origin
  for out in 'git@github.com:FM-T3-Test/Origin-Repo.git' 'ssh://git@github.com/fm-t3-test/origin-repo' \
    'https://github.com/fm-t3-test/origin-repo/' 'https://user@GitHub.com:443/fm-t3-test/origin-repo.git'; do
    [ "$(t3_call fm_backend_t3_repo_key "$out")" = github.com/fm-t3-test/origin-repo ] \
      || fail "'$out' should normalize to T3's repository key, got '$(t3_call fm_backend_t3_repo_key "$out")'"
  done
  clone="$CASE_DIR/projects/origin-repo"
  fm_git_init_commit "$clone"
  git -C "$clone" remote add origin git@github.com:FM-T3-Test/Origin-Repo.git

  # A project rooted at the clone itself wins over one that only shares the repository.
  seed_project "$(uuid)" /nonexistent/captain/origin-repo origin-repo github.com/fm-t3-test/origin-repo
  id=$(uuid)
  seed_project "$id" "$(cd "$clone" && pwd -P)" firstmate-clone
  out=$(t3_call fm_backend_t3_project_find "$clone" 2>"$CASE_DIR/err") || fail "project_find failed for a registered root"
  [ "$out" = "$id" ] || fail "the project rooted at the clone should win, got '$out'"
  assert_not_contains "$(cat "$CASE_DIR/err")" "notice:" "a path match should not announce an origin match"
  pass "fm_backend_t3_project_find: the project rooted at the clone wins"

  # Without it, the captain's own project for the repository is used, and said so.
  jq --arg id "$id" 'del(.projects[$id])' "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
  captain=$(jq -r '.projects[] | select(.workspaceRoot == "/nonexistent/captain/origin-repo") | .id' "$FAKE/state.json")
  out=$(t3_call fm_backend_t3_project_ensure "$clone" 2>"$CASE_DIR/err") || fail "project_ensure failed for an origin match"
  [ "$out" = "$captain" ] || fail "the captain's project for the same repository should be used, got '$out'"
  [ -z "$(dispatch_types)" ] || fail "an origin match must register no second project, got '$(dispatch_types)'"
  err=$(cat "$CASE_DIR/err")
  assert_contains "$err" "using project 'origin-repo' at /nonexistent/captain/origin-repo" "the origin match should name the chosen project and root"

  # A project T3 reports no identity for is matched through its root's own origin.
  jq --arg id "$captain" 'del(.projects[$id])' "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
  other="$CASE_DIR/captain-checkout"
  fm_git_init_commit "$other"
  git -C "$other" remote add origin ssh://git@github.com/fm-t3-test/origin-repo
  id=$(uuid)
  seed_project "$id" "$(cd "$other" && pwd -P)" checkout
  out=$(t3_call fm_backend_t3_project_find "$clone" 2>/dev/null) || fail "project_find failed for a root-origin match"
  [ "$out" = "$id" ] || fail "a project without repositoryIdentity should match through its root's origin, got '$out'"
  pass "fm_backend_t3_project_find: otherwise the repository's project, by T3's normalized origin, announced on stderr"

  # Several matches: the one titled after the repository, then the oldest.
  seed_project "$(uuid)" /nonexistent/a origin-repo github.com/fm-t3-test/origin-repo 2026-05-01T00:00:00.000Z
  created=$(uuid)
  seed_project "$created" /nonexistent/b Origin-Repo github.com/fm-t3-test/origin-repo 2026-03-01T00:00:00.000Z
  seed_project "$(uuid)" /nonexistent/c elsewhere github.com/fm-t3-test/origin-repo 2020-01-01T00:00:00.000Z
  out=$(t3_call fm_backend_t3_project_find "$clone" 2>/dev/null) || fail "project_find failed for several matches"
  [ "$out" = "$created" ] || fail "several matches should resolve to the oldest project titled after the repository, got '$out'"
  pass "fm_backend_t3_project_find: several matches resolve to the oldest project titled after the repository"

  # No project for the repository: nothing is found and ensure registers the clone.
  git -C "$clone" remote set-url origin https://github.com/fm-t3-test/unregistered-repo
  out=$(t3_call fm_backend_t3_project_find "$clone" 2>/dev/null) || fail "project_find failed with no match"
  [ -z "$out" ] || fail "no project for the repository should find nothing, got '$out'"
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_project_ensure "$clone" 2>/dev/null) || fail "project_ensure failed with no match"
  [ "$(dispatch_types)" = "project.create" ] || fail "no match should register exactly one project, got '$(dispatch_types)'"
  [ "$(dispatch_last project.create .workspaceRoot)" = "$(cd "$clone" && pwd -P)" ] || fail "the new project should be rooted at the clone"
  pass "fm_backend_t3_project_ensure: registers a project only when T3 has none for the repository"
}

test_project_find_reads_origin_not_t3s_upstream_identity() {
  local clone captain decoy id out
  t3_case project-upstream
  clone="$CASE_DIR/projects/fork-app"
  fm_git_init_commit "$clone"
  git -C "$clone" remote add origin git@github.com:fm-t3-test/fork-app.git
  # The captain's checkout shares the clone's origin but also has an upstream,
  # which T3 v0.0.42 builds repositoryIdentity from.
  captain="$CASE_DIR/captain-fork-app"
  fm_git_init_commit "$captain"
  git -C "$captain" remote add origin https://github.com/fm-t3-test/fork-app
  git -C "$captain" remote add upstream https://github.com/fm-t3-oss/fork-app
  id=$(uuid)
  seed_project "$id" "$(cd "$captain" && pwd -P)" checkout github.com/fm-t3-oss/fork-app \
    2026-06-01T00:00:00.000Z upstream
  # Older and titled after the repository, so either would win if it matched:
  # a readable root whose origin differs although T3's key equals the clone's,
  # and an unreadable root whose identity names only an upstream remote.
  decoy="$CASE_DIR/decoy-app"
  fm_git_init_commit "$decoy"
  git -C "$decoy" remote add origin https://github.com/fm-t3-test/other-app
  seed_project "$(uuid)" "$(cd "$decoy" && pwd -P)" fork-app github.com/fm-t3-test/fork-app \
    2020-01-01T00:00:00.000Z origin
  seed_project "$(uuid)" /nonexistent/upstream-only fork-app github.com/fm-t3-test/fork-app \
    2019-01-01T00:00:00.000Z upstream
  out=$(t3_call fm_backend_t3_project_find "$clone" 2>/dev/null) || fail "project_find failed"
  [ "$out" = "$id" ] || fail "the project whose root has the clone's origin should match despite an upstream identity, got '$out'"
  pass "fm_backend_t3_project_find: matches the candidate's origin, never T3's upstream-derived identity"
}

test_model_selection_precedence_and_harness_gate() {
  local pid out status
  t3_case model
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  out=$(t3_call fm_backend_t3_model_selection claude claude-x high "$pid") || fail "explicit model failed"
  [ "$(printf '%s' "$out" | jq -c .)" = '{"instanceId":"claudeAgent","model":"claude-x","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "explicit model and effort should shape the selection, got '$out'"
  out=$(t3_call fm_backend_t3_model_selection claude "" "" "$pid") || fail "manifest default failed"
  [ "$(printf '%s' "$out" | jq -r .model)" = claude-manifest-default ] || fail "no model and no project default should fall back to the manifest default, got '$out'"
  jq --arg id "$pid" '.projects[$id].defaultModelSelection = {instanceId:"claudeAgent",model:"claude-project-default"}' \
    "$FAKE/state.json" > "$FAKE/state.json.new" && mv "$FAKE/state.json.new" "$FAKE/state.json"
  out=$(t3_call fm_backend_t3_model_selection claude "" "" "$pid") || fail "project default failed"
  [ "$(printf '%s' "$out" | jq -r .model)" = claude-project-default ] || fail "the project default should beat the manifest default, got '$out'"
  out=$(t3_call fm_backend_t3_model_selection codex "" "" "$pid" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-claude harness must be refused"
  assert_contains "$out" "claude harness family only" "the harness refusal should name the supported family"
  out=$(T3CODE_HOME_OVERRIDE="$CASE_DIR/empty-t3-home" t3_call fm_backend_t3_model_selection claude "" "" "" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "no model from any source must be refused"
  assert_contains "$out" "--model" "the no-model refusal should name the flag that supplies one"
  pass "fm_backend_t3_model_selection: explicit, then project default, then manifest default; claude only"
}

test_thread_create_binds_worktree_and_reads_back() {
  local pid tid wt out status
  t3_case thread-create
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  wt="$CASE_DIR/wt"
  mkdir -p "$wt"
  tid=$(t3_call fm_backend_t3_thread_create "$pid" fm-task1 "$wt" "" '{"instanceId":"claudeAgent","model":"m"}' full-access) \
    || fail "thread_create failed"
  [ "$(dispatch_types)" = "thread.create" ] || fail "thread_create should dispatch exactly thread.create, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.create .threadId)" = "$tid" ] || fail "thread_create should return the id it minted"
  [ "$(dispatch_last thread.create .worktreePath)" = "$wt" ] || fail "thread.create should bind worktreePath"
  [ "$(dispatch_last thread.create .branch)" = null ] || fail "an empty branch should be sent as null"
  [ "$(dispatch_last thread.create .title)" = fm-task1 ] || fail "thread.create should carry the task label as title"
  [ "$(dispatch_last thread.create .runtimeMode)" = full-access ] || fail "thread.create should carry the runtime mode"
  [ "$(thread_field "$tid" .worktreePath)" = "$wt" ] || fail "the server should hold the worktree binding"
  [ "$(t3_call fm_backend_t3_current_path "$tid")" = "$wt" ] || fail "current_path should read worktreePath back"
  : > "$FAKE/fail-thread-create"
  out=$(t3_call fm_backend_t3_thread_create "$pid" fm-task2 "$wt" main '{"instanceId":"claudeAgent","model":"m"}' auto 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-create"
  [ "$status" -ne 0 ] || fail "a refused thread.create must fail the create"
  assert_contains "$out" "thread.create failed" "the create failure should name the dispatch"
  pass "fm_backend_t3_thread_create: mints the id, binds the worktree, proves it by re-read, fails closed on a refused dispatch"
}

test_runtime_mode_maps_permission_flag() {
  t3_case runtime-mode
  [ "$(t3_call fm_backend_t3_runtime_mode '--permission-mode auto')" = auto ] || fail "auto should map to T3 runtimeMode auto"
  [ "$(t3_call fm_backend_t3_runtime_mode '--dangerously-skip-permissions')" = full-access ] || fail "bypass should map to full-access"
  pass "fm_backend_t3_runtime_mode: config/claude-permission-mode maps onto T3's runtime modes"
}

# --- state reads ----------------------------------------------------------------------

test_state_reads_map_session_status() {
  local pid tid st expect_busy expect_agent expect_composer out
  t3_case state-reads
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  while IFS=' ' read -r st expect_busy expect_agent expect_composer; do
    tid=$(uuid)
    seed_thread "$tid" "$pid" "$st"
    out=$(t3_call fm_backend_t3_session_status "$tid")
    [ "$out" = "$st" ] || fail "session_status for $st read '$out'"
    out=$(t3_call fm_backend_t3_busy_state "$tid")
    [ "$out" = "$expect_busy" ] || fail "busy_state for session $st should be $expect_busy, got '$out'"
    out=$(t3_call fm_backend_t3_agent_state "$tid")
    [ "$out" = "$expect_agent" ] || fail "agent_state for session $st should be $expect_agent, got '$out'"
    out=$(t3_call fm_backend_t3_composer_state "$tid")
    [ "$out" = "$expect_composer" ] || fail "composer_state for session $st should be $expect_composer, got '$out'"
    t3_call fm_backend_t3_target_exists "$tid" || fail "a readable thread ($st) must exist"
  done <<'EOF'
starting busy alive unknown
running busy alive unknown
ready idle alive empty
stopped idle alive empty
none idle alive empty
error unknown dead unknown
EOF
  # A gone endpoint: the server answers 404 for archived and deleted threads alike.
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  [ "$(t3_call fm_backend_t3_session_status "$tid")" = missing ] || fail "an archived thread should read missing"
  [ "$(t3_call fm_backend_t3_agent_state "$tid")" = missing ] || fail "an archived thread's agent state should be missing"
  [ "$(t3_call fm_backend_t3_busy_state "$tid")" = unknown ] || fail "an archived thread's busy state should be unknown"
  t3_call fm_backend_t3_target_exists "$tid" && fail "an archived thread must not exist"
  [ "$(t3_call fm_backend_t3_agent_state "$(uuid)")" = missing ] || fail "an unknown thread id should read missing"
  # An unreachable server is unreadable, never death.
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_agent_state "$tid")
  [ "$out" = unreadable ] || fail "an unreachable server should read unreadable, got '$out'"
  pass "fm_backend_t3 state reads: session status maps onto busy, agent, and composer verdicts; 404 is gone, an unreachable server is unreadable"
}

test_capture_renders_transcript_tail_with_state_footer() {
  local pid tid out
  t3_case capture
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  set_thread "$tid" '.messages = [
      {id:"m1",role:"user",text:"first ask",createdAt:"2026-01-01T00:00:01.000Z"},
      {id:"m2",role:"assistant",text:"done",createdAt:"2026-01-01T00:00:03.000Z"}]
    | .activities = [{id:"a1",tone:"tool",kind:"tool.started",summary:"Command run started",createdAt:"2026-01-01T00:00:02.000Z"},
                     {id:"a2",tone:"info",kind:"checkpoint.captured",summary:"Checkpoint captured",createdAt:"2026-01-01T00:00:04.000Z"}]
    | .latestTurn = {turnId:"t1",state:"completed"}'
  out=$(t3_call fm_backend_t3_capture "$tid" 40) || fail "capture failed"
  [ "$out" = $'user: first ask\n[tool] Command run started\nassistant: done\n'"[t3 thread=$tid session=ready turn=completed]" ] \
    || fail "capture should render messages and tool activity in time order with a state footer, got:"$'\n'"$out"
  out=$(t3_call fm_backend_t3_capture "$tid" 2) || fail "bounded capture failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ] || fail "capture should honor the line bound, got:"$'\n'"$out"
  assert_contains "$out" "[t3 thread=" "the footer should survive a bounded tail"
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  t3_call fm_backend_t3_capture "$tid" 5 >/dev/null 2>&1 && fail "capture of a gone thread must fail"
  pass "fm_backend_t3_capture: renders the transcript tail in time order with a live-state footer and fails on a gone thread"
}

# --- sends ------------------------------------------------------------------------------

test_send_text_submit_is_a_turn_start() {
  local pid tid out
  t3_case send
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "hello worker" 3 0.01 0.01)
  [ "$out" = empty ] || fail "an accepted turn.start should report empty (delivered), got '$out'"
  [ "$(dispatch_types)" = "thread.turn.start" ] || fail "send should dispatch exactly thread.turn.start, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.turn.start .message.text)" = "hello worker" ] || fail "the message text should be sent verbatim"
  [ "$(dispatch_last thread.turn.start .message.role)" = user ] || fail "the message should be a user message"
  [ "$(dispatch_last thread.turn.start .runtimeMode)" = full-access ] || fail "a full-access thread's turn should carry full-access"
  set_thread "$tid" '.runtimeMode = "auto"'
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "steer an auto thread" 3 0.01 0.01)
  [ "$out" = empty ] || fail "a send to an auto thread should deliver, got '$out'"
  [ "$(dispatch_last thread.turn.start .runtimeMode)" = auto ] || fail "a steer must carry the thread's own auto runtime mode"
  # A busy thread still accepts a queued message (T3 delivers it mid-turn).
  set_thread "$tid" '.session.status = "running" | .session.activeTurnId = "turn-9"'
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "queued while busy" 3 0.01 0.01)
  [ "$out" = empty ] || fail "a busy thread should still accept a queued turn.start, got '$out'"
  # A gone thread is not retried.
  set_thread "$tid" '.archivedAt = "2026-01-01T00:00:00.000Z"'
  : > "$FAKE/http.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "lost" 3 0.01 0.01)
  [ "$out" = send-failed ] || fail "a gone thread should report send-failed, got '$out'"
  [ "$(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log")" = 1 ] \
    || fail "a 404 must not be retried, saw $(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log") posts"
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_send_text_submit "$tid" "unreachable" 2 0.01 0.01)
  [ "$out" = send-failed ] || fail "an unreachable server should report send-failed, got '$out'"
  # An accepted turn whose landing cannot be read back is delivered, unconfirmed.
  set_thread "$tid" '.archivedAt = null'
  : > "$FAKE/fail-thread-read"
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "accepted, unread" 3 0.01 0.01)
  rm -f "$FAKE/fail-thread-read"
  [ "$out" = pending ] || fail "an accepted turn whose landing re-read fails should report pending, got '$out'"
  [ "$(dispatch_types)" = "thread.turn.start" ] || fail "an accepted turn must not be resent, got '$(dispatch_types)'"
  : > "$FAKE/unlanded-turn-start"
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "accepted, not yet visible" 3 0.01 0.01)
  rm -f "$FAKE/unlanded-turn-start"
  [ "$out" = pending ] || fail "an accepted turn the readable thread does not show yet should report pending, got '$out'"
  [ "$(dispatch_types)" = "thread.turn.start" ] || fail "an accepted, not yet visible turn must not be resent, got '$(dispatch_types)'"
  pass "fm_backend_t3_send_text_submit: a 2xx turn.start is delivery, a busy thread queues, a gone thread is not retried, an unread or not yet visible landing is pending"
}

test_send_key_maps_interrupt_and_enter() {
  local pid tid out status
  t3_case keys
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" running
  t3_call fm_backend_t3_send_key "$tid" Escape || fail "Escape should dispatch an interrupt"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "Escape should dispatch thread.turn.interrupt, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the fake should model T3 stopping the session after an interrupt"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_send_key "$tid" C-c || fail "C-c should dispatch an interrupt"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "C-c should dispatch thread.turn.interrupt"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_send_key "$tid" Enter || fail "Enter should be an accepted no-op"
  [ -z "$(dispatch_types)" ] || fail "Enter must dispatch nothing"
  out=$(t3_call fm_backend_t3_send_key "$tid" C-u 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a composer clear must be refused on a thread"
  assert_contains "$out" "unsupported T3 key" "the key refusal should name the key"
  pass "fm_backend_t3_send_key: Escape and C-c interrupt the turn, Enter is a no-op, other keys refuse"
}

# --- lifecycle --------------------------------------------------------------------------

test_session_stop_and_kill_order_and_proof() {
  local pid tid out status
  t3_case lifecycle
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  t3_call fm_backend_t3_session_stop "$tid" 3 || fail "session_stop should succeed on a ready session"
  [ "$(dispatch_types)" = "thread.session.stop" ] || fail "session_stop should dispatch thread.session.stop"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the session should read stopped"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_session_stop "$tid" 3 || fail "session_stop on a stopped session should be idempotent"
  [ -z "$(dispatch_types)" ] || fail "an already-stopped session must not be stopped again"
  # A stop the server ignores is reported, never assumed.
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/fail-session-stop"
  out=$(t3_call fm_backend_t3_session_stop "$tid" 1 2>&1)
  status=$?
  rm -f "$FAKE/fail-session-stop"
  [ "$status" -ne 0 ] || fail "a session still live after the stop wait must fail"
  assert_contains "$out" "still reports a live session" "the stop failure should say the session stayed live"
  # kill: stop first, then archive, then prove the 404.
  set_thread "$tid" '.session.status = "running" | .session.activeTurnId = "turn-2"'
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_kill "$tid" || fail "kill should succeed on a live thread"
  [ "$(dispatch_types)" = "thread.session.stop thread.archive" ] || fail "kill must stop the session before archiving, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "kill should archive the thread"
  : > "$FAKE/dispatch.log"
  t3_call fm_backend_t3_kill "$tid" || fail "kill of an already-gone thread should succeed silently"
  [ -z "$(dispatch_types)" ] || fail "an already-gone thread must dispatch nothing"
  # An archive the server accepted but did not apply is refused by the re-read.
  tid=$(uuid)
  seed_thread "$tid" "$pid" stopped
  : > "$FAKE/fail-archive"
  : > "$FAKE/dispatch.log"
  out=$(t3_call fm_backend_t3_kill "$tid" 2>&1)
  status=$?
  rm -f "$FAKE/fail-archive"
  [ "$status" -ne 0 ] || fail "a kill whose archive did not take must fail"
  assert_contains "$out" "still readable after thread.archive" "the refused close should name the re-read"
  [ "$(dispatch_types)" = "thread.archive" ] || fail "a stopped session needs no stop before archive, got '$(dispatch_types)'"
  out=$(FM_T3_ORIGIN_OVERRIDE=http://127.0.0.1:9 FM_T3_HTTP_TIMEOUT=2 t3_call fm_backend_t3_kill "$tid" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a kill against an unreachable server must not report success"
  pass "fm_backend_t3_kill: stop, then archive, then a 404 re-read; unproven closes refuse"
}

# --- version pin ------------------------------------------------------------------------

test_dispatch_gate_pins_the_verified_server() {
  local proj pid id out status tid meta wt holder
  t3_case dispatch-gate
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"

  # Supported: the probe is one empty command the server refuses, never one it accepts.
  : > "$FAKE/http.log"
  out=$(t3_call fm_backend_t3_dispatch_check 2>&1)
  status=$?
  expect_code 0 "$status" "a server exposing the dispatch endpoint should pass the gate"$'\n'"$out"
  assert_contains "$(cat "$FAKE/http.log")" "POST /api/orchestration/dispatch 400" "the probe should be the empty command the server refuses"
  [ -z "$(dispatch_types)" ] || fail "the probe must never be an accepted command, got '$(dispatch_types)'"
  assert_no_token_leak "gate" "$out"
  pass "fm_backend_t3_dispatch_check: a server exposing POST /api/orchestration/dispatch passes without dispatching a command"

  # Missing: the surface T3's Orchestrator V2 leaves behind.
  : > "$FAKE/no-dispatch-route"
  out=$(t3_call fm_backend_t3_dispatch_check 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a server without the dispatch endpoint must refuse"
  assert_contains "$out" "does not expose POST /api/orchestration/dispatch" "the refusal should name the missing endpoint"
  assert_contains "$out" "verified against T3 Code v0.0.42" "the refusal should name the verified version"
  assert_contains "$out" "https://github.com/pingdotgg/t3code/pull/2829" "the refusal should point at the V2 removal"
  pass "fm_backend_t3_dispatch_check: a server without the dispatch endpoint is refused, naming the verified version and the V2 removal"

  # A typed send names the removed endpoint too, and does not retry the 404.
  tid=$(uuid)
  seed_thread "$tid" "$pid" ready
  : > "$FAKE/http.log"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "steer a V2 server" 3 0.01 0.01 2>"$CASE_DIR/send.err")
  [ "$out" = send-failed ] || fail "a send to a server without the dispatch endpoint should report send-failed, got '$out'"
  assert_contains "$(cat "$CASE_DIR/send.err")" "does not expose POST /api/orchestration/dispatch" "a failed send should name the removed endpoint"
  [ "$(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log")" = 2 ] \
    || fail "a send's 404 is not retried: expected its turn.start and one capability probe, saw $(grep -c 'POST /api/orchestration/dispatch' "$FAKE/http.log") posts"
  pass "fm_backend_t3_send_text_submit: a server without the dispatch endpoint reports send-failed and names the removed endpoint"
  rm -f "$FAKE/no-dispatch-route"

  # A dispatch 404 naming a resource is not the removed endpoint.
  : > "$FAKE/dispatch-thread-not-found"
  out=$(t3_call fm_backend_t3_send_key "$tid" Escape 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an interrupt the server answers 404 must fail"
  assert_contains "$out" "HTTP 404 (thread_not_found)" "the failure should carry the server's reason"
  assert_not_contains "$out" "does not expose POST /api/orchestration/dispatch" "a resource 404 must not claim the endpoint is gone"
  out=$(t3_call fm_backend_t3_send_text_submit "$tid" "a thread the server does not know" 3 0.01 0.01 2>"$CASE_DIR/send.err")
  [ "$out" = send-failed ] || fail "a send the server answers 404 thread_not_found should report send-failed, got '$out'"
  assert_not_contains "$(cat "$CASE_DIR/send.err")" "does not expose POST /api/orchestration/dispatch" "a resource 404 on a send must not claim the endpoint is gone"
  rm -f "$FAKE/dispatch-thread-not-found"
  pass "fm_backend_t3_dispatch: a 404 naming a resource reports its reason and never the removed endpoint"

  # Server and auth failures are reported as such, not as an unverified server.
  : > "$FAKE/fail-dispatch"
  out=$(t3_call fm_backend_t3_dispatch_check 2>&1)
  status=$?
  rm -f "$FAKE/fail-dispatch"
  [ "$status" -ne 0 ] || fail "a probe the server fails must refuse"
  assert_contains "$out" "failed the dispatch capability probe: HTTP 500 (orchestration_dispatch_failed)" "a 5xx should be reported as a server failure with its reason"
  assert_not_contains "$out" "not verified against" "a 5xx is not a version mismatch"
  rm -f "$HOME_DIR/state/.t3-session" "$HOME_DIR/state/.t3-session.header"
  : > "$CASE_DIR/foreign-tokens"
  # shellcheck disable=SC2016  # $0 and $@ are the child shell's own positionals.
  out=$(t3_env env FM_T3_FAKE_TOKENS="$CASE_DIR/foreign-tokens" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source t3 || exit 97; "$@"' "$ROOT" fm_backend_t3_dispatch_check 2>&1)
  status=$?
  rm -f "$HOME_DIR/state/.t3-session" "$HOME_DIR/state/.t3-session.header"
  [ "$status" -ne 0 ] || fail "a probe whose bearer session the server rejects must refuse"
  assert_contains "$out" "requires an owner-authenticated T3 Code server" "a persistent 401 should be reported as an auth failure"
  assert_contains "$out" "HTTP 401 (invalid_credential)" "the auth failure should carry the server's reason"
  assert_not_contains "$out" "not verified against" "a 401 is not a version mismatch"
  pass "fm_backend_t3_dispatch_check: a 5xx or a rejected session is refused as a server or auth failure with the server's reason"
  : > "$FAKE/no-dispatch-route"

  # A spawn refuses before any lease, project, or thread.
  id=t3v2spawnz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn against a server without the dispatch endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "verified against T3 Code v0.0.42" "the spawn refusal should name the verified version"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''get' "a refused spawn must lease no worktree"
  [ -z "$(dispatch_types)" ] || fail "a refused spawn must dispatch nothing, got '$(dispatch_types)'"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  pass "fm-spawn.sh --backend t3: a server without the dispatch endpoint is refused before any lease or thread exists"

  # Control and relaunch on a task spawned against a supported server refuse
  # up front once the endpoint is gone, before the thread is read or changed.
  rm -f "$FAKE/no-dispatch-route"
  id=t3v2ctlz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=5 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --model claude-test-model --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  expect_code 0 "$status" "the spawn against the supported server should succeed"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  meta="$HOME_DIR/state/$id.meta"
  : > "$FAKE/no-dispatch-route"
  : > "$FAKE/dispatch.log"
  : > "$FAKE/http.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-control interrupt against a server without the dispatch endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "verified against T3 Code v0.0.42" "the control refusal should name the verified version"
  [ -z "$(dispatch_types)" ] || fail "a refused control action must dispatch nothing, got '$(dispatch_types)'"
  ! grep -q "GET /api/orchestration/threads/$tid" "$FAKE/http.log" || fail "the control refusal should come before the thread is read"
  [ "$(thread_field "$tid" .session.status)" = running ] || fail "a refused control action must leave the session untouched"
  pass "fm-control.sh: a T3 task whose server lost the dispatch endpoint is refused before its thread is read"

  cp "$meta" "$CASE_DIR/meta.before"
  set_thread "$tid" '.session.status = "stopped"'
  : > "$FAKE/http.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch against a server without the dispatch endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "verified against T3 Code v0.0.42" "the relaunch refusal should name the verified version"
  [ -z "$(dispatch_types)" ] || fail "a refused relaunch must dispatch nothing, got '$(dispatch_types)'"
  ! grep -q "GET /api/orchestration/threads/$tid" "$FAKE/http.log" || fail "the relaunch refusal should come before the thread is read"
  cmp -s "$meta" "$CASE_DIR/meta.before" || fail "a refused relaunch must leave the record untouched"
  pass "fm-spawn.sh --relaunch on t3: a server without the dispatch endpoint is refused before the record changes"

  # Teardown refuses before its first destructive step, even under --force.
  [ -d "$wt" ] || fail "the spawned task should hold a leased worktree"
  (cd "$wt" && exec sleep 60) &
  holder=$!
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/http.log"
  : > "$T3LOG"
  out=$(t3_env env -u TMUX -u TMUX_PANE "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a teardown against a server without the dispatch endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "verified against T3 Code v0.0.42" "the teardown refusal should name the verified version"
  [ -z "$(dispatch_types)" ] || fail "a refused teardown must dispatch nothing, got '$(dispatch_types)'"
  ! grep -q "GET /api/orchestration/threads/$tid" "$FAKE/http.log" || fail "the teardown refusal should come before the thread is read"
  kill -0 "$holder" 2>/dev/null || fail "a refused teardown must not reap the worktree's processes"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "a refused teardown must not return the lease"
  cmp -s "$meta" "$CASE_DIR/meta.before" || fail "a refused teardown must leave the record untouched"
  [ "$(thread_field "$tid" .archivedAt)" = null ] || fail "a refused teardown must leave the thread open"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown.sh on t3: a server without the dispatch endpoint is refused before any destructive step, even under --force"

  rm -f "$FAKE/no-dispatch-route"
  out=$(t3_env env -u TMUX -u TMUX_PANE "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1) \
    || fail "the case's teardown against the restored server should complete"$'\n'"$out"
  rm -rf "/tmp/fm-$id"
}

# --- dispatcher and spawn -----------------------------------------------------------

test_dispatcher_routes_t3_operations() {
  local pid tid out
  t3_case dispatcher
  pid=$(uuid)
  seed_project "$pid" "$CASE_DIR/repo"
  tid=$(uuid)
  seed_thread "$tid" "$pid" running
  # shellcheck disable=SC2016  # $0 and $1 are the child shell's own positionals.
  out=$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_busy_state t3 "$1"; printf " "; fm_backend_agent_state t3 "$1"; printf " "; fm_backend_composer_state t3 "$1"; printf " "; fm_backend_target_exists t3 "$1" && printf exists' "$ROOT" "$tid")
  [ "$out" = "busy alive unknown exists" ] || fail "dispatcher routing for a running T3 thread read '$out'"
  # shellcheck disable=SC2016  # $0 and $1 are the child shell's own positionals.
  out=$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_text_submit t3 "$1" "via dispatcher" 1 0.01 0.01' "$ROOT" "$tid")
  [ "$out" = empty ] || fail "fm_backend_send_text_submit should route to the T3 adapter, got '$out'"
  [ "$(dispatch_last thread.turn.start .message.text)" = "via dispatcher" ] || fail "the routed send should reach the server"
  # shellcheck disable=SC2016  # $0 is the child shell's own positional.
  [ "$(t3_env bash -c '. "$0/bin/fm-backend.sh"; fm_backend_required_tools t3' "$ROOT")" = "t3 curl jq treehouse" ] \
    || fail "t3 should require t3, curl, jq, and treehouse"
  pass "fm-backend.sh: busy, agent, composer, existence, send, and tool requirements dispatch to the T3 adapter"
}

test_spawn_t3_end_to_end_then_control_peek_and_teardown() {
  local proj pid id=t3spawnz1 out status tid wt meta settings brief_text
  t3_case spawn
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise T3 dispatch end to end."
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=5 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --model claude-test-model --effort high \
    --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  expect_code 0 "$status" "fm-spawn.sh --backend t3 should succeed against the fake server"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.create thread.turn.start" ] \
    || fail "spawn should create the thread then start the brief turn, got '$(dispatch_types)'"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  [ -n "$tid" ] && [ -d "$wt" ] || fail "thread.create should carry a thread id and an existing worktree"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=$tid worktree=$wt" \
    "spawn output should name the thread as the window and the leased worktree"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "backend=t3" "$meta" "meta missing backend=t3"
  assert_grep "window=$tid" "$meta" "meta window should be the thread id"
  assert_grep "t3_thread_id=$tid" "$meta" "meta missing t3_thread_id"
  assert_grep "t3_project_id=$pid" "$meta" "meta missing t3_project_id"
  assert_grep "worktree=$wt" "$meta" "meta missing the leased worktree"
  assert_grep "model=claude-test-model" "$meta" "meta missing the model"
  # The thread is bound to the isolated worktree, never the project root.
  [ "$wt" != "$(cd "$proj" && pwd -P)" ] || fail "the thread was bound to the project root"
  [ "$(git -C "$wt" rev-parse --show-toplevel)" = "$(cd "$wt" && pwd -P)" ] || fail "the leased worktree is not a worktree root"
  [ "$(dispatch_last thread.create .title)" = "fm-$id" ] || fail "the thread should be titled fm-<id>"
  [ "$(dispatch_last thread.create '.modelSelection | tojson')" = '{"instanceId":"claudeAgent","model":"claude-test-model","options":[{"id":"effort","value":"high"}]}' ] \
    || fail "thread.create should carry the spawn's model and effort"
  [ "$(dispatch_last thread.create .runtimeMode)" = full-access ] || fail "the default permission posture should map to full-access"
  [ "$(dispatch_last thread.create .branch)" = null ] || fail "a detached leased worktree should send branch null"
  # The launch brief is the first turn, encoded as a launch-brief operational input.
  brief_text=$(jq -r 'select(.type == "thread.turn.start") | .message.text' "$FAKE/dispatch.log")
  [ "$(printf '%s' "$brief_text" | "$ROOT/bin/fm-operational-input.sh" kind)" = launch-brief ] \
    || fail "the first turn should be an encoded launch-brief input"
  case "$brief_text" in
    *"Exercise T3 dispatch end to end."*) ;;
    *) fail "the first turn should carry the brief's captain intent" ;;
  esac
  case "$brief_text" in
    *"You are a crewmate"*) ;;
    *) fail "the first turn should carry the worker role contract" ;;
  esac
  # The worker settings file carries the hooks the shared claude arm writes plus
  # the environment and policies a terminal launch would have put on argv.
  settings="$wt/.claude/settings.local.json"
  assert_present "$settings" "the worker settings file should exist in the worktree"
  jq -e '.hooks.Stop[0].hooks[0].command | test("fm-busy-event.sh") and test("--source claude-hook")' "$settings" >/dev/null \
    || fail "the Stop hook should drive the busy-state writer"
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("user-prompt-submit")' "$settings" >/dev/null \
    || fail "the UserPromptSubmit hook should open the turn"
  [ "$(jq -r .env.FM_TASK_ID "$settings")" = "$id" ] || fail "settings env should mark the task"
  [ "$(jq -r .env.GOTMPDIR "$settings")" = "/tmp/fm-$id/gotmp" ] || fail "settings env should carry GOTMPDIR"
  [ "$(jq -r .env.COMPACT_ADVISER_DISABLE "$settings")" = 1 ] || fail "settings env should pin the compact-adviser switch"
  [ "$(jq -r .env.CLAUDE_CODE_SEND_FEEDBACK "$settings")" = 0 ] || fail "settings env should disable feedback drafts"
  [ "$(jq -r .env.GIT_CONFIG_COUNT "$settings")" = 1 ] \
    && [ "$(jq -r .env.GIT_CONFIG_KEY_0 "$settings")" = core.hooksPath ] \
    && [ "$(jq -r .env.GIT_CONFIG_VALUE_0 "$settings")" = "$(cd "$HOME_DIR/state" && pwd -P)/$id.git-hooks" ] \
    || fail "settings env should point core.hooksPath at the task's AI-trailer strip hooks"
  [ "$(jq -r .feedbackDrafts "$settings")" = off ] || fail "settings should carry feedbackDrafts off"
  [ "$(jq -r .attribution.commit "$settings")" = "" ] && [ "$(jq -r .attribution.sessionUrl "$settings")" = false ] \
    || fail "settings should carry the attribution-off policy"
  grep -qxF '.claude/settings.local.json' "$(git -C "$wt" rev-parse --git-path info/exclude)" \
    || fail "the settings file should stay out of git's view"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''get'$'\x1f''--lease'$'\x1f''--lease-holder'$'\x1f'"fm-$id" \
    "the worktree should be leased non-interactively for the task"
  [ -z "$(compgen -G "/tmp/fm-$id+*" || true)" ] || fail "a T3 launch must stage no launch file"
  assert_present "$HOME_DIR/state/$id.busy-state" "the busy contract should be armed"
  assert_no_token_leak "spawn" "$out" "$meta" "$T3LOG" "$HOME_DIR/state/$id.status" "$FAKE/dispatch.log"
  pass "fm-spawn.sh --backend t3: leases the worktree, binds the thread to it, delivers the brief as the first turn, wires hooks and environment through settings"

  # fm-peek reads the rendered transcript through the dispatcher.
  out=$(t3_env "$ROOT/bin/fm-peek.sh" "$id" 400 2>&1) || fail "fm-peek should read a T3 task"$'\n'"$out"
  assert_contains "$out" "[t3 thread=$tid session=running" "fm-peek should end with the live-state footer"
  assert_contains "$out" "user: " "fm-peek should show the brief turn"
  pass "fm-peek.sh: reads a T3 task's transcript tail with its live state"

  # fm-control: interrupt is thread.turn.interrupt; exit is thread.session.stop.
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1)
  status=$?
  expect_code 0 "$status" "fm-control interrupt should succeed on T3"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.turn.interrupt" ] || fail "interrupt should dispatch thread.turn.interrupt, got '$(dispatch_types)'"
  assert_contains "$out" "cancel=unconfirmed" "claude has no cancel acknowledgement, so interrupt reports unconfirmed"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "the fake should model T3 stopping the provider after an interrupt"
  # The fake never runs the worker's hooks, so the busy record still holds the
  # spawn's seed; exit interrupts a busy agent first, which on T3 already stops
  # the session (modelled by the fake), so a stop needs an idle record to be
  # observed as its own dispatch.
  set_thread "$tid" '.session.status = "ready"'
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$id" idle --current-gen --source fm-recovery --event test-idle >/dev/null \
    || fail "could not mark the busy record idle"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=3 \
    "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 0 "$status" "fm-control exit should succeed on a ready T3 session"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.session.stop" ] || fail "exit should dispatch thread.session.stop, got '$(dispatch_types)'"
  assert_contains "$out" "stopped" "exit should report the stop"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "exit should leave the session stopped"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=3 "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 0 "$status" "a second exit should be idempotent"$'\n'"$out"
  assert_contains "$out" "already-stopped" "a stopped session should report already-stopped"
  [ -z "$(dispatch_types)" ] || fail "an already-stopped exit must dispatch nothing"
  pass "fm-control.sh: interrupt and exit drive T3's interrupt and session stop with proven postconditions"

  # A close T3 does not apply stops teardown before the lease goes back, even
  # under --force: the returned slot would stay bound to the still-open thread.
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/fail-archive"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env env -u TMUX -u TMUX_PANE "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?
  rm -f "$FAKE/fail-archive"
  [ "$status" -ne 0 ] || fail "a T3 teardown whose archive does not take must fail"$'\n'"$out"
  assert_contains "$out" "stopping this cleanup without removing the task's records" "the refusal should say the records are kept"
  [ "$(thread_field "$tid" .archivedAt)" = null ] || fail "the fake should leave the thread unarchived"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "an unproven close must not return the lease"
  [ -d "$wt" ] || fail "an unproven close must keep the leased worktree"
  assert_present "$settings" "an unproven close must leave the worker's wiring in the worktree"
  assert_present "$meta" "an unproven close must keep the task record"
  pass "fm-teardown.sh: a T3 close that cannot be proven refuses before the lease is returned, even under --force"

  # Teardown stops, archives, proves the 404, returns the lease, and revokes the session.
  set_thread "$tid" '.session.status = "ready"'
  : > "$FAKE/dispatch.log"
  rm -f "$CASE_DIR/pool.dispatch-at-return"
  out=$(t3_env env -u TMUX -u TMUX_PANE "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1)
  status=$?
  expect_code 0 "$status" "fm-teardown should complete for a T3 task"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.session.stop thread.archive" ] || fail "teardown should stop then archive, got '$(dispatch_types)'"
  [ "$(jq -r .type "$CASE_DIR/pool.dispatch-at-return" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" = "thread.session.stop thread.archive" ] \
    || fail "teardown should stop and archive the thread before it returns the lease"
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "teardown should archive the thread"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force'$'\x1f'"$wt" "teardown should return the leased worktree"
  assert_absent "$meta" "teardown should remove the task record"
  assert_absent "$HOME_DIR/state/.t3-session.header" "teardown of the last T3 task should release the bearer session"
  assert_contains "$(cat "$T3LOG")" $'auth\x1f''session'$'\x1f''revoke' "teardown of the last T3 task should revoke the bearer session"
  [ ! -d "$wt" ] || fail "the leased worktree should be returned"
  rm -rf "/tmp/fm-$id"
  pass "fm-teardown.sh: closes a T3 task by stop, archive, and re-read, returns the lease, and revokes the home's session"
}

test_spawn_t3_refuses_before_leasing_and_cleans_a_failed_start() {
  local proj unregistered pid id out status subhome tid wt spawn_pid holder
  t3_case spawn-refusals
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  id=t3codexz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  # A root T3 does not know yet: a late harness check would register it first.
  unregistered="$CASE_DIR/unregistered"
  fm_git_init_commit "$unregistered"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$unregistered" codex --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a codex spawn on t3 must refuse"
  assert_contains "$out" "claude harness family only" "the refusal should name the supported family"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''get' "a refused harness must lease no worktree"
  [ -z "$(dispatch_types)" ] || fail "a refused harness must register no project and create no thread, got '$(dispatch_types)'"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  pass "fm-spawn.sh --backend t3: a non-claude harness is refused before any lease or thread exists"

  # A Claude account pin cannot reach a T3-launched provider, so it refuses
  # rather than record account= for a pin that did not apply. The fake claude
  # reports the ordinary login signed in, so only the T3 conflict can refuse.
  id=t3pinz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  fm_fake_exit0 "$FB" claude
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$HOME_DIR/config/claude-account" "$FB/claude"
  [ "$status" -ne 0 ] || fail "a pinned Claude spawn on t3 must refuse"$'\n'"$out"
  assert_contains "$out" "T3 Code launches the provider with its server's own login" "the refusal should name the pin conflict"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''get' "a refused pin must lease no worktree"
  [ -z "$(dispatch_types)" ] || fail "a refused pin must dispatch nothing, got '$(dispatch_types)'"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused pin must publish no record"
  pass "fm-spawn.sh --backend t3: a declared Claude account pin is refused before any lease or thread exists"

  id=t3smz1
  subhome="$CASE_DIR/subhome"
  mkdir -p "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend t3 --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn on t3 must refuse"
  assert_contains "$out" "backend=t3 does not support --secondmate" "the secondmate refusal should name the backend"
  [ -z "$(dispatch_types)" ] || fail "a refused secondmate must dispatch nothing"
  pass "fm-spawn.sh --backend t3 --secondmate: refused before any mutation"

  # A thread that never starts its session is closed and its lease returned.
  id=t3nostartz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'stopped\n' > "$FAKE/on-turn-status"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/on-turn-status"
  [ "$status" -ne 0 ] || fail "a launch whose session never starts must fail"$'\n'"$out"
  assert_contains "$out" "reported no starting or running session" "the start failure should say what was not observed"
  [ "$(dispatch_types)" = "thread.create thread.turn.start thread.archive" ] \
    || fail "a failed start should archive the thread it created, got '$(dispatch_types)'"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force' "a failed fresh start should return the leased worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "a failed start should leave no task record"
  assert_absent "$HOME_DIR/state/$id.git-hooks" "a failed start whose thread was closed should remove its strip hooks"
  assert_grep "failed" "$HOME_DIR/state/$id.status" "a failed start should append a failed status line"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3: a thread that never starts is archived, its lease returned, and no record left"

  # A brief the server refuses to take is closed exactly like one that never starts.
  id=t3turnfailz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$FAKE/fail-turn-start"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-turn-start"
  [ "$status" -ne 0 ] || fail "a launch whose brief turn is refused must fail"$'\n'"$out"
  assert_contains "$out" "the launch brief could not be sent" "the failure should name the refused brief turn"
  [ "$(dispatch_types)" = "thread.create thread.archive" ] \
    || fail "a refused brief turn should archive the thread it created, got '$(dispatch_types)'"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "the created thread should be archived"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force'$'\x1f'"$wt" "a refused brief turn should return the leased worktree"
  [ ! -d "$wt" ] || fail "the leased worktree should be gone after the failed spawn"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused brief turn should leave no task record"
  assert_absent "$HOME_DIR/state/$id.git-hooks" "a refused brief turn whose thread was closed should remove its strip hooks"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3: a refused brief turn archives the thread, returns the lease, and leaves no record"

  # A thread whose close cannot be proven keeps its lease: the worktree may
  # still hold a running provider.
  id=t3noclosez1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$FAKE/fail-turn-start"
  : > "$FAKE/fail-archive"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-turn-start" "$FAKE/fail-archive"
  [ "$status" -ne 0 ] || fail "a launch whose brief turn is refused must fail"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  assert_contains "$out" "T3 thread $tid could not be proven closed" "the warning should name the unclosed thread"
  assert_contains "$out" "worktree $wt" "the warning should name the kept worktree"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "an unproven close must not return the lease"
  [ -d "$wt" ] || fail "an unproven close must keep the leased worktree"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3: a failed launch whose thread close is unproven keeps the lease and says so"

  # The spawn still holds its meta lock when a launch fails, and teardown takes
  # the Treehouse project lock before that one, so a held Treehouse lock must
  # bound the wait and leave the lease rather than block.
  id=t3lockedz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf 'stopped\n' > "$FAKE/on-turn-status"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  rm -f "$CASE_DIR/lock-held"
  t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=4 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 \
    > "$CASE_DIR/locked.out" 2>&1 &
  spawn_pid=$!
  for _ in $(seq 1 100); do
    [ -z "$(dispatch_last thread.turn.start .threadId)" ] || break
    sleep 0.1
  done
  # shellcheck disable=SC2016  # $0, $1, and $2 are the child shell's own positionals.
  t3_env bash -c '. "$0/bin/fm-wake-lib.sh"; lock=$(fm_treehouse_project_lock_path "$1") || exit 1
    fm_lock_try_acquire "$lock" || exit 1; printf "%s\n" "$$" > "$2"; exec sleep 30' \
    "$ROOT" "$proj" "$CASE_DIR/lock-held" &
  holder=$!
  for _ in $(seq 1 50); do
    [ ! -s "$CASE_DIR/lock-held" ] || break
    sleep 0.1
  done
  wait "$spawn_pid"
  status=$?
  kill "$(cat "$CASE_DIR/lock-held" 2>/dev/null)" "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f "$FAKE/on-turn-status"
  out=$(cat "$CASE_DIR/locked.out")
  assert_present "$CASE_DIR/lock-held" "the test could not hold the Treehouse project lock"
  [ "$status" -ne 0 ] || fail "a launch whose session never starts must fail"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  [ "$(thread_field "$tid" .archivedAt)" != null ] || fail "the thread should still be archived while the lock is contended"
  assert_contains "$out" "Treehouse project lock for" "the warning should say the Treehouse lock stayed held"
  assert_contains "$out" "worktree $wt of closed T3 thread $tid" "the warning should name the kept worktree and the thread"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "a contended lock must not return the lease"
  [ -d "$wt" ] || fail "a contended lock must keep the leased worktree"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend t3: a failed launch bounds its Treehouse lock wait and leaves the lease when it is held"

  # An abort before the record exists returns a clean slot...
  id=t3abortcleanz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$FAKE/fail-thread-create"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-create"
  [ "$status" -ne 0 ] || fail "a spawn whose thread.create fails must fail"$'\n'"$out"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force' "an aborted spawn on a clean slot should return the lease"$'\n'"$out"
  assert_not_contains "$out" "holds uncommitted or unreadable work" "a clean slot must not be reported dirty"
  assert_absent "$HOME_DIR/state/$id.meta" "an aborted spawn should leave no record"
  pass "fm-spawn.sh --backend t3: an abort before the record returns a clean leased slot"

  # ...but never force-returns one holding someone else's uncommitted work.
  id=t3abortdirtyz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE_DIR/pool.dirty"
  : > "$FAKE/fail-thread-create"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-create" "$CASE_DIR/pool.dirty"
  [ "$status" -ne 0 ] || fail "a spawn whose thread.create fails must fail"$'\n'"$out"
  [ -z "$(dispatch_types)" ] || fail "a refused thread.create must dispatch nothing further, got '$(dispatch_types)'"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "a dirty leased slot must not be returned"
  wt=$(compgen -G "$CASE_DIR/pool/*/*/uncommitted.txt" | head -n 1)
  [ -n "$wt" ] || fail "the uncommitted file in the leased slot must survive"
  [ "$(cat "$wt")" = "crashed worker work" ] || fail "the uncommitted file in the leased slot must keep its content"
  assert_contains "$out" "worktree $(dirname "$wt") of task $id holds uncommitted or unreadable work" "the warning should name the dirty worktree"
  assert_contains "$out" "this task's own slot claim was released" "the warning should say the aborted task's claim was released"
  ! grep -qx "task=$id" "$(dirname "$(dirname "$wt")")/.fm-slot-owner" 2>/dev/null \
    || fail "the aborted task must not keep its claim on a dirty slot it never recorded"
  assert_absent "$HOME_DIR/state/$id.meta" "an aborted spawn should leave no record"
  pass "fm-spawn.sh --backend t3: an abort never force-returns a leased slot holding uncommitted work"

  # A thread.create T3 accepted but whose read-back failed is still closed by
  # the minted id once the thread reads again, and only then is the lease returned.
  id=t3readoncez1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$FAKE/fail-thread-read-once"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-read-once"
  [ "$status" -ne 0 ] || fail "a spawn whose thread read-back fails must fail"$'\n'"$out"
  assert_contains "$out" "could not be read back" "the failure should name the failed read-back"
  tid=$(dispatch_last thread.create .threadId)
  [ "$(dispatch_types)" = "thread.create thread.archive" ] \
    || fail "the minted thread should be archived once it reads again, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.archive .threadId)" = "$tid" ] || fail "the archive should name the minted thread"
  assert_contains "$(cat "$T3LOG")" $'treehouse\x1f''return'$'\x1f''--force' "a proven close on a clean slot should return the lease"
  assert_absent "$HOME_DIR/state/$id.meta" "an aborted spawn should leave no record"
  pass "fm-spawn.sh --backend t3: an accepted thread whose read-back failed is archived by its minted id"

  # While the thread stays unreadable its close is unproven: the lease and this
  # task's claim both stay, so no stale owner's teardown recycles the slot.
  id=t3readfailz1
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE_DIR/pool.dirty"
  : > "$FAKE/fail-thread-read"
  : > "$FAKE/dispatch.log"
  : > "$FAKE/http.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  rm -f "$FAKE/fail-thread-read" "$CASE_DIR/pool.dirty"
  [ "$status" -ne 0 ] || fail "a spawn whose thread read-back fails must fail"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  [ "$(dispatch_types)" = "thread.create" ] || fail "an unreadable thread cannot be archived, got '$(dispatch_types)'"
  [ "$(grep -c "GET /api/orchestration/threads/$tid" "$FAKE/http.log")" -ge 2 ] \
    || fail "the abort should attempt to close the minted thread after the failed read-back"
  [ "$(thread_field "$tid" .archivedAt)" = null ] || fail "the unreadable thread should still be unarchived"
  assert_contains "$out" "T3 thread $tid could not be proven closed" "the warning should name the unclosed thread"
  assert_contains "$out" "worktree $wt and this task's slot claim were left in place" "the warning should name the kept worktree and claim"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "an unproven close must not return the lease"
  [ "$(cat "$wt/uncommitted.txt" 2>/dev/null)" = "crashed worker work" ] || fail "an unproven close must keep the leased worktree's work"
  grep -qx "task=$id" "$(dirname "$wt")/.fm-slot-owner" 2>/dev/null \
    || fail "an unproven close must keep this task's claim on the slot its open thread is still bound to"
  assert_absent "$HOME_DIR/state/$id.meta" "an aborted spawn should leave no record"
  pass "fm-spawn.sh --backend t3: an abort whose thread close is unproven keeps the lease and the claim and says so"
}

test_spawn_t3_relaunch_carries_model_and_keeps_thread_on_failure() {
  local proj pid id=t3relaunchz1 out status tid wt meta
  t3_case relaunch
  proj="$CASE_DIR/project"
  fm_git_init_commit "$proj"
  pid=$(uuid)
  seed_project "$pid" "$(cd "$proj" && pwd -P)"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=5 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --model claude-test-model --effort high \
    --mode no-mistakes --yolo off --backend t3 2>&1)
  status=$?
  expect_code 0 "$status" "the fresh spawn under relaunch should succeed"$'\n'"$out"
  tid=$(dispatch_last thread.create .threadId)
  wt=$(dispatch_last thread.create .worktreePath)
  meta="$HOME_DIR/state/$id.meta"

  [ "$(dispatch_last thread.turn.start .runtimeMode)" = full-access ] || fail "the default posture's brief turn should carry full-access"

  set_thread "$tid" '.session.status = "stopped"'
  printf 'auto\n' > "$HOME_DIR/config/claude-permission-mode"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=5 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness claude --model claude-next-model --effort low 2>&1)
  status=$?
  expect_code 0 "$status" "a T3 relaunch should succeed"$'\n'"$out"
  [ "$(dispatch_types)" = "thread.runtime-mode.set thread.turn.start" ] \
    || fail "a relaunch under a changed posture should switch the thread's mode, then start the brief turn, got '$(dispatch_types)'"
  [ "$(dispatch_last thread.runtime-mode.set .runtimeMode)" = auto ] || fail "the mode switch should name auto"
  [ "$(dispatch_last thread.turn.start .threadId)" = "$tid" ] || fail "the relaunch brief should go to the task's own thread"
  [ "$(dispatch_last thread.turn.start '.modelSelection | tojson')" = '{"instanceId":"claudeAgent","model":"claude-next-model","options":[{"id":"effort","value":"low"}]}' ] \
    || fail "the relaunch brief turn should carry the relaunch's model and effort"
  assert_grep "model=claude-next-model" "$meta" "meta should record the relaunch model"
  [ "$(thread_field "$tid" .runtimeMode)" = auto ] || fail "the relaunched thread should run under the changed auto posture"
  [ "$(thread_field "$tid" .session.runtimeMode)" = auto ] || fail "the relaunched provider session should run under auto"
  pass "fm-spawn.sh --relaunch on t3: the brief turn carries the relaunch's model, and the thread takes the changed posture"

  set_thread "$tid" '.session.status = "stopped"'
  cp "$meta" "$CASE_DIR/meta.before"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a codex relaunch on t3 must refuse"
  assert_contains "$out" "claude harness family only" "the relaunch refusal should name the supported family"
  [ -z "$(dispatch_types)" ] || fail "a refused relaunch must dispatch nothing, got '$(dispatch_types)'"
  cmp -s "$meta" "$CASE_DIR/meta.before" || fail "a refused relaunch must leave the record untouched"
  pass "fm-spawn.sh --relaunch on t3: a non-claude harness is refused before the record changes"

  # The session reads ready, never starting or running, so the brief never starts.
  printf 'ready\n' > "$FAKE/on-turn-status"
  : > "$FAKE/dispatch.log"
  : > "$T3LOG"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness claude 2>&1)
  status=$?
  rm -f "$FAKE/on-turn-status"
  [ "$status" -ne 0 ] || fail "a relaunch whose session never starts must fail"$'\n'"$out"
  assert_contains "$out" "reported no starting or running session" "the relaunch failure should say what was not observed"
  [ "$(dispatch_types)" = "thread.turn.start thread.session.stop" ] \
    || fail "a failed relaunch under an unchanged posture should switch no mode, stop the session it started, and never archive the thread, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .archivedAt)" = null ] || fail "a failed relaunch must keep the thread relaunchable"
  [ "$(thread_field "$tid" .session.status)" = stopped ] || fail "a failed relaunch should leave the session stopped"
  [ -d "$wt" ] || fail "a failed relaunch must keep the worktree"
  assert_not_contains "$(cat "$T3LOG")" $'treehouse\x1f''return' "a failed relaunch must not return the worktree"
  assert_present "$meta" "a failed relaunch keeps the record naming the thread"
  pass "fm-spawn.sh --relaunch on t3: a relaunch that never starts stops the session but keeps the thread and worktree"

  # A posture change T3 does not apply refuses before the brief turn.
  rm -f "$HOME_DIR/config/claude-permission-mode"
  : > "$FAKE/fail-runtime-mode-set"
  : > "$FAKE/dispatch.log"
  out=$(t3_env FM_SPAWN_NO_GUARD=1 FM_T3_START_WAIT=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness claude 2>&1)
  status=$?
  rm -f "$FAKE/fail-runtime-mode-set"
  [ "$status" -ne 0 ] || fail "a relaunch whose mode switch does not stick must fail"$'\n'"$out"
  assert_contains "$out" "could not be switched to runtime mode full-access" "the refusal should name the mode that did not stick"
  [ "$(dispatch_types)" = "thread.runtime-mode.set" ] \
    || fail "a mode switch that does not stick must send no brief turn and archive nothing, got '$(dispatch_types)'"
  [ "$(thread_field "$tid" .runtimeMode)" = auto ] || fail "the thread should keep the mode T3 reports"
  [ "$(thread_field "$tid" .archivedAt)" = null ] || fail "a refused mode switch must keep the thread relaunchable"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --relaunch on t3: a posture T3 does not apply refuses the relaunch before the brief turn"
}

test_origin_requires_running_server
test_session_is_minted_once_cached_privately_and_refreshed_on_401
test_project_ensure_matches_existing_root_or_creates
test_project_find_matches_the_repository_by_origin
test_project_find_reads_origin_not_t3s_upstream_identity
test_model_selection_precedence_and_harness_gate
test_thread_create_binds_worktree_and_reads_back
test_runtime_mode_maps_permission_flag
test_state_reads_map_session_status
test_capture_renders_transcript_tail_with_state_footer
test_send_text_submit_is_a_turn_start
test_send_key_maps_interrupt_and_enter
test_session_stop_and_kill_order_and_proof
test_dispatcher_routes_t3_operations
test_spawn_t3_end_to_end_then_control_peek_and_teardown
test_spawn_t3_refuses_before_leasing_and_cleans_a_failed_start
test_spawn_t3_relaunch_carries_model_and_keeps_thread_on_failure
test_dispatch_gate_pins_the_verified_server
