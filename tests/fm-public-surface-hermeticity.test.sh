#!/usr/bin/env bash
# Regression tests for the leak that put test fixtures in the captain's live
# Discord channel, and for the two shapes that must never reach a public
# thread: a progress acknowledgment and a routine blocked/failed status line.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY_STATUS="$ROOT/bin/fm-discord-notify-status.sh"
REAL_NODE=$(command -v node 2>/dev/null) || fail "node is required for the fake transport"
TMP_ROOT=$(fm_test_tmproot fm-public-surface-hermeticity)

# A fake node that records every outbound POST instead of reaching Discord, so
# the cases below assert on what WOULD have been sent without sending anything.
make_fake_node() {  # <home>
  local home=$1
  mkdir -p "$home/fake-bin"
  cat > "$home/fake-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec "$FM_TEST_REAL_NODE" --input-type=module -e '
  import { pathToFileURL } from "node:url";
  const [script, ...args] = process.argv.slice(1);
  process.argv = [process.argv[0], script, ...args];
  globalThis.fetch = async (url, options = {}) => {
    if (url === "https://discord.com/api/v10/users/@me") {
      return Response.json({ id: "9000000000000000001" });
    }
    if (url.includes("/messages") && options.method === "POST") {
      if (process.env.FM_DISCORD_FAKE_POST_LOG) {
        await import("node:fs/promises").then(({ appendFile }) =>
          appendFile(process.env.FM_DISCORD_FAKE_POST_LOG, JSON.stringify({ url, body: JSON.parse(options.body) }) + "\n"));
      }
      return Response.json({ id: "1352000000000000999", channel_id: "1000000000000000001" });
    }
    if (url.includes("/channels/") && url.includes("/messages")) return Response.json([]);
    return new Response("not found", { status: 404 });
  };
  await import(pathToFileURL(script).href);
' "$script" "$@"
SH
  chmod +x "$home/fake-bin/node"
  cat > "$home/fake-bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_DISCORD_FAKE_CREW_STATE:-state: done · source: fake}"
SH
  chmod +x "$home/fake-bin/fm-crew-state.sh"
}

# The leak itself: the notifier resolves its credentials from FM_HOME, and
# FM_HOME falls back to the code root when a suite sets only FM_STATE_OVERRIDE.
# Run from the primary checkout that root's .env holds the real bot token, so a
# status fixture a test wrote became a real public post. The fix is that every
# suite pins FM_HOME to a credential-free case home; this asserts that pinning is
# sufficient, and that the send path is genuinely live, so a silent pass can
# never be mistaken for a broken case.
test_status_override_alone_cannot_post_with_ambient_home_credentials() {
  local home posts
  home="$TMP_ROOT/ambient-home"
  mkdir -p "$home/state"
  make_fake_node "$home"
  # Control: an explicitly configured home does post, so the negative assertion
  # below is about scoping rather than a send path that is quietly dead.
  posts="$home/posts.jsonl"
  : > "$posts"
  FM_TEST_REAL_NODE="$REAL_NODE" FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    "$NOTIFY_STATUS" task-a 'done: fixture-shaped completion' >/dev/null 2>&1
  assert_equals "1" "$(wc -l < "$posts" | tr -d '[:space:]')" \
    "control: a configured home does post, so the negative case is meaningful"
  # The same fixture against a credential-free home, state override still set:
  # nothing is sent. This is the shape every suite now uses.
  local bare="$TMP_ROOT/credential-free"
  mkdir -p "$bare/state"
  make_fake_node "$bare"
  posts="$bare/posts.jsonl"
  : > "$posts"
  FM_TEST_REAL_NODE="$REAL_NODE" FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$bare/fake-bin:$PATH" FM_HOME="$bare" FM_STATE_OVERRIDE="$bare/state" \
    FM_CREW_STATE_BIN="$bare/fake-bin/fm-crew-state.sh" \
    "$NOTIFY_STATUS" task-a 'done: fixture-shaped completion' >/dev/null 2>&1
  [ ! -s "$posts" ] \
    || fail "a credential-free home still delivered a status fixture: $(cat "$posts")"
  pass "a status fixture posts nothing unless its own home carries a credential"
}


# The library is what 200 suites inherit, so the credential scrub has to live
# there rather than in whichever suite happened to leak first.
test_library_scrubs_public_credentials() {
  local out
  out=$(FM_DISCORD_BOT_TOKEN=leaked FM_DISCORD_TOKEN=leaked FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    FMX_PAIRING_TOKEN=leaked FMX_ENV_FILE=/leaked/.env FMX_DRY_RUN=1 \
    bash -c '. "$1"; for v in FM_DISCORD_BOT_TOKEN FM_DISCORD_TOKEN FM_DISCORD_CHANNEL_ID FMX_PAIRING_TOKEN FMX_ENV_FILE FMX_DRY_RUN; do printf "%s=%s\n" "$v" "${!v-<unset>}"; done' \
    _ "$ROOT/tests/lib.sh")
  assert_contains "$out" "FM_DISCORD_BOT_TOKEN=<unset>" "the library must clear the Discord token"
  assert_contains "$out" "FM_DISCORD_TOKEN=<unset>" "the library must clear the Discord token alias"
  assert_contains "$out" "FM_DISCORD_CHANNEL_ID=<unset>" "the library must clear the Discord channel"
  assert_contains "$out" "FMX_PAIRING_TOKEN=<unset>" "the library must clear the Relay pairing token"
  assert_contains "$out" "FMX_ENV_FILE=<unset>" "the library must clear an env-file redirect"
  assert_contains "$out" "FMX_DRY_RUN=<unset>" "the library must clear the dry-run flag"
  pass "the shared test library scrubs every public-surface credential"
}

