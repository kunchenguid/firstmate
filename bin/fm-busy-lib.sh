#!/usr/bin/env bash
# fm-busy-lib.sh - the ONE owner of firstmate's semantic busy-state contract.
#
# Design source: the captain-approved semantic busy-state redesign
# (2026-07-28): each harness adapter reports turn lifecycle through a
# machine-readable semantic source it owns, classification always exposes
# which source produced it, and missing, malformed, stale, unsupported, or
# unverified semantic data is UNKNOWN - never idle. Endpoint death is the only
# process-level override and yields dead, never busy. Child processes, CPU,
# process sleep state, marker mtimes, and the old global UI-regex OR are not
# state signals here; state/<id>.turn-ended files remain wake NOTIFICATIONS
# owned by the watcher, not current-state truth.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq is a strictly increasing integer per gen, advanced
# under the writer's lock, so an out-of-order apply can never regress a
# newer record.
#
# Semantic sources written by adapters (fm_busy_sources_for_harness owns the
# per-harness trust table; a record whose source is not trusted for the
# task's recorded harness classifies unknown, so one adapter's writer can
# never classify another adapter):
#   pi-ext           Pi/pi-signed per-task extension (agent_start/agent_settled)
#   opencode-plugin  OpenCode per-task plugin (session.status)
#   claude-hook      Claude lifecycle hooks (UserPromptSubmit/Stop/StopFailure/SessionEnd)
#   codex-hook, codex-appserver  reserved: Codex, gated by
#                    fm_busy_codex_semantic_source
#   kimi-wire, kimi-hook  reserved: standalone Kimi, gated by fm_busy_kimi_verified
# Firstmate-owned sources accepted for every converted adapter:
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     the legacy Claude fm-send --key Escape idle event
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, grok-regex, muse-session-log,
#   cursor-transcript, missing, malformed, gen-mismatch, source-mismatch,
#   kimi-unverified, codex-unverified, capture-failed, no-target
#
# Classification (fm_busy_classify): busy | idle | unknown | dead, always
# with the producing source as the second token. Precedence:
#   1. dead endpoint (fm_busy_classify_live only) -> dead endpoint-gone
#   2. standalone Kimi before verification       -> unknown kimi-unverified
#   3. a valid, gen-matching, source-trusted record -> its state and source
#   4. no record at all: herdr's native busy verdict is trusted as busy
#      (generation state is sufficient for busy, not for idle), then the
#      muse session-log and cursor transcript pull sources, then the Grok-only
#      temporary regex fallback classifies a grok task from its rendered tail,
#      then unknown missing
#   5. malformed, stale, or untrusted records -> unknown, never a fallback
# The Grok arm is the ONLY rendered-text classification that survives the
# redesign, because Grok's structured lifecycle was not credited-live-verified
# in the approved audit; it is scoped to harness=grok and can never classify
# another adapter. The delivery guards in bin/fm-composer-lib.sh match rendered
# footers for submit acknowledgement and away-mode supervisor injection only;
# neither is a recorded worker state source.
#
# The muse pull source is semantic, not rendered: it folds muse's own durable
# session event log. It has no writer, no arm, and no gen, because
# muse's default build ships no hook or plugin surface that could push events
# (its plugin engine reports "plugins are not available in this build" without
# MUSE_EXPERIMENTAL_PLUGINS). Nothing is armed for muse for the same reason
# standalone Kimi is not: a seeded record with no writer could never be
# cleared. See fm_busy_muse_run_state for the fold.
#
# The cursor pull source works the same way and for the same reason: it folds
# cursor's own durable per-conversation transcript, which brackets each turn
# with a role:user open and a typed turn_ended close that covers aborts. It has
# no writer, no arm, and no gen, so nothing is seeded that could never be
# cleared. See fm_busy_cursor_turn_state for the fold. Cursor's rendered
# `ctrl+c to stop` footer is deliberately not a state source here.
#
# Codex negotiation (fm_busy_codex_appserver_observable,
# fm_busy_codex_hooks_verified): the approved contract prefers Codex's
# app-server turn lifecycle with capability negotiation, and sanctions its
# stable lifecycle hooks as the intermediate. Neither is usable on the
# installed binary, so Codex classifies unknown codex-unverified rather than
# falling back to idle, and fm-spawn installs no Codex busy wiring.
# docs/verification/supervision.md owns the evidence for both probes.
#
# Sourcing: set -u and set -e safe; no subshell-unfriendly globals.

FM_BUSY_LIB_VERSION=v1

