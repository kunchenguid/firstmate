#!/usr/bin/env bash
# Portable behavior coverage for scoped Codex trust and fail-closed spawns.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-trust)
TRUST="$ROOT/bin/fm-codex-trust.sh"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/worktree"
CONFIG="$TMP_ROOT/codex"
mkdir -p "$CONFIG" "$TMP_ROOT/bin"
fm_test_fake_codex_config "$TMP_ROOT/bin"
export PATH="$TMP_ROOT/bin:$PATH"
fm_git_worktree "$PROJ" "$WT" codex-trust
run_trust() { CODEX_HOME="$CONFIG" "$TRUST" "$@" 2>&1; }
assert_trusted() {
  node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.exit(j.projects[process.argv[2]].trust_level === "trusted" ? 0 : 1)' "$CONFIG/config.toml" "$1"
}
run_trust "$WT" "$PROJ" >/dev/null || fail 'fresh registration failed'
assert_trusted "$WT" || fail 'worktree was not trusted'
cp "$CONFIG/config.toml" "$TMP_ROOT/before"
run_trust "$WT" "$PROJ" >/dev/null || fail 'repeat registration failed'
cmp -s "$CONFIG/config.toml" "$TMP_ROOT/before" || fail 'repeat changed the store'
pass 'fresh worktree trust is idempotent'

printf '%s\n' '{"model":"example","projects":{"/elsewhere":{"trust_level":"untrusted"}}}' > "$CONFIG/config.toml"
run_trust "$WT" "$PROJ" >/dev/null || fail 'preserving registration failed'
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(j.model!=="example"||j.projects["/elsewhere"].trust_level!=="untrusted")process.exit(1)' "$CONFIG/config.toml"
expect_code 0 $? 'unrelated configuration changed'
pass 'existing configuration is preserved'

mkdir -p "$WT/subdir" "$TMP_ROOT/plain"
for target in "$PROJ" "$WT/subdir" "$TMP_ROOT/plain" "$TMP_ROOT/missing"; do
  out=$(run_trust "$target" "$PROJ")
  expect_code 1 $? "out-of-scope path accepted: $target: $out"
done
fm_git_worktree "$TMP_ROOT/unrelated" "$TMP_ROOT/unrelated-wt" unrelated
out=$(run_trust "$TMP_ROOT/unrelated-wt" "$PROJ")
expect_code 1 $? "unrelated worktree accepted: $out"
pass 'primary checkout, subdirectories and unrelated paths are refused'

for content in 'broken = [' "{\"projects\":{\"$WT\":{\"trust_level\":\"untrusted\"}}}"; do
  printf '%s\n' "$content" > "$CONFIG/config.toml"
  cp "$CONFIG/config.toml" "$TMP_ROOT/before"
  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "unsafe store accepted: $out"
  cmp -s "$CONFIG/config.toml" "$TMP_ROOT/before" || fail 'refusal changed the store'
done
rm "$CONFIG/config.toml"
ln -s "$TMP_ROOT/before" "$CONFIG/config.toml"
out=$(run_trust "$WT" "$PROJ")
expect_code 1 $? "symlinked store accepted: $out"
rm "$CONFIG/config.toml"
out=$(CODEX_HOME=relative "$TRUST" "$WT" "$PROJ" 2>&1)
expect_code 1 $? "relative CODEX_HOME accepted: $out"
pass 'malformed, declined, symlinked and ambiguous stores fail closed'

# The vendor's optimistic version contract detects a concurrent edit; a fresh
# read retries it, and an edit that keeps racing past the bound is refused.
printf '%s\n' '{"operator_setting":true}' > "$CONFIG/config.toml"
out=$(FM_TEST_CODEX_CONFIG_CONFLICT=2 run_trust "$WT" "$PROJ")
expect_code 0 $? "a conflict that cleared on retry was refused: $out"
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!j.operator_setting||j.concurrent_setting!==2)process.exit(1)' "$CONFIG/config.toml"
expect_code 0 $? 'retried registration lost concurrent changes'
assert_trusted "$WT" || fail 'retried registration did not record trust'
pass 'a version conflict that clears is retried and retains concurrent changes'

printf '%s\n' '{"operator_setting":true}' > "$CONFIG/config.toml"
out=$(FM_TEST_CODEX_CONFIG_CONFLICT=3 run_trust "$WT" "$PROJ")
expect_code 1 $? "a persistent concurrent edit was overwritten: $out"
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!j.operator_setting||j.concurrent_setting!==3||j.projects)process.exit(1)' "$CONFIG/config.toml"
expect_code 0 $? 'version conflict lost configuration or recorded trust'
pass 'a version conflict past the bound refuses registration and retains concurrent changes'

