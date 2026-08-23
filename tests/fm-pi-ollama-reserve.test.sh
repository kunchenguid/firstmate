#!/usr/bin/env bash
# Behavior tests for the Ollama Cloud reserve segment on a Pi worker's footer.
#
# Two layers, both through public interfaces and never through implementation
# source bytes:
#   1. .pi/extensions/lib/fm-ollama-reserve.ts driven directly in a plain Node
#      host, covering every reading the probe file can present.
#   2. The REAL fm-spawn against a fake tmux pane, then the extension artifact
#      it generates driven in a plain Node host with a recording Pi context, so
#      the interpolated probe path, the lazy module load, and the published
#      footer entry are exercised together with no live harness session.
#
# Live evidence that ctx.ui.setStatus APPENDS a footer line rather than
# replacing Pi's own cwd, branch, context, tokens, and model segments is
# recorded in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
MODULE="$ROOT/.pi/extensions/lib/fm-ollama-reserve.ts"
TMP_ROOT=$(fm_test_tmproot fm-pi-ollama-reserve)

require_node() {  # <context>
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for $1"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- module layer

drive_module() {  # stdin: driver body, run with MODULE_PATH exported
  MODULE_PATH="$MODULE" node --input-type=module 2>&1
}

test_module_reports_the_tightest_window_and_never_overstates_it() {
  require_node "the Ollama reserve module test" || return 0
  local out
  out=$(drive_module <<'JS'
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.MODULE_PATH).href);
const now = Date.UTC(2026, 7, 20, 12, 0, 0);
const read = (session, weekly) =>
  m.parseOllamaReserve(
    JSON.stringify({
      fetched_at: "2026-08-20T12:00:00Z",
      session_free: session,
      weekly_free: weekly,
    }),
    now,
  );

const check = (label, got, wantKind, wantValue) => {
  if (got.kind !== wantKind) throw new Error(label + ": kind " + got.kind + " != " + wantKind);
  const value = got.kind === "known" ? got.freePercent : got.reason;
  if (value !== wantValue) throw new Error(label + ": " + value + " != " + wantValue);
};

// The tighter of the two windows is the one that actually stops work.
check("session tighter", read(0.851, 0.924), "known", 85);
check("weekly tighter", read(0.924, 0.851), "known", 85);
// Floored, never rounded up: a reserve must not be reported larger than it is.
check("floor not round", read(0.859, 0.999), "known", 85);
check("floor at boundary", read(0.9999, 0.9999), "known", 99);
// An over-limit account clamps instead of rendering a negative reserve.
check("clamped low", read(-0.2, 0.5), "known", 0);
check("empty reserve", read(0, 0.5), "known", 0);
check("full reserve", read(1, 1), "known", 100);

// The rendered text stays compact; the footer line is already dense.
const text = m.formatOllamaReserve(read(0.851, 0.924));
if (text !== "olla 85%") throw new Error('rendered "' + text + '"');
console.log("OK");
JS
)
  [ "$out" = "OK" ] || fail "the reserve is not the floored tightest window: $out"
  pass "the reserve is the floored tightest of the two windows and renders compactly"
}

test_module_refuses_to_present_an_untrustworthy_reading_as_current() {
  require_node "the Ollama reserve staleness test" || return 0
  local out
  out=$(drive_module <<'JS'
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.MODULE_PATH).href);
const now = Date.UTC(2026, 7, 20, 12, 0, 0);
const hour = 60 * 60 * 1000;
const at = (offsetMs) => new Date(now + offsetMs).toISOString().replace(/\.\d+Z$/, "Z");
const read = (stamp) =>
  m.parseOllamaReserve(
    JSON.stringify({ fetched_at: stamp, session_free: 0.851, weekly_free: 0.924 }),
    now,
  );

