#!/usr/bin/env bash
# fm-dispatch-pick-lib.sh - the captain route pick: what replaces a guessed
# route when Jev cannot route a brief. Sourced by bin/fm-dispatch-resolve.sh,
# whose header owns the commands (pick, pick-card, picks). This header is the
# single owner of the pick request format, the bound-to-words verification,
# and the card; bin/fm-dispatch-receipt-lib.sh owns the receipt it produces.
#
# When it applies: the resolver's status captain-pick. Jev is down or answers
#   unusably after one retry, or Jev answered but code cannot dispatch the
#   answer (escalate, error, or quota evidence still incomplete when the
#   bounded gather ends). No row and no profile is ever assumed: the request
#   offers every row of the table, Jev's most probable rows first when Jev
#   answered, each candidate with the evidence a clear resolution computes.
#
# Pick request: state/dispatch-pick/<CODE>.json, private (0600), one per
#   resolution, created with noclobber under a fresh 4-character code from
#   A-H J-N P-Z 2-9. Fields:
#   schemaVersion, code, issuedAt, issuedAtEpoch, task, project
#   brief       {path, sha256} (the receipt hash, bin/fm-dispatch-receipt-lib.sh)
#   table       {path, sha256} of config/crew-dispatch.json at issue time
#   jevStatus   down | escalate | error | incomplete
#   reason      why code could not dispatch
#   jev         {model, requestId, ruleChoice, ruleProbabilities, confidence}
#               when Jev answered; null when it did not
#   options     [{n, row: {id, sha256, when, approval, probability, rowFloor},
#               profile: {harness, model, effort, account, provider},
#               reasoning_class, eligible, status, reason, strongest,
#               spendPriority, pct, scope, windows, plan}], numbered from 1 in
#               row order. eligible is true only for an eligible, rankable,
#               measured candidate; strongest marks the highest declared
#               reasoning_class among a row's eligible candidates.
#   <CODE>.answered  (noclobber) records the one answer the request accepted.
#
# Bound-to-words verification (`pick <CODE>`): the captain's answer counts only
#   when all of these hold.
#   1. It is captain text from a record the model does not write in-band: a
#      `tag: captain` entry of $STATE/.host-mirror.jsonl (written by the
#      Claude prompt-submit hook, bin/fm-host-mirror.sh) or a `role: user`
#      chat entry of the Lavish server's own state ($FM_LAVISH_STATE, default
#      ~/.lavish-axi/state.json), which the card's button produces.
#      Pi, Codex, Grok and OpenCode have no file mirror writer; their picks
#      must use Lavish, not primary chat (Pi's in-process mirror is not evidence).
#   2. It is newer than the request and says `route <CODE> <n>` (or
#      `route <CODE> wait`), case-insensitive; the newest such entry wins,
#      and one entry naming two different answers for the code is refused.
#   3. <n> is an option on the request. An option that is not eligible needs
#      the word `override` in the same entry; the receipt records it.
#   4. The brief and the table still hash as they did at issue time, the
#      option's row is unchanged, and the request is at most
#      FM_DISPATCH_PICK_MAX_AGE seconds old (default 86400, can only shorten).
#   5. The evidence entry has not admitted another pick (a noclobber marker
#      per entry under state/dispatch-pick/used/).
#   `wait` records the answer and issues nothing. Firstmate runs as the
#   captain's OS user, so both records are same-user writable: this binding
#   makes a forged pick visible to the receipt audit, not impossible.
#
# Card: `pick-card [<CODE>...]` renders every named (default: every pending)
#   request into one self-contained dark HTML page at
#   $DATA/dispatch-pick/route-pick.html, from this fixed template only. Each
#   option's button queues `route <CODE> <n>` (plus `override` for a
#   not-eligible option) through Lavish; opened outside Lavish the page shows
#   the line to type instead.
#
# Requires the sourcing script to set CONFIG, STATE, DATA and SCRIPT_DIR and to
# source bin/fm-dispatch-receipt-lib.sh.

