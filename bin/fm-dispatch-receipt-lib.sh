#!/usr/bin/env bash
# fm-dispatch-receipt-lib.sh - the dispatch receipt: the record that proves one
# launch's harness, model, effort, and account came out of this home's dispatch
# table (config/crew-dispatch.json), and the gate that refuses a launch without
# one. Sourced by bin/fm-dispatch-resolve.sh, the only script that writes a
# receipt; bin/fm-spawn.sh and bin/fm-control.sh relaunch call that script's
# `gate` subcommand. This header is the single owner of the receipt format and
# of the gate's rules; bin/fm-dispatch-resolve.sh's header owns the commands.
#
# Storage reuses the quota-intake record mechanics (bin/fm-quota-intake.sh):
#   one private (0600) timestamped JSON file per receipt under
#   state/dispatch-receipt/, a freshness window, a `<receipt>.spent` marker
#   created with noclobber when a launch consumes it, and a retention count.
#   A launch that passes --consume-token writes that token into the marker, and
#   `refund --token` removes only the marker holding that exact token.
#   bin/fm-spawn.sh refunds when it fails before sending a launch, because such a
#   start launched nothing and the receipt still owes its one launch. A start
#   whose launch was sent, even if its outcome is unknown, never refunds, and a
#   marker with no token (a remote second mate's) cannot be refunded.
#   Receipts are unsigned exactly like quota-intake records; the gate instead
#   re-derives every binding it can from the brief, the launch, and the current
#   table, so a receipt is only ever as good as what it still matches.
#
# Receipt fields:
#   schemaVersion, receipt (file name), issuedAt, issuedAtEpoch
#   source      jev | captain
#   status      clear
#   jev         {model, requestId, ruleChoice, ruleProbabilities, confidence,
#                candidatePreference, latencyMs, inputTokens}; on a captain
#                receipt Jev's answer when Jev answered, else null
#   quotaIntakeRecord  intake record issued by the producing invocation
#   captainPick null, or for source captain {code, option, override, words,
#                wordsSha256, channel, evidenceRef, evidenceEpoch}: the pick
#                request and the captured captain words that chose the profile
#                (format and verification: bin/fm-dispatch-pick-lib.sh)
#   task        optional task id; a
#               receipt that names one admits only that task
#   brief       {path, sha256} - the hash covers the brief up to the first
#               relaunch progress note, so the note bin/fm-control.sh relaunch
#               appends never unbinds a task from its own receipt
#   table       {path, sha256} of config/crew-dispatch.json at issue time
#   row         {id, sha256} - id is rule_<n> (1-based position in `rules`) or
#               default; sha256 is of the row's canonical JSON, so any edit to
#               the row makes its outstanding receipts stale
#   profile     {harness, model, effort, account, provider}; an omitted axis is ""
#   candidates  evaluated profiles from the row or strongest-class union:
#               harness, model, effort, account, provider, reasoning_class,
#               catalog, plan, quotaIntakeRecord, spendPriority (a number or
#               the literal "unknown"), eligible, reason
#   rationale   why this candidate (the resolver's note, or the rationale file)
#   override    null; legacy override receipts are refused
#
# The gate (fm_dr_cmd_gate) admits a launch only when:
#   - this home has no routing rows (no rules and no default): there is no
#     table to route from, so nothing is demanded; or
#   - it is the host-local launch of a remote second mate that the parent home's
#     gate already admitted (see "Remote second mates" below); or
#   - the launch keeps the profile already recorded for the task (a relaunch or
#     a secondmate respawn with the same harness, model, effort, and account); or
#   - the newest receipt whose brief hash matches this task's brief is unspent,
#     at most FM_DISPATCH_RECEIPT_MAX_AGE seconds old, names a row that is
#     unchanged in the current table with the receipt's profile among that
#     row's candidates, its source is jev (with request id) or captain (with a
#     captainPick naming an answered pick request whose option is this profile
#     and row, and override set whenever that option was not eligible), and
#     its profile equals the launch field by field.
#   Raw launch commands cannot match table profiles and are refused.
#   Every refusal names the missing or mismatching receipt field and the
#   command that produces a receipt. Exit 0 pass, 3 refusal, 2 usage.
#
# Remote second mates: bin/fm-spawn.sh runs this gate in the PARENT home, against
#   a receipt in the parent home, before it delegates the launch to the remote
#   host, and the launch consumes that receipt. The host-local fm-spawn the
#   remote control plane then runs has no receipt producer of its own, so
#   bin/fm-remote-secondmate-control.sh launch hands it
#   FM_DISPATCH_PARENT_ADMITTED=<id>. The gate honours that only for the launch
#   it describes: the state directory is the remote home's private
#   state/parent-route, the brief is that home's data/charter.md, the home's
#   .fm-secondmate-home marker names the same id, and the launch is not a raw
#   command. A ship, a scout, or a relaunch matches none of that, so the
#   variable does not switch the gate off for them. Every one of those
#   conditions is established on the launching side, though, so a local session
#   can reach the pass-through for a seeded second-mate home, by running the
#   remote control plane's launch verb against it or by setting the variables
#   by hand.
#
# What the gate does and does not prevent: it physically stops a launch whose
#   profile no receipt names, which catches hand-picked profiles. Receipts and
#   state/<id>.meta remain same-user writable; parent admission remains an
#   audit-only pass-through. `audit` (session start) makes a forged receipt
#   visible: a Jev receipt's request id must appear in jevd's own log
#   (journalctl --user -u jevd, whose unit field the journal sets, or the
#   FM_JEVD_AUDIT_LOG file, default ~/.local/state/jev-gate/jevd.log, which is
#   same-user writable), and a captain receipt's words must still match the
#   captured record that produced it.
#
# FM_DISPATCH_RECEIPT_MAX_AGE can only shorten the freshness window (clamped
# 1..900 seconds, default 900); the test suite reaches the gate the way a home
# does, by producing real receipts.
#
# Historical data/dispatch-overrides.jsonl remains readable by session start.
# Self-service overrides stay refused: a captain's choice outside Jev's answer
# is a captain pick, verified against the captain's captured words.
# Degraded receipts are retired; a legacy one is refused.
#
# Requires the sourcing script to set CONFIG, STATE, and DATA.

