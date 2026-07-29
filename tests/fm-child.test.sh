#!/usr/bin/env bash
# Focused fake-Herdr tests for bounded child authorization and lifecycle safety.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
TASK_ID="child-unit-$$"
TASK_TMP="/tmp/fm-$TASK_ID"
HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
WORKTREE="$TMP/worktree"
PROJECT="$TMP/project"
FAKE_BIN="$TMP/fake-bin"
FAKE_STATE="$TMP/fake-state"
INSTRUCTIONS="$TMP/instructions.md"
PASS=0
FAIL=0
ORIGINAL_PATH=$PATH

cleanup() {
  if [ "${KEEP_FM_CHILD_TEST_TMP:-0}" = 1 ]; then
    printf 'kept test fixture: %s %s\n' "$TMP" "$TASK_TMP" >&2
    return
  fi
  rm -rf "$TMP" "$TASK_TMP"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_success() {  # <label> <command...>
  local label=$1
  shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    ok "$label"
  else
    not_ok "$label"
    sed 's/^/  /' "$TMP/err" >&2
  fi
}

assert_failure_contains() {  # <label> <needle> <command...>
  local label=$1 needle=$2
  shift 2
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    not_ok "$label (unexpected success)"
  elif grep -Fq "$needle" "$TMP/err"; then
    ok "$label"
  else
    not_ok "$label (missing '$needle')"
    sed 's/^/  /' "$TMP/err" >&2
  fi
}

mkdir -p "$STATE" "$WORKTREE" "$PROJECT" "$FAKE_BIN" "$FAKE_STATE"
git -C "$PROJECT" init -q
git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.email test@example.com
git -C "$WORKTREE" config user.name Test
printf 'base\n' > "$WORKTREE/a.txt"
printf 'base\n' > "$WORKTREE/b.txt"
printf 'base\n' > "$WORKTREE/c.txt"
printf 'base\n' > "$WORKTREE/d.txt"
mkdir -p "$WORKTREE/src" "$WORKTREE/docs"
printf 'nested\n' > "$WORKTREE/src/one.txt"
git -C "$WORKTREE" add .
git -C "$WORKTREE" commit -qm base
printf 'edit the assigned path and report privately\n' > "$INSTRUCTIONS"
printf 'p:parent|w-home|t:task|%s\n' "$WORKTREE" > "$FAKE_STATE/panes"
printf 'p:parent|pi|working\n' > "$FAKE_STATE/agents"
printf 'pi\n' > "$FAKE_STATE/next-agent"
printf '0\n' > "$FAKE_STATE/counter"
: > "$FAKE_STATE/log"

cat > "$STATE/$TASK_ID.meta" <<EOF
window=lab:p:parent
endpoint_task_id=$TASK_ID
worktree=$WORKTREE
project=$PROJECT
harness=pi
model=openai-codex/gpt-5.6-sol
effort=xhigh
kind=ship
mode=no-mistakes
tasktmp=$TASK_TMP
backend=herdr
herdr_session=lab
herdr_workspace_id=w-home
herdr_tab_id=t:task
herdr_pane_id=p:parent
EOF

cat > "$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
state=${FAKE_HERDR_STATE:?}
printf 'CALL' >> "$state/log"
for value in "$@"; do printf ' <%s>' "$value" >> "$state/log"; done
printf '\n' >> "$state/log"

json_error() {
  jq -nc --arg code "$1" --arg message "$2" '{error:{code:$code,message:$message}}'
  exit 1
}

strip_session() {
  count=$#
  [ "$count" -ge 2 ] || return 0
  eval "penultimate=\${$((count - 1))}"
  if [ "$penultimate" = --session ]; then
    set -- "${@:1:$((count - 2))}"
  fi
  printf '%s\n' "$@"
}

cmd=${1:-}
sub=${2:-}
case "$cmd:$sub" in
  status:*)
    jq -nc '{client:{version:"0.7.5",protocol:16},server:{running:true}}'
    ;;
  pane:get)
    pane=${3:-}
    row=$(awk -F'|' -v pane="$pane" '$1 == pane { print; exit }' "$state/panes")
    [ -n "$row" ] || json_error pane_not_found "missing pane"
    IFS='|' read -r pane workspace tab cwd <<ROW
$row
ROW
    jq -nc --arg pane "$pane" --arg workspace "$workspace" --arg tab "$tab" --arg cwd "$cwd" \
      '{result:{pane:{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,foreground_cwd:$cwd}}}'
    ;;
  pane:split)
    parent=${3:-}
    parent_row=$(awk -F'|' -v pane="$parent" '$1 == pane { print; exit }' "$state/panes")
    [ -n "$parent_row" ] || json_error pane_not_found "missing parent"
    IFS='|' read -r _ workspace tab cwd <<ROW