# Standalone-Kimi verification gate. Empty means no installed Kimi version
# has passed live verification, so every standalone Kimi task classifies
# unknown kimi-unverified and fm-spawn wires no Kimi busy events. Kimi's
# rendered moon-phase spinner is deliberately NOT a state source here: the
# approved redesign forbids inventing a Kimi UI signature, and that spinner
# is locale- and emoji-font-sensitive.
#
# Preferred source, in order: Wire mode's JSON-RPC `prompt` request lifetime,
# whose outstanding request exactly brackets a turn and returns finished,
# cancelled, or max_steps_reached (so it covers interruption, which `Stop`
# does not); then the documented lifecycle hooks, which must include
# `Interrupt` because Kimi documents that `Stop` does not fire on interrupts.
#
# To open the gate: install Kimi, live-verify the chosen source brackets a
# real turn on a firstmate-launched worker including the interrupt path,
# record the version, exact commands, and observed output in
# docs/verification/supervision.md, add the verified version string(s) here,
# and land the wiring in fm-spawn behind this same gate in the same change.
FM_BUSY_KIMI_VERIFIED_VERSIONS=""

fm_busy_kimi_verified() {
  [ -n "$FM_BUSY_KIMI_VERIFIED_VERSIONS" ]
}

# fm_busy_codex_appserver_observable: capability/version negotiation for the
# Codex app-server turn lifecycle. Returns 0 only when a pane worker's turns
# are observable through the app-server protocol on the installed binary.
# codex-cli 0.145.0 verdict (live, 2026-07-28): NOT observable. The v2
# protocol does define the needed turn lifecycle (turn/started plus a
# turn/completed status of completed, interrupted, failed, or inProgress),
# but an interactive TUI worker neither starts nor attaches to the
# app-server daemon, and `codex app-server daemon start` refuses outside the
# managed standalone install, so no client can observe a pane worker's turns.
fm_busy_codex_appserver_observable() {
  return 1
}

# fm_busy_codex_hooks_verified: the sanctioned intermediate - Codex's stable
# hooks engine (UserPromptSubmit to open a turn, Stop and SessionEnd to close
# it). Returns 0 only once those hooks are live-verified to fire for a
# firstmate-launched worker. codex-cli 0.145.0 verdict (live, 2026-07-28):
# NOT verified. Firstmate-written project hooks under <worktree>/.codex/
# never fired in an interactive pane whose directory trust was granted, nor
# under `codex exec`, in either case with --dangerously-bypass-hook-trust,
# while global hooks fired in the same runs. Codex additionally exposes no
# StopFailure hook, so an API-error turn end would need separate coverage
# even after the discovery problem is solved.
fm_busy_codex_hooks_verified() {
  return 1
}

# fm_busy_codex_semantic_source: 0 when ANY verified Codex semantic source
# exists. fm-spawn arms and wires Codex only behind this gate, and the
# classifier reports unknown codex-unverified until it opens.
fm_busy_codex_semantic_source() {
  fm_busy_codex_appserver_observable || fm_busy_codex_hooks_verified
}

fm_busy_record_path() {  # <state-dir> <id>
  printf '%s/%s.busy-state' "$1" "$2"
}

fm_busy_gen_path() {  # <state-dir> <id>
  printf '%s/%s.busy-gen' "$1" "$2"
}

# fm_busy_token_valid: conservative token charset shared by gen, source, and
# event fields. Anything else is malformed.
fm_busy_token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_busy_current_gen: the task's armed gen token, or failure when the busy
# contract has never been armed for this task.
fm_busy_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}

# fm_busy_sources_for_harness: the semantic sources trusted to classify a
# task recorded with <harness>. One line, space-separated, possibly empty.
# The firstmate-owned sources are appended for every converted adapter.
# Grok and muse deliberately trust nothing: neither has a semantic WRITER, so
# neither is armed, and both read their live source on demand in the classifier
# (grok's rendered tail, muse's session log) rather than through a stored
# record. Listing a source here without a writer that can clear it would seed a
# busy record nothing could ever settle.
fm_busy_sources_for_harness() {  # <harness>
  local adapter=
  case "${1:-}" in
    claude*) adapter=claude-hook ;;
    codex*)
      fm_busy_codex_semantic_source || { printf ''; return 0; }
      adapter='codex-hook codex-appserver'
      ;;
    opencode*) adapter=opencode-plugin ;;
    pi|pi-signed) adapter=pi-ext ;;
    kimi*)
      fm_busy_kimi_verified || { printf ''; return 0; }
      adapter='kimi-wire kimi-hook'
      ;;
    agy*)
      adapter=agy-hook
      ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s fm-spawn fm-interrupt fm-recovery' "$adapter"
}

