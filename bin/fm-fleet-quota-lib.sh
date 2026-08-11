#!/usr/bin/env bash
# fm-fleet-quota-lib.sh — FirstMate quota/pace SURFACE layer (leaf library).
#
# Owns per-surface quota/pace reporting, the model->surfaces map, the
# operator-facing model-surface picker, and fm_fleet_budget_ok's conservation-pressure
# gate: fm_fleet_quota_now, fm_fleet_quota_report, fm_fleet_model_map,
# fm_fleet_models_report, fm_fleet_pick_surface, fm_fleet_num_ge,
# fm_fleet_reserve_cmp, fm_fleet_pace_rows, fm_fleet_pace_fields,
# fm_fleet_render_reserve, fm_fleet_pressured, fm_fleet_budget_reason,
# fm_fleet_budget_ok.
#
# LEAF: zero dependencies on the fleet KB/claim/route/lifecycle layer
# (bin/fm-fleet-lib.sh). Reads only quota-axi, jq, and bin/quota-sources/*.sh —
# never resolves a fleet dir, never touches operators.md/backlog.md/events.log.
# Independently sourceable: `bash -c '. bin/fm-fleet-quota-lib.sh; fm_fleet_budget_ok'`
# works with fm-fleet-lib.sh never sourced.
#
# Sourced by bin/fm-fleet-lib.sh only — consumers (bin/fm-fleet.sh,
# bin/fm-fleet-join.sh, bin/fm-fleet-wait.sh, tests/federation/*.sh) keep
# sourcing bin/fm-fleet-lib.sh and receive these functions transitively; no
# caller's sourcing contract changes.
#
# ANTI-GOAL (standing, N1): fm_fleet_pick_surface answers "which pool has tokens
# right now" for a human running `fm-fleet.sh pick` only. It must NEVER be called
# from bin/fm-spawn.sh, crew dispatch, or any automated selection path — that
# belongs solely to upstream's `quota-array-dispatch` skill. Moving these
# functions into this leaf file must not make that any easier to reach; see the
# function's own comment block below for the full rationale.

# Min headroom % across providers via quota-axi (current shell's auth); '-' if
# unavailable. Bash-only, zero LLM tokens.
fm_fleet_quota_now() {
  command -v quota-axi >/dev/null 2>&1 || { printf '%s' '-'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s' '-'; return 0; }
  local j min
  j=$(quota-axi --json 2>/dev/null) || { printf '%s' '-'; return 0; }
  min=$(printf '%s' "$j" | jq -r '[.providers[]?.windows[]?.percentRemaining] | min // "-"' 2>/dev/null)
  case "$min" in ''|null) printf '%s' '-' ;; *) printf '%s' "$min" ;; esac
}