$parent_row
ROW
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --cwd ] && [ "$#" -ge 2 ]; then cwd=$2; shift 2; else shift; fi
    done
    if [ -f "$state/split-tab" ]; then tab=$(cat "$state/split-tab"); fi
    if [ -f "$state/split-pane" ]; then
      pane=$(cat "$state/split-pane")
    else
      counter=$(cat "$state/counter")
      counter=$((counter + 1))
      printf '%s\n' "$counter" > "$state/counter"
      pane="p:child-$counter"
    fi
    if [ -f "$state/pause-split" ]; then
      : > "$state/split-entered"
      while [ -f "$state/pause-split" ]; do sleep 0.02; done
    fi
    if ! awk -F'|' -v pane="$pane" '$1 == pane { found=1 } END { exit !found }' "$state/panes"; then
      printf '%s|%s|%s|%s\n' "$pane" "$workspace" "$tab" "$cwd" >> "$state/panes"
    fi
    jq -nc --arg pane "$pane" --arg workspace "$workspace" --arg tab "$tab" --arg cwd "$cwd" \
      '{result:{pane:{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,foreground_cwd:$cwd}}}'
    ;;
  pane:close)
    pane=${3:-}
    if ! awk -F'|' -v pane="$pane" '$1 == pane { found=1 } END { exit !found }' "$state/panes"; then
      json_error pane_not_found "missing pane"
    fi
    awk -F'|' -v pane="$pane" '$1 != pane' "$state/panes" > "$state/panes.tmp"
    mv "$state/panes.tmp" "$state/panes"
    awk -F'|' -v pane="$pane" '$1 != pane' "$state/agents" > "$state/agents.tmp"
    mv "$state/agents.tmp" "$state/agents"
    jq -nc --arg pane "$pane" '{result:{closed:true,pane_id:$pane}}'
    ;;
  pane:run)
    pane=${3:-}
    agent=$(cat "$state/next-agent")
    awk -F'|' -v pane="$pane" '$1 != pane' "$state/agents" > "$state/agents.tmp"
    printf '%s|%s|idle\n' "$pane" "$agent" >> "$state/agents.tmp"
    mv "$state/agents.tmp" "$state/agents"
    jq -nc '{result:{started:true}}'
    ;;
  pane:read)
    if [ -f "$state/pane-output" ]; then
      cat "$state/pane-output"
    else
      printf 'bounded child pane output\n'
    fi
    ;;
  pane:send-text)
    jq -nc '{result:{sent:true}}'
    ;;
  pane:send-keys)
    pane=${3:-}
    if [ ! -f "$state/send-pending" ]; then
      awk -F'|' -v pane="$pane" '
        $1 == pane { print $1 "|" $2 "|working"; next }
        { print }
      ' "$state/agents" > "$state/agents.tmp"
      mv "$state/agents.tmp" "$state/agents"
    elif [ -f "$state/corroboration-agent" ]; then
      replacement=$(cat "$state/corroboration-agent")
      awk -F'|' -v pane="$pane" -v replacement="$replacement" '
        $1 == pane { print $1 "|" replacement "|idle"; next }
        { print }
      ' "$state/agents" > "$state/agents.tmp"
      mv "$state/agents.tmp" "$state/agents"
    fi
    jq -nc '{result:{sent:true}}'
    ;;
  agent:get)
    pane=${3:-}
    row=$(awk -F'|' -v pane="$pane" '$1 == pane { print; exit }' "$state/agents")
    [ -n "$row" ] || json_error agent_not_found "missing agent"
    IFS='|' read -r pane agent status <<ROW
$row
ROW
    jq -nc --arg pane "$pane" --arg agent "$agent" --arg status "$status" \
      '{result:{agent:{pane_id:$pane,agent:$agent,agent_status:$status}}}'
    ;;
  agent:start)
    pane=
    kind=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pane) pane=$2; shift 2 ;;
        --kind) kind=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$pane" ] || json_error invalid_request "missing pane"
    awk -F'|' -v pane="$pane" '$1 != pane' "$state/agents" > "$state/agents.tmp"
    printf '%s|%s|idle\n' "$pane" "$kind" >> "$state/agents.tmp"
    mv "$state/agents.tmp" "$state/agents"
    jq -nc '{result:{started:true}}'
    ;;
  agent:prompt)
    jq -nc '{result:{sent:true}}'
    ;;
  *)
    json_error unsupported "unsupported fake call: $cmd $sub"
    ;;
esac
EOF
chmod +x "$FAKE_BIN/herdr"
for binary in claude codex opencode pi pi-signed grok kimi; do
  cat > "$FAKE_BIN/$binary" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$FAKE_BIN/$binary"
done