const expect = (label, got, wantKind, wantReason) => {
  if (got.kind !== wantKind) throw new Error(label + ": kind " + got.kind + " != " + wantKind);
  if (wantReason !== undefined && got.reason !== wantReason) {
    throw new Error(label + ": reason " + got.reason + " != " + wantReason);
  }
};

// Inside the shelf life the number is presented; past it, never.
expect("just inside", read(at(-hour + 1000)), "known");
expect("just outside", read(at(-hour - 1000)), "unknown", "stale");
expect("long stale", read(at(-9 * hour)), "unknown", "stale");
// A reading stamped in the future is a clock disagreement, not freshness:
// trusting it would let an arbitrarily old number look current forever.
expect("far future", read(at(9 * hour)), "unknown", "stale");

// Nothing usable is ever guessed at.
expect("absent file", m.parseOllamaReserve(null, now), "unknown", "absent");
expect("not json", m.parseOllamaReserve("{not json", now), "unknown", "malformed");
expect("not an object", m.parseOllamaReserve("42", now), "unknown", "malformed");
expect("null payload", m.parseOllamaReserve("null", now), "unknown", "malformed");
expect(
  "no timestamp",
  m.parseOllamaReserve(JSON.stringify({ session_free: 0.5, weekly_free: 0.5 }), now),
  "unknown",
  "malformed",
);
expect(
  "unparseable timestamp",
  m.parseOllamaReserve(
    JSON.stringify({ fetched_at: "whenever", session_free: 0.5, weekly_free: 0.5 }),
    now,
  ),
  "unknown",
  "malformed",
);
expect(
  "missing weekly",
  m.parseOllamaReserve(JSON.stringify({ fetched_at: at(0), session_free: 0.5 }), now),
  "unknown",
  "malformed",
);
expect(
  "string fraction",
  m.parseOllamaReserve(
    JSON.stringify({ fetched_at: at(0), session_free: "0.5", weekly_free: 0.5 }),
    now,
  ),
  "unknown",
  "malformed",
);
expect(
  "null fraction",
  m.parseOllamaReserve(
    JSON.stringify({ fetched_at: at(0), session_free: null, weekly_free: 0.5 }),
    now,
  ),
  "unknown",
  "malformed",
);

// Every untrustworthy reading renders as an explicit unknown, never a figure.
for (const reserve of [
  m.parseOllamaReserve(null, now),
  read(at(-9 * hour)),
  m.parseOllamaReserve("{not json", now),
]) {
  const text = m.formatOllamaReserve(reserve);
  if (text !== "olla ?") throw new Error('unknown rendered as "' + text + '"');
  if (/[0-9]/.test(text)) throw new Error('unknown rendered a digit: "' + text + '"');
}
console.log("OK");
JS
)
  [ "$out" = "OK" ] || fail "an untrustworthy reading is not rendered as an explicit unknown: $out"
  pass "absent, malformed, stale, and future-stamped readings render as an explicit unknown"
}

test_module_reader_never_throws_on_a_failing_read() {
  require_node "the Ollama reserve reader test" || return 0
  local out
  out=$(drive_module <<'JS'
import { pathToFileURL } from "node:url";
const m = await import(pathToFileURL(process.env.MODULE_PATH).href);
const now = Date.UTC(2026, 7, 20, 12, 0, 0);
const raising = (code) => () => {
  const error = new Error("boom");
  if (code) error.code = code;
  throw error;
};

const expect = (label, got, reason) => {
  if (got.kind !== "unknown" || got.reason !== reason) {
    throw new Error(label + ": " + got.kind + "/" + got.reason + " != unknown/" + reason);
  }
};

// A missing probe file is an ordinary state: the probe only writes once it has
// credentials and a successful fetch.
expect("enoent", m.readOllamaReserve(raising("ENOENT"), "/nope", now), "absent");
expect("permission", m.readOllamaReserve(raising("EACCES"), "/nope", now), "unreadable");
expect("no code", m.readOllamaReserve(raising(), "/nope", now), "unreadable");

const good = m.readOllamaReserve(
  () => JSON.stringify({
    fetched_at: "2026-08-20T12:00:00Z",
    session_free: 0.5,
    weekly_free: 0.9,
  }),
  "/probe.json",
  now,
);
if (good.kind !== "known" || good.freePercent !== 50) {
  throw new Error("good read: " + JSON.stringify(good));
}
console.log("OK");
JS
)
  [ "$out" = "OK" ] || fail "the reserve reader does not absorb read failures: $out"
  pass "the reserve reader maps read failures to an unknown instead of throwing"
}