fm_busy_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(fm_busy_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# fm_busy_record_read: parse and validate state/<id>.busy-state against the
# armed gen. Prints "<state> <source> <event> <seq>" for a valid record.
# Non-zero returns name the reason on stdout instead:
#   missing      no record file (or no armed gen and no record)
#   malformed    unparseable line, bad tokens, or a missing armed gen for an
#                existing record
#   gen-mismatch a record from a stale incarnation
fm_busy_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts=''
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(fm_busy_current_gen "$state" "$id"); then
    # A record without an armed gen has no incarnation to bind to.
    printf 'malformed'
    return 1
  fi
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  # `read -a` rather than `set --`: it never glob-expands a field and never
  # touches the caller's positional parameters or shell options.
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq"
}

# ---------------------------------------------------------------------------
# muse session-log busy source
#
# muse persists an append-only session event log per session at
# <sessions-root>/YYYY/MM/DD/<session-uuid>/session.jsonl, and brackets every
# submitted turn with one run lifecycle pair. Verified live on muse
# 0.1.0-R708.1 across completed, interrupted, and killed-mid-turn turns:
#   {"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started",...
#   {"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"terminal",
#     "terminal":"completed"|"cancelled",...
# An Escape interrupt closes its run with terminal=cancelled, so unlike Claude's
# Stop hook this source covers the interrupt path itself. Any later
# run_retracted records follow the terminal rather than replacing it.
#
# Both halves of the fold are trusted. An open run is positive proof a turn is
# in flight, and a settled log is idle: the credentialed multi-step smoke showed
# one run pair spans a whole multi-step turn, including an Escape interrupt that
# closes the run with terminal=cancelled instead of continuing the turn in
# another run. This gives the settled log the same idle trust as the Claude and
# Pi push sources. A version allowlist would be false precision and a maintenance
# treadmill for an auto-updating vendor binary: busy classification receives
# only the normalized muse harness identity, while session metadata records
# semver 0.1.0 plus a build SHA that cannot be matched against it. Resolution
# failures - no sidecar, no matching log, an unreadable or run-free log - remain
# unknown because those prove nothing about the turn either way. See
# docs/verification/muse.md for the evidence.
# fm_busy_muse_binding_path: the per-task sidecar fm-spawn writes so the
# classifier binds a pane to its session log without re-deriving muse's data
# directory. It records sessions_root=<abs>, workspace_root=<abs>, one
# binding_id=<token>, and one prior_log=<abs> for each matching main log that
# predates this pane.
fm_busy_muse_binding_path() {  # <state-dir> <id>
  printf '%s/%s.muse-session' "$1" "$2"
}

fm_busy_muse_cache_path() {  # <state-dir> <id>
  printf '%s/%s.muse-session-current' "$1" "$2"
}