run_parent() {
  (
    cd "$WORKTREE" || exit 1
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FAKE_HERDR_STATE="$FAKE_STATE" PATH="$FAKE_BIN:$ORIGINAL_PATH" \
      HERDR_ENV=1 HERDR_PANE_ID=p:parent \
      "$ROOT/bin/fm-child.sh" "$@"
  )
}

set_profile() {  # <harness> <model> <effort> <live-agent>
  local harness=$1 model=$2 effort=$3 agent=$4 tmp="$TMP/meta.tmp"
  awk -F= -v h="$harness" -v m="$model" -v e="$effort" '
    $1 == "harness" { print "harness=" h; next }
    $1 == "model" { print "model=" m; next }
    $1 == "effort" { print "effort=" e; next }
    { print }
  ' "$STATE/$TASK_ID.meta" > "$tmp"
  mv "$tmp" "$STATE/$TASK_ID.meta"
  awk -F'|' '$1 != "p:parent"' "$FAKE_STATE/agents" > "$FAKE_STATE/agents.tmp"
  printf 'p:parent|%s|working\n' "$agent" >> "$FAKE_STATE/agents.tmp"
  mv "$FAKE_STATE/agents.tmp" "$FAKE_STATE/agents"
  printf '%s\n' "$agent" > "$FAKE_STATE/next-agent"
}

assert_success "creates one exact same-tab child with explicit path ownership" \
  run_parent create alpha --instructions "$INSTRUCTIONS" --path src
if [ -f "$TASK_TMP/children/alpha/meta" ] \
   && grep -Fxq 'parent_tab_id=t:task' "$TASK_TMP/children/alpha/meta" \
   && grep -Fxq 'worktree='"$WORKTREE" "$TASK_TMP/children/alpha/meta" \
   && [ "$(cat "$TASK_TMP/children/alpha/paths")" = src ]; then
  ok "persists canonical parent, tab, worktree, and path bindings privately"
else
  not_ok "persists canonical parent, tab, worktree, and path bindings privately"
fi
if [ "$(git -C "$WORKTREE" status --porcelain)" = "" ] \
   && ! find "$WORKTREE" -name '*child*' -o -name 'report.md' | grep -q .; then
  ok "keeps child coordination and reports outside the repository"
else
  not_ok "keeps child coordination and reports outside the repository"
fi
if grep -Fq 'Runtime profile: harness=pi model=openai-codex/gpt-5.6-sol effort=xhigh' "$TASK_TMP/children/alpha/launch.md" \
   && grep -Fq -- '--model' "$FAKE_STATE/log" \
   && grep -Fq -- '--thinking' "$FAKE_STATE/log" \
   && grep -Fq "Read and follow the child brief at $TASK_TMP/children/alpha/launch.md." "$FAKE_STATE/log" \
   && ! grep -Fq 'You are a bounded child agent delegated' "$FAKE_STATE/log" \
   && grep -Fxq 'delivery_verdict=empty' "$TASK_TMP/children/alpha/startup.log"; then
  ok "inherits the Pi profile and submits only the short private-brief pointer"
else
  not_ok "inherits the Pi profile and submits only the short private-brief pointer"
fi

assert_failure_contains "rejects duplicate child names" "already exists" \
  run_parent create alpha --instructions "$INSTRUCTIONS" --path b.txt
assert_failure_contains "rejects overlapping ancestor path ownership" "overlaps child 'alpha'" \
  run_parent create overlap --instructions "$INSTRUCTIONS" --path src/one.txt
git -C "$WORKTREE" config core.ignorecase true
assert_failure_contains "rejects case-equivalent reserved Git ownership" "external, symlinked, globbed, or ambiguous" \
  run_parent create reserved-case --instructions "$INSTRUCTIONS" --path .GIT/config
assert_failure_contains "rejects case-equivalent ownership overlap" "overlaps child 'alpha'" \
  run_parent create overlap-case --instructions "$INSTRUCTIONS" --path SRC/one.txt
UNICODE_PANES_BEFORE=$(cat "$FAKE_STATE/panes")
UNICODE_SPLITS_BEFORE=$(grep -c 'CALL <pane> <split>' "$FAKE_STATE/log" || true)
assert_failure_contains "rejects incomparable Unicode ownership on case-insensitive filesystems" \
  "use an ASCII repository-relative ownership path" \
  run_parent create unicode-case --instructions "$INSTRUCTIONS" --path 'Å.txt'
UNICODE_SPLITS_AFTER=$(grep -c 'CALL <pane> <split>' "$FAKE_STATE/log" || true)
if [ ! -e "$TASK_TMP/children/unicode-case" ] \
   && [ "$(cat "$FAKE_STATE/panes")" = "$UNICODE_PANES_BEFORE" ] \
   && [ "$UNICODE_SPLITS_AFTER" -eq "$UNICODE_SPLITS_BEFORE" ]; then
  ok "Unicode refusal starts no child and publishes no private record"