# ------------------------------------------------------- generated-artifact layer

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tmux.src" <<'TMUXSH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
TMUXSH
  install -m 0755 "$dir/tmux.src" "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi
  printf '%s\n' "$fakebin"
}

# spawn_pi_case <name> <id> [fm-root]: run the REAL fm-spawn for a Pi ship task
# and print "<home>|<ext-path>". An explicit fm-root lets a case prove what the
# artifact does when its helper module is not where it was generated to expect.
spawn_pi_case() {
  local name=$1 id=$2 fm_root=${3:-} case_dir home proj wt fakebin out
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'pi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  out=$(FM_ROOT_OVERRIDE="$fm_root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1) \
    || fail "pi spawn for $name failed: $out"
  assert_present "$home/state/$id.pi-ext.ts" "pi spawn did not write the extension for $name"
  printf '%s|%s\n' "$home" "$home/state/$id.pi-ext.ts"
}

write_probe() {  # <home> <session-free> <weekly-free> <age-seconds>
  python3 - "$1/state/ollama-usage.json" "$2" "$3" "$4" <<'PY'
import json, sys, time
target, session, weekly, age = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - age))
with open(target, "w") as handle:
    json.dump({
        "fetched_at": stamp,
        "session_usage": round(1 - session, 4),
        "weekly_usage": round(1 - weekly, 4),
        "session_free": session,
        "weekly_free": weekly,
    }, handle)
PY
}

# drive_ext <ext-path> <event> [expected-call]: load the generated extension in
# a plain Node host, fire one lifecycle event with a RECORDING Pi context, and
# print every interaction it attempted, one "<surface> <detail>" line each.
# The reserve segment loads its module lazily, so the driver waits (bounded)
# for the expected call to be recorded - or, with no expectation, for the
# recording to go quiet - before printing.
drive_ext() {
  EXT_PATH="$1" EVENT="$2" EXPECT="${3:-}" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const calls = [];
// A permissive recorder: every UI surface the extension could reach answers,
// so a segment that tried to take the footer over would be recorded rather
// than silently skipped over a missing method.
const ui = new Proxy(
  {},
  {
    has: () => true,
    get: (_target, prop) => {
      if (typeof prop !== "string") return undefined;
      if (prop === "theme") return { fg: (_name, text) => text };
      return (...args) => {
        calls.push("ui." + prop + " " + args.join(" "));
      };
    },
  },
);
const ctx = { ui, isIdle: () => true };

const handlers = {};
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
mod.default({
  on: (name, fn) => {
    calls.push("register " + name);
    handlers[name] = fn;
  },
});

const handler = handlers[process.env.EVENT];
if (!handler) throw new Error("no handler for " + process.env.EVENT);
await handler({}, ctx);
// On a lapsed deadline the recorded calls are still printed, so a real
// regression reports what actually happened instead of looking like a timeout.
const deadline = Date.now() + 5000;
const tick = () => new Promise((resolve) => setTimeout(resolve, 25));
const expected = process.env.EXPECT || "";
if (expected) {
  while (Date.now() < deadline && !calls.some((line) => line.includes(expected))) {
    await tick();
  }
} else {
  let seen = calls.length;
  let quietSince = Date.now();
  while (Date.now() < deadline && Date.now() - quietSince < 400) {
    await tick();
    if (calls.length !== seen) {
      seen = calls.length;
      quietSince = Date.now();
    }
  }
}
console.log(calls.join("\n"));
JS
}

