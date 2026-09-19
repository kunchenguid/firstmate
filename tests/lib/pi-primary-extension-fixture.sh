#!/usr/bin/env bash
# Shared mock-Pi fixture for Pi primary extension integration tests.
#
# Source after tests/lib.sh:
#   # shellcheck source=tests/lib/pi-primary-extension-fixture.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/pi-primary-extension-fixture.sh"

install_pi_primary_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/bin" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-primary-stuck-primary.ts" "$repo/.pi/extensions/lib/fm-primary-stuck-primary.ts"
  cp "$ROOT/.pi/extensions/lib/fm-watcher-beacon.ts" "$repo/.pi/extensions/lib/fm-watcher-beacon.ts"
  cp "$ROOT/.pi/extensions/lib/fm-cursor-replay-execute.ts" "$repo/.pi/extensions/lib/fm-cursor-replay-execute.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started Pi extension arm child 1\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/bin/fm-fleet-live-count.sh" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH
  chmod +x \
    "$repo/bin/fm-watch-arm.sh" \
    "$repo/bin/fm-fleet-live-count.sh" \
    "$repo/bin/fm-turnend-guard.sh" \
    "$repo/bin/fm-arm-pretool-check.sh" \
    "$repo/bin/fm-cd-pretool-check.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

prepare_pi_extension_fleet_state() {
  local home=$1
  mkdir -p "$home/state"
  printf '%s\n' "$$" >"$home/state/.lock"
  printf 'window=1\n' >"$home/state/task-1.meta"
  printf 'epoch\t1\tsignal\ttask-1\tdone: worker finished\n' >"$home/state/.wake-queue"
}

prepare_pi_extension_idle_state() {
  local home=$1
  mkdir -p "$home/state"
  printf '%s\n' "$$" >"$home/state/.lock"
}

run_pi_extension_node_case() {
  local home=$1 repo=$2 label=$3 node_script=$4
  local case_idle=${5:-0} case_progress=${6:-0}
  local out status=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    CASE_IDLE="$case_idle" CASE_PROGRESS="$case_progress" \
    TURNEND_EXT="$repo/.pi/extensions/fm-primary-turnend-guard.ts" \
    WATCH_EXT="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
    node --experimental-strip-types --input-type=module 2>&1 <<EOF
$node_script
EOF
  ) || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'integration failure (%s):\n%s\n' "$label" "$out" >&2
  fi
  expect_code 0 "$status" "$label"
  [ -z "$out" ] || fail "$label printed unexpected output: $out"
}