else
  not_ok "Unicode refusal starts no child and publishes no private record"
fi
git -C "$WORKTREE" config core.ignorecase false
assert_failure_contains "rejects duplicate paths in one request" "supplied more than once" \
  run_parent create duplicate --instructions "$INSTRUCTIONS" --path b.txt --path b.txt
assert_failure_contains "rejects create without a path assignment" "at least one --path" \
  run_parent create missing --instructions "$INSTRUCTIONS"
assert_failure_contains "rejects absolute path ownership" "external, symlinked, globbed, or ambiguous" \
  run_parent create absolute --instructions "$INSTRUCTIONS" --path "$WORKTREE/b.txt"
assert_failure_contains "rejects glob path ownership" "external, symlinked, globbed, or ambiguous" \
  run_parent create glob --instructions "$INSTRUCTIONS" --path 'src/*'
ln -s a.txt "$WORKTREE/link.txt"
assert_failure_contains "rejects symlink path ownership" "external, symlinked, globbed, or ambiguous" \
  run_parent create symlink --instructions "$INSTRUCTIONS" --path link.txt
rm "$WORKTREE/link.txt"
printf 'inside\n' > "$WORKTREE/instructions.md"
assert_failure_contains "rejects instruction files inside the repository" "outside the repository" \
  run_parent create inside --instructions "$WORKTREE/instructions.md" --path b.txt
rm "$WORKTREE/instructions.md"

assert_failure_contains "child callers cannot recurse through the helper" "child agents cannot create or manage" \
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FAKE_HERDR_STATE="$FAKE_STATE" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 HERDR_PANE_ID=p:parent FM_CHILD_AGENT=1 \
    "$ROOT/bin/fm-child.sh" list
assert_failure_contains "missing parent pane identity is refused" "current Herdr pane identity is missing" \
  env -u HERDR_PANE_ID FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FAKE_HERDR_STATE="$FAKE_STATE" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 \
    "$ROOT/bin/fm-child.sh" list
assert_failure_contains "another tab pane cannot claim this parent" "parent ownership is missing or ambiguous" \
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FAKE_HERDR_STATE="$FAKE_STATE" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" HERDR_ENV=1 HERDR_PANE_ID=p:other \
    "$ROOT/bin/fm-child.sh" list

cp "$STATE/$TASK_ID.meta" "$STATE/duplicate.meta"
assert_failure_contains "ambiguous parent metadata is refused" "missing or ambiguous" run_parent list
rm "$STATE/duplicate.meta"

printf 't:foreign\n' > "$FAKE_STATE/split-tab"
assert_failure_contains "a split response in another tab is refused" "did not return one exact pane" \
  run_parent create wrong-tab --instructions "$INSTRUCTIONS" --path b.txt
rm "$FAKE_STATE/split-tab"
if [ ! -e "$TASK_TMP/children/wrong-tab" ]; then
  ok "foreign-tab split never becomes a child record"
else
  not_ok "foreign-tab split never becomes a child record"
fi
printf 'p:parent\n' > "$FAKE_STATE/split-pane"
assert_failure_contains "a split response targeting the parent pane is refused" "did not return one exact pane" \
  run_parent create parent-target --instructions "$INSTRUCTIONS" --path b.txt
rm "$FAKE_STATE/split-pane"
if awk -F'|' '$1 == "p:parent" { found=1 } END { exit !found }' "$FAKE_STATE/panes"; then
  ok "parent pane survives a malicious parent-target split response"
else
  not_ok "parent pane survives a malicious parent-target split response"
fi

assert_failure_contains "a child report is required before completion" "write the private child report" \
  env FM_CHILD_AGENT=1 FM_CHILD_NAME=alpha "$TASK_TMP/children/alpha/complete.sh" nope
printf '# Alpha report\n\nChanged a.txt. Checks passed.\n' > "$TASK_TMP/children/alpha/report.md"
assert_success "child records private completion after writing its report" \
  env FM_CHILD_AGENT=1 FM_CHILD_NAME=alpha "$TASK_TMP/children/alpha/complete.sh" "alpha complete"
assert_failure_contains "readiness refuses a completed but still-live child" "state=complete" run_parent ready
assert_success "stops one exact child without touching the parent" run_parent stop alpha
assert_success "readiness accepts a reported, completed, stopped child" run_parent ready
if run_parent inspect alpha >"$TMP/inspect" 2>"$TMP/err" \
   && grep -Fq 'state=complete-stopped' "$TMP/inspect" \
   && grep -Fq 'result=alpha complete' "$TMP/inspect"; then
  ok "inspect reports deterministic stopped completion state"
else
  not_ok "inspect reports deterministic stopped completion state"
fi