test_generated_extension_publishes_the_reserve_from_the_home_probe() {
  require_node "the generated Pi extension reserve test" || return 0
  local rec home ext out other
  rec=$(spawn_pi_case reserve-fresh olla-fresh)
  home=${rec%%|*}
  ext=${rec#*|}
  write_probe "$home" 0.851 0.924 60

  out=$(drive_ext "$ext" session_start "ui.setStatus fm-ollama ") \
    || fail "session_start drive failed: $out"
  assert_contains "$out" "ui.setStatus fm-ollama olla 85%" \
    "the generated extension did not publish the reserve read from this home's probe"

  # The segments Pi already renders - working directory, branch, context,
  # tokens, model - are Pi's to render. The extension must touch nothing but
  # its own keyed status entry, or it would be reproducing them and drifting
  # from them at the next Pi release.
  other=$(printf '%s\n' "$out" | grep '^ui\.' | grep -v '^ui\.setStatus fm-ollama ' || true)
  [ -z "$other" ] || fail "the extension reached past its own status entry: $other"
  pass "the generated extension publishes the reserve under its own key and touches nothing else"
}

test_generated_extension_renders_an_unknown_rather_than_a_stale_figure() {
  require_node "the generated Pi extension unknown-reserve test" || return 0
  local rec home ext out

  rec=$(spawn_pi_case reserve-absent olla-absent)
  home=${rec%%|*}
  ext=${rec#*|}
  assert_absent "$home/state/ollama-usage.json" "the absent case must start with no probe file"
  out=$(drive_ext "$ext" session_start "ui.setStatus fm-ollama ") \
    || fail "absent-probe drive failed: $out"
  assert_contains "$out" "ui.setStatus fm-ollama olla ?" \
    "an absent probe file must publish an explicit unknown"

  rec=$(spawn_pi_case reserve-stale olla-stale)
  home=${rec%%|*}
  ext=${rec#*|}
  # Well past the shelf life: the probe refreshes on a five-minute sweep, so a
  # reading this old means the sweep is not running.
  write_probe "$home" 0.851 0.924 10800
  out=$(drive_ext "$ext" session_start "ui.setStatus fm-ollama ") \
    || fail "stale-probe drive failed: $out"
  assert_contains "$out" "ui.setStatus fm-ollama olla ?" \
    "a stale probe reading must publish an explicit unknown"
  assert_not_contains "$out" "olla 85%" \
    "a stale probe reading must never be presented as current"
  pass "an absent or stale probe reading publishes an explicit unknown, never a figure"
}

# Pi's in-process session replacement (/new, /resume, fork) clears its
# extension-status store while reusing the already-loaded extension module, so
# a second session_start on the SAME instance must publish the reserve again
# even though the rendered text has not changed. The recorder mirrors the
# cleared store by dropping everything recorded before the replacement.
test_generated_extension_republishes_after_session_replacement() {
  require_node "the generated Pi extension session-replacement test" || return 0
  local rec home ext out
  rec=$(spawn_pi_case reserve-replace olla-replace)
  home=${rec%%|*}
  ext=${rec#*|}
  write_probe "$home" 0.851 0.924 60

  out=$(EXT_PATH="$ext" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const calls = [];
const ui = new Proxy(
  {},
  {
    has: () => true,
    get: (_target, prop) => {
      if (typeof prop !== "string") return undefined;
      if (prop === "theme") return { fg: (_name, text) => text };
      return (...args) => {
        calls.push("ui." + prop + " " + args.join(" "));
      };
    },
  },
);
const ctx = { ui, isIdle: () => true };

const handlers = {};
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
mod.default({
  on: (name, fn) => {
    handlers[name] = fn;
  },
});

const waitForPublish = async () => {
  const deadline = Date.now() + 5000;
  while (
    Date.now() < deadline &&
    !calls.some((line) => line.includes("ui.setStatus fm-ollama "))
  ) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
};

await handlers.session_start({}, ctx);
await waitForPublish();
const first = calls.splice(0, calls.length);
if (!first.some((line) => line.includes("ui.setStatus fm-ollama "))) {
  throw new Error("first session_start never published: " + JSON.stringify(first));
}

await handlers.session_start({}, ctx);
await waitForPublish();
console.log(calls.map((line) => "replacement " + line).join("\n"));
JS
  ) || fail "session-replacement drive failed: $out"
  assert_contains "$out" "replacement ui.setStatus fm-ollama olla 85%" \
    "a replacement session_start was swallowed by the publish-on-change cache"
  pass "a replacement session_start republishes the reserve into the cleared store"
}

test_generated_extension_keeps_supervision_wiring_when_the_reserve_cannot_load() {
  require_node "the generated Pi extension degraded-module test" || return 0
  local rec home ext out fm_root
  # A code root with the real busy-state writer but no reserve module: the
  # footer segment is a nicety, and it must not be able to keep the busy-state
  # and turn-end wiring supervision depends on from registering.
  fm_root="$TMP_ROOT/rootless"
  mkdir -p "$fm_root"
  # A complete, working code root except for .pi, so the only thing missing is
  # the reserve module itself.
  local entry
  for entry in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$entry" ] || continue
    [ "$(basename "$entry")" = ".pi" ] && continue
    ln -s "$entry" "$fm_root/$(basename "$entry")"
  done
  assert_absent "$fm_root/.pi/extensions/lib/fm-ollama-reserve.ts" \
    "the degraded case must have no reserve module"

  rec=$(spawn_pi_case reserve-degraded olla-degraded "$fm_root")
  home=${rec%%|*}
  ext=${rec#*|}
  write_probe "$home" 0.851 0.924 60

  out=$(drive_ext "$ext" session_start) || fail "degraded-module drive failed: $out"
  assert_contains "$out" "register agent_start" \
    "a missing reserve module stopped the busy-state wiring from registering"
  assert_contains "$out" "register agent_settled" \
    "a missing reserve module stopped the settle wiring from registering"
  assert_contains "$out" "register turn_end" \
    "a missing reserve module stopped the turn-end wiring from registering"
  assert_not_contains "$out" "ui.setStatus" \
    "a missing reserve module must publish nothing rather than guess"
  pass "a reserve module that cannot load leaves the supervision wiring intact"
}

test_generated_extension_keeps_the_turn_end_notification() {
  require_node "the generated Pi extension turn-end test" || return 0
  local rec home ext out marker
  rec=$(spawn_pi_case reserve-turnend olla-turnend)
  home=${rec%%|*}
  ext=${rec#*|}
  write_probe "$home" 0.4 0.9 60
  marker="$home/state/olla-turnend.turn-ended"
  assert_absent "$marker" "a fresh spawn must not already carry a turn-end notification"

  out=$(drive_ext "$ext" turn_end "ui.setStatus fm-ollama ") \
    || fail "turn_end drive failed: $out"
  assert_present "$marker" "the reserve segment displaced the turn-end notification"
  assert_contains "$out" "ui.setStatus fm-ollama olla 40%" \
    "turn_end must also refresh the reserve so a long session stays current"
  pass "turn_end still touches the notification marker and refreshes the reserve"
}

test_module_reports_the_tightest_window_and_never_overstates_it
test_module_refuses_to_present_an_untrustworthy_reading_as_current
test_module_reader_never_throws_on_a_failing_read
test_generated_extension_publishes_the_reserve_from_the_home_probe
test_generated_extension_renders_an_unknown_rather_than_a_stale_figure
test_generated_extension_republishes_after_session_replacement
test_generated_extension_keeps_supervision_wiring_when_the_reserve_cannot_load
test_generated_extension_keeps_the_turn_end_notification

echo "all fm-pi-ollama-reserve tests passed"