# Human-readable per-surface headroom for EVERY llm/cli/app quota-axi knows about,
# with each surface's observability status. Read-only, bash+jq, 0 LLM tokens.
# Rationale: each CLI/app subscription is its OWN token pool, so a model reachable via
# more than one surface (e.g. grok via the grok CLI AND via a Cursor subscription) has
# one row per surface. A surface only contributes to routing when status is "fresh";
# "auth_required"/"unavailable"/"error" surfaces are shown but flagged un-observable.
fm_fleet_quota_report() {
  command -v quota-axi >/dev/null 2>&1 || {
    { echo "fm-fleet: quota-axi is not on PATH — per-surface headroom is unavailable."
      echo "  quota-axi reports how much budget each provider has left; the fleet uses it to"
      echo "  route work away from drained accounts. Install it, or skip quota-aware routing."
      echo "  Everything else (queue/claim/route/handoff) works without it."
    } >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null) || {
    { echo "fm-fleet: quota-axi ran but returned no usable data."
      echo "  Most often this means no provider is signed in yet in THIS shell's environment."
      echo "  Check with:  quota-axi auth      (shows each provider's credential source/status)"
    } >&2
    return 1
  }
  local base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # Collect custom-source rows once. A source is authoritative for its surface and
  # SUPERSEDES the quota-axi row of the same name (e.g. an authed `cursor` override
  # replaces quota-axi's blind cursor row; `cline` is added since quota-axi lacks it).
  local -a SRC=(); local f s
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    [ -n "$s" ] && SRC+=("$s")
  done
  local ex_json='[]'
  if [ "${#SRC[@]}" -gt 0 ]; then
    ex_json=$(printf '%s\n' "${SRC[@]}" | jq -r '.surface // empty' 2>/dev/null | jq -R . | jq -s . 2>/dev/null)
    [ -n "$ex_json" ] || ex_json='[]'
  fi
  # Pace facts per NATIVE provider (§5.1), independent of custom-source
  # supersession above, so an excluded native row's pace still drives the
  # "masks native pace" advisory below even though it never itself prints.
  declare -A PACE_OF RESERVE_OF
  local psurf ppace preserve
  while IFS=$'\037' read -r psurf _ ppace preserve; do
    [ -n "$psurf" ] || continue
    PACE_OF[$psurf]=$ppace
    RESERVE_OF[$psurf]=$preserve
  done < <(fm_fleet_pace_fields "$j")
  {
    printf 'SURFACE\tHEADROOM\tPACE\tRESERVE\tSTATUS\tSOURCE\tNOTE\n'
    printf '%s\n' "$j" | jq -r --argjson ex "$ex_json" '
      .providers[] | select((.provider as $p | $ex | index($p)) | not)
      | ((.quotaSemantics.effectiveAvailability // []
           | map(select(.scope=="all_models").effectivePercentRemaining) | .[0])
         // (.windows // [] | map(.percentRemaining) | min)) as $rem
      | [ .provider,
          (if $rem==null then "—" else ($rem|tostring)+"%" end),
          (.state.status // "?"), (.source // "?"),
          (if (.state.status // "")=="fresh" then "observable"
           else (.state.error // "not reporting") end)
        ] | @tsv' \
    | while IFS=$'\t' read -r nsurf nhr nst nsrc nnote; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$nsurf" "$nhr" "${PACE_OF[$nsurf]:-—}" "$(fm_fleet_render_reserve "${RESERVE_OF[$nsurf]:-}")" \
          "$nst" "$nsrc" "$nnote"
      done
    local row surf note
    for row in "${SRC[@]:-}"; do
      [ -n "$row" ] || continue
      surf=$(printf '%s' "$row" | jq -r '.surface // empty')
      note=$(printf '%s' "$row" | jq -r '.note // ""')
      # A bare-int custom source masking a paced native row is an advisory (R7),
      # ahead of the T10-gated retirement that can remove the custom source.
      if [ -n "${PACE_OF[$surf]:-}" ]; then
        note="${note:+$note; }custom int masks native pace"
      fi
      printf '%s\n' "$row" | jq -r --arg note "$note" '
        [ .surface,
          (if .headroom==null then "—" else (.headroom|tostring)+"%" end),
          "—", "—",
          (.status // "?"), "custom", $note ] | @tsv'
    done
  } | if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# Resolve the model->surfaces map: the operator's gitignored config/model-surfaces.json
# when one exists, else the tracked default shipped at docs/examples/model-surfaces.json
# (config/ must hold no tracked files — repo invariant), so a bare clone still routes.
fm_fleet_model_map() { # base
  local m="$1/config/model-surfaces.json"
  [ -f "$m" ] || m="$1/docs/examples/model-surfaces.json"
  printf '%s\n' "$m"
}

# model family -> surfaces (quota pools) with each surface's live status + headroom.
# Answers "for model X, which pools can serve it and which have tokens?" — the basis
# for grok/kimi picker decisions across surfaces. Reads fm_fleet_model_map. 0 LLM tokens.
fm_fleet_models_report() {
  command -v jq >/dev/null 2>&1 || { echo "jq not installed" >&2; return 1; }
  local base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local map; map=$(fm_fleet_model_map "$base")
  [ -f "$map" ] || { echo "no model map at $map" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null || echo '{"providers":[]}')
  declare -A ST HR
  local p st hr
  while IFS=$'\t' read -r p st hr; do ST[$p]=$st; HR[$p]=$hr; done < <(
    printf '%s\n' "$j" | jq -r '.providers[]
      | ((.quotaSemantics.effectiveAvailability // [] | map(select(.scope=="all_models").effectivePercentRemaining) | .[0])
         // (.windows//[]|map(.percentRemaining)|min)) as $r
      | [.provider, (.state.status//"?"), (if $r==null then "—" else ($r|tostring)+"%" end)] | @tsv')
  local f s surf
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    surf=$(printf '%s' "$s" | jq -r '.surface // empty' 2>/dev/null); [ -n "$surf" ] || continue
    ST[$surf]=$(printf '%s' "$s" | jq -r '.status//"?"')
    HR[$surf]=$(printf '%s' "$s" | jq -r 'if .headroom==null then "—" else (.headroom|tostring)+"%" end')
  done
  {
    printf 'MODEL\tSURFACES (pool: status headroom)\n'
    local fam surfaces sfx out
    while IFS= read -r fam; do
      surfaces=$(jq -r --arg k "$fam" '.[$k][]?' "$map")
      out=""
      while IFS= read -r sfx; do
        [ -n "$sfx" ] || continue
        out+="${out:+  |  }${sfx}: ${ST[$sfx]:-unconfigured} ${HR[$sfx]:-—}"
      done <<< "$surfaces"
      printf '%s\t%s\n' "$fam" "$out"
    done < <(jq -r 'keys_unsorted[] | select(startswith("_")|not)' "$map")
  } | if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi
}

# Model-surface picker: pick the best surface (quota pool) to serve a model family.
# OPERATOR-FACING DIAGNOSTIC ONLY — answers "which pool has tokens for grok right
# now" for a human running `fm-fleet.sh pick`. NEVER called from `fm-spawn`, crew
# dispatch, or any automated path (anti-goal §4.1) — dispatch's pace-aware
# selection belongs solely to upstream's `quota-array-dispatch` skill. Selects
# among surfaces of ONE model family only (map is keyed by family); must never
# become a cross-family selector — that needs the reasoning-class judgment
# `quota-array-dispatch` owns (R4).
#
#   pass 1: among surfaces with OBSERVABLE headroom >= FM_FLEET_QUOTA_MIN (raw
#           floor, unchanged, still dominant), prefer by pace (§5.5):
#     1a known sustainable (behind/on_pace/mixed-with-no-remaining-ahead-window,
#        i.e. NOT pressured per §5.2) -> first in map order
#     1b unknown pace, or pace absent (v2, custom source, no v3 pace fields)
#        -> first in map order
#     1c pressured (ahead; mixed with a remaining aheadWindowId; or a bounding
#        window itself ahead) -> least-negative worst reserve; ties -> map order
#   pass 2: else first surface configured/online but unobservable (fail-open)
#   pass 3: else the first listed surface (last resort)
# Map order is a documented OPERATOR preference (map's own _comment says the
# picker walks the list left-to-right), distinct from the array-order bias
# quota-array-dispatch forbids for dispatch ties (that rule targets an
# unordered config array; this map is explicitly ordered).
# R1: only FRESH surfaces' pace is trusted for 1a/1b/1c; a stale surface's pace
# is treated as unavailable (falls to 1b) though its raw headroom (pass 1) and
# `quota` display (T6) are unaffected.
# Echoes the surface name; non-zero (with message) if the family is unknown.
fm_fleet_pick_surface() { # model-family
  command -v jq >/dev/null 2>&1 || return 2
  local fam=$1 base map floor=${FM_FLEET_QUOTA_MIN:-5}
  base="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  map=$(fm_fleet_model_map "$base")
  [ -f "$map" ] || return 2
  local surfaces; surfaces=$(jq -r --arg k "$fam" '.[$k][]?' "$map")
  [ -n "$surfaces" ] || { echo "unknown model family: $fam" >&2; return 1; }
  local j; j=$(quota-axi --json 2>/dev/null || echo '{"providers":[]}')
  declare -A ST HR PACE_OF RESERVE_OF
  local p st hr
  while IFS=$'\t' read -r p st hr; do ST[$p]=$st; HR[$p]=$hr; done < <(
    printf '%s\n' "$j" | jq -r '.providers[]
      | ((.quotaSemantics.effectiveAvailability//[]|map(select(.scope=="all_models").effectivePercentRemaining)|.[0])
         //(.windows//[]|map(.percentRemaining)|min)) as $r
      | [.provider,(.state.status//"?"),(if $r==null then "" else ($r|tostring) end)] | @tsv')
  local psurf pstate ppace preserve
  while IFS=$'\037' read -r psurf pstate ppace preserve; do
    [ -n "$psurf" ] && [ "$pstate" = fresh ] || continue
    PACE_OF[$psurf]=$ppace; RESERVE_OF[$psurf]=$preserve
  done < <(fm_fleet_pace_fields "$j")
  local f s surf
  for f in "$base"/bin/quota-sources/*.sh; do
    [ -f "$f" ] || continue; s=$(bash "$f" 2>/dev/null) || continue
    surf=$(printf '%s' "$s" | jq -r '.surface//empty' 2>/dev/null); [ -n "$surf" ] || continue
    ST[$surf]=$(printf '%s' "$s" | jq -r '.status//"?"')
    HR[$surf]=$(printf '%s' "$s" | jq -r 'if .headroom==null then "" else (.headroom|tostring) end')
  done
  local sfx h pace reserve first_1a="" first_1b="" best_1c="" best_1c_reserve=""
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    h=${HR[$sfx]:-}
    { [ -n "$h" ] && fm_fleet_num_ge "$h" "$floor"; } || continue
    pace=${PACE_OF[$sfx]:-}
    if [ -z "$pace" ] || [ "$pace" = unknown ]; then
      [ -n "$first_1b" ] || first_1b=$sfx
    elif fm_fleet_pressured "$(printf '%s' "$j" | jq -c --arg s "$sfx" '.providers[] | select(.provider==$s)')"; then
      reserve=${RESERVE_OF[$sfx]:-}
      # Strictly-better reserve displaces; a numeric TIE keeps the incumbent, i.e.
      # map order (so -5 never displaces an equal -5.0 — quota-axi emits floats).
      # An incumbent with no reserve at all ranks WORST: a pressured surface whose
      # reserve is unmeasurable must not permanently outrank a later, measurably
      # more sustainable one.
      if [ -z "$best_1c" ]; then
        best_1c=$sfx; best_1c_reserve=$reserve
      elif [ -n "$reserve" ] \
           && { [ -z "$best_1c_reserve" ] || ! fm_fleet_reserve_cmp "$best_1c_reserve" "$reserve"; }; then
        best_1c=$sfx; best_1c_reserve=$reserve
      fi
    else
      [ -n "$first_1a" ] || first_1a=$sfx
    fi
  done <<< "$surfaces"
  [ -n "$first_1a" ] && { echo "$first_1a"; return 0; }
  [ -n "$first_1b" ] && { echo "$first_1b"; return 0; }
  [ -n "$best_1c" ] && { echo "$best_1c"; return 0; }
  while IFS= read -r sfx; do [ -n "$sfx" ] || continue
    case "${ST[$sfx]:-}" in fresh|configured|online|logged_in) echo "$sfx"; return 0;; esac
  done <<< "$surfaces"
  printf '%s\n' "$surfaces" | head -1
}

# Float-safe >= (headroom percentages can be fractional, e.g. 90.5, which the
# integer-only [ -ge ] test cannot parse).
fm_fleet_num_ge() { # a b
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0)>=(b+0))}'
}

# Float-safe signed >= (reserve is signed points, e.g. -18.0 — distinct from
# fm_fleet_num_ge's headroom-shaped callers so negatives are never a surprise).
fm_fleet_reserve_cmp() { # a b -> exit 0 if a >= b
  awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0)>=(b+0))}'
}

# --- quota-window pace (quota-axi >= 0.1.15, schemaVersion 3) -----------------
# See docs/fleet-addon.md "Per-surface pace" + .agents/skills/federation/SKILL.md.
# Dispatch's pace-aware selection is owned solely by upstream's
# `quota-array-dispatch` skill — these are read-only reporting primitives.

# One quota-axi snapshot -> one TSV row per provider: <surface>\t<headroom>\t
# <state>\t<pace>\t<reserve>. Resolution (PRD §5.1), reusing the SAME headroom
# precedence every other fleet quota reader uses:
#   headroom: effectiveAvailability[scope=all_models].effectivePercentRemaining,
#             else min(windows[].percentRemaining), else absent.
#   pace:     effectiveAvailability[...].pace.status when present (verbatim,
#             including "mixed" — never simplified to a binary flag); else
#             derived from windows[].pace.status ("ahead" if any ahead, else
#             "unknown" if any unknown, else "behind" if any behind, else
#             "on_pace"); else EMPTY (absent) — never fabricated as "on_pace".
#   reserve:  effectiveAvailability[...].pace.worstReservePercentPoints when
#             present (preferred), else min(windows[].pace.reservePercentPoints)
#             across windows that carry one, else absent.
# Absent renders as an EMPTY field; the caller shows "—". A literal "unknown"
# must never collapse into that same field (R3) — stated uncertainty vs. silence.
# Callers fetch quota-axi --json ONCE per command and pass the snapshot in; this
# function makes no subprocess call of its own.
fm_fleet_pace_rows() { # quota-axi-json-snapshot
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$1" | jq -r '
    def eff: (.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope=="all_models")) | .[0];
    .providers[]? as $p
    | ($p | eff) as $eff
    | ($p.windows // []) as $windows
    | ( $eff.effectivePercentRemaining
        // ([$windows[]?.percentRemaining] | map(select(.!=null)) | if length>0 then min else null end)
      ) as $headroom
    | ( if $eff.pace.status != null then $eff.pace.status
        else
          ([$windows[]?.pace.status] | map(select(.!=null))) as $ws
          | if ($ws|length)==0 then null
            elif ($ws|any(.=="ahead")) then "ahead"
            elif ($ws|any(.=="unknown")) then "unknown"
            elif ($ws|any(.=="behind")) then "behind"
            else "on_pace" end
        end
      ) as $pace
    | ( if $eff.pace.worstReservePercentPoints != null then $eff.pace.worstReservePercentPoints
        else
          ([$windows[]?.pace.reservePercentPoints] | map(select(.!=null))) as $wr
          | if ($wr|length)==0 then null else ($wr|min) end
        end
      ) as $reserve
    | [ $p.provider, ($headroom // ""), ($p.state.status // ""), ($pace // ""), ($reserve // "") ] | @tsv
  '
}

# fm_fleet_pace_rows projected to the four fields every shell consumer needs —
# <surface><US><state><US><pace><US><reserve> — ready for `read`. The delimiter is
# US (\037), NOT the row format's tab: bash treats tab as IFS *whitespace*, so a run
# of tabs collapses into one and an absent MIDDLE field (no headroom, no
# state.status) shifts every later field left — printing a reserve under PACE and
# "—" under RESERVE. awk -F'\t' does not collapse, and \037 is not IFS whitespace,
# so an absent field stays absent. Values can contain neither character (@tsv
# escapes both).
fm_fleet_pace_fields() { # quota-axi-json-snapshot
  fm_fleet_pace_rows "$1" | awk -F'\t' -v OFS=$'\037' '{print $1,$3,$4,$5}'
}

# Render a signed reserve: explicit "+"/"-", "—" when absent. Separate from
# fm_fleet_pace_rows (bare jq number) since that raw value is still compared
# numerically (fm_fleet_reserve_cmp) before ever being rendered.
fm_fleet_render_reserve() { # reserve
  local r=$1
  [ -n "$r" ] || { printf '%s' '—'; return 0; }
  case "$r" in
    -*) printf '%s' "$r" ;;
    *)  printf '+%s' "$r" ;;
  esac
}

# §5.2 conservation-pressure predicate, verbatim from quota-array-dispatch
# (fa0d85d) — do not simplify to `status == ahead`; that misclassifies `mixed`
# + remaining aheadWindowIds as healthy (R2), which the skill forbids.
#   pressured := status=="ahead" OR (status=="mixed" AND aheadWindowIds non-empty)
#                OR any applicable bounding window has status=="ahead"
# Absent pace ⇒ NOT pressured (merely unclassified; caller's own absent/unknown
# handling applies, R3). Exit 0 when pressured.
fm_fleet_pressured() { # single-provider-json
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$1" | jq -e '
    def eff: (.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope=="all_models")) | .[0];
    (eff) as $eff
    | (($eff.pace.status // "") == "ahead")
      or ((($eff.pace.status // "") == "mixed") and ((($eff.pace.aheadWindowIds // []) | length) > 0))
      or ([(.windows // [])[]?.pace.status] | any(. == "ahead"))
  ' >/dev/null 2>&1
}

# FM_FLEET_RESERVE_MIN — worst tolerated signed reserve, in points, before
# conservation pressure alone holds back work. Default -25 below (resolved
# inline, like every other FM_FLEET_* knob — sourcing this lib never mutates
# the caller's env). -25 = "burned 25 points more than the window's elapsed
# share". Set to -100 to disable the pace floor and restore raw-headroom-only.

# fm-fleet.sh budget prints this after fm_fleet_budget_ok — inspectable facts,
# never a bare verdict. Function-local global since callers only check $?.
# shellcheck disable=SC2034 # Read by bin/fm-fleet.sh's `budget` verb, not this lib.
fm_fleet_budget_reason=""

# 0 if headroom is ok AND not held back by conservation pressure. Truth table
# (§5.4), raw floor DOMINANT:
#   headroom unmeasurable (-)                    -> ok   (fail-open, unchanged)
#   headroom < FM_FLEET_QUOTA_MIN                 -> below floor (unchanged)
#   headroom ok, not pressured                    -> ok
#   headroom ok, pressured, worst reserve >= MIN  -> ok
#   headroom ok, pressured, worst reserve < MIN   -> below pace floor (NEW)
#   headroom ok, pressured, reserve absent        -> ok (can't measure, fail-open)
# R1: only FRESH providers feed pressure/reserve — a stale window's reserve only
# ages toward looking MORE ahead as the clock runs, so it must never refuse
# (still VISIBLE via `quota`, T6). Degradation (G5): when NO provider anywhere
# carries a pace field, this reproduces today's exact static message/exit code.
#
# Callers audited 2026-07-28 (T7): bin/fm-fleet.sh's `budget` verb (prints
# $fm_fleet_budget_reason, same 0/1 exit convention); tests/federation/
# test_fleet_ops.sh (exit code only, v2-shaped stub -> legacy path); docs/
# fleet-token-economy.md + .agents/skills/federation/SKILL.md (prose, T9).
fm_fleet_budget_ok() {
  local floor=${FM_FLEET_QUOTA_MIN:-5} rmin=${FM_FLEET_RESERVE_MIN:--25}
  local reason rc

  if ! command -v quota-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    reason="ok (min headroom >= ${floor}%)"; rc=0
  else
    local j; j=$(quota-axi --json 2>/dev/null)
    local q
    q=$(printf '%s' "${j:-}" | jq -r '[.providers[]?.windows[]?.percentRemaining] | min // "-"' 2>/dev/null)
    case "$q" in ''|null) q='-' ;; esac
    if [ "$q" = '-' ]; then
      reason="ok (min headroom >= ${floor}%)"; rc=0
    elif ! fm_fleet_num_ge "$q" "$floor"; then
      reason="below floor (< ${floor}%)"; rc=1
    else
      # Headroom clears the floor. Fold in pace, restricted to FRESH providers (R1).
      # Track the WORST (most negative / least sustainable) reserve among fresh,
      # KNOWN-class providers (never "unknown" — R3) as the single inspectable
      # pace fact to report, whether or not it happens to be the one that trips
      # `pressured`; `pressured` itself is a separate OR across every fresh
      # provider's §5.2 predicate, since a "mixed" summary can be pressured via
      # its aheadWindowIds even when its own reserve number isn't the worst one.
      local psurf pstate ppace preserve
      local pace_seen=0 pressured=0 have_worst=0 worst_reserve="" worst_pace=""
      while IFS=$'\037' read -r psurf pstate ppace preserve; do
        [ -n "$psurf" ] || continue
        [ -n "$ppace" ] && pace_seen=1
        [ "$pstate" = fresh ] || continue
        [ -n "$ppace" ] && [ "$ppace" != unknown ] || continue
        if fm_fleet_pressured "$(printf '%s' "$j" | jq -c --arg s "$psurf" '.providers[] | select(.provider==$s)')"; then
          pressured=1
        fi
        if [ -n "$preserve" ] && { [ "$have_worst" -eq 0 ] || ! fm_fleet_reserve_cmp "$preserve" "$worst_reserve"; }; then
          worst_reserve=$preserve; worst_pace=$ppace; have_worst=1
        elif [ "$have_worst" -eq 0 ]; then
          worst_pace=$ppace
        fi
      done < <(fm_fleet_pace_fields "$j")

      if [ "$pace_seen" -eq 0 ]; then
        # True v2/degraded: no provider anywhere carries a pace field. Reproduce
        # today's exact message — never invent pace, never claim on_pace (G5/R3).
        reason="ok (min headroom >= ${floor}%)"; rc=0
      elif [ "$pressured" -eq 0 ]; then
        if [ -n "$worst_pace" ]; then
          reason="ok (headroom ${q}% >= ${floor}%, pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve"))"
        else
          reason="ok (headroom ${q}% >= ${floor}%, no conservation pressure)"
        fi
        rc=0
      elif [ -z "$worst_reserve" ]; then
        reason="ok (headroom ${q}% >= ${floor}%, pace pressured but reserve unmeasurable, fail-open)"; rc=0
      elif fm_fleet_reserve_cmp "$worst_reserve" "$rmin"; then
        reason="ok (headroom ${q}% >= ${floor}%, pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve"))"; rc=0
      else
        reason="below pace floor (headroom ${q}% >= ${floor}% but pace ${worst_pace}, reserve $(fm_fleet_render_reserve "$worst_reserve") < ${rmin})"; rc=1
      fi
    fi
  fi

  # shellcheck disable=SC2034 # Read by bin/fm-fleet.sh's `budget` verb, not this lib.
  fm_fleet_budget_reason=$reason
  return "$rc"
}
