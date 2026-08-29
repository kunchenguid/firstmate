#!/usr/bin/env bash
# G5: the inject path respects the 10k-char cap. A handoff under the cap is
# injected verbatim; a handoff over the cap yields a short POINTER to the file, not
# the bloated body. Tested at two layers: fm_ctx_inject_payload (the primitive) and
# the bootstrap's rendered additionalContext. Mutation (LEDGER_MUTATE=1): shrink the
# "large" handoff below the cap, so the pointer assertion fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-ctx-lib.sh
. "$ROOT/bin/fm-ctx-lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g5.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export FM_CTX_INJECT_CAP=10000

# --- small handoff: injected verbatim ---------------------------------------
small="$TMP/small.md"
printf 'tiny handoff body MARKER-SMALL\n' > "$small"
payload_small=$(fm_ctx_inject_payload "$small")
printf '%s' "$payload_small" | grep -q 'MARKER-SMALL' || fail "small handoff must be injected verbatim"
printf '%s' "$payload_small" | grep -q 'cap' && fail "small handoff must NOT become a pointer"

# --- large handoff: pointer fallback ----------------------------------------
large="$TMP/large.md"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  printf 'short\n' > "$large"                      # mutation: under the cap
else
  head -c 15000 /dev/zero | tr '\0' 'x' > "$large" # 15000 chars > 10k cap
fi
payload_large=$(fm_ctx_inject_payload "$large")
plen=$(printf '%s' "$payload_large" | wc -c | tr -d ' ')
printf '%s' "$payload_large" | grep -q "$large" || fail "large handoff must yield a pointer to the file path"
printf '%s' "$payload_large" | grep -qi 'cap'   || fail "large handoff pointer must mention the cap"
[ "$plen" -lt 10000 ] || fail "pointer payload must be far under the cap (got $plen chars)"

# --- bootstrap honors the cap end-to-end ------------------------------------
FM="$TMP/fmhome"; mkdir -p "$FM/state"
cp "$large" "$FM/state/handoff-g5win.md"
out=$(printf '%s' '{"source":"clear","cwd":"/tmp/x","session_id":"s5"}' \
  | FM_HOME="$FM" FM_CTX_WINDOW=g5win FM_CTX_ROLE=crew "$ROOT/bin/fm-captain-bootstrap.sh")
printf '%s' "$out" | grep -qi 'cap' || fail "bootstrap must emit the pointer (not the 15k body) for an over-cap handoff"

pass "G5 inject cap respected (verbatim under cap, pointer over cap)"
