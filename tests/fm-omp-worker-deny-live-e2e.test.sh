#!/usr/bin/env bash
# Live guard for the omp worker's hard refusals.
#
# The tracked worker overlay (.omp/fm-worker-overlay.yml) carries omp
# `bash.patterns` deny rules so a Firstmate-launched omp worker cannot merge a
# PR, run sudo, or push to the default branch even under --auto-approve. Whether
# a rule refuses is decided by the installed omp, so a stub cannot prove it: this
# guard replays the REAL launch flags fm-spawn builds (captured through a fake
# pane) against the installed omp, and lets a scripted local model ask its bash
# tool for each command. The verdict is the consumer-visible outcome: a refused
# command never reaches the program (recording gh/gh-axi/sudo stubs, a bare
# origin whose main does not move), while the worker's own branch push lands.
#
# The scripted model is a local OpenAI-compatible server, so the guard spends no
# model tokens and runs by default wherever omp, node, and git are installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_OMP_WORKER_DENY_LIVE omp node git

OMP_VERSION=$(omp --version 2>/dev/null | head -1)
TMP_ROOT=$(fm_test_tmproot fm-omp-worker-deny-live)
BRANCH=fm/omp-deny-task
SERVER_PID=

stop_server() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; }
trap 'stop_server; fm_test_cleanup' EXIT

# capture_omp_flags <case-dir>: spawns an omp scout on the task worktree
# <case-dir>/wt against a fake pane and echoes the configuration flags
# (overlay, approval, cwd) of the launch firstmate sent.
capture_omp_flags() {
  local case_dir=$1 home proj fakebin launchlog launch flags id=omp-deny-q1
  home="$case_dir/home"
  proj="$case_dir/project"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" omp)
  fm_test_spawn_home "$home" omp
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$case_dir/wt" "$BRANCH"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$case_dir/wt" "$fakebin" "$id" "$proj" --scout >/dev/null ||
    fail "omp $OMP_VERSION: fm-spawn could not build a worker launch"
  launch=$(cat "$launchlog")
  case "$launch" in
    *"/omp' "*) ;;
    *) fail "could not find the quoted omp path in the captured launch: $launch" ;;
  esac
  flags=${launch#*"/omp' "}
  flags=${flags%% -e *}
  case "$flags" in
    *"--config "*"--auto-approve"*) printf '%s' "$flags" ;;
    *) fail "could not find the overlay and --auto-approve in the captured omp launch: $launch" ;;
  esac
}

# start_model <dir>: a scripted OpenAI chat-completions server. The prompt is a
# shell command; the first turn calls the bash tool with it and the next turn
# echoes the tool result back as the final answer.
start_model() {
  local dir=$1
  cat > "$dir/model.mjs" <<'JS'
import http from "node:http";
const text = (m) => (typeof m.content === "string" ? m.content : m.content[m.content.length - 1].text);
const srv = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    if (req.method !== "POST" || !req.url.endsWith("/chat/completions")) return res.writeHead(404).end("{}");
    const msgs = JSON.parse(body).messages;
    const last = msgs[msgs.length - 1];
    const delta = last.role === "tool"
      ? { role: "assistant", content: "TOOL_RESULT<<" + text(last) + ">>" }
      : { role: "assistant", tool_calls: [{ index: 0, id: "call_1", type: "function",
          function: { name: "bash", arguments: JSON.stringify({ command: text([...msgs].reverse().find((m) => m.role === "user")).trim() }) } }] };
    const chunk = (d, finish) => res.write("data: " + JSON.stringify({ id: "x", object: "chat.completion.chunk", created: 0, model: "scripted",
      choices: [{ index: 0, delta: d, finish_reason: finish }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }) + "\n\n");
    res.writeHead(200, { "content-type": "text/event-stream" });
    chunk(delta, null);
    chunk({}, delta.tool_calls ? "tool_calls" : "stop");
    res.end("data: [DONE]\n\n");
  });
});
srv.listen(0, "127.0.0.1", () => console.log(srv.address().port));
JS
  node "$dir/model.mjs" > "$dir/port" 2> "$dir/model.err" &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$dir/port" ] && break
    sleep 0.1
  done
  [ -s "$dir/port" ] || fail "the scripted model server did not start: $(cat "$dir/model.err")"
  mkdir -p "$dir/omp-home/.omp/agent"
  cat > "$dir/omp-home/.omp/agent/models.yml" <<EOF
providers:
  scripted:
    baseUrl: http://127.0.0.1:$(cat "$dir/port")/v1
    auth: none
    api: openai-completions
    models:
      - id: scripted
        name: scripted
        reasoning: false
        input: [text]
        contextWindow: 100000
        maxTokens: 1000
EOF
}

# worker_bash <command>: one omp print-mode turn under the captured launch
# flags in an isolated omp home; echoes what the bash tool returned.
worker_bash() {
  eval "env -i PATH=\"\$STUBS:\$PATH\" HOME=\"\$CASE/omp-home\" TERM=dumb OMP_SKIP_SETUP=1 STUB_LOG=\"\$CASE/stub.log\" \
    omp -p --no-session --no-title --max-time 60 $FLAGS --model scripted/scripted \"\$1\"" < /dev/null 2>&1
}