FM_DP_SCHEMA=1
FM_DP_MAX_AGE_CAP=86400
FM_DP_ALPHABET=ABCDEFGHJKLMNPQRSTUVWXYZ23456789

fm_dp_dir() { printf '%s\n' "$STATE/dispatch-pick"; }
fm_dp_lavish_state() { printf '%s\n' "${FM_LAVISH_STATE:-$HOME/.lavish-axi/state.json}"; }
fm_dp_mirror() { printf '%s\n' "$STATE/.host-mirror.jsonl"; }
fm_dp_code_ok() { [[ ${1:-} =~ ^[A-HJ-NP-Z2-9]{4}$ ]]; }
fm_dp_refuse() { printf 'dispatch pick: refusing - %s\n' "$1"; exit 3; }

fm_dp_max_age() {
  local v=${FM_DISPATCH_PICK_MAX_AGE:-$FM_DP_MAX_AGE_CAP}
  case "$v" in '' | *[!0-9]*) v=$FM_DP_MAX_AGE_CAP ;; esac
  [ "$v" -ge 1 ] || v=1
  [ "$v" -le "$FM_DP_MAX_AGE_CAP" ] || v=$FM_DP_MAX_AGE_CAP
  printf '%s' "$v"
}

fm_dp_iso() {  # <epoch>
  date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$1"
}

# Reserve a fresh code: prints it and leaves an empty private <CODE>.json.
fm_dp_reserve_code() {
  local dir code i
  dir=$(fm_dp_dir)
  mkdir -p -- "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  for ((i = 0; i < 64; i++)); do
    code=$(LC_ALL=C tr -dc "$FM_DP_ALPHABET" < /dev/urandom 2>/dev/null | head -c 4)
    fm_dp_code_ok "$code" || continue
    if ( umask 077; set -C; : > "$dir/$code.json" ) 2>/dev/null; then
      printf '%s\n' "$code"
      return 0
    fi
  done
  return 1
}

