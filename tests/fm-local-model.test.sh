#!/usr/bin/env bash
# tests/fm-local-model.test.sh - the portable regression for the local
# OpenAI/Anthropic-compatible endpoint owner behind the claude-local adapter.
#
# The endpoint is addressed through a real `curl` against a real `file://` URL
# rather than a stubbed curl. That keeps the load-bearing parts genuine - the
# real fetch, the real JSON parse, the real exit codes - while staying portable
# to a CI runner that cannot bind a listening socket. It deliberately does NOT
# claim to prove TCP behavior: the live evidence against a real HTTP endpoint,
# including the request-path finding these contracts are built on, is recorded
# in docs/verification/runtime-backends.md under "claude-local".
#
# The load-bearing contracts:
#   1. The CATALOG is the only model-identity source. Verified against LM Studio
#      2026-09-01, a request naming an unloaded model is answered by whatever IS
#      loaded, so the request path can never report an eviction.
#   2. An unreachable endpoint and an evicted model are DISTINCT, non-silent
#      failures with distinct exit codes, and the watcher check prints one
#      actionable line for each and nothing at all when the runtime is healthy.
#   3. The context budget is the smaller of what the server loaded and the
#      firstmate ceiling, so loading a very wide window can never by itself turn
#      this into a long-context runtime.
#   4. The boundary that actually bites is the HEADROOM above the harness's own
#      prompt, measured at ~60k tokens on 2026-09-01. An oversized brief - and a
#      window with no headroom at all - is REFUSED, not silently degraded.
#   5. LOCAL means loopback. The endpoint becomes the worker's
#      ANTHROPIC_BASE_URL, so a remote host is refused before any request is
#      made rather than quietly shipping the brief and transcript off the box.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCAL_MODEL="$ROOT/bin/fm-local-model.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-model)

# endpoint <name> <state> <loaded_context_length> -> echoes a file:// endpoint
# whose /api/v0/models is a real catalog document. The decoy first model is what
# makes the lookup prove it reads the RIGHT entry rather than the first "state"
# it happens to find.
endpoint() {  # <name> <state> <ctx>
  local name=$1 state=$2 ctx=$3 dir
  dir="$TMP_ROOT/$name/api/v0"
  mkdir -p "$dir"
  cat > "$dir/models" <<EOF
{"object":"list","data":[
 {"id":"other-model","object":"model","type":"llm","state":"not-loaded","max_context_length":8192,"loaded_context_length":8192},
 {"id":"local-coder","object":"model","type":"llm","state":"$state","max_context_length":262144,"loaded_context_length":$ctx}
]}
EOF
  printf 'file://%s\n' "$TMP_ROOT/$name"
}

# An endpoint that answers nothing at all: the directory exists but the catalog
# does not, so the same curl invocation that reaches a live server fails.
dead_endpoint() {
  mkdir -p "$TMP_ROOT/dead"
  printf 'file://%s\n' "$TMP_ROOT/dead"
}

missing_loaded_window_endpoint() {
  local dir
  dir="$TMP_ROOT/missing-window/api/v0"
  mkdir -p "$dir"
  cat > "$dir/models" <<'EOF'
{"object":"list","data":[
 {"id":"local-coder","object":"model","type":"llm","state":"loaded","max_context_length":262144}
]}
EOF
  printf 'file://%s\n' "$TMP_ROOT/missing-window"
}

unreadable_catalog_endpoint() {
  local dir
  dir="$TMP_ROOT/unreadable/api/v0"
  mkdir -p "$dir"
  printf '<html>another service</html>\n' > "$dir/models"
  printf 'file://%s\n' "$TMP_ROOT/unreadable"
}