FM_DR_SCHEMA=1
FM_DR_MAX_AGE_CAP=900
FM_DR_KEEP=200
FM_DR_OVERRIDE_RECENT_SECS=604800
FM_DR_OVERRIDE_RECENT_MAX=10
# The heading bin/fm-control.sh record_note appends to a relaunched brief.
FM_DR_RELAUNCH_NOTE_HEADING='## Progress note ('
FM_DR_ERR=

fm_dr_dir() { printf '%s\n' "$STATE/dispatch-receipt"; }
fm_dr_table() { printf '%s\n' "$CONFIG/crew-dispatch.json"; }
fm_dr_override_log() { printf '%s\n' "$DATA/dispatch-overrides.jsonl"; }

fm_dr_die() { printf 'error: %s\n' "$1" >&2; exit 2; }
fm_dr_refuse() { printf 'dispatch receipt gate: refusing - %s\n' "$1"; exit 3; }

fm_dr_max_age() {
  local v=${FM_DISPATCH_RECEIPT_MAX_AGE:-$FM_DR_MAX_AGE_CAP}
  case "$v" in '' | *[!0-9]*) v=$FM_DR_MAX_AGE_CAP ;; esac
  [ "$v" -ge 1 ] || v=1
  [ "$v" -le "$FM_DR_MAX_AGE_CAP" ] || v=$FM_DR_MAX_AGE_CAP
  printf '%s' "$v"
}

fm_dr_sha256() {  # stdin -> 64 hex characters
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum | awk '{ print $1 }')
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 | awk '{ print $1 }')
  else
    return 1
  fi
  case "$out" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}

fm_dr_brief_hash() {  # <brief-file>
  [ -f "$1" ] && [ -r "$1" ] || return 1
  awk -v note="$FM_DR_RELAUNCH_NOTE_HEADING" '
    index($0, note) == 1 { exit }
    { lines[++n] = $0 }
    END {
      while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "$1" | fm_dr_sha256
}

fm_dr_abs_path() {  # <file>
  local dir
  dir=$(cd "$(dirname -- "$1")" 2>/dev/null && pwd -P) || { printf '%s' "$1"; return 0; }
  printf '%s/%s' "$dir" "$(basename -- "$1")"
}

fm_dr_axis() {  # <value>: an omitted axis and the literal default are the same
  case "${1:-}" in default) printf '' ;; *) printf '%s' "${1:-}" ;; esac
}

fm_dr_meta_get() {  # <meta-file> <key>: last value wins, as fm_meta_get reads it
  local line value=''
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done < "$1" 2>/dev/null || true
  printf '%s' "$value"
}

fm_dr_profile_json() {  # <harness> <model> <effort> <account> [provider]
  jq -cn --arg h "$1" --arg m "$(fm_dr_axis "$2")" --arg e "$(fm_dr_axis "$3")" --arg a "$4" --arg p "${5:-}" \
    '{harness: $h, model: $m, effort: $e, account: $a, provider: $p}'
}

fm_dr_profile_text() {  # <profile-json>
  jq -r '"--harness \(.harness)"
    + (if .model != "" then " --model \(.model)" else "" end)
    + (if .effort != "" then " --effort \(.effort)" else "" end)
    + (if .account != "" then " --account \(.account)" else "" end)' <<<"$1"
}

# shellcheck source=bin/fm-dispatch-ladder-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-dispatch-ladder-lib.sh"

