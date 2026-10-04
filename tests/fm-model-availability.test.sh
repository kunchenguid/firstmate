#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { printf 'skip - jq absent\n'; exit 0; }
dir=$(fm_test_tmproot fm-model-availability)
mkdir -p "$dir/bin"
cat > "$dir/bin/quota-axi" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models) printf '{"models":[]}\n' ;;
  *) printf '{"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"model:fable","percentRemaining":53}]}]}\n' ;;
esac
EOF
cat > "$dir/bin/pi" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  anthropic) printf 'provider model context\nanthropic claude-fable-5 1M\n' ;;
  other) printf 'provider model context\nother other-model 1M\n' ;;
  claude-fable-5) printf 'provider model context\nanthropic claude-fable-5 1M\n' ;;
esac
EOF
cat > "$dir/bin/pi-signed" <<'EOF'
#!/usr/bin/env bash
printf 'provider model context\nother signed-only 1M\n'
EOF
cat > "$dir/bin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
printf 'cursor-fable - current account model\n'
EOF
chmod +x "$dir/bin/quota-axi" "$dir/bin/pi" "$dir/bin/pi-signed" "$dir/bin/cursor-agent"
tool="$ROOT/bin/fm-model-availability.sh"
out=$(PATH="$dir/bin:$PATH" "$tool" claude fable)
printf '%s' "$out" | jq -e '.harness == "claude" and .model == "fable" and
  .resolution == "uncertain" and .harnessCatalog.status == "unverified" and
  (.quotaModelScopes | any(.provider == "claude" and .scope == "model:fable"))' >/dev/null \
  || fail "Fable quota evidence was turned into a false Claude unavailability verdict: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" pi claude-fable-5)
printf '%s' "$out" | jq -e '.resolution == "available" and .harness == "pi"' >/dev/null \
  || fail "Pi's exact catalog model was not found: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" pi anthropic/claude-fable-5)
printf '%s' "$out" | jq -e '.resolution == "available" and .harness == "pi"' >/dev/null \
  || fail "Pi's qualified catalog model was not found: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" pi other/claude-fable-5)
printf '%s' "$out" | jq -e '.resolution == "unsupported-on-this-harness"' >/dev/null \
  || fail "Pi matched a model from the wrong provider: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" pi absent-model)
printf '%s' "$out" | jq -e '.resolution == "unsupported-on-this-harness" and .harness == "pi"' >/dev/null \
  || fail "reachable catalog omission was not kept harness-specific: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" pi-signed signed-only)
printf '%s' "$out" | jq -e '.resolution == "available" and .harnessCatalog.source == "pi-signed --list-models"' >/dev/null \
  || fail "Pi-signed catalog was replaced by plain Pi: $out"
out=$(PATH="$dir/bin:$PATH" "$tool" cursor cursor-fable)
printf '%s' "$out" | jq -e '.resolution == "available" and (.harnessCatalog.source | contains("cursor-agent --list-models"))' >/dev/null \
  || fail "verified Cursor catalog did not prove its own model: $out"
printf 'ok - Fable quota and harness evidence remain separate\n'