# fm_busy_muse_binding_field: read one field from the sidecar, or fail.
fm_busy_muse_binding_field() {  # <state-dir> <id> <key>
  local path line key=$3
  path=$(fm_busy_muse_binding_path "$1" "$2")
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        line=${line#"$key="}
        [ -n "$line" ] || return 1
        printf '%s' "$line"
        return 0
        ;;
    esac
  done < "$path"
  return 1
}

# fm_busy_muse_matching_logs: every MAIN session log whose recorded
# workspace_root is this task's worktree. The depth bounds are what exclude
# muse's own native sub-agent logs, which live one directory deeper under
# subagent/<child-session-id>/session.jsonl and carry their own independent run
# lifecycle - folding a child's log would report the parent busy long after the
# parent's turn ended.
fm_busy_muse_matching_logs() {  # <sessions-root> <workspace-root>
  local root=$1 ws=$2
  [ -d "$root" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  node - "$root" "$ws" <<'NODE'
const fs = require("fs");
const path = require("path");
const [root, workspace] = process.argv.slice(2);

function directories(parent) {
  try {
    return fs.readdirSync(parent, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(parent, entry.name));
  } catch {
    return [];
  }
}

function metadataWorkspace(file) {
  let descriptor;
  try {
    descriptor = fs.openSync(file, "r");
    const buffer = Buffer.alloc(65536);
    const length = fs.readSync(descriptor, buffer, 0, buffer.length, 0);
    const newline = buffer.indexOf(10, 0);
    if (newline < 0 || newline >= length) return null;
    const record = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
    return record?.payload?.record?.workspace_root ?? null;
  } catch {
    return null;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

for (const year of directories(root)) {
  for (const month of directories(year)) {
    for (const day of directories(month)) {
      for (const session of directories(day)) {
        const file = path.join(session, "session.jsonl");
        try {
          if (!fs.lstatSync(file).isFile()) continue;
        } catch {
          continue;
        }
        if (metadataWorkspace(file) === workspace) process.stdout.write(`${file}\n`);
      }
    }
  }
}
NODE
}

fm_busy_muse_binding_has_prior_log() {  # <state-dir> <id> <session-log>
  local path line
  path=$(fm_busy_muse_binding_path "$1" "$2")
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "prior_log=$3" ] && return 0
  done < "$path"
  return 1
}

fm_busy_muse_cache_field() {  # <state-dir> <id> <key>
  local path line key=$3
  path=$(fm_busy_muse_cache_path "$1" "$2")
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        line=${line#"$key="}
        [ -n "$line" ] || return 1
        printf '%s' "$line"
        return 0
        ;;
    esac
  done < "$path"
  return 1
}

fm_busy_muse_main_log_path_valid() {  # <sessions-root> <session-log>
  local root=${1%/} log=$2 rel year month day session leaf
  while :; do
    case "$root" in
      *'//'*) root=${root//\/\//\/} ;;
      *) break ;;
    esac
  done
  [ -n "$root" ] && [ -f "$log" ] && [ ! -L "$log" ] || return 1
  case "$log" in
    "$root"/*) rel=${log#"$root"/} ;;
    *) return 1 ;;
  esac
  year=${rel%%/*}; rel=${rel#*/}
  month=${rel%%/*}; rel=${rel#*/}
  day=${rel%%/*}; rel=${rel#*/}
  session=${rel%%/*}; leaf=${rel#*/}
  [ -n "$year" ] && [ -n "$month" ] && [ -n "$day" ] && [ -n "$session" ] \
    && [ "$leaf" = session.jsonl ]
}

fm_busy_muse_namespace_day() {  # <sessions-root>
  printf '%s/%s' "${1%/}" "$(date '+%Y/%m/%d')"
}

fm_busy_muse_namespace_signature() {  # <day-directory>
  local first first_signature manifest='' path paths signature
  if [ ! -d "$1" ]; then
    printf '%s' missing
    return 0
  fi
  paths=$(find "$1" -mindepth 2 -maxdepth 2 -type f -name session.jsonl -print 2>/dev/null) \
    || return 1
  paths=$(printf '%s\n' "$paths" | LC_ALL=C sort) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    first=$(sed -n '1p' "$path") || return 1
    first_signature=$(printf '%s' "$first" | cksum | awk '{ print $1 ":" $2 }') || return 1
    manifest="${manifest}${path}:${first_signature}
"
  done <<EOF
$paths
EOF
  signature=$(printf '%s' "$manifest" | cksum | awk '{ print $1 ":" $2 }') || return 1
  [ -n "$signature" ] || return 1
  printf '%s' "$signature"
}

fm_busy_muse_cached_session_log() {  # <state-dir> <id> <root> <binding-id>
  local cache_binding log cache_day cache_signature day signature
  [ -n "$4" ] || return 1
  cache_binding=$(fm_busy_muse_cache_field "$1" "$2" binding_id) || return 1
  [ "$cache_binding" = "$4" ] || return 1
  log=$(fm_busy_muse_cache_field "$1" "$2" session_log) || return 1
  fm_busy_muse_main_log_path_valid "$3" "$log" || return 1
  fm_busy_muse_binding_has_prior_log "$1" "$2" "$log" && return 1
  cache_day=$(fm_busy_muse_cache_field "$1" "$2" namespace_day) || return 1
  cache_signature=$(fm_busy_muse_cache_field "$1" "$2" namespace_signature) || return 1
  day=$(fm_busy_muse_namespace_day "$3") || return 1
  [ "$cache_day" = "$day" ] || return 1
  signature=$(fm_busy_muse_namespace_signature "$day") || return 1
  [ "$cache_signature" = "$signature" ] || return 1
  printf '%s' "$log"
}

fm_busy_muse_cache_session_log() {  # <state-dir> <id> <binding-id> <session-log> <namespace-day> <namespace-signature>
  local cache tmp current
  [ -n "$3" ] || return 0
  current=$(fm_busy_muse_binding_field "$1" "$2" binding_id) || return 1
  [ "$current" = "$3" ] || return 1
  cache=$(fm_busy_muse_cache_path "$1" "$2")
  tmp="$cache.tmp.$$"
  {
    printf 'binding_id=%s\n' "$3"
    printf 'session_log=%s\n' "$4"
    printf 'namespace_day=%s\n' "$5"
    printf 'namespace_signature=%s\n' "$6"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$cache"
}

# fm_busy_muse_session_log: the one matching MAIN session log that did not
# exist when fm-spawn created this pane's binding. Multiple candidates are
# ambiguous and fail closed rather than guessing which pane owns either log.
fm_busy_muse_session_log() {  # <state-dir> <id>
  local root ws binding_id='' candidate selected='' cache namespace_day namespace_before namespace_after
  root=$(fm_busy_muse_binding_field "$1" "$2" sessions_root) || return 1
  ws=$(fm_busy_muse_binding_field "$1" "$2" workspace_root) || return 1
  binding_id=$(fm_busy_muse_binding_field "$1" "$2" binding_id 2>/dev/null || true)
  if cache=$(fm_busy_muse_cached_session_log "$1" "$2" "$root" "$binding_id"); then
    printf '%s' "$cache"
    return 0
  fi
  rm -f "$(fm_busy_muse_cache_path "$1" "$2")"
  namespace_day=$(fm_busy_muse_namespace_day "$root") || return 1
  namespace_before=$(fm_busy_muse_namespace_signature "$namespace_day") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    fm_busy_muse_binding_has_prior_log "$1" "$2" "$candidate" && continue
    [ -z "$selected" ] || return 1
    selected=$candidate
  done <<EOF
$(fm_busy_muse_matching_logs "$root" "$ws")
EOF
  [ -n "$selected" ] || return 1
  namespace_after=$(fm_busy_muse_namespace_signature "$namespace_day") || return 1
  [ "$namespace_before" = "$namespace_after" ] || return 1
  fm_busy_muse_cache_session_log "$1" "$2" "$binding_id" "$selected" \
    "$namespace_day" "$namespace_after" || return 1
  printf '%s' "$selected"
}

fm_busy_muse_run_events() {  # <session-log>
  [ -f "$1" ] || return 1
  LC_ALL=C awk '
    BEGIN { OFS = "\t"; pre = "\"payload\":{\"kind\":\"run\",\"run_id\":\"" }
    {
      p = index($0, pre)
      if (p == 0) next
      rest = substr($0, p + length(pre))
      q = index(rest, "\"")
      if (q == 0) next
      rid = substr(rest, 1, q - 1)
      rest = substr(rest, q)
      head = "\",\"event\":{\"kind\":\""
      if (substr(rest, 1, length(head)) != head) next
      rest = substr(rest, length(head) + 1)
      q = index(rest, "\"")
      if (q == 0) next
      ev = substr(rest, 1, q - 1)
      terminal = ""
      if (ev == "terminal") {
        marker = "\"terminal\":\""
        p = index(rest, marker)
        if (p != 0) {
          value = substr(rest, p + length(marker))
          q = index(value, "\"")
          if (q != 0) terminal = substr(value, 1, q - 1)
        }
      }
      if (ev == "started" || ev == "terminal") print rid, ev, terminal
    }
  ' "$1"
}

# fm_busy_muse_run_state: fold one session log to busy|settled|none.
#   busy     at least one run started with no matching terminal
#   settled  every started run reached a terminal
#   none     the log holds no run lifecycle records at all
# The match is anchored on the exact structural prefix rather than a bare
# "kind":"terminal" search, because muse also emits nested "record":{"kind":
# "terminal"} cleanup-effect payloads that are NOT run terminals and would
# otherwise close a run that is still in flight.
fm_busy_muse_run_state() {  # <session-log>
  [ -f "$1" ] || return 1
  fm_busy_muse_run_events "$1" | LC_ALL=C awk -F '\t' '
    $2 == "started" { open[$1] = 1; seen = 1 }
    $2 == "terminal" { open[$1] = 0 }
    END {
      if (!seen) { print "none"; exit }
      for (rid in open) if (open[rid] == 1) { print "busy"; exit }
      print "settled"
    }
  '
}

fm_busy_muse_active_run_id() {  # <session-log>
  [ -f "$1" ] || return 1
  fm_busy_muse_run_events "$1" | LC_ALL=C awk -F '\t' '
    $2 == "started" { open[$1] = 1 }
    $2 == "terminal" { open[$1] = 0 }
    END {
      for (rid in open) {
        if (open[rid] != 1) continue
        active = rid
        count++
      }
      if (count != 1) exit 1
      print active
    }
  '
}

fm_busy_muse_run_terminal() {  # <session-log> <run-id>
  [ -f "$1" ] && [ -n "${2:-}" ] || return 1
  fm_busy_muse_run_events "$1" | LC_ALL=C awk -F '\t' -v wanted="$2" '
    $1 == wanted && $2 == "terminal" && $3 != "" { terminal = $3 }
    END {
      if (terminal == "") exit 1
      print terminal
    }
  '
}

# cursor conversation-transcript busy source
#
# cursor-agent persists an append-only JSONL transcript per conversation at
# <projects-root>/<workspace-slug>/agent-transcripts/<conversation-id>/<id>.jsonl
# and brackets every submitted turn. Verified live on cursor-agent
# 2026.08.11-e8db854:
#   {"role":"user", ...}                                    <- turn opens
#   {"role":"assistant", ...}                               <- work
#   {"type":"turn_ended","status":"success"}                <- turn closes
# An Escape interrupt closes the turn with status "aborted", so like muse's
# session log - and unlike Claude's Stop hook - this source covers the manual
# interrupt path. Nothing is installed and no trust grant is needed: cursor
# writes this transcript on its own.
#
# Resolution deliberately does NOT reconstruct cursor's workspace-slug directory
# name. That slug is a lossy transformation of the workspace path (separators
# collapse), so rebuilding it would be a guess that silently binds the wrong
# pane. cursor writes the exact absolute path into each project directory's
# .workspace-trusted, so the binding matches on that recorded value instead.
#
# fm_busy_cursor_binding_path: the per-task sidecar fm-spawn writes. It records
# projects_root=<abs>, workspace_root=<abs>, and one prior_conversation=<id> for
# each conversation that already existed for that workspace when this pane
# launched, so a relaunched task cannot fold its predecessor's transcript.
fm_busy_cursor_binding_path() {  # <state-dir> <id>
  printf '%s/%s.cursor-session' "$1" "$2"
}

fm_busy_cursor_binding_field() {  # <state-dir> <id> <key>
  local path value
  path=$(fm_busy_cursor_binding_path "$1" "$2")
  [ -f "$path" ] || return 1
  value=$(LC_ALL=C awk -F= -v k="$3" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$path")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# fm_busy_cursor_project_dir: the project directory whose recorded
# .workspace-trusted workspacePath is exactly <workspace-root>. Exact-match
# only: a prefix or slug comparison would bind a nested worktree to its parent.
fm_busy_cursor_project_dir() {  # <projects-root> <workspace-root>
  local root=$1 want=$2 marker dir path
  [ -d "$root" ] || return 1
  for marker in "$root"/*/.workspace-trusted; do
    [ -f "$marker" ] || continue
    path=$(LC_ALL=C sed -n 's/.*"workspacePath"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$marker" | head -1)
    [ -n "$path" ] || continue
    [ "$path" = "$want" ] || continue
    dir=${marker%/.workspace-trusted}
    printf '%s' "$dir"
    return 0
  done
  return 1
}

# fm_busy_cursor_transcript: the ONE transcript this pane owns, or failure.
# A conversation recorded as prior_conversation is excluded, so a relaunch in a
# reused worktree folds its own turn rather than the previous pane's. Requiring
# a UNIQUE remaining conversation is what keeps the binding honest: zero means
# no turn has been submitted yet and several means the pane cannot be told
# apart, and neither proves anything about the current turn.
fm_busy_cursor_transcript() {  # <state-dir> <id>
  local root workspace project dir conv found='' count=0 prior
  root=$(fm_busy_cursor_binding_field "$1" "$2" projects_root) || return 1
  workspace=$(fm_busy_cursor_binding_field "$1" "$2" workspace_root) || return 1
  project=$(fm_busy_cursor_project_dir "$root" "$workspace") || return 1
  prior=$(LC_ALL=C awk -F= '$1 == "prior_conversation" { sub(/^[^=]*=/, ""); print }' \
    "$(fm_busy_cursor_binding_path "$1" "$2")" 2>/dev/null)
  for dir in "$project"/agent-transcripts/*/; do
    [ -d "$dir" ] || continue
    conv=$(basename -- "${dir%/}")
    printf '%s\n' "$prior" | grep -Fqx "$conv" && continue
    [ -f "$dir$conv.jsonl" ] || continue
    found="$dir$conv.jsonl"
    count=$((count + 1))
  done
  [ "$count" = 1 ] && [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# fm_busy_cursor_turn_state: fold the transcript into busy | settled | none.
# Lifecycle records are matched on top-level fields of structurally valid JSON,
# so a turn whose own text mentions turn_ended cannot close it.
fm_busy_cursor_turn_state() {  # <transcript>
  [ -f "$1" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    LC_ALL=C jq -Rr '
      try (
        fromjson
        | if type == "object" and .type? == "turn_ended" then "close"
          elif type == "object" and .role? == "user" then "open"
          else "other"
          end
      ) catch "malformed"
    ' "$1"
  else
    LC_ALL=C awk '
      function ws(    c) {
        while (p <= n) {
          c = substr(line, p, 1)
          if (c != " " && c != "\t" && c != "\r") break
          p++
        }
      }
      function hex(c) {
        if (c >= "0" && c <= "9") return c + 0
        c = tolower(c)
        return index("abcdef", c) + 9
      }
      function string(    c, e, h, i, code, out) {
        if (substr(line, p, 1) != "\"") return 0
        p++; out = ""
        while (p <= n) {
          c = substr(line, p++, 1)
          if (c == "\"") { value = out; kind = "string"; return 1 }
          if (c ~ /[[:cntrl:]]/) return 0
          if (c != "\\") { out = out c; continue }
          if (p > n) return 0
          e = substr(line, p++, 1)
          if (e == "\"" || e == "\\" || e == "/") out = out e
          else if (e ~ /^[bfnrt]$/) out = out "?"
          else if (e == "u") {
            h = substr(line, p, 4)
            if (length(h) != 4 || h !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return 0
            code = 0
            for (i = 1; i <= 4; i++) code = code * 16 + hex(substr(h, i, 1))
            out = out (code < 128 ? sprintf("%c", code) : "?")
            p += 4
          } else return 0
        }
        return 0
      }
      function number(    c) {
        if (substr(line, p, 1) == "-") p++
        c = substr(line, p, 1)
        if (c == "0") {
          p++
          if (substr(line, p, 1) ~ /^[0-9]$/) return 0
        } else if (c ~ /^[1-9]$/) {
          do { p++; c = substr(line, p, 1) } while (c ~ /^[0-9]$/)
        } else return 0
        if (substr(line, p, 1) == ".") {
          p++
          if (substr(line, p, 1) !~ /^[0-9]$/) return 0
          while (substr(line, p, 1) ~ /^[0-9]$/) p++
        }
        c = substr(line, p, 1)
        if (c == "e" || c == "E") {
          p++; c = substr(line, p, 1)
          if (c == "+" || c == "-") p++
          if (substr(line, p, 1) !~ /^[0-9]$/) return 0
          while (substr(line, p, 1) ~ /^[0-9]$/) p++
        }
        kind = "number"; value = ""
        return 1
      }
      function array(depth,    c) {
        p++; ws()
        if (substr(line, p, 1) == "]") { p++; return 1 }
        while (p <= n) {
          if (!json(depth + 1)) return 0
          ws(); c = substr(line, p, 1)
          if (c == "]") { p++; return 1 }
          if (c != ",") return 0
          p++; ws()
        }
        return 0
      }
      function object(depth,    c, key, vkind, vvalue, is_close, is_open) {
        p++; ws()
        if (substr(line, p, 1) == "}") { p++; kind = "object"; return 1 }
        while (p <= n) {
          if (!string()) return 0
          key = value; ws()
          if (substr(line, p, 1) != ":") return 0
          p++; ws()
          if (!json(depth + 1)) return 0
          vkind = kind; vvalue = value
          if (depth == 0 && key == "type") is_close = (vkind == "string" && vvalue == "turn_ended")
          if (depth == 0 && key == "role") is_open = (vkind == "string" && vvalue == "user")
          ws(); c = substr(line, p, 1)
          if (c == "}") {
            p++; kind = "object"; value = ""
            if (depth == 0) event = (is_close ? "close" : (is_open ? "open" : "other"))
            return 1
          }
          if (c != ",") return 0
          p++; ws()
        }
        return 0
      }
      function json(depth,    c, word) {
        ws(); c = substr(line, p, 1)
        if (c == "\"") return string()
        if (c == "{") return object(depth)
        if (c == "[") { kind = "array"; value = ""; return array(depth) }
        if (c == "-" || c ~ /^[0-9]$/) return number()
        word = substr(line, p)
        if (substr(word, 1, 4) == "true" || substr(word, 1, 4) == "null") { p += 4; kind = "literal"; value = ""; return 1 }
        if (substr(word, 1, 5) == "false") { p += 5; kind = "literal"; value = ""; return 1 }
        return 0
      }
      {
        line = $0; p = 1; n = length(line); event = "other"; kind = ""; value = ""
        valid = json(0); ws()
        print (valid && p > n ? event : "malformed")
      }
    ' "$1"
  fi | LC_ALL=C awk '
    $0 == "close" { open = 0; seen = 1; malformed = 0; next }
    $0 == "open" { open = 1; seen = 1; next }
    $0 == "malformed" { if (!open) malformed = 1; next }
    END {
      if (!seen || (!open && malformed)) { print "none"; exit }
      print (open ? "busy" : "settled")
    }
  '
}

# fm_busy_grok_tail_busy: the Grok-only temporary rendered-tail fallback.
# Consumes the tail on stdin; 0 when Grok's verified busy signature matches.
# FM_BUSY_REGEX still globally overrides the signature, mirroring the
# historical operator escape hatch.
fm_busy_grok_tail_busy() {
  grep -v '^[[:space:]]*$' | tail -12 \
    | grep -qiE "${FM_BUSY_REGEX:-${FM_DELIVERY_GROK_BUSY_REGEX_DEFAULT:-Ctrl\\+c:cancel}}"
}

# fm_busy_classify: semantic classification for a task whose endpoint the
# caller has already established as present. Prints "<verdict> <source>":
# busy|idle|unknown plus the producing source (see header). Never probes
# process state. <tail40> is optional pre-captured plain output used only by
# the Grok arm; when absent the Grok arm captures through fm_backend_capture
# if available, else reports unknown capture-failed.
fm_busy_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source native log
  case "$harness" in
    kimi*)
      if ! fm_busy_kimi_verified; then
        printf 'unknown kimi-unverified'
        return 0
      fi
      ;;
    codex*)
      if ! fm_busy_codex_semantic_source; then
        printf 'unknown codex-unverified'
        return 0
      fi
      ;;
    cursor*)
      # Semantic, on demand: fold this task's bound conversation transcript. A
      # turn open past its last close is positive proof of a turn in flight and
      # a trailing turn_ended is a finished turn. Every other outcome - no
      # sidecar, no resolvable transcript, an unreadable or record-free file -
      # is unknown, never idle. The rendered `ctrl+c to stop` footer is
      # deliberately NOT consulted here; see the source note above.
      if ! log=$(fm_busy_cursor_transcript "$state" "$id"); then
        printf 'unknown cursor-transcript'
        return 0
      fi
      case "$(fm_busy_cursor_turn_state "$log" 2>/dev/null)" in
        busy) printf 'busy cursor-transcript' ;;
        settled) printf 'idle cursor-transcript' ;;
        *) printf 'unknown cursor-transcript' ;;
      esac
      return 0
      ;;
  esac
  out=$(fm_busy_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    if fm_busy_source_trusted "$harness" "$r_source"; then
      printf '%s %s' "$r_state" "$r_source"
    else
      printf 'unknown source-mismatch'
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  # No record at all. A native herdr busy verdict is semantic enough to trust
  # for BUSY (streaming means a turn is running); native idle is narrower
  # than turn state (a long foreground tool call reads idle) and stays
  # unknown here.
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
    if [ "$native" = busy ]; then
      printf 'busy herdr-native'
      return 0
    fi
  fi
  case "$harness" in
    muse*)
      # Semantic, on demand: fold this task's bound session log. An open run is
      # positive proof of a turn in flight and a settled log is a finished turn.
      # Every other outcome - no sidecar, no matching log, an unreadable or
      # run-free log - is unknown, never idle.
      if ! log=$(fm_busy_muse_session_log "$state" "$id"); then
        printf 'unknown muse-session-log'
        return 0
      fi
      case "$(fm_busy_muse_run_state "$log" 2>/dev/null)" in
        busy) printf 'busy muse-session-log' ;;
        settled) printf 'idle muse-session-log' ;;
        *) printf 'unknown muse-session-log' ;;
      esac
      return 0
      ;;
    grok*)
      if [ -z "$tail40" ]; then
        if command -v fm_backend_capture >/dev/null 2>&1; then
          tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
            printf 'unknown capture-failed'
            return 0
          }
        else
          printf 'unknown capture-failed'
          return 0
        fi
      fi
      if printf '%s' "$tail40" | fm_busy_grok_tail_busy; then
        printf 'busy grok-regex'
      else
        printf 'idle grok-regex'
      fi
      return 0
      ;;
  esac
  printf 'unknown missing'
}

# fm_busy_classify_live: fm_busy_classify behind the one process-level
# override - a gone endpoint is dead, never busy. Requires fm-backend.sh to
# be sourced for fm_backend_target_exists.
fm_busy_classify_live() {  # <backend> <target> <harness> <id> <state-dir> [expected-label]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 label=${6-}
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  if ! fm_backend_target_exists "$backend" "$target" "$label" 2>/dev/null; then
    printf 'dead endpoint-gone'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state"
}

# fm_busy_classify_meta: classify a task from its recorded metadata, so every
# consumer resolves backend, target, and harness the same way instead of
# re-deriving them. Requires fm-backend.sh to be sourced. <tail40> is
# optional pre-captured plain output reused by the Grok arm.
fm_busy_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}

# fm_busy_is_busy: boolean view for callers that only gate on provable
# activity. 0 iff the classification verdict is exactly busy; idle, unknown,
# and dead all return 1, so an unknown can never be silently promoted to
# either boolean pole - callers that must distinguish idle from unknown read
# the full classification instead.
fm_busy_is_busy() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local verdict
  verdict=$(fm_busy_classify "$@")
  [ "${verdict%% *}" = busy ]
}
