#!/usr/bin/env bash
# fm-bearings-board.sh - build and arm the /bearings lavish fleet board.
#
# The board is the captain-facing interactive surface of /bearings lavish: the
# shipped template (.agents/skills/bearings/assets/board-template.html) plus one
# injected fm-bearings-board.v1 JSON payload. This script owns the mechanics so
# the invoking agent's per-run work stays "compose the JSON, run build" - the
# agent never authors board UI at invocation time.
#
# Usage:
#   fm-bearings-board.sh build <data.json>
#   fm-bearings-board.sh compose <dest.json>
#   fm-bearings-board.sh refresh
#   fm-bearings-board.sh path
#
# compose    Write a deterministic fm-bearings-board.v1 payload built from the
#            canonical snapshot (bin/fm-bearings-snapshot.sh --json): the fleet
#            rows, one fallback card per open captain call, and nothing an
#            agent would have to judge. The fallback card carries the call's
#            durable summary as its title, no options, and freeform answers
#            only; the raise-time card in the durable store is merged first by
#            build, so it supplies the real options whenever one was written.
#            A Charted Next gate is composed dispatchable=false and only the
#            parenthesized sentinel ids are classified as warnings, because
#            the snapshot proves neither a cleared blocker-and-time gate nor a
#            richer kind, and prose is never read to guess either.
# refresh    compose to a temporary path, then build it. This is the scheduled
#            path that keeps the board current with no agent turn: a cron or
#            timer pass runs `refresh` and Lavish's live reload redraws every
#            open review, phone included. It never invents the richer copy or
#            the dispatch picker a /bearings lavish composition owns; re-run
#            that composition when the board needs them.
#
# build      Validate the payload, drop the Captain's Call cards whose subject
#            already landed, give every surviving decision card the standard
#            reconcile choice, and inject the result into a fresh copy of the
#            shipped template at the stable board path. Establish the Lavish
#            session on that board and PROVE it is live BEFORE binding and
#            arming its answer source, so a registered poll can never race a
#            session that does not exist or attach to one that has ended.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm, so the board can never produce an answer that has
#            nowhere to go (captain-hold-lifecycle's ordering rule, enforced
#            here rather than left to agent memory). Output starts with
#            `board: <path>`, then includes lavish-axi's session output and
#            the remaining status:
#              session: live | reopened
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
#              listening: <owner>            (only when a replacement was needed)
#            Every dropped card is named on stderr as a `dropped-landed-card:`
#            line, so a rebuild states what it removed instead of quietly
#            shrinking Captain's Call.
# path       Print the stable board path for this home.
#
# A LIVE SESSION IS PROVED, NEVER ASSUMED. `lavish-axi <file>` exits 0 even
# when it refuses to reopen a session the captain ended from the browser,
# reporting `status: user-ended` with the same session id, so exit status alone
# cannot tell a live board from a dead one. build requires the server's fresh
# session listing to show the canonical board open and refuses rather than
# arming an ended session. After a reopen it retires the pre-reopen source
# generation through the guarded adapter path, arms a fresh registration, and
# accepts only the replacement listener as live. A registered board with no
# live owner also gets a replacement before build returns, because
# `already-armed` is not the same fact as `listening`.
#
# CAPTAIN'S CALL HYGIENE. A decision card is dropped when its work item, PR, or
# structured artifact/version subject appears among the payload's own landed
# rows, or when `bin/fm-captain-hold.sh open` reports the task is no longer an
# open captain call. A newer published version also supersedes a version card.
# A task whose state cannot be established is kept, because a call wrongly
# hidden is worse than a card wrongly shown. Cleanup is therefore a normal
# rebuild effect rather than a committed migration or direct state mutation.
#
# THE RECONCILE CHOICE. Every decision card carries the standard `reconcile`
# option, injected here so the guarantee does not depend on the composer's
# memory, and the payload validator reserves that value across every card type.
# The validator's reservation scope must equal the adapter's reconcile
# classification scope, which is all card types because the captured payload
# carries no card type. Its meaning, and the reason it can never reach the
# keyed-answer intake as a blind close, are owned by
# docs/captain-hold-lifecycle.md.
#
# DURABLE DECISION CARDS. `build` also writes every surviving decision card to
# state/decision-cards/<task>.json (schema fm-decision-card.v1), because the
# board page is rebuilt from scratch and a card absent from the newest payload
# would otherwise be lost to later readers such as the captain's deck. The stored
# record is the EFFECTIVE card, reconcile choice included. A record whose task
# is definitely no longer an open captain call is pruned; an absent or
# unestablished task keeps its record, because a card wrongly hidden is worse
# than one wrongly shown.
#
# The store has a second writer: bin/fm-captain-hold.sh writes the same record
# when a call is RAISED with structured options, so the Deck shows the options,
# context, and recommendation the asking agent already had instead of waiting
# for a composition to re-derive them. The store is therefore a source for a
# key as well as a sink, and its precedence rule is STORE-FIRST: for a key the
# payload also carries, the stored record is the effective card, because it was
# authored where the question was raised and can be newer than the payload's
# snapshot; the payload's copy is used only for a key the store does not hold.
# Every merged record is re-validated in its stored form and a malformed record
# is reported and left out rather than failing the build, so a damaged file can
# never take the board down.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-bearings-board.v1 and every renderer-consumed field must satisfy
# the fm-bearings-board.v1 types and item invariants below. Every fleet row and
# Captain's Call item explicitly carries `repo`; the composer fills it from the
# snapshot and task records wherever known, and uses null or an empty string
# only as the deliberate genuinely-no-repo marker. In that exceptional case
# the template may display the routing id. Anything else refuses before the
# existing board is touched.
#
# Every Underway row likewise carries a non-empty `name`: the durable task name
# when known, otherwise its durable identifier.
# A Charted Next row MAY carry `filed`, the durable filed date (YYYY-MM-DD, or
# that date with a UTC timestamp) the template orders the section by, newest
# first; a row with no comparable date keeps its payload order after every dated
# row. Anything else in that field refuses rather than sorting on garbage.
#
# The board path is stable - $FM_HOME/.lavish/bearings-board.html - so a
# re-invocation rebuilds the same file in place, which keeps the same Lavish
# session URL and the same canonical process-event source id. Injection escapes
# every `<` in the compact JSON as the \u003c string escape, so a payload string
# containing "</script>" can never terminate the data block early.
#
# FM_BEARINGS_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-decision-card-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-decision-card-lib.sh"