CHILD_BIN="$TASK_TMP/children/alpha/bin"
assert_success "child Git guard permits read-only status" \
  env PATH="$CHILD_BIN:$ORIGINAL_PATH" git -C "$WORKTREE" status --short
assert_failure_contains "child Git guard blocks staging" "parent owns every Git mutation" \
  env PATH="$CHILD_BIN:$ORIGINAL_PATH" git -C "$WORKTREE" add a.txt
assert_failure_contains "child no-mistakes guard blocks final validation" "final exact-head validation belongs to the parent" \
  env PATH="$CHILD_BIN:$ORIGINAL_PATH" no-mistakes axi run
assert_failure_contains "child publication guard blocks PR operations" "parent owns them" \
  env PATH="$CHILD_BIN:$ORIGINAL_PATH" gh-axi pr create

assert_success "cleanup removes stopped private records without changing shared files" run_parent cleanup
if [ ! -e "$TASK_TMP/children" ] && grep -Fxq base "$WORKTREE/a.txt"; then
  ok "cleanup preserves the shared working copy"
else
  not_ok "cleanup preserves the shared working copy"
fi

git -C "$WORKTREE" config core.ignorecase true
assert_success "accepts ASCII ownership on a case-insensitive filesystem" \
  run_parent create ascii-case --instructions "$INSTRUCTIONS" --path Docs/Guide.txt
assert_success "stops the ASCII case-insensitive child" run_parent stop ascii-case
assert_success "cleans the ASCII case-insensitive child" run_parent cleanup
git -C "$WORKTREE" config core.ignorecase false
COMPOSED_PATH=$(printf '\303\251.txt')
DECOMPOSED_PATH=$(printf 'e\314\201.txt')
NORMALIZATION_PANES_BEFORE=$(cat "$FAKE_STATE/panes")
NORMALIZATION_SPLITS_BEFORE=$(grep -c 'CALL <pane> <split>' "$FAKE_STATE/log" || true)
assert_failure_contains "rejects composed Unicode when case sensitivity cannot prove normalization identity" \
  "exact Unicode filesystem equivalence is not proven" \
  run_parent create unicode-composed --instructions "$INSTRUCTIONS" --path "$COMPOSED_PATH"
assert_failure_contains "rejects decomposed Unicode when case sensitivity cannot prove normalization identity" \
  "exact Unicode filesystem equivalence is not proven" \
  run_parent create unicode-decomposed --instructions "$INSTRUCTIONS" --path "$DECOMPOSED_PATH"
NORMALIZATION_SPLITS_AFTER=$(grep -c 'CALL <pane> <split>' "$FAKE_STATE/log" || true)
if [ ! -e "$TASK_TMP/children/unicode-composed" ] \
   && [ ! -e "$TASK_TMP/children/unicode-decomposed" ] \
   && [ "$(cat "$FAKE_STATE/panes")" = "$NORMALIZATION_PANES_BEFORE" ] \
   && [ "$NORMALIZATION_SPLITS_AFTER" -eq "$NORMALIZATION_SPLITS_BEFORE" ]; then
  ok "normalization-variant refusals start no child and publish no private record"
else
  not_ok "normalization-variant refusals start no child and publish no private record"
fi

touch "$FAKE_STATE/pause-split"
run_parent create readiness-race --instructions "$INSTRUCTIONS" --path b.txt >"$TMP/create-race.out" 2>"$TMP/create-race.err" &
CREATE_RACE_PID=$!
for _ in $(seq 1 100); do
  [ -f "$FAKE_STATE/split-entered" ] && break
  kill -0 "$CREATE_RACE_PID" 2>/dev/null || break
  sleep 0.02
done
if [ -f "$FAKE_STATE/split-entered" ]; then
  run_parent ready >"$TMP/ready-race.out" 2>"$TMP/ready-race.err" &
  READY_RACE_PID=$!
  for _ in $(seq 1 20); do
    kill -0 "$READY_RACE_PID" 2>/dev/null || break
    sleep 0.02
  done
  if kill -0 "$READY_RACE_PID" 2>/dev/null; then
    ok "readiness waits behind concurrent child creation"
  else
    not_ok "readiness waits behind concurrent child creation"
  fi
  rm -f "$FAKE_STATE/pause-split"
  if wait "$CREATE_RACE_PID"; then
    ok "concurrent child creation completes after releasing its lifecycle lock"
  else
    not_ok "concurrent child creation completes after releasing its lifecycle lock"
    sed 's/^/  /' "$TMP/create-race.err" >&2
  fi
  if wait "$READY_RACE_PID"; then
    not_ok "readiness inspects the child created while it waited"
  elif grep -Fq 'state=running:' "$TMP/ready-race.err"; then
    ok "readiness inspects the child created while it waited"
  else
    not_ok "readiness inspects the child created while it waited"
    sed 's/^/  /' "$TMP/ready-race.err" >&2
  fi