# A loaded model is reported loaded, and the budget is the smaller of the
# server's own loaded window and the firstmate ceiling - in BOTH directions, so
# neither side can be the only one that ever binds.
test_loaded_model_and_budget() {
  local url out
  url=$(endpoint healthy loaded 65536)

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" model-state local-coder) \
    || fail "model-state failed against a healthy endpoint"
  [ "$out" = loaded ] || fail "expected state 'loaded', got '$out'"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_MAX_CONTEXT=32768 \
    "$LOCAL_MODEL" context-budget local-coder) || fail "context-budget failed"
  [ "$out" = 32768 ] || fail "the firstmate ceiling must bind below the server window, got '$out'"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_MAX_CONTEXT=200000 \
    "$LOCAL_MODEL" context-budget local-coder) || fail "context-budget failed"
  [ "$out" = 65536 ] || fail "the server window must bind below the ceiling, got '$out'"

  FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" preflight local-coder >/dev/null \
    || fail "preflight refused a loaded model on a reachable endpoint"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" check local-coder) \
    || fail "check exited nonzero on a healthy runtime"
  [ -z "$out" ] || fail "check must print NOTHING when the runtime is healthy, got '$out'"

  pass "a loaded model reports loaded, and the budget is the smaller of the server window and the ceiling"
}

# An evicted model is the failure LM Studio's idle TTL and auto-evict produce
# under a running worker. It must be loud, and it must be distinguishable from
# an unreachable endpoint.
test_evicted_model_is_loud() {
  local url out status
  url=$(endpoint evicted not-loaded 0)

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" model-state local-coder) \
    || fail "model-state failed against a reachable endpoint"
  [ "$out" = not-loaded ] || fail "expected 'not-loaded', got '$out'"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" preflight local-coder 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "an evicted model must exit 4, got $status"
  case "$out" in *"not loaded"*) : ;; *) fail "the eviction refusal did not name the state: $out" ;; esac

  FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" context-budget local-coder >/dev/null 2>&1 \
    && fail "context-budget must refuse rather than invent a window for an unloaded model"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" check local-coder)
  case "$out" in
    blocked:*"no longer loaded"*) : ;;
    *) fail "the watcher check did not report the eviction as blocked: '$out'" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the watcher check must print exactly one line"

  pass "an evicted model exits 4 and wakes firstmate with one actionable line"
}

# A model the endpoint has never heard of is a different operator mistake than
# an evicted one, and says so.
test_absent_model_names_the_gap() {
  local url out status
  url=$(endpoint absent loaded 65536)
  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" preflight no-such-model 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "an absent model must exit 4, got $status"
  case "$out" in *"does not list a model named"*) : ;; *) fail "absent-model refusal was not specific: $out" ;; esac
  pass "a model absent from the catalog is refused with its own message"
}

# The other half of the going-away requirement: an endpoint that does not answer
# must be its own exit code and its own wake line, never confused with an
# eviction and never silent.
test_unreachable_endpoint_is_loud_and_distinct() {
  local url out status
  url=$(dead_endpoint)

  FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" probe >/dev/null 2>&1
  status=$?
  [ "$status" -eq 3 ] || fail "an unreachable endpoint must exit 3, got $status"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" preflight local-coder 2>&1)
  status=$?
  [ "$status" -eq 3 ] || fail "preflight against an unreachable endpoint must exit 3, got $status"
  case "$out" in *"is not answering"*) : ;; *) fail "the unreachable-endpoint refusal was not actionable: $out" ;; esac

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" check local-coder)
  case "$out" in
    blocked:*"stopped answering"*) : ;;
    *) fail "the watcher check did not report the unreachable endpoint as blocked: '$out'" ;;
  esac
  case "$out" in
    *"no longer loaded"*) fail "an unreachable endpoint must not be reported as an eviction" ;;
  esac
  pass "an unreachable endpoint exits 3 and wakes firstmate with its own distinct line"
}

