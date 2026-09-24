#!/usr/bin/env bash
# Conservative rendered stop recognition for fm-watch.sh; no network calls.
# fm_pane_stop <harness> <pane> prints kind<TAB>provider<TAB>reset-delay<TAB>display.
# Unknown reset delays use '-' (never infer a weekly reset date).
# Callers establish a live, idle worker first. Only standalone lines qualify;
# quota errors must be in the last 12 nonblank lines, dialogs in the last 40.
# An unknown error or changed vendor wording stays on ordinary stale triage.
fm_pane_stop() {
  local harness=$1 pane=$2 allowed kind provider pattern line normalized recent
  local hours minutes seconds duration
  normalized=$(printf '%s\n' "$pane" | sed -E $'s/\033\\[[0-9;]*[mK]//g; s/^[[:space:]│┃]+//; s/[[:space:]│┃]+$//; /^[[:space:]]*$/d' | tail -n 40)
  while IFS='|' read -r allowed kind provider pattern; do
    case ",$allowed," in *",$harness,"*) ;; *) continue ;; esac
    recent=$normalized
    [ "$kind" != quota-exhausted ] || recent=$(printf '%s\n' "$normalized" | tail -n 12)
    while IFS= read -r line; do
      [[ $line =~ $pattern ]] || continue
      if [ "$kind" = quota-exhausted ] && [ "$provider" = gemini ]; then
        hours=${BASH_REMATCH[2]:-0}; minutes=${BASH_REMATCH[4]:-0}; seconds=${BASH_REMATCH[6]:-0}
        duration=${BASH_REMATCH[1]}${BASH_REMATCH[3]}${BASH_REMATCH[5]}
        [ -n "$duration" ] || continue
        [ "$((10#$minutes))" -lt 60 ] && [ "$((10#$seconds))" -lt 60 ] || continue
        printf '%s\t%s\t%s\t%s\n' "$kind" "$provider" "$((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))" "$duration"
      elif [ "$kind" = blocked-at-prompt ]; then
        printf '%s\n' "$recent" | grep -qE '^Do not trust$' || continue
        printf '%s\t%s\t-\t%s\n' "$kind" "$harness" "$provider"
      else
        printf '%s\t%s\t-\tunknown\n' "$kind" "$provider"
      fi
      return 0
    done <<< "$recent"
  done <<'PATTERNS'
grok|quota-exhausted|grok|^You hit your weekly limit$
pi,pi-signed|quota-exhausted|gemini|^Error: Quota reached\. Please wait (([0-9]{1,3})h)?(([0-9]{1,2})m)?(([0-9]{1,2})s)?$
pi,pi-signed|blocked-at-prompt|trust|^Trust project folder[?]$
PATTERNS
  return 1
}