else
  not_ok "concurrent create reached the locked split boundary"
  rm -f "$FAKE_STATE/pause-split"
  wait "$CREATE_RACE_PID" 2>/dev/null || true
fi
assert_success "cleanup reconciles the readiness race child" run_parent cleanup

assert_success "creates child allowed to replace its owned file with a symlink" \
  run_parent create symlink-edit --instructions "$INSTRUCTIONS" --path d.txt
rm "$WORKTREE/d.txt"
ln -s a.txt "$WORKTREE/d.txt"
assert_success "lifecycle can stop a child after its owned path becomes a symlink" \
  run_parent stop symlink-edit
assert_success "cleanup remains deterministic after an owned symlink edit" run_parent cleanup
rm "$WORKTREE/d.txt"
git -C "$WORKTREE" checkout -- d.txt

touch "$FAKE_STATE/send-pending"
assert_failure_contains "unconfirmed shared delivery verdict refuses child startup" "verdict=pending" \
  run_parent create pending --instructions "$INSTRUCTIONS" --path d.txt
rm "$FAKE_STATE/send-pending"
if grep -Fxq 'submit_baseline_raw=idle' "$TASK_TMP/children/pending/startup.log" \
   && grep -Fxq 'delivery_verdict=pending' "$TASK_TMP/children/pending/startup.log" \
   && grep -Fq 'sanitized_composer_capture:' "$TASK_TMP/children/pending/startup.log" \
   && grep -Fq 'bounded child pane output' "$TASK_TMP/children/pending/startup.log"; then
  ok "failed delivery preserves raw baseline, exact verdict, and sanitized composer evidence privately"
else
  not_ok "failed delivery preserves raw baseline, exact verdict, and sanitized composer evidence privately"
fi
assert_success "cleanup reconciles the refused delivery record" run_parent cleanup

# Verify the existing runtime adapter rules are reused for every supported
# harness while model and effort remain visible in each private launch brief.
for profile in \
  'claude|claude-sonnet-4-5|high|claude|--dangerously-skip-permissions|--effort|esc to interrupt' \
  'codex|gpt-5.4|xhigh|codex|--dangerously-bypass-approvals-and-sandbox|model_reasoning_effort|esc to interrupt' \
  'opencode|anthropic/claude-sonnet-4-5|high|opencode|--model|Runtime profile:|esc interrupt' \
  'pi|openai-codex/gpt-5.6-sol|xhigh|pi|--approve|--thinking|Working...' \
  'pi-signed|openai-codex/gpt-5.6-sol|xhigh|pi|<pane> <run>|FM_PI_HARNESS=pi-signed|Working...' \
  'grok|grok-code-fast-1|high|grok|--always-approve|--reasoning-effort|Ctrl+c:cancel' \
  'kimi|kimi-for-coding|high|kimi|--auto|Runtime profile:|🌒 · working'
do
  IFS='|' read -r harness model effort agent needle1 needle2 busy_signature <<ROW
$profile
ROW
  set_profile "$harness" "$model" "$effort" "$agent"
  : > "$FAKE_STATE/log"
  if run_parent create profile --instructions "$INSTRUCTIONS" --path c.txt >"$TMP/out" 2>"$TMP/err" \
     && grep -Fq -- "$needle1" "$FAKE_STATE/log" \
     && { grep -Fq -- "$needle2" "$FAKE_STATE/log" || grep -Fq -- "$needle2" "$TASK_TMP/children/profile/launch.md"; } \
     && grep -Fq "Runtime profile: harness=$harness model=$model effort=$effort" "$TASK_TMP/children/profile/launch.md"; then
    ok "inherits existing $harness launch, model, and effort semantics"
  else
    not_ok "inherits existing $harness launch, model, and effort semantics"
    sed 's/^/  /' "$TMP/err" >&2
    sed 's/^/  /' "$FAKE_STATE/log" >&2
  fi
  run_parent cleanup >/dev/null 2>&1 || not_ok "cleanup after $harness profile"

  touch "$FAKE_STATE/send-pending"
  printf '%s\n' "$busy_signature" > "$FAKE_STATE/pane-output"
  if run_parent create corroborated --instructions "$INSTRUCTIONS" --path c.txt >"$TMP/out" 2>"$TMP/err" \
     && grep -Fxq 'delivery_verdict=pending' "$TASK_TMP/children/corroborated/startup.log" \
     && grep -Fq "pending_corroboration=busy-signature agent=$agent harness=$harness" "$TASK_TMP/children/corroborated/startup.log"; then
    ok "pending $harness delivery accepts only its verified busy signature and matching agent"
  else
    not_ok "pending $harness delivery accepts only its verified busy signature and matching agent"
    sed 's/^/  /' "$TMP/err" >&2
  fi
  run_parent cleanup >/dev/null 2>&1 || not_ok "cleanup after corroborated $harness delivery"

  printf 'ordinary idle output\n' > "$FAKE_STATE/pane-output"
  assert_failure_contains "pending $harness delivery without its busy signature is refused" \
    "verdict=pending" run_parent create uncorroborated --instructions "$INSTRUCTIONS" --path c.txt
  if grep -Fq "pending_corroboration=no-busy-signature agent=$agent harness=$harness" \
      "$TASK_TMP/children/uncorroborated/startup.log"; then
    ok "pending $harness refusal records the routed no-busy evidence"
  else
    not_ok "pending $harness refusal records the routed no-busy evidence"
  fi
  run_parent cleanup >/dev/null 2>&1 || not_ok "cleanup after uncorroborated $harness delivery"
  rm -f "$FAKE_STATE/send-pending" "$FAKE_STATE/pane-output"