test_loaded_model_without_loaded_window_is_refused() {
  local url out status
  url=$(missing_loaded_window_endpoint)

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" context-budget local-coder 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "a loaded model without a loaded window must exit 4, got $status"
  case "$out" in *"no positive loaded context length"*) : ;; *) fail "missing loaded window did not explain the refusal: $out" ;; esac

  FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" headroom local-coder >/dev/null 2>&1
  status=$?
  [ "$status" -eq 4 ] || fail "headroom must refuse a model without a loaded window, got $status"

  pass "a loaded model without loaded_context_length is refused instead of using its maximum"
}

test_unreadable_catalog_wakes_once() {
  local url out
  url=$(unreadable_catalog_endpoint)

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" check local-coder) \
    || fail "check exited nonzero for an unreadable catalog"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "an unreadable catalog must print exactly one wake line"
  case "$out" in
    blocked:*"unreadable catalog"*) : ;;
    *) fail "an unreadable catalog did not produce its own wake line: '$out'" ;;
  esac
  case "$out" in
    *"no longer loaded"*|*"stopped answering"*) fail "an unreadable catalog was confused with another failure: '$out'" ;;
  esac

  pass "an unreadable catalog wakes firstmate with one distinct actionable line"
}

# The short-context boundary is enforced, not documented. It is enforced against
# the HEADROOM above the harness's own prompt, because that baseline - measured
# at ~60k tokens on 2026-09-01 - is what actually consumes this window.
test_oversized_brief_is_refused() {
  local url brief out status n
  url=$(endpoint oversize loaded 65536)

  # Baseline 45536 against a 65536 window leaves 20000 tokens of headroom, so
  # the default 25% share is a 5000-token allowance.
  brief="$TMP_ROOT/small-brief.md"
  printf 'do one small thing\n' > "$brief"
  FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_HARNESS_BASELINE=45536 \
    "$LOCAL_MODEL" brief-fits local-coder "$brief" >/dev/null \
    || fail "a small brief was refused inside the headroom"

  brief="$TMP_ROOT/big-brief.md"
  : > "$brief"
  n=0
  while [ "$n" -lt 400 ]; do
    printf 'this is a hundred bytes of brief text repeated to build an oversized brief for the refusal case aaa\n' >> "$brief"
    n=$(( n + 1 ))
  done
  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_HARNESS_BASELINE=45536 \
    "$LOCAL_MODEL" brief-fits local-coder "$brief" 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "an oversized brief must exit 6, got $status"
  case "$out" in *"too large for the local model runtime"*) : ;; *) fail "the oversize refusal was not explicit: $out" ;; esac
  case "$out" in *"SHORT-CONTEXT"*) : ;; *) fail "the oversize refusal did not state the boundary: $out" ;; esac
  case "$out" in *"after the harness"*) : ;; *) fail "the oversize refusal did not attribute the window to the harness prompt: $out" ;; esac

  pass "a brief beyond the headroom is refused with the numbers behind the refusal"
}

# The failure this runtime actually hits by default: the harness's own prompt
# nearly fills the loaded window, leaving nothing for the task. That is refused
# outright, with the one action that fixes it, rather than accepted and then
# silently compacted against a window the server does not have.
test_no_headroom_is_refused_with_the_fix() {
  local url out status
  url=$(endpoint headroom loaded 65536)

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_HARNESS_BASELINE=60000 \
    "$LOCAL_MODEL" headroom local-coder) || fail "a window with headroom was refused"
  [ "$out" = 5536 ] || fail "headroom must be window minus baseline, got '$out'"

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_HARNESS_BASELINE=65536 \
    "$LOCAL_MODEL" headroom local-coder 2>&1)
  status=$?
  [ "$status" -eq 7 ] || fail "a window with no headroom must exit 7, got $status"
  case "$out" in *"no usable context headroom"*) : ;; *) fail "the no-headroom refusal was not explicit: $out" ;; esac
  case "$out" in *"loaded context length"*) : ;; *) fail "the no-headroom refusal did not name the fix: $out" ;; esac

  # A brief cannot slip through a window that has no room for the harness itself.
  printf 'tiny\n' > "$TMP_ROOT/tiny.md"
  FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_HARNESS_BASELINE=70000 \
    "$LOCAL_MODEL" brief-fits local-coder "$TMP_ROOT/tiny.md" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 7 ] || fail "even a tiny brief must be refused with exit 7 when there is no headroom, got $status"

  pass "a window the harness prompt alone fills is refused with the action that fixes it"
}