# An operator may launch the suite with FM_HOME pointing at a real home whose
# .env contains live credentials.  Sourcing the library must replace that home
# before any production script can discover it, while keeping the fake outbound
# transport as the proof that a post would have been observable.
test_library_replaces_hostile_ambient_home() {
  local hostile posts
  hostile="$TMP_ROOT/hostile-ambient-home"
  posts="$hostile/posts.jsonl"
  mkdir -p "$hostile/state"
  make_fake_node "$hostile"
  cat > "$hostile/.env" <<'EOF'
FM_DISCORD_BOT_TOKEN=ambient-live-shaped-token
FM_DISCORD_CHANNEL_ID=1000000000000000001
EOF
  : > "$posts"

  FM_HOME="$hostile" FM_TEST_REAL_NODE="$REAL_NODE" \
    FM_DISCORD_FAKE_POST_LOG="$posts" PATH="$hostile/fake-bin:$PATH" \
    FM_CREW_STATE_BIN="$hostile/fake-bin/fm-crew-state.sh" \
    ROOT="$ROOT" NOTIFY_STATUS="$NOTIFY_STATUS" \
    bash -c '
      . "$ROOT/tests/lib.sh"
      [ "$FM_HOME" != "$1" ] || exit 91
      [ -f "$FM_HOME/.env" ] && [ ! -s "$FM_HOME/.env" ] || exit 92
      "$NOTIFY_STATUS" task-a "done: hostile inherited home fixture" >/dev/null 2>&1
    ' _ "$hostile" || fail "the shared library did not replace the hostile ambient home"

  [ ! -s "$posts" ] \
    || fail "a hostile ambient home produced a public post: $(cat "$posts")"
  pass "the shared library replaces a hostile ambient home before notification code runs"
}

# The captain's actual complaint, asserted directly: a routine blocker and a
# routine failure are not things they need to act on, so they never arrive.
test_routine_status_shapes_never_post() {
  local home posts line
  home="$TMP_ROOT/routine-shapes"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  for line in \
    'blocked: need release access' \
    'blocked [key=access]: need release access' \
    'failed: crew c3 hit an unrecoverable migration error' \
    'failed: build script exited 1' \
    'working: compiling step 2' \
    'paused: waiting for an upstream release' \
    'note: cache pruned' \
    'blocked: pending-reply-missed: task=task pending-reply-id=0123456789abcdef request=finish report'; do
    posts="$home/$(printf '%s' "$line" | shasum -a 256 | cut -c1-12).jsonl"
    : > "$posts"
    FM_TEST_REAL_NODE="$REAL_NODE" FM_DISCORD_FAKE_POST_LOG="$posts" \
      PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
      FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
      "$NOTIFY_STATUS" task-a "$line" >/dev/null 2>&1
    [ ! -s "$posts" ] || fail "a routine status line reached Discord: $line"
  done
  pass "routine blocked, failed, working, paused, and note lines never post"
}

# The two shapes that DO have a place: a real captain-only decision, and a
# verified terminal completion. Suppressing the noise must not silence these.
test_genuine_decision_and_completion_still_post() {
  local home posts
  home="$TMP_ROOT/genuine"
  mkdir -p "$home/state/x-context"
  chmod 700 "$home/state" "$home/state/x-context"
  make_fake_node "$home"
  posts="$home/posts.jsonl"
  FM_TEST_REAL_NODE="$REAL_NODE" FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$NOTIFY_STATUS" task-a \
      'needs-decision [key=pr-ready-task-a]: task=task-a yolo=off pull request ready: https://github.com/acme/app/pull/42 choose merge or leave open' \
    >/dev/null 2>&1 || fail "a genuine decision failed to classify"
  assert_contains "$(cat "$posts")" "필요한 결정" "a captain-only decision must still reach Discord"
  FM_TEST_REAL_NODE="$REAL_NODE" FM_DISCORD_FAKE_POST_LOG="$posts" \
    PATH="$home/fake-bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fake-bin/fm-crew-state.sh" \
    FM_DISCORD_BOT_TOKEN=fake-token FM_DISCORD_CHANNEL_ID=1000000000000000001 \
    "$NOTIFY_STATUS" task-b 'done: the migration finished and the release is published' \
    >/dev/null 2>&1 || fail "a genuine completion failed to classify"
  assert_contains "$(cat "$posts")" "작업 완료" "a verified completion must still reach Discord"
  assert_equals "2" "$(wc -l < "$posts" | tr -d '[:space:]')" \
    "only the decision and the completion should have posted"
  pass "a captain-only decision and a verified completion still reach Discord"
}

test_status_override_alone_cannot_post_with_ambient_home_credentials
test_library_scrubs_public_credentials
test_library_replaces_hostile_ambient_home
test_routine_status_shapes_never_post
test_genuine_decision_and_completion_still_post