# Real Codex can acknowledge a write that a concurrent replace then drops; the
# next read notices, and the write is retried within the same bound.
printf '%s\n' '{"operator_setting":true}' > "$CONFIG/config.toml"
out=$(FM_TEST_CODEX_CONFIG_LOST=2 run_trust "$WT" "$PROJ")
expect_code 0 $? "a lost write that cleared on retry was refused: $out"
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!j.operator_setting||j.concurrent_setting!==2)process.exit(1)' "$CONFIG/config.toml"
expect_code 0 $? 'retried lost write dropped concurrent changes'
assert_trusted "$WT" || fail 'retried lost write did not record trust'
pass 'an acknowledged write lost to a concurrent replace is retried'

printf '%s\n' '{"operator_setting":true}' > "$CONFIG/config.toml"
out=$(FM_TEST_CODEX_CONFIG_LOST=3 run_trust "$WT" "$PROJ")
expect_code 1 $? "a write lost past the bound was reported trusted: $out"
node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(!j.operator_setting||j.concurrent_setting!==3||j.projects)process.exit(1)' "$CONFIG/config.toml"
expect_code 0 $? 'lost write past the bound changed configuration or recorded trust'
pass 'a write lost past the bound refuses registration'

# A server that ignores SIGTERM after the verdict must not keep the refusal waiting.
printf 'broken = [\n' > "$CONFIG/config.toml"
FM_TEST_CODEX_CONFIG_STALL="$TMP_ROOT/stall.pid" run_trust "$WT" "$PROJ" > "$TMP_ROOT/stall.out" &
helper=$!
for _ in $(seq 1 100); do kill -0 "$helper" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$helper" 2>/dev/null; then
  kill -9 "$helper" "$(cat "$TMP_ROOT/stall.pid")" 2>/dev/null
  fail 'helper hung on a server that stalled during shutdown'
fi
wait "$helper"
expect_code 1 $? "stalled server refusal lost: $(cat "$TMP_ROOT/stall.out")"
kill -0 "$(cat "$TMP_ROOT/stall.pid")" 2>/dev/null && fail 'stalled server was left running'
rm "$CONFIG/config.toml"
pass 'a server stalled on shutdown is killed and the refusal still returns'

home="$TMP_ROOT/secondmate"
fm_git_init_commit "$home"
mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
printf 'contract\n' > "$home/AGENTS.md"
printf 'mate-n1\n' > "$home/.fm-secondmate-home"
run_trust --secondmate-home "$home" mate-n1 >/dev/null || fail 'seeded home refused'
assert_trusted "$home" || fail 'seeded home not trusted'
out=$(run_trust --secondmate-home "$home" wrong-n1)
expect_code 1 $? "another secondmate accepted: $out"
pass 'only the named seeded secondmate home is eligible'

spawn_home="$TMP_ROOT/spawn-home"
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$spawn_home" codex
fm_test_spawn_brief "$spawn_home" trustspawn
launchlog="$TMP_ROOT/launch.log"
out=$(FM_TEST_CODEX_HOME="$CONFIG" FM_FAKE_LAUNCH_LOG="$launchlog" \
  fm_test_run_spawn "$spawn_home" "$WT" "$fakebin" trustspawn "$PROJ" codex --mode no-mistakes --yolo off)
expect_code 0 $? "Codex spawn failed: $out"
assert_grep "CODEX_HOME='$CONFIG'" "$launchlog" 'launch reads a different trust store'
pass 'spawn registers trust and forwards the same CODEX_HOME'
rm "$launchlog"
fm_test_spawn_brief "$spawn_home" refusedspawn
printf 'broken = [\n' > "$CONFIG/config.toml"
out=$(FM_TEST_CODEX_HOME="$CONFIG" FM_FAKE_LAUNCH_LOG="$launchlog" \
  fm_test_run_spawn "$spawn_home" "$WT" "$fakebin" refusedspawn "$PROJ" codex --mode no-mistakes --yolo off)
expect_code 1 $? "spawn launched with unrecordable trust: $out"
assert_contains "$out" 'could not pre-register Codex workspace trust' 'missing refusal diagnostic'
assert_absent "$launchlog" 'refused spawn launched a worker'
pass 'spawn refuses before launching when trust registration fails'
echo '# all fm-codex-trust checks passed'