# A body that PARSES but is not shaped like a catalog must take the unreadable
# path, never the eviction path. This is the other half of the unreadable-catalog
# distinction: the earlier case covers bodies that fail to parse, and without
# this one a wrong-shaped body still yields a confident "no longer loaded",
# sending an operator to reload a model when the real fault is that something
# other than the model server is answering on that port.
test_wrong_shaped_catalog_is_not_reported_as_eviction() {
  local dir url out status shape
  for shape in '{"data":{}}' '{"data":"nope"}' '{"data":null}'; do
    dir="$TMP_ROOT/shaped$RANDOM/api/v0"
    mkdir -p "$dir"
    printf '%s' "$shape" > "$dir/models"
    url="file://$(dirname "$(dirname "$dir")")"

    out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" check local-coder)
    case "$out" in
      *"no longer loaded"*) fail "shape $shape was reported as an eviction: '$out'" ;;
    esac
    case "$out" in
      blocked:*"unreadable catalog"*) : ;;
      *) fail "shape $shape did not produce the unreadable-catalog line: '$out'" ;;
    esac
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
      || fail "the watcher check must print exactly one line for shape $shape"

    FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" model-state local-coder >/dev/null 2>&1
    status=$?
    [ "$status" -eq 5 ] || fail "shape $shape must exit 5 (unreadable), got $status"
  done

  # The contrast that keeps this from going vacuous: a well-formed catalog that
  # genuinely lacks the model still reports absent, not unreadable.
  url=$(endpoint shaped-contrast loaded 65536)
  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" model-state no-such-model) \
    || fail "a well-formed catalog missing the model must not be unreadable"
  [ "$out" = absent ] || fail "expected 'absent' for a missing model, got '$out'"

  pass "a parseable but wrong-shaped catalog reports unreadable, never a false eviction"
}

# A ceiling that is present but not a positive integer is an operator mistake
# that must never read as "no limit". An EMPTY value is deliberately not in that
# set: it carries no number, so it means "unset" under ordinary environment
# semantics and falls back to the compiled default ceiling - which is a bound,
# not an absence of one. The asserted contrast is the point: every malformed
# value is refused, and the one value that is merely absent still lands on a
# real ceiling rather than opening the window.
test_bad_ceiling_is_refused() {
  local url status v out
  url=$(endpoint ceiling loaded 65536)
  for v in 0 abc -1 12.5 ' '; do
    FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_MAX_CONTEXT="$v" \
      "$LOCAL_MODEL" context-budget local-coder >/dev/null 2>&1
    status=$?
    [ "$status" -eq 2 ] || fail "ceiling '$v' must be refused with exit 2, got $status"
  done

  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" FM_LOCAL_MODEL_MAX_CONTEXT='' \
    "$LOCAL_MODEL" context-budget local-coder) \
    || fail "an empty ceiling must fall back to the default, not refuse"
  [ "$out" = 65536 ] || fail "an empty ceiling must land on a real bound, got '$out'"

  pass "a malformed ceiling is refused, and an absent one falls back to a real bound"
}