done

set_profile kimi kimi-for-coding high kimi
KIMI_FALLBACK_HOME="$TMP/kimi-home"
mkdir -p "$KIMI_FALLBACK_HOME/.kimi-code/bin"
mv "$FAKE_BIN/kimi" "$KIMI_FALLBACK_HOME/.kimi-code/bin/kimi"
: > "$FAKE_STATE/log"
if HOME="$KIMI_FALLBACK_HOME" run_parent create kimi-fallback --instructions "$INSTRUCTIONS" --path c.txt \
    >"$TMP/out" 2>"$TMP/err" \
   && grep -Fq "$KIMI_FALLBACK_HOME/.kimi-code/bin/kimi" "$FAKE_STATE/log"; then
  ok "child Kimi launch reuses the parent fallback binary resolution"
else
  not_ok "child Kimi launch reuses the parent fallback binary resolution"
  sed 's/^/  /' "$TMP/err" >&2
fi
assert_success "cleanup after Kimi fallback profile" run_parent cleanup
mv "$KIMI_FALLBACK_HOME/.kimi-code/bin/kimi" "$FAKE_BIN/kimi"

set_profile claude claude-sonnet-4-5 high claude
: > "$FAKE_STATE/log"
if CLAUDE_CONFIG_DIR="$TMP/claude-config" run_parent create claude-config --instructions "$INSTRUCTIONS" --path c.txt \
    >"$TMP/out" 2>"$TMP/err" \
   && grep -Fq "CLAUDE_CONFIG_DIR='$TMP/claude-config'" "$FAKE_STATE/log"; then
  ok "child Claude launch inherits the parent config directory"
else
  not_ok "child Claude launch inherits the parent config directory"
  sed 's/^/  /' "$TMP/err" >&2
fi
assert_success "cleanup after Claude config inheritance" run_parent cleanup

set_profile pi openai-codex/gpt-5.6-sol xhigh pi
touch "$FAKE_STATE/send-pending"
printf 'Working...\n' > "$FAKE_STATE/pane-output"
printf 'codex\n' > "$FAKE_STATE/corroboration-agent"
assert_failure_contains "pending busy signature refuses a mismatched registered child agent" \
  "verdict=pending" run_parent create mismatch --instructions "$INSTRUCTIONS" --path d.txt
if grep -Fq 'pending_corroboration=agent-mismatch expected=pi actual=codex' \
    "$TASK_TMP/children/mismatch/startup.log"; then
  ok "agent-mismatch refusal preserves exact expected and actual identities"
else
  not_ok "agent-mismatch refusal preserves exact expected and actual identities"
fi
assert_success "cleanup reconciles the agent-mismatch refusal" run_parent cleanup
rm -f "$FAKE_STATE/send-pending" "$FAKE_STATE/pane-output" "$FAKE_STATE/corroboration-agent"

set_profile pi openai-codex/gpt-5.6-sol xhigh pi
assert_success "creates first of three bounded live children" \
  run_parent create one --instructions "$INSTRUCTIONS" --path a.txt
assert_success "creates second disjoint bounded live child" \
  run_parent create two --instructions "$INSTRUCTIONS" --path b.txt
assert_success "creates third disjoint bounded live child" \
  run_parent create three --instructions "$INSTRUCTIONS" --path c.txt
assert_failure_contains "refuses a fourth concurrent child" "maximum of 3" \
  run_parent create four --instructions "$INSTRUCTIONS" --path d.txt

TWO_PANE=$(awk -F= '$1 == "child_pane_id" { print $2 }' "$TASK_TMP/children/two/meta")
awk -F'|' -v pane="$TWO_PANE" '$1 != pane' "$FAKE_STATE/panes" > "$FAKE_STATE/panes.tmp"
mv "$FAKE_STATE/panes.tmp" "$FAKE_STATE/panes"
awk -F'|' -v pane="$TWO_PANE" '$1 != pane' "$FAKE_STATE/agents" > "$FAKE_STATE/agents.tmp"
mv "$FAKE_STATE/agents.tmp" "$FAKE_STATE/agents"
if run_parent list >"$TMP/list" 2>"$TMP/err" && grep -Fq 'two state=dead' "$TMP/list"; then
  ok "list deterministically reconciles a disappeared child as dead"
