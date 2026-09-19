# shellcheck shell=bash
# fm-typesafe-lib.sh - the one typesafe.ai System One client shared by the
# opt-in typed-resolution tools (bin/fm-dispatch-resolve.sh and
# bin/fm-voice-check.sh). Sourced, never executed.
#
# Key handling contract, owned here and by docs/configuration.md "Typed dispatch
# resolution": a caller captures an environment-provided TYPESAFE_API_KEY into
# the non-exported shell variable TYPESAFE_API_KEY_PRIVATE and unsets
# TYPESAFE_API_KEY at the very top of the script, before sourcing anything, so
# no child process inherits the secret. fm_typesafe_key_resolve then falls back
# to the home's gitignored .env line; the environment wins. The key reaches curl
# only as a header read from file descriptor 3, never on argv, and nothing here
# prints, logs, or writes it.
#
# Fixed endpoint, model, and request timeout; TYPESAFE_API_KEY is the only
# setting. Requires fm-env-lib.sh (fmx_env_get) and fm-timing-lib.sh.

FM_TYPESAFE_BASE=https://api.typesafe.ai
# shellcheck disable=SC2034 # Read by the sourcing callers' request builders.
FM_TYPESAFE_MODEL=jev-latest
FM_TYPESAFE_TIMEOUT=5

# fm_typesafe_key_resolve <env-file>: fill TYPESAFE_API_KEY_PRIVATE from the
# .env line when the environment supplied none. Returns 1 when still empty (off).
fm_typesafe_key_resolve() {
  if [ -z "${TYPESAFE_API_KEY_PRIVATE:-}" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1")
  fi
  [ -n "${TYPESAFE_API_KEY_PRIVATE:-}" ]
}

# fm_typesafe_post <response-file>: POST the JSON request read from stdin to
# /v1/systemone and write the response body to <response-file>. Sets
# FM_TYPESAFE_HTTP (000 on a transport failure or timeout) and
# FM_TYPESAFE_LATENCY_MS. Always returns 0; the caller judges the outcome.
# shellcheck disable=SC2034 # Output globals read by the sourcing callers.
fm_typesafe_post() {
  local resp=$1 t0 t1
  t0=$(fm_timing_now_ms)
  FM_TYPESAFE_HTTP=$(curl -sS --max-time "$FM_TYPESAFE_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$FM_TYPESAFE_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || FM_TYPESAFE_HTTP=000
  t1=$(fm_timing_now_ms)
  FM_TYPESAFE_LATENCY_MS=$(( t1 - t0 ))
  return 0
}