# The endpoint becomes the worker's ANTHROPIC_BASE_URL, so it decides where the
# brief, every file the worker reads, and its whole tool transcript are sent. A
# remote host would make "local model" a name for shipping the repository off
# the machine, silently and with no error at all, so it is refused before any
# request is made. The two halves are asserted together because a guard that
# refused everything would pass the refusal half alone: a loopback endpoint must
# still reach the network, and a loopback host that merely LOOKS like one
# (127.0.0.1.evil.example) must not.
test_remote_endpoint_is_refused() {
  local url out status bad
  url=$(endpoint loopback loaded 65536)

  # Accepted: the empty-authority file:// fixture the rest of this suite uses,
  # and a real loopback HOST in the authority, both fetched by the real curl.
  out=$(FM_LOCAL_MODEL_ENDPOINT="$url" "$LOCAL_MODEL" model-state local-coder) \
    || fail "an empty-authority endpoint was refused"
  [ "$out" = loaded ] || fail "expected 'loaded' from the local endpoint, got '$out'"
  out=$(FM_LOCAL_MODEL_ENDPOINT="file://localhost$TMP_ROOT/loopback" \
    "$LOCAL_MODEL" model-state local-coder) \
    || fail "a localhost endpoint was refused"
  [ "$out" = loaded ] || fail "expected 'loaded' from the localhost endpoint, got '$out'"

  # A loopback ADDRESS reaches the network: with nothing listening it must fail
  # as unreachable (3), never as a refused configuration (2).
  FM_LOCAL_MODEL_ENDPOINT=http://127.0.0.1:1 FM_LOCAL_MODEL_TIMEOUT=2 \
    "$LOCAL_MODEL" probe >/dev/null 2>&1
  status=$?
  [ "$status" -eq 3 ] || fail "a loopback address must reach the endpoint check, got exit $status"

  for bad in http://remote-host.example:1234 http://127.0.0.1.evil.example:1234 \
    'http://[2001:db8::1]:1234' http://127.0.0.1@evil.example:1234 file://evil.example/catalog; do
    FM_LOCAL_MODEL_ENDPOINT="$bad" FM_LOCAL_MODEL_TIMEOUT=2 \
      "$LOCAL_MODEL" model-state local-coder >/dev/null 2>&1
    status=$?
    [ "$status" -eq 2 ] || fail "endpoint '$bad' must be refused with exit 2, got $status"
  done

  # The refusal has to be actionable on its own: it names the endpoint, the
  # variable that sets it, and what is allowed instead.
  out=$(FM_LOCAL_MODEL_ENDPOINT=http://remote-host.example:1234 \
    "$LOCAL_MODEL" preflight local-coder 2>&1)
  case "$out" in
    *"http://remote-host.example:1234"*) : ;;
    *) fail "the remote-endpoint refusal did not name the endpoint: $out" ;;
  esac
  case "$out" in
    *FM_LOCAL_MODEL_ENDPOINT*) : ;;
    *) fail "the remote-endpoint refusal did not name the variable: $out" ;;
  esac
  case "$out" in
    *127.0.0.0/8*) : ;;
    *) fail "the remote-endpoint refusal did not say what is allowed: $out" ;;
  esac

  # The watcher poll shares the same boundary. A remote endpoint must be a
  # refusal there too, never a wake line blaming a server that stopped
  # answering - that would send the operator to restart LM Studio when the real
  # fault is the endpoint they configured.
  out=$(FM_LOCAL_MODEL_ENDPOINT=http://remote-host.example:1234 \
    "$LOCAL_MODEL" check local-coder 2>/dev/null)
  status=$?
  [ "$status" -eq 2 ] || fail "the watcher check must refuse a remote endpoint, got exit $status"
  [ -z "$out" ] || fail "the watcher check misreported a remote endpoint as a wake: $out"

  pass "the endpoint is confined to loopback, and a loopback endpoint still reaches the network"
}

test_loaded_model_and_budget
test_evicted_model_is_loud
test_absent_model_names_the_gap
test_unreachable_endpoint_is_loud_and_distinct
test_loaded_model_without_loaded_window_is_refused
test_unreadable_catalog_wakes_once
test_oversized_brief_is_refused
test_no_headroom_is_refused_with_the_fix
test_wrong_shaped_catalog_is_not_reported_as_eviction
test_bad_ceiling_is_refused
test_remote_endpoint_is_refused