# ladder_profiles are the extra profiles the row'"'"'s escalation ladder can seat
# (bin/fm-dispatch-ladder-lib.sh); the gate counts them as row members so a
# relaunch on a higher rung is admitted, while `rows` keeps listing `profiles`.
# shellcheck disable=SC2016 # jq program text, not shell expansion
FM_DR_ROW_JQ="$FM_DL_JQ"'
  def axis: if . == null or . == "default" then "" else . end;
  def norm: {harness: .harness, model: (.model | axis), effort: (.effort | axis), account: (.account // ""), provider: (.provider // "")};
  def row_entry($id; $sha; $when; $approval; $use; $meta):
    {id: $id, sha256: $sha, when: $when, approval: $approval,
     profiles: ((if ($use | type) == "array" then $use else [$use] end) | map(norm)),
     ladder_profiles: (dl_all($cfg[0]; $use; $meta) | map(norm))};
'

# The table's rows as [{id, sha256, when, approval, profiles}]. An absent file
# and a file with neither rules nor default both yield []. rc 1 with FM_DR_ERR
# set when the file exists but is unreadable or malformed.
fm_dr_table_rows() {
  local table rows='[]' canon sha n=0 err
  table=$(fm_dr_table)
  FM_DR_ERR=
  if [ ! -e "$table" ] && [ ! -L "$table" ]; then
    printf '[]\n'
    return 0
  fi
  [ -f "$table" ] && [ -r "$table" ] || { FM_DR_ERR="$table is not a readable regular file"; return 1; }
  err=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else null end;
    def bad_profiles($v): profiles($v) as $p
      | $p == null or ($p | length) == 0
        or any($p[]; type != "object" or (.harness | type) != "string" or (.harness | length) == 0
          or (has("model") and (.model | type) != "string")
          or (has("effort") and (.effort | type) != "string")
          or (has("account") and (.account | type) != "string"));
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif any((.rules // [])[]; type != "object") then "each rule must be an object"
    elif any((.rules // [])[]; bad_profiles(.use)) then "each rule needs a use profile with a harness"
    elif has("default") and bad_profiles(.default) then "default needs a profile with a harness"
    else empty end' "$table" 2>/dev/null) || { FM_DR_ERR="$table is not JSON"; return 1; }
  [ -z "$err" ] || { FM_DR_ERR="$table - $err"; return 1; }
  while IFS= read -r canon; do
    [ -n "$canon" ] || continue
    n=$((n + 1))
    sha=$(printf '%s' "$canon" | fm_dr_sha256) || { FM_DR_ERR="no sha256 tool (sha256sum or shasum)"; return 1; }
    rows=$(jq -c --slurpfile cfg "$table" --arg id "rule_$n" --arg sha "$sha" --argjson row "$canon" "$FM_DR_ROW_JQ"'
      . + [row_entry($id; $sha; $row.when // ""; $row.approval // null; $row.use; $row)]' <<<"$rows") || return 1
  done < <(jq -cS '(.rules // [])[]' "$table")
  canon=$(jq -cS '.default // empty' "$table")
  if [ -n "$canon" ]; then
    sha=$(printf '%s' "$canon" | fm_dr_sha256) || { FM_DR_ERR="no sha256 tool (sha256sum or shasum)"; return 1; }
    rows=$(jq -c --slurpfile cfg "$table" --arg sha "$sha" --argjson use "$canon" "$FM_DR_ROW_JQ"'
      . + [row_entry("default"; $sha; "No listed rule applies to this task."; null; $use; {})]' <<<"$rows") || return 1
  fi
  printf '%s\n' "$rows"
}
# The launch identity of a profile: provider is evidence, not something a
# launch passes, so membership and equality compare the four launch axes.
# shellcheck disable=SC2016 # jq program text, not shell expansion
FM_DR_KEY_JQ='def key: {harness: (.harness // ""), model: (.model // ""), effort: (.effort // ""), account: (.account // "")};'

fm_dr_list() {  # one receipt path per line, oldest first
  local f dir
  dir=$(fm_dr_dir)
  for f in "$dir"/dispatch-*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

fm_dr_newest_for_brief() {  # <brief-sha256> -> path of the newest receipt binding it
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(jq -r '.brief.sha256 // ""' "$f" 2>/dev/null)" = "$1" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(fm_dr_list | LC_ALL=C sort -r)
  return 1
}

# fm_dr_write <source> <status> <task> <brief> <row-json|null> <profile-json>
#             <candidates-json> <rationale> <override-json|null>
# Prints the new receipt's file name. Internal: only this library's producers
# call it, each after its own checks.
fm_dr_write() {
  local source=$1 status=$2 task=$3 brief=$4 row=$5 profile=$6 candidates=$7 rationale=$8 override=$9
  local dir now ns name file brief_sha table table_sha='' total old
  case "$source" in jev|captain) ;; *) printf 'dispatch receipt: source %s disabled\n' "$source" >&2; return 1 ;; esac
  dir=$(fm_dr_dir)
  mkdir -p -- "$dir" || { FM_DR_ERR="could not create $dir"; return 1; }
  brief_sha=$(fm_dr_brief_hash "$brief") || { FM_DR_ERR="could not hash the brief $brief"; return 1; }
  table=$(fm_dr_table)
  if [ -f "$table" ]; then
    table_sha=$(fm_dr_sha256 < "$table") || table_sha=''
  fi
  now=$(date -u +%s)
  ns=$(date -u +%N 2>/dev/null)
  case "$ns" in '' | *[!0-9]*) ns=000000000 ;; esac
  name=$(printf 'dispatch-%s-%s-%s.json' "$now" "$ns" "$$")
  file=$dir/$name
  ( umask 077
    jq -cn --argjson schema "$FM_DR_SCHEMA" --arg name "$name" --argjson epoch "$now" \
      --arg at "$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$now")" \
      --arg source "$source" --arg status "$status" --arg task "$task" \
      --arg brief "$(fm_dr_abs_path "$brief")" --arg brief_sha "$brief_sha" \
      --arg table "$table" --arg table_sha "$table_sha" \
      --argjson row "$row" --argjson profile "$profile" --argjson candidates "$candidates" \
      --arg rationale "$rationale" --argjson override "$override" \
      --argjson jev "${FM_DR_JEV:-null}" --argjson pick "${FM_DR_CAPTAIN_PICK:-null}" \
      --arg intake "${FM_DR_INTAKE_RECORD:-}" \
      '{schemaVersion: $schema, receipt: $name, issuedAt: $at, issuedAtEpoch: $epoch,
        source: $source, status: $status, task: $task,
        brief: {path: $brief, sha256: $brief_sha},
        table: {path: $table, sha256: $table_sha},
        row: $row, profile: $profile, candidates: $candidates,
        rationale: $rationale, override: $override, jev: $jev,
        quotaIntakeRecord: $intake,
        captainPick: (if $source == "captain" then $pick else null end)}' > "$file"
  ) || { rm -f -- "$file"; FM_DR_ERR="could not write the receipt under $dir"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  total=$(fm_dr_list | wc -l)
  if [ "$total" -gt "$FM_DR_KEEP" ]; then
    fm_dr_list | head -n $(( total - FM_DR_KEEP )) | while IFS= read -r old; do
      rm -f -- "$old" "$old.spent"
    done
  fi
  printf '%s\n' "$name"
}

# The receipt for a `clear` resolution: <brief> <task> <resolver-result-json>.
# The result carries the matched row, the chosen candidate, and every
# candidate's evidence; nothing here re-decides any of it.
fm_dr_write_clear() {
  local brief=$1 task=$2 result=$3 rows row_id row profile candidates intake
  [ "$(fm_dr_brief_hash "$brief")" = "$FM_DR_BRIEF_SHA" ] \
    || { printf 'dispatch receipt: brief changed during resolution; route again\n' >&2; return 1; }
  [ "$(fm_dr_sha256 < "$(fm_dr_table)")" = "$FM_DR_TABLE_SHA" ] \
    || { printf 'dispatch receipt: table changed during resolution; route again\n' >&2; return 1; }
  rows=$(fm_dr_table_rows) || return 1
  row_id=$(jq -r '.row // ""' <<<"$result")
  row=$(jq -c --arg id "$row_id" '[.[] | select(.id == $id)] | first // null | if . == null then null else {id, sha256} end' <<<"$rows")
  [ "$row" != null ] || { FM_DR_ERR="the resolved row '$row_id' is not in $(fm_dr_table)"; return 1; }
  intake=${FM_DR_INTAKE_RECORD:-}
  [ -n "$intake" ] || { printf 'dispatch receipt: quota intake record required\n' >&2; return 1; }
  profile=$(jq -c '.chosen | {harness: .profile.harness, model: ((.profile.model // "") | if . == "default" then "" else . end),
    effort: ((.profile.effort // "") | if . == "default" then "" else . end), account: (.profile.account // ""), provider: (.provider // "")}' <<<"$result") || return 1
  candidates=$(jq -c --arg intake "${intake:-none}" '[.candidates[] | {
      harness: .profile.harness,
      model: ((.profile.model // "") | if . == "default" then "" else . end),
      effort: ((.profile.effort // "") | if . == "default" then "" else . end),
      account: (.profile.account // ""), provider: (.provider // ""),
      reasoning_class: (.profile.reasoning_class // null),
      catalog: "unknown (the resolver does not read harness catalogs; fm-spawn validates the model at launch)",
      plan: (.plan // "unknown"), quotaIntakeRecord: $intake,
      spendPriority: (if (.spendPriority | type) == "number" then .spendPriority else "unknown" end),
      eligible: ((.eligible // false) and ((.unranked // false) | not)),
      reason: (.reason // "")}]' <<<"$result") || return 1
  fm_dr_write jev clear "$task" "$brief" "$row" "$profile" "$candidates" \
    "$(jq -r '.note // "rule matched"' <<<"$result")" null
}

fm_dr_producer_hint() {
  printf '%s' 'produce one with bin/fm-dispatch-resolve.sh <brief> --project <name> --task <id>; Jev chooses, or the captain picks from the table when Jev cannot (bin/fm-dispatch-resolve.sh pick <code>); self-service choose and override are disabled'
}

# Record the per-launch quota intake a receipt binds; sets FM_DR_INTAKE_RECORD.
fm_dr_record_intake() {
  local output
  if ! output=$("$SCRIPT_DIR/fm-quota-intake.sh" record); then
    printf '%s\n' "$output"
    return 1
  fi
  printf '%s\n' "$output"
  FM_DR_INTAKE_RECORD=$(awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i ~ /^record=/) { sub(/^record=/, "", $i); print $i } }' <<<"$output")
  [ -n "$FM_DR_INTAKE_RECORD" ] && [ -f "$STATE/quota-intake/$FM_DR_INTAKE_RECORD" ] \
    || { printf 'dispatch receipt: quota intake produced no record\n' >&2; return 1; }
}

# Shared resolved guard settings for dispatch and both read-only exports.
fm_dr_five_hour_guard() {
  local now stamp dow hour tz hours start end work off floor period active=false
  now=${FM_DISPATCH_NOW_EPOCH:-$(date +%s)}
  tz=${FM_DISPATCH_WORKDAY_TZ:-Europe/Amsterdam}
  hours=${FM_DISPATCH_WORKDAY_HOURS:-08-18}
  [[ "$hours" =~ ^[0-9]{1,2}-[0-9]{1,2}$ ]] || hours=08-18
  start=$((10#${hours%-*})) end=$((10#${hours#*-}))
  work=$(fm_dr_guard_percent "${FM_DISPATCH_FIVE_HOUR_WORKDAY_PERCENT:-}" 20)
  off=$(fm_dr_guard_percent "${FM_DISPATCH_FIVE_HOUR_OFFHOURS_PERCENT:-}" 5)
  stamp=$(TZ=$tz date -d "@$now" '+%u %H' 2>/dev/null || TZ=$tz date -r "$now" '+%u %H' 2>/dev/null) || stamp='7 00'
  read -r dow hour <<< "$stamp"
  if [ "$dow" -le 5 ] && [ "$((10#$hour))" -ge "$start" ] && [ "$((10#$hour))" -lt "$end" ]; then
    active=true; floor=$work; period="while the captain works (Mon-Fri $hours $tz)"
  else
    floor=$off; period="outside working hours (Mon-Fri $hours $tz)"
  fi
  jq -cn --argjson floor "$floor" --arg period "$period" --argjson work "$work" --argjson off "$off" --arg tz "$tz" --arg hours "$hours" --argjson active "$active" \
    '{floor:$floor, period:$period, workdayPercent:$work, offhoursPercent:$off, tz:$tz, hours:$hours, workdayNow:$active}'
}
fm_dr_guard_percent() {
  local v=$1
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  [ "$v" -le 100 ] || v=100
  printf '%s' "$v"
}
fm_dr_cmd_rows() {
  local rows json=0 table
  case "${1:-}" in --json) json=1 ;; '') ;; *) fm_dr_die "unknown rows argument: $1" ;; esac
  rows=$(fm_dr_table_rows) || fm_dr_die "$FM_DR_ERR"
  if [ "$json" -eq 1 ]; then
    # The routing criteria as one document (the cockpit's source of truth):
    # every row's matching text, gates, and candidates with reasoning_class.
    table=$(fm_dr_table)
    jq -n --argjson rows "$rows" --arg path "$table" --arg sha "$( [ -f "$table" ] && fm_dr_sha256 < "$table")" \
      --argjson five "$(fm_dr_five_hour_guard)" --slurpfile t "$( [ -f "$table" ] && printf '%s' "$table" || printf '/dev/null')" '
      def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
      ($t[0] // {}) as $cfg |
      {schemaVersion: 1, table: {path: $path, sha256: $sha}, preferredProvider: ($cfg.preferred_provider // null),
       sharedQuota: ($cfg.shared_quota // false), ranking: ($cfg.ranking // {mode:"spend_priority"}), plan_value: ($cfg.plan_value // {}),
       guards: {weekly:{maxUsedPercent:($cfg.weekly_guard.max_used_percent // 98), reservePercent:($cfg.weekly_guard.reserve_percent // 1), reserveByPlan:($cfg.weekly_guard.reserve_by_plan // {}), decayHours:($cfg.weekly_guard.decay_hours // 6)}, fiveHour:$five},
       pipelineRows: [($cfg.pipeline_rows // [])[] | {label:(.label // null), steps, never_providers, candidates:.use}],
       rows: [$rows[] | .id as $id |
         (if $id == "default" then ($cfg.default // null) else ($cfg.rules[($id | ltrimstr("rule_") | tonumber) - 1]) end) as $raw |
         {id, sha256, when, approval, label: (if $id == "default" then null else ($raw.label // null) end), minConfidence: (if $id == "default" then null else ($raw.min_confidence // null) end),
          floor: (if $id == "default" then null else ($raw.floor // null) end), strict_tiers: (if $id == "default" then false else ($raw.strict_tiers // false) end),
          never_providers: (if ($raw | type) == "object" then ($raw.never_providers // null) else null end), never_models: (if ($raw | type) == "object" then ($raw.never_models // null) else null end),
          candidates: [(if $id == "default" then profiles($raw) else profiles($raw.use) end)[] |
            {harness, model: (.model // ""), effort: (.effort // ""), account: (.account // ""), provider: (.provider // ""),
             reasoning_class: (.reasoning_class // null), floor: (.floor // null), quota_scope: (.quota_scope // null),
             seat_tier:(.seat_tier // null), fallback_only:(.fallback_only // false), pool:(.pool // null)}]}],
       unclassed: ([$rows[] | .id as $id | (if $id == "default" then profiles($cfg.default // null) else profiles($cfg.rules[($id | ltrimstr("rule_") | tonumber) - 1].use) end)[] | select((.reasoning_class | type) != "number")] | length)}'
    return 0
  fi
  if [ "$(jq 'length' <<<"$rows")" -eq 0 ]; then
    printf 'dispatch rows: none (%s has no rules and no default)\n' "$(fm_dr_table)"
    return 0
  fi
  jq -r '.[] | "row \(.id)  sha256=\(.sha256[0:12])" + (if .approval then "  approval=\(.approval)" else "" end) + "  when: \(.when | gsub("[\t\r\n]"; " ") | .[0:100])",
    (.profiles[] | "  candidate: --harness \(.harness)"
      + (if .model != "" then " --model \(.model)" else "" end)
      + (if .effort != "" then " --effort \(.effort)" else "" end)
      + (if .account != "" then " --account \(.account)" else "" end))' <<<"$rows"
}

# audit [--days <n>] [--problems]: re-checks every receipt issued in the last
# <n> days (default 7) against the record that should have produced it. A Jev
# receipt's request id must appear in jevd's log; a captain receipt's words
# must still match its captured evidence. --problems prints only findings.
fm_dr_jevd_log() {  # all jevd log text this host can read, on stdout
  local file=${FM_JEVD_AUDIT_LOG:-$HOME/.local/state/jev-gate/jevd.log}
  if [ "${FM_JEVD_AUDIT_JOURNAL:-1}" = 1 ] && command -v journalctl >/dev/null 2>&1; then
    journalctl --user -u jevd --since "-$1 days" -o cat --no-pager 2>/dev/null || true
  fi
  [ ! -r "$file" ] || cat -- "$file"
}
fm_dr_cmd_audit() {
  local days=7 problems=0 files=() log f cutoff source rid line verdict n=0 bad=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) [ $# -ge 2 ] || fm_dr_die "--days needs a value"; days=$2; shift 2 ;;
      --problems) problems=1; shift ;;
      *) fm_dr_die "unknown audit argument: $1" ;;
    esac
  done
  case "$days" in '' | *[!0-9]*) fm_dr_die "--days must be a whole number" ;; esac
  cutoff=$(( $(date -u +%s) - days * 86400 ))
  mapfile -t files < <(fm_dr_list)
  log=$(fm_dr_jevd_log "$days")
  for f in "${files[@]}"; do
    [ "$(jq -r '.issuedAtEpoch // 0' "$f" 2>/dev/null)" -ge "$cutoff" ] 2>/dev/null || continue
    n=$((n + 1))
    source=$(jq -r '.source // ""' "$f")
    case "$source" in
      jev)
        rid=$(jq -r '.jev.requestId // ""' "$f")
        line=$(grep -F "dispatch $rid:" <<<"$log" | head -n 1)
        if [ -z "$log" ]; then verdict="unverifiable: no jevd log readable (journalctl --user -u jevd, FM_JEVD_AUDIT_LOG)"
        elif [ -z "$rid" ] || [ -z "$line" ]; then verdict="NOT IN JEVD LOG: request id ${rid:-missing} has no jevd dispatch line"
        elif [ -n "$(jq -r '.jev.ruleChoice // ""' "$f")" ] && ! grep -qF "rule=$(jq -r '.jev.ruleChoice' "$f") " <<<"$line"; then
          verdict="MISMATCH: jevd logged '${line#*: }' but the receipt says rule $(jq -r '.jev.ruleChoice' "$f")"
        else verdict=ok; fi ;;
      captain) verdict=$(fm_dp_verify_receipt "$f"); [ "$verdict" = ok ] || verdict="CAPTAIN WORDS: $verdict" ;;
      *) verdict="UNKNOWN SOURCE '$source'" ;;
    esac
    case "$verdict" in ok) ;; *) bad=$((bad + 1)) ;; esac
    [ "$problems" -eq 1 ] && [ "$verdict" = ok ] && continue
    printf 'receipt %s task=%s source=%s: %s\n' "$(basename -- "$f")" "$(jq -r '.task // "-"' "$f")" "$source" "$verdict"
  done
  [ "$problems" -eq 1 ] || printf 'dispatch audit: %s receipt(s) in the last %s day(s), %s finding(s)\n' "$n" "$days" "$bad"
}

# overrides: the durable log, newest last. --recent prints only what a session
# start lists: the newest entries from the last week, or nothing at all.
fm_dr_cmd_overrides() {
  local recent=0 log now
  case "${1:-}" in
    --recent) recent=1 ;;
    '') ;;
    *) fm_dr_die "unknown overrides argument: $1" ;;
  esac
  log=$(fm_dr_override_log)
  [ -f "$log" ] || { [ "$recent" -eq 1 ] || printf 'dispatch overrides: none recorded\n'; return 0; }
  now=$(date -u +%s)
  jq -rs --argjson recent "$recent" --argjson now "$now" \
    --argjson window "$FM_DR_OVERRIDE_RECENT_SECS" --argjson cap "$FM_DR_OVERRIDE_RECENT_MAX" '
    def line: "\(.at)  task=\(.task)  --harness \(.profile.harness)"
      + (if .profile.model != "" then " --model \(.profile.model)" else "" end)
      + (if .profile.effort != "" then " --effort \(.profile.effort)" else "" end)
      + (if .profile.account != "" then " --account \(.profile.account)" else "" end)
      + "  captain: \"\(.words | gsub("[\t\r\n]+"; " ") | .[0:300])\"";
    if $recent == 1 then
      [.[] | select((.atEpoch // 0) >= ($now - $window))] as $r |
      if ($r | length) == 0 then empty
      else ($r | .[-$cap:][] | line),
        (if ($r | length) > $cap then "(\(($r | length) - $cap) older override(s) in the last week not shown)" else empty end)
      end
    elif length == 0 then "dispatch overrides: none recorded"
    else .[] | line end' "$log" 2>/dev/null \
    || printf 'dispatch overrides: %s is unreadable; read it by hand\n' "$log"
}

# A captain receipt must point at an answered pick request whose answered
# option is exactly this receipt's row and profile.
fm_dr_gate_captain() {  # <receipt> <name>
  local receipt=$1 name=$2 code req
  code=$(jq -r '.captainPick.code // ""' "$receipt")
  [[ $code =~ ^[A-HJ-NP-Z2-9]{4}$ ]] || fm_dr_refuse "captain receipt $name has no pick code"
  req="$STATE/dispatch-pick/$code.json"
  [ -s "$req" ] && [ -f "$req.answered" ] || fm_dr_refuse "captain receipt $name names pick $code, which has no answered request in $STATE/dispatch-pick"
  jq -e --slurpfile q "$req" --slurpfile a "$req.answered" "$FM_DR_KEY_JQ"'
    ($q[0]) as $q | ($a[0]) as $a | .captainPick as $p |
    ($q.options[] | select(.n == $p.option)) as $o |
    $a.receipt == .receipt and $a.answer == $p.option and $q.brief.sha256 == .brief.sha256
    and $o.row.id == .row.id and $o.row.sha256 == .row.sha256 and ($o.profile | key) == (.profile | key)
    and ($o.eligible or $p.override == true)
    and ($p.evidenceRef | type) == "string" and ($p.wordsSha256 | type) == "string"' "$receipt" >/dev/null 2>&1 \
    || fm_dr_refuse "captain receipt $name does not match the answered option of pick $code (row, profile, brief, override, or evidence); route again"
}

fm_dr_cmd_refund() {  # --token <token>: undo only the consume that wrote this token
  local token='' marker
  [ "${1:-}" = --token ] && [ -n "${2:-}" ] || fm_dr_die "refund needs --token <token>"
  token=$2
  for marker in "$(fm_dr_dir)"/*.spent; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    [ "$(cat -- "$marker" 2>/dev/null)" = "$token" ] || continue
    rm -f -- "$marker" || return 1
    printf 'dispatch receipt gate: receipt returned - %s launched nothing, so it can launch once more\n' "$(basename "$marker" .spent)"
    return 0
  done
}

fm_dr_cmd_gate() {
  local brief='' task='' harness='' model='' effort='' account='' raw=0 consume=0 meta='' consume_token=''
  local resolved_model='' resolved_effort='' resolved_set=0 arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --brief | --task | --harness | --model | --effort | --account | --recorded-meta | --resolved-model | --resolved-effort | --consume-token)
        [ $# -gt 0 ] || fm_dr_die "$arg needs a value" ;;
    esac
    case "$arg" in
      --consume) consume=1 ;;
      --consume-token) consume_token=$1; shift ;;
      --raw) raw=1 ;;
      --brief) brief=$1; shift ;;
      --task) task=$1; shift ;;
      --harness) harness=$1; shift ;;
      --model) model=$1; shift ;;
      --effort) effort=$1; shift ;;
      --account) account=$1; shift ;;
      --recorded-meta) meta=$1; shift ;;
      --resolved-model) resolved_model=$1; resolved_set=1; shift ;;
      --resolved-effort) resolved_effort=$1; resolved_set=1; shift ;;
      *) fm_dr_die "unknown gate argument: $arg" ;;
    esac
  done
  [ -n "$harness" ] || fm_dr_die "gate requires --harness"
  local task_id=$task
  [ -n "$task" ] || task='this task'
  model=$(fm_dr_axis "$model")
  effort=$(fm_dr_axis "$effort")
  [ "$resolved_set" -eq 1 ] || { resolved_model=$model; resolved_effort=$effort; }
  resolved_model=$(fm_dr_axis "$resolved_model")
  resolved_effort=$(fm_dr_axis "$resolved_effort")
  command -v jq >/dev/null 2>&1 || fm_dr_refuse "jq is not installed, so the dispatch table cannot be read"

  local rows
  rows=$(fm_dr_table_rows) \
    || fm_dr_refuse "config/crew-dispatch.json is not a readable, well-formed rules file ($FM_DR_ERR); correct it rather than launching around it"
  if [ "$(jq 'length' <<<"$rows")" -eq 0 ]; then
    printf 'dispatch receipt gate: PASS - this home has no routing rows in config/crew-dispatch.json, so there is no table to route from\n'
    return 0
  fi

  # The host-local launch of a remote second mate its parent home already admitted.
  local remote_home=${STATE%/state/parent-route}
  if [ -n "$task_id" ] && [ "${FM_DISPATCH_PARENT_ADMITTED:-}" = "$task_id" ] && [ "$raw" -eq 0 ] \
    && [ "$remote_home" != "$STATE" ] && [ -n "$brief" ] && [ "$brief" -ef "$remote_home/data/charter.md" ] \
    && [ "$(cat "$remote_home/.fm-secondmate-home" 2>/dev/null)" = "$task_id" ]; then
    printf 'dispatch receipt gate: PASS - %s was admitted by the gate in its parent home; this host-local launch of a remote second mate needs no receipt of its own\n' "$task_id"
    return 0
  fi

  # A launch that keeps the task's recorded profile changes no routing decision.
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    local rec_account
    rec_account=$(fm_dr_meta_get "$meta" account)
    case "$rec_account" in ordinary | /*) rec_account='' ;; esac
    if [ "$(fm_dr_meta_get "$meta" harness)" = "$harness" ] \
      && [ "$(fm_dr_axis "$(fm_dr_meta_get "$meta" model)")" = "$resolved_model" ] \
      && [ "$(fm_dr_axis "$(fm_dr_meta_get "$meta" effort)")" = "$resolved_effort" ] \
      && [ "$rec_account" = "$account" ]; then
      printf 'dispatch receipt gate: PASS - %s keeps its recorded profile (harness=%s model=%s effort=%s account=%s); no new receipt is needed\n' \
        "$task" "$harness" "${resolved_model:-default}" "${resolved_effort:-default}" "${account:-home seat}"
      return 0
    fi
  fi

  [ -n "$brief" ] || fm_dr_refuse "no brief was named for $task, so no receipt can bind it"
  [ -f "$brief" ] && [ -r "$brief" ] \
    || fm_dr_refuse "the brief $brief for $task is not readable, so no receipt can bind it"
  local brief_sha hint receipt name age max launch
  brief_sha=$(fm_dr_brief_hash "$brief") || fm_dr_refuse "the brief $brief could not be hashed (no sha256sum or shasum)"
  hint=$(fm_dr_producer_hint)
  launch=$(fm_dr_profile_json "$harness" "$model" "$effort" "$account")
  if ! receipt=$(fm_dr_newest_for_brief "$brief_sha"); then
    local other
    other=$(fm_dr_list | tail -n 1)
    [ -z "$other" ] || other=$(jq -r '.brief.path // "an unreadable receipt"' "$other" 2>/dev/null)
    fm_dr_refuse "no dispatch receipt binds the brief of $task (brief.sha256 ${brief_sha:0:12} for $brief); the newest receipt in this home binds ${other:-nothing, because there is none}. A hand-picked $(fm_dr_profile_text "$launch") is not a routing decision: $hint"
  fi
  name=$(basename -- "$receipt")
  [ ! -e "$receipt.spent" ] \
    || fm_dr_refuse "receipt $name for this brief was already consumed by a launch (marker $name.spent); every launch needs its own receipt: $hint"
  max=$(fm_dr_max_age)
  age=$(jq -r --argjson now "$(date -u +%s)" '$now - (.issuedAtEpoch // 0)' "$receipt" 2>/dev/null)
  case "$age" in
    '' | *[!0-9-]*) fm_dr_refuse "receipt $name is unreadable; $hint" ;;
  esac
  [ "$age" -ge 0 ] && [ "$age" -le "$max" ] \
    || fm_dr_refuse "receipt $name is stale: issuedAt is ${age}s ago (max ${max}s); $hint"

  local source verdict row_id receipt_task
  source=$(jq -r '.source // ""' "$receipt")
  receipt_task=$(jq -r '.task // ""' "$receipt")
  [ -z "$receipt_task" ] || [ -z "$task_id" ] || [ "$receipt_task" = "$task_id" ] \
    || fm_dr_refuse "receipt $name was issued for task '$receipt_task', not $task_id (the task field does not match); $hint"
  if [ "$source" = override ] || [ "$(jq -r '.override.by // ""' "$receipt")" = captain ]; then
    fm_dr_refuse "self-service override receipts are refused; the captain's own choice is a captain pick (bin/fm-dispatch-resolve.sh pick <code>)"
  else
    [ "$raw" -eq 0 ] \
      || fm_dr_refuse "a raw launch command cannot be matched to a profile of the dispatch table; overrides are disabled in phase 1"
    case "$source" in
      jev | captain) ;;
      degraded) fm_dr_refuse "receipt $name is a retired degraded receipt; no route is ever guessed: $hint" ;;
      *) fm_dr_refuse "receipt $name has no recognised source (source is '${source}'); $hint" ;;
    esac
    if [ "$source" = jev ]; then
      jq -e '.jev.requestId | type == "string" and length > 0' "$receipt" >/dev/null \
        || fm_dr_refuse "Jev receipt has no request id"
    else
      fm_dr_gate_captain "$receipt" "$name"
    fi
    jq -e '.status == "clear" and (.quotaIntakeRecord | type == "string" and test("^quota-[0-9A-Za-z-]+\\.json$"))' "$receipt" >/dev/null \
      || fm_dr_refuse "receipt $name has no dispatchable status or quota intake binding"
    [ -f "$STATE/quota-intake/$(jq -r .quotaIntakeRecord "$receipt")" ] \
      || fm_dr_refuse "receipt $name names a missing quota intake record"
    row_id=$(jq -r '.row.id // ""' "$receipt")
    verdict=$(jq -r --slurpfile r "$receipt" "$FM_DR_KEY_JQ"'
      ($r[0]) as $rc |
      ([.[] | select(.id == ($rc.row.id // ""))] | first) as $row |
      if $row == null then "gone"
      elif $row.sha256 != ($rc.row.sha256 // "") then "changed"
      elif any(($row.profiles + ($row.ladder_profiles // []))[]; key == ($rc.profile | key)) | not then "outside"
      else "member" end' <<<"$rows") || fm_dr_refuse "receipt $name is unreadable; $hint"
    case "$verdict" in
      member) ;;
      gone) fm_dr_refuse "receipt $name names row.id '$row_id', which config/crew-dispatch.json no longer has; route again: $hint" ;;
      changed) fm_dr_refuse "receipt $name names row.id '$row_id' at row.sha256 $(jq -r '(.row.sha256 // "")[0:12]' "$receipt"), but that row has changed in config/crew-dispatch.json since; route again: $hint" ;;
      *) fm_dr_refuse "receipt $name carries profile $(fm_dr_profile_text "$(jq -c '.profile' "$receipt")"), which is not a candidate of row.id '$row_id' in the current config/crew-dispatch.json; a profile outside the matched row is refused: $hint" ;;
    esac
  fi

  local field want got drop
  for field in harness model effort account; do
    want=$(jq -r --arg f "$field" '.profile[$f] // ""' "$receipt")
    got=$(jq -r --arg f "$field" '.[$f] // ""' <<<"$launch")
    [ "$want" = "$got" ] && continue
    case "$field" in
      model | effort) drop="; pass --$field default to drop a carried-over value" ;;
      *) drop='' ;;
    esac
    fm_dr_refuse "the launch of $task does not equal receipt $name: profile.$field is '${want:-default}' on the receipt but the launch passes '${got:-default}'. Launch the receipt's profile ($(fm_dr_profile_text "$(jq -c '.profile' "$receipt")")$drop), or route this profile properly: $hint"
  done

  if [ "$consume" -eq 1 ]; then
    ( set -C; printf '%s' "$consume_token" > "$receipt.spent" ) 2>/dev/null \
      || fm_dr_refuse "receipt $name for this brief was already consumed by a launch (marker $name.spent); every launch needs its own receipt: $hint"
  fi
  printf 'dispatch receipt gate: PASS - receipt %s (%s%s) admits %s for %s%s\n' "$name" "$source" \
    "$(jq -r '(if .row then ", row \(.row.id)" else "" end) + (if .captainPick then ", captain pick \(.captainPick.code) option \(.captainPick.option)" + (if .captainPick.override then " override" else "" end) else "" end)' "$receipt")" \
    "$(fm_dr_profile_text "$launch")" "$task" "$([ "$consume" -eq 1 ] && printf '; receipt consumed' || printf ' (preview)')"
}