TEMPLATE="${FM_BEARINGS_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/board-template.html}"
SNAPSHOT_BIN="${FM_BEARINGS_BOARD_SNAPSHOT:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
PLACEHOLDER='__FM_BEARINGS_BOARD_DATA__'
BOARD_SCHEMA=fm-bearings-board.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/bearings-board.html\n' "$FM_HOME"; }

# --- deterministic refresh ---------------------------------------------------
# The floor under the agent composition: rows the snapshot proves, a fallback
# card per open call, and the durable store merged in by build. Nothing here
# reads prose to classify anything, and nothing here invents ranking judgment.
compose_payload() {  # <dest.json>
  local dest=$1 snapshot tmp file key extra='[]' card='' stored='' reasons=''
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -x "$SNAPSHOT_BIN" ] || fail "the bearings snapshot is missing: $SNAPSHOT_BIN"
  snapshot=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-snapshot.XXXXXX") \
    || fail "cannot stage the snapshot"
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-composed.XXXXXX") \
    || { rm -f -- "$snapshot"; fail "cannot stage the composed payload"; }
  if ! "$SNAPSHOT_BIN" --json > "$snapshot" 2>/dev/null; then
    rm -f -- "$snapshot" "$tmp"
    fail "the bearings snapshot failed: $SNAPSHOT_BIN --json"
  fi
  if ! jq -e '.schema == "fm-bearings.v1"' "$snapshot" >/dev/null 2>&1; then
    rm -f -- "$snapshot" "$tmp"
    fail "the bearings snapshot is not fm-bearings.v1: $SNAPSHOT_BIN"
  fi
  if ! jq --slurpfile fleet "$snapshot" '
    def artifact_url: (.artifact // "") | select(test("^https://"));
    def artifact_repo:
      (.artifact // "")
      | if test("^https://github\\.com/[^/]+/[^/]+")
        then capture("^https://github\\.com/[^/]+/(?<repo>[^/]+)").repo
        else null end;
    def home_repo: if (.owner // "") == "(main)" then null else .owner end;
    $fleet[0] as $s
    | {
        schema: "fm-bearings-board.v1",
        home: $s.home,
        generated: $s.generated,
        prs_live: false,
        captains_call: [
          $s.decisions_open[]?
          | {key: (.key // .id), type: "decision", repo: null,
             title: (.summary // .id), options: [], allow_freeform: true}
        ],
        underway: [
          $s.in_flight[]?
          | {id: .id, state: .state, doing: (.doing // "-"), kind: .kind,
             name: .name, repo: (.repo // home_repo)}
        ],
        landed: [
          $s.landed[]?
          | {id: .id, what: .what, owner: .owner, repo: artifact_repo}
          + (if (artifact_url // "") == "" then {} else {pr_url: artifact_url} end)
        ],
        charted: [
          $s.gates[]?
          | {id: (.id | if test("^\\(") then gsub("[^A-Za-z0-9._-]"; "") else . end),
             title: .title, reason: (.reason // ""), repo: home_repo,
             dispatchable: false,
             kind: (if (.id | test("^\\(")) then "warning" else "queued" end)}
          + (if (.filed // null) == null then {} else {filed: .filed} end)
        ],
        charted_more: 0,
        charted_warning_more: 0
      }' "$snapshot" > "$tmp"; then
    rm -f -- "$snapshot" "$tmp"
    fail "cannot compose the board payload from the snapshot"
  fi
  rm -f -- "$snapshot"
  # The durable store is a SOURCE for a card the composed payload cannot author
  # itself: an agent-authored `merge.<task>` card for a call the snapshot still
  # lists as live. A stored card for a blocked, dated, reconciling, or aged hold
  # must stay out of Captain's Call - those holds belong to the disclosed
  # Charted Next gates, and the durable record remains in the store until the
  # call is live again. Every merged record is re-validated in its stored form; a
  # malformed one is named on stderr and skipped rather than failing the whole
  # refresh. The injected reconcile choice is stripped before appending because
  # the authored contract reserves it and build injects exactly one itself.
  if [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ]; then
    for file in "$DECISION_CARDS_DIR"/*.json; do
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      key=$(basename "$file" .json)
      case "$key" in merge.*) ;; *) continue ;; esac
      jq -e --arg key "$key" '[.captains_call[]?.key] | index($key) != null' "$tmp" >/dev/null 2>&1 && continue
      jq -e --arg task "${key#merge.}" '[.captains_call[]?.key] | index($task) != null' "$tmp" >/dev/null 2>&1 || continue
      card=$(jq -c '.card? // empty' "$file" 2>/dev/null) || card=''
      reasons=''
      if [ -n "$card" ]; then
        reasons=$(printf '%s' "$card" | jq -r "$FM_DECISION_CARD_JQ_DEFS"'
          if stored_call_item then "" else (call_reasons | join("; ")) end' 2>/dev/null) \
          || reasons='unreadable record'
      else
        reasons='unreadable record'
      fi
      if [ -n "$reasons" ]; then
        printf 'ignored-store-card: %s (%s)\n' "$key" "$reasons" >&2
        continue
      fi
      if [ "$(jq -r '.card.key? // empty' "$file" 2>/dev/null)" != "$key" ]; then
        printf 'ignored-store-card: %s (record key does not match its file name)\n' "$key" >&2
        continue
      fi
      card=$(printf '%s' "$card" | jq -c '
        .options = [(.options // [])[] | select(.value != "reconcile")]') || continue
      extra=$(printf '%s' "$extra" | jq -c --argjson card "$card" '. + [$card]') || continue
    done
  fi
  if [ "$extra" != '[]' ]; then
    if ! jq --argjson extra "$extra" '.captains_call += $extra' "$tmp" > "$tmp.next"; then
      rm -f -- "$tmp" "$tmp.next"
      fail "cannot add the durable decision cards to the composed payload"
    fi
    mv -f -- "$tmp.next" "$tmp" || { rm -f -- "$tmp" "$tmp.next"; fail "cannot publish the composed payload"; }
  fi
  if ! validate_payload "$tmp"; then
    rm -f -- "$tmp"
    fail "the composed payload does not satisfy $BOARD_SCHEMA"
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; fail "cannot write the composed payload: $dest"; }
}

command_compose() {  # <dest.json>
  local dest=${1-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  [ -n "$dest" ] || { usage >&2; exit 2; }
  compose_payload "$dest"
  printf 'composed: %s\n' "$dest"
}

command_refresh() {
  local data
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  data=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-refresh.XXXXXX") \
    || fail "cannot stage the refreshed payload"
  if ! compose_payload "$data"; then
    rm -f -- "$data"
    fail "cannot refresh the board from the snapshot"
  fi
  if ! command_build "$data"; then
    rm -f -- "$data"
    fail "cannot build the refreshed board"
  fi
  rm -f -- "$data"
}

validate_payload() {  # <data.json>
  # The authored-card contract is shared with the raise-time writer
  # (bin/fm-captain-hold.sh) and owned once by bin/fm-decision-card-lib.sh, so
  # the payload validator and the CLI can never disagree about a valid card.
  jq -e --arg schema "$BOARD_SCHEMA" "$FM_DECISION_CARD_JQ_DEFS"'
    def name_marker: has("name") and (.name | nonempty_string);
    def valid_filed:
      . as $filed
      | type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)?$")
      and (if test("T")
        then try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $filed) catch false
        else try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $filed) catch false
        end);
    def optional_filed:
      (has("filed") | not) or (.filed == null) or (.filed | valid_filed);
    # slug, repo_marker, optional_*, version, optional_subject, and call_item
    # are spliced in from bin/fm-decision-card-lib.sh above.
    def underway_item:
      type == "object" and repo_marker and name_marker and (.id | nonempty_string)
      and (.state | nonempty_string) and (.doing | nonempty_string) and (.kind | nonempty_string);
    def landed_item:
      type == "object" and repo_marker and (.id | nonempty_string)
      and (.what | nonempty_string) and (.owner | nonempty_string)
      and optional_https_url("pr_url")
      and optional_subject;
    def charted_item:
      type == "object" and repo_marker and (.id | slug(128))
      and (.title | nonempty_string) and (.reason | type == "string")
      and (.dispatchable | type == "boolean")
      and ((has("kind") | not) or (.kind == "queued" or .kind == "warning"))
      and optional_filed
      and (if .kind == "warning" then .dispatchable == false else true end);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.prs_live | type == "boolean")
    and (.captains_call | type == "array")
    and (.underway | type == "array")
    and (.landed | type == "array")
    and (.charted | type == "array")
    and ((has("charted_more") | not)
      or ((.charted_more | type == "number") and (.charted_more >= 0) and (.charted_more | floor == .)))
    and ((has("charted_warning_more") | not)
      or ((.charted_warning_more | type == "number") and (.charted_warning_more >= 0) and (.charted_warning_more | floor == .)))
    and ([.captains_call[] | call_item] | all)
    and ([.underway[] | underway_item] | all)
    and ([.landed[] | landed_item] | all)
    and ([.charted[] | charted_item] | all)
  ' "$1" >/dev/null
}

# --- Lavish session liveness -------------------------------------------------
# Verified against lavish-axi 0.1.61. `lavish-axi <file>` EXITS 0 even when it
# refuses to reopen a session the captain ended from the browser, reporting
# `status: user-ended` and the same session id, so an exit-code check alone
# cannot tell a live board from a dead one. The establish status is an initial
# signal only; the server's fresh session listing must also show the canonical
# board open before the build may bind or arm its source.

board_realpath() {  # <board>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

lavish_status_field() {  # <lavish-axi output>
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"'
}

# The server's own listing, keyed on the canonical artifact path. Rows are
# `<file>,<status>,"<url>",<pending>`, and only a live session is listed `open`.
lavish_session_listed_open() {  # <canonical-board-path>
  local listing
  listing=$(lavish-axi 2>/dev/null) || return 1
  printf '%s\n' "$listing" | awk -v path="$1" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest = substr(line, length(path) + 2)
      split(rest, field, ",")
      if (field[1] == "open") { found = 1 }
    }
    END { exit found ? 0 : 1 }
  '
}

lavish_board_live() {  # <establish output> <canonical-board-path>
  lavish_session_listed_open "$2"
}

# Establish the board session and PROVE it is live before anything arms a poll
# on it. A session the captain ended is reopened once - the captain asked for
# this board, which is exactly the attention `--reopen` exists for - and a
# session that is still not live after that refuses the build rather than
# arming a poll that can never attach.
establish_board_session() {  # <board>
  local board=$1 real out status version
  BOARD_SESSION_REOPENED=0
  real=$(board_realpath "$board") || fail "cannot resolve the board path: $board"
  out=$(lavish-axi "$board") || fail "cannot establish the board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    printf 'session: live\n'
    return 0
  fi
  out=$(lavish-axi "$board" --reopen) || fail "cannot reopen the ended board Lavish session"
  printf '%s\n' "$out"
  if lavish_board_live "$out" "$real"; then
    BOARD_SESSION_REOPENED=1
    printf 'session: reopened\n'
    return 0
  fi
  status=$(lavish_status_field "$out")
  version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
  fail "the board Lavish session is not live after reopening it (lavish-axi ${version:-version-unknown} reported status ${status:-none}); refusing to arm a poll on an ended session"
}

# --- Captain's Call hygiene ---------------------------------------------------
# A held decision whose subject already shipped is not a live call, so it is
# dropped here instead of being carded again. All checks use exact structured
# identities; unknown subject state keeps the card.

decision_card_is_stale() {  # <task-id> <landed-0-or-1>
  local task=$1 landed=$2 rc=0
  if [ "$landed" = 1 ]; then
    printf 'structured subject already landed\n'
    return 0
  fi
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
  # 1 is a definite "no longer an open captain call". 2 is "cannot tell", 3 is
  # absent from this backlog, and a call wrongly hidden is worse than a card
  # wrongly shown, so both uncertain and absent cards stay.
  if [ "$rc" -eq 1 ]; then
    printf 'no longer an open captain call\n'
    return 0
  fi
  return 1
}

# Drop every stale decision card, then give every surviving decision card the
# standard reconcile choice. Injecting it here is what makes "every decision
# card offers reconcile" a property of the board rather than of the composer's
# memory; the validator prevents duplicate decision options.
merge_store_cards() {  # <data.json> <dest.json>
  # STORE-FIRST. A durable record written at raise time (or by an earlier
  # build) replaces the payload's card for the same key; the payload card is
  # used only where the store holds nothing. Order is preserved, and a record
  # that fails the stored form of the shared contract is named on stderr and
  # skipped rather than failing the build.
  local data=$1 dest=$2 key file stored reasons staged
  cp -- "$data" "$dest" || return 1
  [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    file="$DECISION_CARDS_DIR/$key.json"
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    stored=$(jq -c '.card? // empty' "$file" 2>/dev/null) || stored=''
    reasons=''
    if [ -n "$stored" ]; then
      reasons=$(printf '%s' "$stored" | jq -r "$FM_DECISION_CARD_JQ_DEFS"'
        if stored_call_item then "" else (call_reasons | join("; ")) end' 2>/dev/null) \
        || reasons='unreadable record'
    else
      reasons='unreadable record'
    fi
    if [ -n "$reasons" ]; then
      printf 'ignored-store-card: %s (%s)\n' "$key" "$reasons" >&2
      continue
    fi
    # A record answers for its own key only: a file whose card names another
    # task would otherwise be merged into this key's slot.
    if [ "$(jq -r '.card.key? // empty' "$file" 2>/dev/null)" != "$key" ]; then
      printf 'ignored-store-card: %s (record key does not match its file name)\n' "$key" >&2
      continue
    fi
    staged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-card.XXXXXX") || return 1
    if ! jq --arg key "$key" --slurpfile record "$file" '
          .captains_call = [.captains_call[]
            | if .key == $key then $record[0].card else . end]' "$dest" > "$staged"; then
      rm -f -- "$staged"
      return 1
    fi
    mv -f -- "$staged" "$dest" || { rm -f -- "$staged"; return 1; }
  done < <(jq -r '.captains_call[]?.key' "$data")
  return 0
}

effective_payload() {  # <data.json> <dest.json>
  local data=$1 dest=$2 merged rc=0
  merged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-merged.XXXXXX") || return 1
  if ! merge_store_cards "$data" "$merged"; then
    rm -f -- "$merged"
    return 1
  fi
  landed_drop_and_inject "$merged" "$dest" || rc=$?
  rm -f -- "$merged"
  return "$rc"
}

landed_drop_and_inject() {  # <data.json> <dest.json>
  local data=$1 dest=$2 landed_keys key reason drop='' tmp landed=0
  landed_keys=$(jq -c '
    def version_parts: split(".") | map(tonumber);
    . as $payload
    | [$payload.captains_call[]
      | select(.type == "decision")
      | . as $card
      | select(
          ($payload.landed | any(.id == $card.key))
          or (($card.pr_url? != null) and ($payload.landed | any(.pr_url? == $card.pr_url)))
          or (($card.subject? != null) and ($payload.landed | any(
            (.subject? != null)
            and (.subject.artifact == $card.subject.artifact)
            and ((.subject.version | version_parts) >= ($card.subject.version | version_parts)))))
        )
      | .key]
  ' "$data") || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    landed=0
    if jq -e --arg key "$key" 'index($key) != null' <<< "$landed_keys" >/dev/null; then
      landed=1
    fi
    reason=$(decision_card_is_stale "$key" "$landed") || continue
    printf 'dropped-landed-card: %s (%s)\n' "$key" "$reason" >&2
    drop=$drop$key$'\n'
  done < <(jq -r '.captains_call[]? | select(.type == "decision") | .key' "$data")
  tmp=$(printf '%s' "$drop" | jq -R -s 'split("\n") | map(select(length > 0))') || return 1
  jq --argjson dropped "$tmp" '
    .captains_call = [
      .captains_call[]
      | . as $card
      | select($card.type != "decision" or (($dropped | index($card.key)) == null))
      | if .type == "decision"
          and ([.options[]? | select(type == "object" and .value == "reconcile")] | length == 0)
        then .options += [{
          value: "reconcile",
          label: "Reconcile",
          hint: "Re-check the latest state, then close this with evidence or keep it open with a note"
        }]
        else . end
    ]' "$data" > "$dest" || return 1
}

# --- durable decision cards ---------------------------------------------------
# The board is rebuilt from scratch on every composition, so a card that is not
# in the newest payload disappears with it. The Deck and any later reader still
# need the options the captain was shown, so every surviving card is persisted
# per task under state/decision-cards/. A record whose task is definitely no
# longer an open captain call is pruned; a task whose state cannot be
# established is kept, because a card wrongly hidden is worse than one wrongly
# shown - the same asymmetry as the card hygiene above.

DECISION_CARDS_DIR="$FM_HOME/state/decision-cards"

persist_decision_cards() {  # <effective-payload.json>
  local data=$1 key card tmp existing task rc keep=''
  if [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ]; then
    :
  elif ! (umask 077; mkdir -p "$DECISION_CARDS_DIR"); then
    return 1
  fi
  [ -d "$DECISION_CARDS_DIR" ] && [ ! -L "$DECISION_CARDS_DIR" ] || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    keep=$keep$key$'\n'
    card=$(jq -c --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg key "$key" \
      '.captains_call[] | select(.key == $key)
       | {schema:"fm-decision-card.v1",generated:$generated,card:.}' "$data") || return 1
    [ -n "$card" ] || return 1
    tmp=$(umask 077; mktemp "$DECISION_CARDS_DIR/.card.XXXXXX") || return 1
    if printf '%s\n' "$card" > "$tmp" \
      && chmod 0600 "$tmp" \
      && mv -f -- "$tmp" "$DECISION_CARDS_DIR/$key.json"; then
      continue
    fi
    rm -f -- "$tmp"
    return 1
  done < <(jq -r '.captains_call[]?.key' "$data")
  for existing in "$DECISION_CARDS_DIR"/*.json; do
    [ -f "$existing" ] && [ ! -L "$existing" ] || continue
    task=$(basename "$existing" .json)
    case $'\n'"$keep" in
      *$'\n'"$task"$'\n'*) continue ;;
    esac
    rc=0
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || continue
    rm -f -- "$existing" || return 1
  done
  return 0
}

# The OWNER column bin/fm-procevent.sh already publishes: live, none,
# orphaned, or uncertain. Empty means the source is not registered at all.
source_owner() {  # <source-id>
  "$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3 }'
}

# A replacement listener is started detached, so it claims the source shortly
# after reconcile returns. Wait for that claim rather than reporting the race.
await_source_owner() {  # <source-id>
  local owner i=0
  while [ "$i" -lt 50 ]; do
    owner=$(source_owner "$1")
    [ "$owner" != live ] || { printf '%s\n' "$owner"; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "${owner:-none}"
}

command_build() {
  local data=${1-} board json tmp sid extracted effective owner version pre_reopen_owner
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  effective=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-bearings-payload.XXXXXX") \
    || fail "cannot stage the board payload"
  if ! effective_payload "$data" "$effective"; then
    rm -f -- "$effective"
    fail "cannot reconcile the board payload against landed work"
  fi
  persist_decision_cards "$effective" || {
    rm -f -- "$effective"
    fail "cannot persist the decision cards under $DECISION_CARDS_DIR"
  }
  json=$(jq -c . "$effective") || { rm -f -- "$effective"; fail "cannot compact the board data"; }
  rm -f -- "$effective"
  # `<` never appears in JSON syntax outside strings, so escaping every
  # occurrence keeps the payload valid JSON while making </script> inert.
  json=${json//</\\u003c}

  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.board.XXXXXX") || fail "cannot stage the board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the board data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the board data slot survived injection"
  fi
  # Round-trip the injected payload back out of the built page, so a board that
  # would fail to parse in the browser fails here instead.
  extracted=$(sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$tmp" \
    | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the board"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the board source id"
  pre_reopen_owner=$(source_owner "$sid")
  establish_board_session "$board"
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" retire "$board" >/dev/null \
      || fail "cannot retire the pre-reopen source generation (observed owner: ${pre_reopen_owner:-none})"
  fi
  if ! lavish_session_listed_open "$(board_realpath "$board")"; then
    version=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
    fail "the board Lavish session is not listed open immediately before arming (lavish-axi ${version:-version-unknown}); refusing to arm a poll on observed state not-open"
  fi
  printf 'served: %s\n' "$board"

  "$SCRIPT_DIR/fm-captain-hold.sh" bind "$sid" >/dev/null \
    || fail "cannot bind the board source to the keyed-answer intake"
  printf 'bound: %s\n' "$sid"

  owner=$(source_owner "$sid")
  if [ "$BOARD_SESSION_REOPENED" = 1 ]; then
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm a fresh board source after reopening"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  elif [ -n "$owner" ]; then
    printf 'already-armed: %s\n' "$sid"
  else
    "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$board" >/dev/null \
      || fail "cannot arm the board as a process-event source"
    printf 'armed: %s\n' "$sid"
    owner=$(source_owner "$sid")
  fi
  # Registered is not listening. A board whose source has no live owner gets a
  # replacement started now rather than at the next supervision cycle, which is
  # what keeps a rebuilt board from sitting silent behind `already-armed`.
  if [ "$owner" != live ]; then
    "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
    owner=$(await_source_owner "$sid")
    if [ "$owner" != live ]; then
      fail "source $sid is not listening after reconcile (observed owner: ${owner:-none})"
    fi
    printf 'listening: live\n'
  fi
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  compose) shift; command_compose "$@" ;;
  refresh) shift; command_refresh "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
