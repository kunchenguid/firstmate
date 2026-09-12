#!/usr/bin/env bash
# Owned-write-path regression for config/dispatch-pools.json. No harness or
# backend is started; the Codex side runs on the protocol-only fixture and
# wrappers run on PATH fakes.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-pools-install)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state" "$TMP_ROOT/auth" "$TMP_ROOT/home"
export CODEX_HOME="$TMP_ROOT/auth"
fm_test_pool_codex "$TMP_ROOT/bin"
export PATH="$TMP_ROOT/bin:$PATH"
fm_test_pool_config "$TMP_ROOT/good.json"
install() { "$ROOT/bin/fm-dispatch-pools-install.sh" "$TMP_ROOT/home/dispatch-pools.json" "$@"; }
refused() { if "$@" >"$TMP_ROOT/refusal" 2>&1; then fail 'expected refusal'; fi; }
install "$TMP_ROOT/good.json" >/dev/null
[ -f "$TMP_ROOT/home/dispatch-pools.json" ] || fail 'valid install missing'
[ "$(stat -f %Lp "$TMP_ROOT/home/dispatch-pools.json")" = 600 ] || fail 'install perms not 0600'
pass 'valid pools install atomically at 0600 with default probe'
printf '%s' '{"schemaVersion":1,"defaults":{},"pools":{"w":[{"id":"x","harness":"codex","model":"a/b","effort":"low","provider":"t","authCarrier":"t","carrier":"wrapper","weight":1}]}}' > "$TMP_ROOT/bad.json"
refused install "$TMP_ROOT/bad.json"
[ "$(cat "$TMP_ROOT/home/dispatch-pools.json")" = "$(cat "$TMP_ROOT/good.json")" ] || fail 'refused install modified destination'
pass 'invalid candidate identity refuses and preserves destination'
printf '%s' '{"schemaVersion":1,"defaults":{},"pools":{"w":[{"id":"x","harness":"claude","model":"opus","effort":"high","provider":"anthropic","authCarrier":"claude-oauth","carrier":"claude-native","weight":1}]}}' > "$TMP_ROOT/stale.json"
refused install "$TMP_ROOT/stale.json"
pass 'validate-clean but zero-viable pool refuses under default probe'
install --help >/dev/null 2>&1 && fail 'help should exit nonzero' || true
"$ROOT/bin/fm-dispatch-pools-install.sh" "$TMP_ROOT/home/offline.json" "$TMP_ROOT/stale.json" --no-probe >/dev/null
[ -f "$TMP_ROOT/home/offline.json" ] || fail '--no-probe install missing'
pass '--no-probe installs validate-clean files when offline'
ln -s "$TMP_ROOT/good.json" "$TMP_ROOT/link.json"
refused install "$TMP_ROOT/link.json"
pass 'symlink replacement refuses'
