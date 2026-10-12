# shellcheck shell=bash
# Claude Code advisor-model validation shared by every surface that accepts an
# optional advisor for a Claude worker: the dispatch-profile `advisor` field
# (bin/fm-dispatch-resolve.sh and the bin/fm-bootstrap.sh diagnostic), and the
# --advisor flag of bin/fm-spawn.sh and bin/fm-control.sh relaunch.
# Usage: . bin/fm-claude-advisor-lib.sh
#
# This file is the single owner of what Firstmate accepts as an advisor and of
# its copy of Claude Code's advisor pairing table
# (https://code.claude.com/docs/en/advisor, "Choose an advisor model").
# Claude Code receives the value as its per-session `--advisor <model>` launch
# flag, so one worker's advisor never leaks into the operator's saved
# advisorModel setting or into any other worker.
#
# Accepted values: the aliases fable, opus, and sonnet, or a full claude-*
# model id such as claude-opus-5-5 or claude-haiku-5-5. The haiku alias is
# refused because Claude Code documents only those three aliases for the role.
# Only the claude harness accepts an advisor.
#
# Pairing: an advisor must rank at or above the session's main model. When the
# main model and the advisor both name versions this table covers, a pairing
# the table rejects is refused here, because Claude Code would otherwise start
# the worker without the advisor and say so only in its own pane. Haiku before
# 5.5 can never act as an advisor. When either side is an alias whose version
# matters, a model the table does not cover, or the main model is left to
# Claude Code's default, the pairing is undeterminable here and is left to
# Claude Code, which exits at launch only on an advisor that can never advise
# or another launch error such as an allowlist or Fable consent, while an
# advisor ranked below the main model only warns in the worker's own pane and
# runs without it.
#
# Prepend FM_CLAUDE_ADVISOR_JQ to a consumer's jq program:
#   claude_advisor_problem($harness; $model; $advisor)
#     null when acceptable (including undeterminable pairings), otherwise one
#     human-readable reason. $model is the profile's main model or null.
# fm_claude_advisor_problem <harness> <model-or-empty> <advisor> prints that
#   reason (nothing when acceptable) and returns 0; it returns 2 when jq is
#   missing or fails, so a caller never mistakes an unchecked value for a pass.

# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_CLAUDE_ADVISOR_JQ='
  def claude_advisor_parse($m):
    if ($m | type) != "string" then null
    else ($m | sub("\\[[^]]*\\]$"; "")) as $s
      | if ($s | test("^(fable|opus|sonnet|haiku)$")) then {family: $s, version: null}
        else ($s | capture("^claude-(?<family>fable|opus|sonnet|haiku)-(?<maj>[0-9]+)(-(?<min>[0-9]{1,2}))?(-[0-9]{8})?$")
              | {family, version: [(.maj | tonumber), ((.min // "0") | tonumber)]}) // null
        end
    end;
  # Claude Code advisor pairing table: the accepted advisor families for a main
  # model, each with the minimum advisor version it requires (null for any).
  def claude_advisor_accepts($main):
    ($main.family) as $f | ($main.version) as $v |
    if ($f == "haiku" and $v == [4,5]) or ($f == "sonnet" and $v == [4,6]) then
      {fable: null, opus: null, sonnet: null, haiku: [5,5]}
    elif $f == "opus" and $v == [4,6] then
      {fable: null, opus: null, sonnet: [5,0], haiku: [5,5]}
    elif ($f == "sonnet" and $v == [5,0]) or ($f == "haiku" and $v == [5,5]) then
      {fable: null, opus: [4,7], sonnet: [5,0], haiku: [5,5]}
    elif $f == "opus" and ($v == [4,7] or $v == [4,8]) then
      {fable: null, opus: [4,7], sonnet: [5,5]}
    elif $f == "sonnet" and $v == [5,5] then
      {fable: null, opus: [5,0], sonnet: [5,5]}
    elif $f == "opus" and ($v == [5,0] or $v == [5,5]) then
      {fable: null, opus: [5,0]}
    elif $f == "fable" and $v == [5,0] then
      {fable: [5,0]}
    elif $f == "fable" and $v == [5,1] then
      {fable: [5,1]}
    else null end;
  def claude_advisor_main_rows($main):
    if $main == null then []
    elif $main.version != null then [claude_advisor_accepts($main) | select(. != null)]
    else [[4,5],[4,6],[4,7],[4,8],[5,0],[5,1],[5,5]]
      | map(claude_advisor_accepts({family: $main.family, version: .}) | select(. != null))
    end;
  # ok, below, or unknown for one pairing.
  def claude_advisor_pairing($model; $advisor):
    (claude_advisor_parse($model)) as $main |
    (claude_advisor_parse($advisor)) as $adv |
    (claude_advisor_main_rows($main)) as $rows |
    if $adv == null or ($rows | length) == 0 then "unknown"
    else
      [$rows[] |
        if has($adv.family) | not then "below"
        elif .[$adv.family] == null then "ok"
        elif $adv.version == null then "unknown"
        elif $adv.version >= .[$adv.family] then "ok"
        else "below" end] as $verdicts |
      if all($verdicts[]; . == "ok") then "ok"
      elif all($verdicts[]; . == "below") then "below"
      else "unknown" end
    end;
  def claude_advisor_problem($harness; $model; $advisor):
    if $harness != "claude" then "advisor applies only to the claude harness, not \($harness)"
    elif ($advisor | type) != "string" or ($advisor | length) == 0 then "advisor must be a non-empty string"
    elif ($advisor | test("^(fable|opus|sonnet)$") or test("^claude-[a-z0-9]+(-[a-z0-9]+)*$")) | not then
      "advisor \($advisor) must be fable, opus, sonnet, or a full claude-* model id"
    elif (claude_advisor_parse($advisor)) as $a | $a != null and $a.family == "haiku" and $a.version != null and $a.version < [5,5] then
      "advisor \($advisor) cannot act as an advisor (Haiku before 5.5)"
    elif claude_advisor_pairing($model; $advisor) == "below" then
      "advisor \($advisor) ranks below main model \($model) in Claude Code'"'"'s advisor pairing table, so the worker would run without it"
    else null end;
'

fm_claude_advisor_problem() {
  local harness=$1 model=$2 advisor=$3
  command -v jq >/dev/null 2>&1 || return 2
  # shellcheck disable=SC2016  # jq program text: $h, $m, and $a are jq variables.
  jq -nr --arg h "$harness" --arg m "$model" --arg a "$advisor" "$FM_CLAUDE_ADVISOR_JQ"'
    claude_advisor_problem($h; (if $m == "" or $m == "default" then null else $m end); $a) // empty
  ' 2>/dev/null || return 2
}