# fm_dp_write_request <brief> <task> <project> <resolver-result-json>
# Prints the new request's code, or rc 1 with the reason on stdout. Called
# only for status captain-pick.
fm_dp_write_request() {
  local brief=$1 task=$2 project=$3 result=$4 rows code file now table
  [ "$(fm_dr_brief_hash "$brief")" = "$FM_DR_BRIEF_SHA" ] || { printf "%s\n" "brief changed during resolution; route again"; return 1; }
  table=$(fm_dr_table)
  [ "$(fm_dr_sha256 < "$table")" = "$FM_DR_TABLE_SHA" ] || { printf "%s\n" "table changed during resolution; route again"; return 1; }
  rows=$(fm_dr_table_rows) || { printf "%s\n" "$FM_DR_ERR"; return 1; }
  code=$(fm_dp_reserve_code) || { printf "%s\n" "could not reserve a pick code under $(fm_dp_dir)"; return 1; }
  file="$(fm_dp_dir)/$code.json"
  now=$(date -u +%s)
  if ! jq -n --argjson schema "$FM_DP_SCHEMA" --arg code "$code" --argjson epoch "$now" --arg at "$(fm_dp_iso "$now")" \
      --arg task "$task" --arg project "$project" --arg brief "$(fm_dr_abs_path "$brief")" --arg brief_sha "$FM_DR_BRIEF_SHA" \
      --arg table "$table" --arg table_sha "$FM_DR_TABLE_SHA" --argjson rows "$rows" --argjson r "$result" --argjson jev "${FM_DR_JEV:-null}" '
      def axis: if . == null or . == "default" then "" else . end;
      def norm($p; $prov): {harness: $p.harness, model: ($p.model | axis), effort: ($p.effort | axis), account: ($p.account // ""), provider: ($prov // $p.provider // "")};
      ([$r.pick[] | . as $row | ($rows | map(select(.id == $row.id)) | first) as $tr | $row.candidates[] |
        {row: {id: $row.id, sha256: $tr.sha256, when: $row.when, approval: $row.approval, probability: $row.probability, rowFloor: $row.row_floor},
         profile: norm(.profile; .provider), reasoning_class: (.profile.reasoning_class // null),
         eligible: ((.eligible // false) and ((.unranked // false) | not) and ((.incomplete // false) | not)),
         status: (if .incomplete then "incomplete" elif .unranked then "eligible, unranked" elif .eligible then "eligible" else "not eligible" end),
         reason: (.reason // ""), strongest: (.strongest // false),
         spendPriority: (.spendPriority // null), pct: (.pct // null), scope: (.scope // null),
         windows: (.windows // null), plan: (.plan // "unknown")}] | to_entries | map(.value + {n: (.key + 1)})) as $options |
      {schemaVersion: $schema, code: $code, issuedAt: $at, issuedAtEpoch: $epoch, task: $task, project: $project,
       brief: {path: $brief, sha256: $brief_sha}, table: {path: $table, sha256: $table_sha},
       jevStatus: ($r.jev_status // "down"), reason: ($r.reason // ""), jev: $jev, options: $options}' > "$file.tmp"; then
    rm -f -- "$file.tmp" "$file"
    printf 'could not write the pick request %s\n' "$file"
    return 1
  fi
  chmod 600 "$file.tmp" 2>/dev/null || true
  mv -f -- "$file.tmp" "$file" || { rm -f -- "$file.tmp" "$file"; printf "%s\n" "could not write the pick request $file"; return 1; }
  printf '%s\n' "$code"
}

fm_dp_render_options() {  # <code>: the TOON-style lines the resolver prints
  local file
  file="$(fm_dp_dir)/$1.json"
  jq -r --argjson max "$(fm_dp_max_age)" '
    def flat: tostring | gsub("[\t\r\n]"; " ");
    def show($v): ($v // "-") | flat;
    def prof: "--harness \(.harness)" + (if .model != "" then " --model \(.model)" else "" end)
      + (if .effort != "" then " --effort \(.effort)" else "" end) + (if .account != "" then " --account \(.account)" else "" end);
    "  pick: \(.code) for task \(show(.task)) - captain picks the route (valid \($max)s from \(.issuedAt))",
    "  jev: \(.jevStatus | flat) - \(.reason | flat)",
    (.options | group_by(.row.id) | sort_by(.[0].n)[] |
      "  row \(.[0].row.id | flat)" + (if .[0].row.probability != null then " p=\(.[0].row.probability)" else "" end)
        + (if .[0].row.approval then " approval=\(.[0].row.approval | flat)" else "" end)
        + " (\(.[0].row.when | flat | .[0:90]))",
      (.[] | "    option \(.n): \(.profile | prof)  class=\(show(.reasoning_class))  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  -> \(.status)"
        + (if .strongest then ", strongest" else "" end) + (if .status != "eligible" then ": \(.reason | flat)" else "" end))),
    "  answer: the captain says \"route \(.code) <n>\" (adding \"override\" for an option that is not eligible) or \"route \(.code) wait\" on the Lavish card or in Claude chat (Pi, Codex, Grok and OpenCode: Lavish only)",
    "  card: bin/fm-dispatch-resolve.sh pick-card \(.code)   then: bin/fm-dispatch-resolve.sh pick \(.code)"' "$file"
}

# fm_dp_find_words <code> <since-epoch>: the newest captain entry answering
# the code, as JSON {channel, ref, text, epoch, answer, override}. rc 1 with
# the reason on stdout when there is none or it is ambiguous.
fm_dp_find_words() {
  local code=$1 since=$2 mirror lavish candidates='[]' found
  # shellcheck disable=SC2016 # jq program text
  local match_jq='
    def answers($t): [$t | match("(?<![A-Za-z0-9])route\\s+" + $code + "\\s*[:=#]?\\s*(?<ans>[0-9]+|wait)(?![A-Za-z0-9])"; "gi") | .captures[0].string | ascii_downcase] | unique;
    select(.epoch >= $since) | answers(.text) as $a | select(($a | length) > 0)
    | . + {answers: $a, override: (.text | test("(?<![A-Za-z0-9])override(?![A-Za-z0-9])"; "i"))}'
  mirror=$(fm_dp_mirror)
  if [ -f "$mirror" ]; then
    found=$(jq -cR --arg code "$code" --argjson since "$since" "fromjson? // empty | select(type == \"object\" and .tag == \"captain\" and (.text | type) == \"string\" and (.epoch | type) == \"number\")
      | {channel: \"mirror\", ref: \"mirror:\\(.key // \"-\"):\\(.seq // \"-\")\", text, epoch} | $match_jq" "$mirror" 2>/dev/null | jq -cs .) || found='[]'
    candidates=$(jq -c --argjson more "${found:-[]}" '. + $more' <<<"$candidates")
  fi
  lavish=$(fm_dp_lavish_state)
  if [ -f "$lavish" ]; then
    found=$(jq -c --arg code "$code" --argjson since "$since" "[(.sessions // {}) | to_entries[] | .key as \$k | (.value.chat // [])[]
      | select(type == \"object\" and .role == \"user\" and (.text | type) == \"string\" and (.at | type) == \"string\")
      | {channel: \"lavish\", ref: \"lavish:\\(\$k):\\(.at)\", text, epoch: ((.at | sub(\"\\\\.[0-9]+Z\$\"; \"Z\") | fromdateiso8601?) // 0)} | $match_jq]" "$lavish" 2>/dev/null) || found='[]'
    candidates=$(jq -c --argjson more "${found:-[]}" '. + $more' <<<"$candidates")
  fi
  found=$(jq -c 'sort_by(.epoch) | last // empty' <<<"$candidates")
  if [ -z "$found" ]; then
    printf 'no captain words answer route %s since %s: the captain answers on the Lavish card or says "route %s <n>" in Claude chat; Pi, Codex, Grok and OpenCode require Lavish\n' "$code" "$(fm_dp_iso "$since")" "$code"
    return 1
  fi
  if [ "$(jq '.answers | length' <<<"$found")" -ne 1 ]; then
    printf "the captain's newest entry names more than one answer for route %s (%s); ask again\n" "$code" "$(jq -r '.answers | join(", ")' <<<"$found")"
    return 1
  fi
  jq -c '{channel, ref, text, epoch, answer: .answers[0], override}' <<<"$found"
}

# Claim one captain entry for one pick (noclobber); rc 1 when already claimed.
fm_dp_mark_used() {  # <marker-path>
  mkdir -p -- "$(dirname -- "$1")" || return 1
  ( umask 077; set -C; : > "$1" ) 2>/dev/null
}

fm_dp_cmd_pick() {
  local code=${1:-} file issued age words answer n option override profile row rows verdict ref used task brief name cands pick
  fm_dp_code_ok "$code" || fm_dr_die "pick needs a 4-character pick code (see --help)"
  file="$(fm_dp_dir)/$code.json"
  [ -s "$file" ] || fm_dp_refuse "no pick request $code in $(fm_dp_dir)"
  [ ! -e "$file.answered" ] || fm_dp_refuse "pick $code was already answered ($(jq -r '"answer \(.answer)" + (if .receipt then ", receipt \(.receipt)" else "" end)' "$file.answered" 2>/dev/null)); route again for a new decision"
  issued=$(jq -r '.issuedAtEpoch // 0' "$file" 2>/dev/null)
  case "$issued" in '' | *[!0-9]*) fm_dp_refuse "pick request $code is unreadable" ;; esac
  age=$(( $(date -u +%s) - issued ))
  [ "$age" -le "$(fm_dp_max_age)" ] || fm_dp_refuse "pick request $code is stale (${age}s old, max $(fm_dp_max_age)s); route again"
  brief=$(jq -r '.brief.path' "$file")
  [ "$(fm_dr_brief_hash "$brief" 2>/dev/null)" = "$(jq -r '.brief.sha256' "$file")" ] \
    || fm_dp_refuse "the brief $brief changed since pick $code was issued; route again"
  [ "$(fm_dr_sha256 < "$(fm_dr_table)" 2>/dev/null)" = "$(jq -r '.table.sha256' "$file")" ] \
    || fm_dp_refuse "config/crew-dispatch.json changed since pick $code was issued; route again"
  words=$(fm_dp_find_words "$code" "$issued") || fm_dp_refuse "$words"
  answer=$(jq -r .answer <<<"$words")
  ref=$(jq -r .ref <<<"$words")
  used="$(fm_dp_dir)/used/$(printf '%s' "$ref" | fm_dr_sha256)"
  if [ "$answer" = wait ]; then
    fm_dp_mark_used "$used" || fm_dp_refuse "the captain entry $ref already answered another pick"
    ( umask 077; set -C; jq -n --argjson w "$words" --arg at "$(fm_dp_iso "$(date -u +%s)")" '{answer: "wait", at: $at, evidenceRef: $w.ref, channel: $w.channel}' > "$file.answered" ) 2>/dev/null \
      || fm_dp_refuse "pick $code was answered concurrently"
    printf 'dispatch-pick:\n  status: wait\n  pick: %s\n  captain: chose to wait for Jev (%s)\n  receipt: none - re-run the resolver once jevd answers\n' "$code" "$ref"
    return 3
  fi
  n=$((10#$answer))
  option=$(jq -c --argjson n "$n" '.options[] | select(.n == $n)' "$file")
  [ -n "$option" ] || fm_dp_refuse "the captain answered option $n, which pick $code does not offer"
  override=$(jq -r .override <<<"$words")
  if [ "$(jq -r .eligible <<<"$option")" != true ] && [ "$override" != true ]; then
    fm_dp_refuse "option $n of pick $code is $(jq -r '.status + ": " + .reason' <<<"$option"); the captain must say \"route $code $n override\" to take it anyway"
  fi
  rows=$(fm_dr_table_rows) || fm_dp_refuse "$FM_DR_ERR"
  verdict=$(jq -r --argjson o "$option" "$FM_DR_KEY_JQ"'
    ([.[] | select(.id == $o.row.id)] | first) as $row |
    if $row == null then "gone" elif $row.sha256 != $o.row.sha256 then "changed"
    elif any($row.profiles[]; key == ($o.profile | key)) | not then "outside" else "member" end' <<<"$rows")
  [ "$verdict" = member ] || fm_dp_refuse "row $(jq -r .row.id <<<"$option") of option $n is $verdict in config/crew-dispatch.json; route again"
  task=$(jq -r '.task // ""' "$file")
  profile=$(jq -c '.profile' <<<"$option")
  # A captain pick can override optional eligibility, not the launch rule.
  local row_label
  row_label=$(jq -r --arg id "$(jq -r .row.id <<<"$option")" '.[] | select(.id == $id) | .label // "unlabelled"' <<<"$rows")
  fm_dr_claude3_guard "$(jq -r '.account // ""' <<<"$profile")" "$(fm_dr_task_kind "$brief" "$task")" "$row_label"
  fm_dp_mark_used "$used" || fm_dp_refuse "the captain entry $ref already admitted another pick; every pick needs its own answer"
  fm_dr_record_intake || fm_dp_refuse "quota intake failed; stop and report"
  row=$(jq -c '{id: .row.id, sha256: .row.sha256}' <<<"$option")
  cands=$(jq -c --argjson o "$option" --arg intake "$FM_DR_INTAKE_RECORD" '[.options[] | select(.row.id == $o.row.id) |
    .profile + {reasoning_class, catalog: "unknown (the resolver does not read harness catalogs; fm-spawn validates the model at launch)",
      plan, quotaIntakeRecord: $intake, spendPriority: (if (.spendPriority | type) == "number" then .spendPriority else "unknown" end),
      eligible, reason}]' "$file")
  pick=$(jq -c -n --arg code "$code" --argjson o "$option" --argjson w "$words" \
    '{code: $code, option: $o.n, override: ($o.eligible | not), words: ($w.text | .[0:2000]), wordsSha256: null,
      channel: $w.channel, evidenceRef: $w.ref, evidenceEpoch: $w.epoch}')
  pick=$(jq -c --arg sha "$(jq -j .text <<<"$words" | fm_dr_sha256)" '.wordsSha256 = $sha' <<<"$pick")
  FM_DR_JEV=$(jq -c '.jev' "$file")
  FM_DR_CAPTAIN_PICK=$pick
  name=$(fm_dr_write captain clear "$task" "$brief" "$row" "$profile" "$cands" "captain pick $code option $n" null) \
    || fm_dp_refuse "receipt not written (${FM_DR_ERR:-see diagnostic above})"
  ( umask 077; jq -n --argjson n "$n" --arg receipt "$name" --argjson w "$words" --arg at "$(fm_dp_iso "$(date -u +%s)")" \
      '{answer: $n, receipt: $receipt, at: $at, evidenceRef: $w.ref, channel: $w.channel, override: $w.override}' > "$file.answered" ) \
    || fm_dp_refuse "could not record the answer for pick $code"
  printf 'dispatch-pick:\n  status: clear\n  source: captain\n  pick: %s option %s (%s, row %s)%s\n' "$code" "$n" "$(jq -r .channel <<<"$words")" "$(jq -r .row.id <<<"$option")" \
    "$([ "$(jq -r .eligible <<<"$option")" = true ] || printf '; override of: %s' "$(jq -r .reason <<<"$option")")"
  printf '  profile: %s\n' "$(fm_dr_profile_text "$profile")"
  printf '  receipt: %s (one launch, valid %ss)\n' "$name" "$(fm_dr_max_age)"
}

fm_dp_pending() {  # one pending request path per line, oldest first
  local f dir now max
  dir=$(fm_dp_dir)
  now=$(date -u +%s)
  max=$(fm_dp_max_age)
  for f in "$dir"/*.json; do
    [ -s "$f" ] && [ ! -e "$f.answered" ] || continue
    [ $(( now - $(jq -r '.issuedAtEpoch // 0' "$f" 2>/dev/null || printf 0) )) -le "$max" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

fm_dp_cmd_card() {
  local files=() code out
  if [ $# -gt 0 ]; then
    for code in "$@"; do
      fm_dp_code_ok "$code" || fm_dr_die "pick-card takes pick codes, not '$code'"
      [ -s "$(fm_dp_dir)/$code.json" ] || fm_dr_die "no pick request $code"
      files+=("$(fm_dp_dir)/$code.json")
    done
  else
    mapfile -t files < <(fm_dp_pending)
  fi
  [ "${#files[@]}" -gt 0 ] || { printf 'dispatch pick card: no pending picks\n'; return 0; }
  out="$DATA/dispatch-pick/route-pick.html"
  mkdir -p -- "$(dirname -- "$out")" || fm_dr_die "could not create $(dirname -- "$out")"
  jq -rs '
    def e: tostring | @html;
    def prof: "\(.harness)" + (if .model != "" then " \(.model)" else "" end) + (if .effort != "" then " \(.effort)" else "" end) + (if .account != "" then " (\(.account))" else " (home seat)" end);
    def pct: if .pct == null then "quota unknown" else "\(.pct)% left" end;
    def opt($code):
      "<li class=\"opt \(if .eligible then "ok" else "no" end)\"><div><b>\(.n)</b> \(.profile | prof | e)</div>"
      + "<div class=\"ev\">\(pct | e) &middot; class \((.reasoning_class // "-") | e) &middot; spendPriority \((.spendPriority // "-") | e)"
      + (if .strongest then " &middot; <span class=\"s\">strongest</span>" else "" end)
      + (if .status != "eligible" then "<br><span class=\"r\">\(.status | e): \(.reason | e)</span>" else "" end) + "</div>"
      + "<button type=\"button\" data-prompt=\"route \($code) \(.n)\(if .eligible then "" else " override" end)\">"
      + (if .eligible then "Pick \(.n)" else "Override: pick \(.n)" end) + "</button></li>";
    def req:
      .code as $code |
      "<section data-lavish-question=\"route-\($code)\"><h2>Task \((.task // "-") | e) <span class=\"code\">\($code)</span></h2>"
      + "<p class=\"why\">Jev: \(.jevStatus | e) - \(.reason | e)</p>"
      + ([.options | group_by(.row.id) | sort_by(.[0].n)[] |
          "<details\(if (.[0].row.probability // 0) >= 0.25 or (.[0].n == 1) then " open" else "" end)><summary>\(.[0].row.id | e)"
          + (if .[0].row.probability != null then " &middot; Jev \(.[0].row.probability | e)" else "" end)
          + " &middot; \(.[0].row.when | .[0:140] | e)</summary><ul>" + (map(opt($code)) | join("")) + "</ul></details>"] | join(""))
      + "<p class=\"wait\"><button type=\"button\" data-prompt=\"route \($code) wait\">Wait for Jev</button> Or type <code>route \($code) &lt;number&gt;</code> in Lavish or Claude chat (other primaries: Lavish only).</p></section>";
    "<!doctype html><html lang=\"en\" data-lavish-annotate=\"off\" style=\"background:#0d1117\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"dark\"><title>Route pick</title>"
    + "<style>:root{color-scheme:dark}html,body{background:#0d1117;color:#e6edf3;margin:0}body{font:15px/1.5 system-ui,sans-serif;padding:14px;max-width:900px;margin:0 auto}"
    + "h1{font-size:20px}h2{font-size:17px;margin:20px 0 4px}.code{background:#0f2540;color:#58a6ff;border-radius:6px;padding:1px 8px}.why{color:#9da7b3}"
    + "details{background:#161b22;border:1px solid #30363d;border-radius:10px;margin:8px 0;padding:6px 10px}summary{cursor:pointer;font-weight:600}"
    + "ul{list-style:none;padding:0;margin:6px 0}li.opt{display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;justify-content:space-between;border-top:1px solid #30363d;padding:8px 0}"
    + "li.opt>div{min-width:0;flex:1 1 220px}.ev{color:#9da7b3;font-size:13px}.s{color:#3fb950}.r{color:#f0883e}li.no{opacity:.85}"
    + "button{background:#58a6ff;color:#0d1117;border:0;border-radius:8px;padding:8px 12px;font-weight:700;cursor:pointer}li.no button{background:#30363d;color:#e6edf3}"
    + "code{background:#21262d;padding:1px 5px;border-radius:4px}.done{color:#3fb950;font-weight:700}</style></head><body style=\"background:#0d1117\">"
    + "<h1>Pick a route</h1><p class=\"why\">Jev could not route these launches, so nothing starts until you pick. Code computed the evidence; your answer becomes the receipt.</p>"
    + (map(req) | join(""))
    + "<script>document.addEventListener(\"click\",function(ev){var b=ev.target.closest(\"button[data-prompt]\");if(!b)return;var t=b.getAttribute(\"data-prompt\");"
    + "if(window.lavish&&window.lavish.queuePrompt){window.lavish.queuePrompt(t,{tag:\"choice\",text:t,element:b,data:{question:b.closest(\"section\").getAttribute(\"data-lavish-question\"),answer:t}});b.insertAdjacentHTML(\"afterend\",\" <span class=done>queued - press Send</span>\");}"
    + "else{b.insertAdjacentHTML(\"afterend\",\" <span class=done>type: \"+t+\"</span>\");}});</script></body></html>"' "${files[@]}" > "$out.tmp" \
    || { rm -f -- "$out.tmp"; fm_dr_die "could not render the pick card"; }
  mv -f -- "$out.tmp" "$out" || fm_dr_die "could not write $out"
  printf 'dispatch pick card: %s (%s pick(s): %s)\n' "$out" "${#files[@]}" "$(for code in "${files[@]}"; do basename -- "$code" .json; done | paste -sd' ' -)"
  printf 'open it for the captain: bin/fm-lavish-open.sh %s\n' "$out"
}

# picks [--recent]: pending requests, then answered picks of the last week.
fm_dp_cmd_picks() {
  local recent=0 f now
  case "${1:-}" in --recent) recent=1 ;; '') ;; *) fm_dr_die "unknown picks argument: $1" ;; esac
  now=$(date -u +%s)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jq -r '"route pick \(.code) PENDING for task \(.task // "-") since \(.issuedAt) (jev \(.jevStatus): \(.reason | gsub("[\t\r\n]"; " ") | .[0:120])); card: bin/fm-dispatch-resolve.sh pick-card \(.code)"' "$f" 2>/dev/null
  done < <(fm_dp_pending)
  for f in "$(fm_dp_dir)"/*.json.answered; do
    [ -f "$f" ] || continue
    [ "$recent" -eq 0 ] || [ $(( now - $(stat -c %Y "$f" 2>/dev/null || printf 0) )) -le 604800 ] || continue
    jq -r --slurpfile q "${f%.answered}" '"route pick \($q[0].code) task=\($q[0].task // "-") answered \(.at): " + (if .answer == "wait" then "wait for Jev" else "option \(.answer) via \(.channel)" + (if .override then " (override)" else "" end) + " -> receipt \(.receipt)" end)' "$f" 2>/dev/null
  done
}

# fm_dp_verify_receipt <receipt-file>: re-checks a captain receipt's evidence.
# Prints ok, aged-out, or a mismatch description.
fm_dp_verify_receipt() {
  local receipt=$1 code epoch words
  code=$(jq -r '.captainPick.code // ""' "$receipt")
  fm_dp_code_ok "$code" || { printf 'no pick code'; return 0; }
  epoch=$(jq -r '.captainPick.evidenceEpoch // 0' "$receipt")
  case "$epoch" in '' | *[!0-9.]*) epoch=0 ;; esac
  words=$(fm_dp_find_words "$code" "${epoch%.*}" 2>/dev/null) || {
    printf 'evidence not found in the mirror or Lavish state (aged out, or never captain words)'
    return 0
  }
  if [ "$(jq -r .ref <<<"$words")" != "$(jq -r '.captainPick.evidenceRef' "$receipt")" ]; then
    printf 'newest captain answer is %s, not the receipt evidence %s' "$(jq -r .ref <<<"$words")" "$(jq -r '.captainPick.evidenceRef' "$receipt")"
  elif [ "$(jq -j .text <<<"$words" | fm_dr_sha256)" != "$(jq -r '.captainPick.wordsSha256' "$receipt")" ]; then
    printf 'captain words differ from the receipt'
  elif [ "$(jq -r .answer <<<"$words")" != "$(jq -r '.captainPick.option | tostring' "$receipt")" ]; then
    printf 'captain answered %s, receipt says option %s' "$(jq -r .answer <<<"$words")" "$(jq -r '.captainPick.option' "$receipt")"
  else
    printf ok
  fi
}