else
  not_ok "list deterministically reconciles a disappeared child as dead"
fi
assert_success "stop is idempotent for an already-dead exact child" run_parent stop two
assert_success "parent cleanup stops remaining siblings and removes records" run_parent cleanup
if awk -F'|' '$1 == "p:parent" { parent=1 } $1 ~ /^p:child-/ && $3 == "t:task" { task_child=1 } END { exit !(parent && !task_child) }' "$FAKE_STATE/panes"; then
  ok "cleanup preserves the parent and removes only recorded same-tab child panes"
else
  not_ok "cleanup preserves the parent and removes only recorded same-tab child panes"
fi

# Teardown-only cleanup rejects malformed ownership instead of touching a pane.
assert_success "creates child used for malformed-record refusal" \
  run_parent create malformed --instructions "$INSTRUCTIONS" --path d.txt
printf 'parent_tab_id=t:foreign\n' >> "$TASK_TMP/children/malformed/meta"
assert_failure_contains "ambiguous child ownership refuses teardown cleanup" "malformed or belongs to another parent" \
  env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FAKE_HERDR_STATE="$FAKE_STATE" \
    PATH="$FAKE_BIN:$ORIGINAL_PATH" FM_CHILD_TEARDOWN=1 \
    "$ROOT/bin/fm-child.sh" cleanup "$TASK_ID"
if [ -d "$TASK_TMP/children/malformed" ]; then
  ok "refused cleanup preserves malformed private evidence"
else
  not_ok "refused cleanup preserves malformed private evidence"
fi

# Restore the intentionally malformed record, then prove normal task teardown
# quiesces children and retires their private records before returning the
# shared working copy, without resetting shared edits.
grep -v '^parent_tab_id=t:foreign$' "$TASK_TMP/children/malformed/meta" > "$TMP/meta.fixed"
mv "$TMP/meta.fixed" "$TASK_TMP/children/malformed/meta"
assert_success "cleanup succeeds after malformed child ownership is repaired" run_parent cleanup
assert_success "creates child used for task teardown ordering" \
  run_parent create teardown-child --instructions "$INSTRUCTIONS" --path d.txt
printf 'shared-child-edit\n' >> "$WORKTREE/d.txt"
cat > "$FAKE_BIN/treehouse" <<'EOF'
#!/usr/bin/env bash
set -u
state=${FAKE_HERDR_STATE:?}
child_root=${FM_TEARDOWN_CHILD_ROOT:?}
worktree=${FM_TEARDOWN_WORKTREE:?}
if awk -F'|' '$1 ~ /^p:child-/ && $3 == "t:task" { found=1 } END { exit !found }' "$state/panes"; then
  echo 'treehouse observed a live child pane' >&2
  exit 70
fi
[ ! -e "$child_root" ] || { echo 'treehouse observed retained child records' >&2; exit 71; }
grep -Fxq 'shared-child-edit' "$worktree/d.txt" \
  || { echo 'treehouse observed discarded shared edits' >&2; exit 72; }
printf 'return-ready\n' >> "${FM_TEARDOWN_ORDER_LOG:?}"
exit 0
EOF
chmod +x "$FAKE_BIN/treehouse"
if env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT" \
    FAKE_HERDR_STATE="$FAKE_STATE" PATH="$FAKE_BIN:$ORIGINAL_PATH" \
    FM_GATE_REFUSE_BYPASS=1 FM_TEARDOWN_CHILD_ROOT="$TASK_TMP/children" \
    FM_TEARDOWN_WORKTREE="$WORKTREE" FM_TEARDOWN_ORDER_LOG="$TMP/teardown-order.log" \
    "$ROOT/bin/fm-teardown.sh" "$TASK_ID" --force >"$TMP/out" 2>"$TMP/err"; then
  ok "task teardown quiesces and cleans children before returning the working copy"
else
  not_ok "task teardown quiesces and cleans children before returning the working copy"
  sed 's/^/  /' "$TMP/err" >&2
fi
if grep -Fxq return-ready "$TMP/teardown-order.log" \
   && [ ! -e "$STATE/$TASK_ID.meta" ] \
   && [ ! -e "$TASK_TMP/children" ] \
   && grep -Fxq 'shared-child-edit' "$WORKTREE/d.txt"; then
  ok "teardown preserves shared edits while retiring exact child panes and private records"
else
  not_ok "teardown preserves shared edits while retiring exact child panes and private records"
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