expect_refused() {  # <command>
  local out
  out=$(worker_bash "$1")
  case "$out" in
    *"blocked by tool policy"*) ;;
    *) fail "omp $OMP_VERSION let a worker run '$1' under the worker overlay: $out" ;;
  esac
}

CASE="$TMP_ROOT/case"
WT="$CASE/wt"
mkdir -p "$CASE"
FLAGS=$(capture_omp_flags "$CASE")
STUBS="$CASE/stubs"
mkdir -p "$STUBS"
for tool in gh gh-axi sudo; do
  # shellcheck disable=SC2016 # the stub expands $* and $STUB_LOG at its own runtime
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >> "$STUB_LOG"\n' "$tool" > "$STUBS/$tool"
  chmod +x "$STUBS/$tool"
done
: > "$CASE/stub.log"
start_model "$CASE"

# The worker has a commit its default branch lacks, so a push that got through
# would visibly move origin's main.
printf 'worker change\n' > "$WT/change.txt"
git -C "$WT" add change.txt
git -C "$WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'worker change'
ORIGIN="$CASE/project.origin.git"
MAIN_BEFORE=$(git -C "$ORIGIN" rev-parse refs/heads/main)

test_merge_sudo_and_default_branch_push_are_refused() {
  local cmd
  for cmd in \
    'gh pr merge 7 --squash' \
    'gh -R owner/repo pr merge 7' \
    'gh-axi pr merge 7 --squash -R owner/repo' \
    'gh api -X PUT repos/owner/repo/pulls/7/merge' \
    'sudo true' \
    'echo ok | sudo tee /dev/null' \
    'git push origin HEAD:main' \
    'git push --force origin +HEAD:refs/heads/main' \
    "git -C '$WT' push origin HEAD:master" \
    'git push origin main' \
    'git push origin :main' \
    'git push origin master' \
    'git push origin main --force' \
    'git fetch -q origin && git push origin main' \
    'false || git push origin main' \
    'true ; git push origin main' \
    'sleep 0 & git push origin main' \
    'true | git push origin main' \
    '(git push origin main)' \
    "true
git push origin main"; do
    expect_refused "$cmd"
  done
  [ ! -s "$CASE/stub.log" ] || fail "a refused command still reached its program: $(cat "$CASE/stub.log")"
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" = "$MAIN_BEFORE" ] ||
    fail "a refused push still moved origin's default branch"
  ! git -C "$ORIGIN" rev-parse -q --verify refs/heads/master >/dev/null ||
    fail "a refused push still created origin's master"
  printf 'ok - omp %s refuses PR merge, sudo, and default-branch pushes for a firstmate worker under --auto-approve\n' "$OMP_VERSION"
}

test_task_branch_push_and_other_commands_still_run() {
  local out
  out=$(worker_bash "git push -u origin $BRANCH")
  [ "$(git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$BRANCH")" = "$(git -C "$WT" rev-parse HEAD)" ] ||
    fail "omp $OMP_VERSION refused the worker's own task-branch push: $out"
  local branch
  for branch in maintenance-x mastery-y; do
    git -C "$WT" branch -q "$branch"
    out=$(worker_bash "git push origin $branch")
    [ "$(git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$branch")" = "$(git -C "$WT" rev-parse HEAD)" ] ||
      fail "omp $OMP_VERSION refused the push of task branch $branch: $out"
  done
  out=$(worker_bash "git push origin $BRANCH:main-fix")
  [ "$(git -C "$ORIGIN" rev-parse -q --verify refs/heads/main-fix)" = "$(git -C "$WT" rev-parse HEAD)" ] ||
    fail "omp $OMP_VERSION refused a refspec whose destination only starts with main: $out"
  # A worker also pushes its task branch to the no-mistakes gate's own remote.
  # The gate starts empty, so only a push that ran can create the branch there.
  git init -q --bare "$CASE/gate.git"
  git -C "$WT" remote add no-mistakes "$CASE/gate.git"
  out=$(worker_bash "git push no-mistakes $BRANCH")
  [ "$(git -C "$CASE/gate.git" rev-parse -q --verify "refs/heads/$BRANCH")" = "$(git -C "$WT" rev-parse HEAD)" ] ||
    fail "omp $OMP_VERSION refused the worker's push of its task branch to the no-mistakes gate: $out"
  out=$(worker_bash 'gh pr view 7 -R owner/repo')
  grep -qx 'gh pr view 7 -R owner/repo' "$CASE/stub.log" ||
    fail "omp $OMP_VERSION refused a non-merge gh command: $out"
  printf 'ok - omp %s still runs the worker task-branch push and other gh commands\n' "$OMP_VERSION"
}

test_merge_sudo_and_default_branch_push_are_refused
test_task_branch_push_and_other_commands_still_run

echo "# all fm-omp-worker-deny-live-e2e tests passed"
