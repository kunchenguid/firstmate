#!/usr/bin/env bash
# fm-gex-drift.sh - deployed-state drift guard for service repos (plan v3 U1.6):
# a merge into a service repo is an intermediate state until the running
# service carries it ("KEIN PUSH OHNE AUSROLLEN" - captain's order 23.08.;
# EN: no push without rollout), and a service running behind its repo is a
# finding, not a footnote (L01; measured three-of-four adrift on 23.08.,
# report data/lensclash-scan-ablauf-messung/report.md section 0).
#
# Usage:
#   fm-gex-drift.sh check    silent when in sync; one line per NEW finding;
#                            a missing or empty inventory is loudly
#                            unpruefbar every poll and is never an all-clear
#   fm-gex-drift.sh report   every service, probe verdict, and owed rollout
#   fm-gex-drift.sh owe <owner/repo> <task-id> <pr-url>
#                            deposit an owed rollout. An unlisted repo is a
#                            silent no-op so the merge hook may call this
#                            unconditionally; a MISSING OR EMPTY inventory
#                            cannot tell service repos from other repos, so
#                            owe refuses loudly (kein Inventar - unpruefbar)
#                            instead of silently dropping the reminder
#   fm-gex-drift.sh clear <owner/repo>
#                            drop owed rollouts for a repo (verified deploy)
#   fm-gex-drift.sh relevant <repo-dir> <from-sha> <to-sha> <pattern...>
#                            classify one window read-only: exit 0 and list
#                            the matching paths when a service-relevant path
#                            changed, exit 1 when none did, exit 2 on error
#   fm-gex-drift.sh arm      write + register state/gex-drift.check.sh
#   fm-gex-drift.sh disarm   remove shim, trust binding, and records
#   fm-gex-drift.sh --help
#
# SERVICE INVENTORY (deposit form): config/gex-drift.services - LOCAL,
# gitignored; one service per line, tab-separated:
#
#   <name>\t<owner/repo>\t<repo-dir>\t<art> [args...] [\t<path-patterns>]
#
# arts, each read-only; probe verdicts: in sync, drifted, or failed - and a
# failed probe is reported as failed, never counted as in sync:
#   image-tag <ssh-host> <container>
#       docker-inspect the running container's image reference over ssh; in
#       sync when the reference carries the repo tip's short sha. This asks
#       the target, never memory.
#   cmd <one-line reading command>
#       Extension point: exit 0 = in sync, exit 1 = drifted, else failed.
#
# PATH FILTER (optional fifth field): space- or comma-separated globs such as
# "backend/* shared/* contracts/*"; a trailing slash means everything under
# the directory ("backend/" matches "backend/x"). When set, a tag mismatch is
# drift only if the window deployed-commit..repo-tip changed at least one
# matching path, so pure docs/frontend merges stay in sync. Lines without the
# field keep the previous meaning: every commit counts. The filter applies to
# sha-carrying image-tag probes; cmd probes decide themselves and ignore it.
# A deployed reference the repo cannot resolve is reported as full drift
# (loudly unknown), never as in sync.
#
# FRESHNESS: every probe first fetches the repo read-only (plain `git fetch`
# in the clone, BatchMode ssh, time-bounded), so a stale local checkout can
# never alarm in the wrong direction. The measured tip is the checkout head
# or its fetched upstream tip, whichever contains the other, and the verdict
# declares which stand it measured. A FAILED FETCH IS A FAILED VERDICT,
# never in sync; a repo without a configured remote says so and measures its
# checkout stand.
#
# Test hook: setting FM_GEX_DRIFT_TEST_IMAGE replaces the ssh-read image
# string for every image-tag probe; production homes never set it.
#
# The inventory is HASH-BOUND at arm time: `arm` records its sha256 in
# state/.gex-drift-armed, and a `check` against an edited inventory refuses to
# probe (loudly, once per edit) until re-armed - an unnoticed edit must not
# silently change what the guard executes. `arm` refuses an inventory with no
# active service lines, an unknown probe art, or a missing repo directory.
# A never-armed home probes directly; the binding protects the watcher path.
#
# State (this header is the single owner):
#   state/.gex-drift-armed   sha256 of the armed inventory
#   state/.gex-drift-seen    the finding set of the last report (a finding is
#                            news once, not every poll; changed or returning
#                            findings are news again; the unpruefbar and
#                            refusal lines below are NOT deduped - they fire
#                            every poll until the configuration is fixed)
#   state/.rollout-owed      owed rollouts: <utc>\t<owner/repo>\t<task>\t<pr-url>
#                            deposited by `owe` (bin/fm-pr-merge.sh calls it
#                            after every successful merge), cleared by a probe
#                            confirming the repo deployed in sync or by `clear`
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SERVICES="$CONFIG/gex-drift.services"
ARMED="$STATE/.gex-drift-armed"
SEEN="$STATE/.gex-drift-seen"
OWED="$STATE/.rollout-owed"
CHECK_ID=gex-drift
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
TAB=$(printf '\t')

usage() { sed -n '2,83p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
services_sha() { sha256sum "$SERVICES" 2>/dev/null | cut -d' ' -f1; }

# active_line_count: number of inventory lines that carry a service
# (non-empty, not starting with '#'). Zero means the guard is unpruefbar.
active_line_count() {
  if [ -f "$SERVICES" ]; then
    awk 'NF && $1 !~ /^#/ {n++} END {print n + 0}' "$SERVICES"
  else
    printf '0\n'
  fi
}

# inventory_state classifies the inventory before any probe may run:
#   ready          probe normally
#   edited         armed, but the inventory changed since arm
#   armed-missing  armed, but the inventory file is gone
#   missing        no inventory file at all
#   empty          inventory file exists but carries no active service line
inventory_state() {
  local armed_now=""
  if [ -f "$ARMED" ]; then
    armed_now=$(cat "$ARMED" 2>/dev/null)
  fi
  if [ -n "$armed_now" ]; then
    if [ ! -f "$SERVICES" ]; then
      printf 'armed-missing\n'
      return
    fi
    if [ "$armed_now" != "$(services_sha)" ]; then
      printf 'edited\n'
      return
    fi
  fi
  if [ ! -f "$SERVICES" ]; then
    printf 'missing\n'
    return
  fi
  if [ "$(active_line_count)" -eq 0 ]; then
    printf 'empty\n'
    return
  fi
  printf 'ready\n'
}

refusal_edited() {
  printf 'GEX_DRIFT: inventory %s edited since arm - probes refused until re-armed (bin/fm-gex-drift.sh arm)\n' "$SERVICES"
}

refusal_armed_missing() {
  printf 'GEX_DRIFT: armed inventory %s is missing (kein Inventar - unpruefbar) - probes refused until re-armed or disarmed\n' "$SERVICES"
}

unpruefbar_line() {
  printf 'GEX_DRIFT: kein Inventar unter %s - unpruefbar (missing or empty service inventory): no all-clear derivable, probes refused\n' "$SERVICES"
}

# normalize_patterns <field>: split a path-filter field on commas and
# whitespace, expand a trailing slash to "everything under it", print one
# glob per line.
normalize_patterns() {
  printf '%s\n' "$1" | tr ',' ' ' | tr -s ' ' '\n' | while IFS= read -r pat; do
    case "$pat" in
      */) printf '%s*\n' "${pat%/}" ;;
      ?*) printf '%s\n' "$pat" ;;
    esac
  done
}

# window_matches <dir> <from-full> <to-full> <pattern...>
# Prints every path changed between the two commits that matches one pattern.
# Empty output means no service-relevant change; rc 1 means the window diff
# itself was unreadable.
window_matches() {
  local dir=$1 from=$2 to=$3 pat path changed
  shift 3
  changed=$(git -C "$dir" diff --name-only "$from" "$to" 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    for pat in "$@"; do
      # shellcheck disable=SC2254 # patterns are globs, matching is the point
      case "$path" in
        $pat)
          printf '%s\n' "$path"
          break
          ;;
      esac
    done
  done <<< "$changed"
  return 0
}

FETCH_NOTE=""

# fetch_fresh <dir>: refresh the clone read-only before any comparison.
# Sets FETCH_NOTE on the two declared non-fresh paths. rc 1 = fetch failed,
# which callers must turn into a failed verdict, never into in-sync.
fetch_fresh() {
  local dir=$1 out rc
  FETCH_NOTE=""
  if [ -z "$(git -C "$dir" remote 2>/dev/null)" ]; then
    FETCH_NOTE="no configured remote; measuring the checkout stand"
    return 0
  fi
  if command -v timeout >/dev/null 2>&1; then
    out=$(GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=8' \
      timeout 30 git -C "$dir" fetch --quiet 2>&1)
  else
    out=$(GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=8' \
      git -C "$dir" fetch --quiet 2>&1)
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    out=$(printf '%s' "$out" | tail -n 1 | cut -c1-120)
    FETCH_NOTE="fetch failed (${out:-rc=$rc})"
    return 1
  fi
  return 0
}

TIP=""
TIP_NOTE=""

# resolve_tip <dir>: pick the reference stand the deployed state is measured
# against and declare it. Preference: when the checkout branch tracks an
# upstream, take whichever of checkout head and fetched upstream tip contains
# the other; without an upstream, declare that the checkout stand is used.
resolve_tip() {
  local dir=$1 head up
  head=$(git -C "$dir" rev-parse --short=7 HEAD 2>/dev/null)
  TIP="$head"
  TIP_NOTE=""
  up=$(git -C "$dir" rev-parse --short=7 --verify --quiet '@{upstream}' 2>/dev/null || true)
  if [ -z "$up" ]; then
    TIP_NOTE="reference: checkout head $head (branch has no upstream)"
    return 0
  fi
  if [ "$up" = "$head" ]; then
    TIP_NOTE="fetched; checkout matches upstream tip $up"
    return 0
  fi
  if git -C "$dir" merge-base --is-ancestor "$head" "$up" 2>/dev/null; then
    TIP="$up"
    TIP_NOTE="checkout behind fetched upstream tip $up; measured against the fetched tip"
    return 0
  fi
  if git -C "$dir" merge-base --is-ancestor "$up" "$head" 2>/dev/null; then
    TIP_NOTE="checkout ahead of upstream; measured against checkout head $head"
    return 0
  fi
  TIP_NOTE="checkout $head DIVERGED from upstream $up; measured against checkout head $head"
  return 0
}

# image_token <image-reference>: best-effort extract the trailing tag token
# that may carry a commit sha (last path segment after the last colon).
image_token() {
  local tok=${1##*/}
  tok=${tok##*:}
  printf '%s' "$tok"
}

# classify_image <deployed> <dir> <paths-field> <tip> <tip-note>
# Print the image-tag verdict line for one service.
classify_image() {
  local deployed=$1 dir=$2 paths_field=$3 tip=$4 note=$5
  local suffix="" dep_full="" cand tip_full matches shown dep_short
  [ -n "$note" ] && suffix=" ($note)"
  case "$deployed" in
    *"$tip"*)
      printf 'insync %s%s\n' "$tip" "$suffix"
      return 0
      ;;
  esac
  cand=$(image_token "$deployed")
  if [ -n "$cand" ]; then
    dep_full=$(git -C "$dir" rev-parse --verify --quiet "${cand}^{commit}" 2>/dev/null || true)
  fi
  tip_full=$(git -C "$dir" rev-parse --verify --quiet "${tip}^{commit}" 2>/dev/null || true)
  if [ -n "$dep_full" ] && [ -n "$tip_full" ] && [ "$dep_full" = "$tip_full" ]; then
    printf 'insync %s (same commit; tag format differs)%s\n' "$tip" "$suffix"
    return 0
  fi
  if [ -z "$dep_full" ]; then
    printf 'drift %s %s (deployed reference not resolvable in repo; assuming full drift)%s\n' \
      "$deployed" "$tip" "$suffix"
    return 0
  fi
  local patterns=()
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    patterns+=("$pat")
  done < <(normalize_patterns "$paths_field")
  if [ "${#patterns[@]}" -eq 0 ]; then
    printf 'drift %s %s%s\n' "$deployed" "$tip" "$suffix"
    return 0
  fi
  dep_short=${dep_full%"${dep_full#???????}"}
  if ! matches=$(window_matches "$dir" "$dep_full" "$tip_full" "${patterns[@]}"); then
    printf 'drift %s %s (window diff unreadable; assuming full drift)%s\n' \
      "$deployed" "$tip" "$suffix"
    return 0
  fi
  if [ -n "$matches" ]; then
    shown=$(printf '%s\n' "$matches" | head -n 3 | paste -sd, -)
    printf 'drift %s %s (service-relevant change: %s)%s\n' \
      "$deployed" "$tip" "$shown" "$suffix"
  else
    printf 'insync %s (only non-service paths changed in %s..%s)%s\n' \
      "$tip" "$dep_short" "$tip" "$suffix"
  fi
  return 0
}

# probe_service <repo-dir> <paths-field> <art> [args...]
# Prints exactly one verdict line: "insync <tip>[ (note)]",
# "drift <deployed> <tip>[ (reason)]", or "failed <reason>".
# Freshness first: a failed fetch is a failed verdict, never in sync.
probe_service() {
  local dir=$1 paths_field=$2 art=$3 deployed host container rc
  shift 3
  if ! fetch_fresh "$dir"; then
    printf 'failed %s\n' "$FETCH_NOTE"
    return 0
  fi
  resolve_tip "$dir"
  if [ -z "$TIP" ]; then
    printf 'failed repo head unreadable (%s)\n' "$dir"
    return 0
  fi
  case "$art" in
    image-tag)
      host=${1:-}; container=${2:-}
      if [ -z "$host" ] || [ -z "$container" ]; then
        printf 'failed image-tag needs <ssh-host> <container>\n'
        return 0
      fi
      if [ -n "${FM_GEX_DRIFT_TEST_IMAGE:-}" ]; then
        deployed=$FM_GEX_DRIFT_TEST_IMAGE
      else
        deployed=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
          docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null | tr -d '[:space:]')
      fi
      if [ -z "$deployed" ]; then
        printf 'failed image-tag probe unreachable or empty (%s %s)\n' "$host" "$container"
        return 0
      fi
      classify_image "$deployed" "$dir" "$paths_field" "$TIP" "$TIP_NOTE"
      ;;
    cmd)
      bash -c "$*" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        0) printf 'insync %s (%s)\n' "$TIP" "$TIP_NOTE" ;;
        1) printf 'drift cmd-verdict %s\n' "$TIP" ;;
        *) printf 'failed cmd probe rc=%s\n' "$rc" ;;
      esac
      ;;
    *)
      printf 'failed unknown probe art %s\n' "$art"
      ;;
  esac
}

# owed_findings: the owed-rollout reminder block, independent of the
# inventory (an unpruefbar guard must keep reminding about what it owes).
owed_findings() {
  local findings="" owhen orepo otask opr
  if [ -f "$OWED" ]; then
    while IFS="$TAB" read -r owhen orepo otask opr; do
      [ -n "$orepo" ] || continue
      findings="${findings}GEX_DRIFT: rollout owed for $orepo since $owhen (task $otask, $opr) - the merge is not done until the service carries it
"
    done < "$OWED"
  fi
  printf '%s' "$findings" | sort -u
}

# gather_findings <mode>: prints the CURRENT finding set (sorted, one line
# each) on stdout. Requires inventory_state = ready. In mode "report"
# additionally prints per-service verdicts to stderr. Clears owed rollouts
# that an in-sync probe just confirmed deployed, and reports each such
# confirmation as a finding once.
gather_findings() {
  local mode=$1 findings="" name repo dir rest verdict deployed head extra
  local art_args paths_field
  while IFS="$TAB" read -r name repo dir rest; do
    case "$name" in ''|'#'*) continue ;; esac
    art_args=${rest%%"$TAB"*}
    paths_field=""
    case "$rest" in
      *"$TAB"*) paths_field=${rest#*"$TAB"} ;;
    esac
    # shellcheck disable=SC2086 # rest is the probe art plus its args, split on purpose
    verdict=$(probe_service "$dir" "$paths_field" $art_args)
    [ "$mode" = report ] && printf '%s (%s): %s\n' "$name" "$repo" "$verdict" >&2
    case "$verdict" in
      insync*)
        head=$(printf '%s' "$verdict" | cut -d' ' -f2)
        if [ -f "$OWED" ] && grep -qF "$TAB$repo$TAB" "$OWED"; then
          while IFS="$TAB" read -r _ orepo otask opr; do
            [ "$orepo" = "$repo" ] || continue
            findings="${findings}GEX_DRIFT: rollout CONFIRMED for $repo (service $name in sync at $head) - owed entry cleared (task $otask, $opr)
"
          done < "$OWED"
          grep -vF "$TAB$repo$TAB" "$OWED" > "$OWED.tmp.$$" || true
          mv -f "$OWED.tmp.$$" "$OWED"
        fi
        ;;
      drift*)
        deployed=$(printf '%s' "$verdict" | cut -d' ' -f2)
        head=$(printf '%s' "$verdict" | cut -d' ' -f3)
        extra=$(printf '%s' "$verdict" | cut -d' ' -f4-)
        findings="${findings}GEX_DRIFT: $name ($repo) runs $deployed, repo is at $head - rollout owed or unexplained drift${extra:+ $extra}
"
        ;;
      failed*)
        findings="${findings}GEX_DRIFT: probe FAILED for $name ($repo): ${verdict#failed } - drift unknown, never assumed in sync
"
        ;;
    esac
  done < "$SERVICES"
  findings="${findings}$(owed_findings)"
  printf '%s' "$findings" | sort -u
}

# news_since_seen <current-findings-text>: dedupe against the seen set,
# persist the new set, print what is news.
news_since_seen() {
  local news
  news=$(comm -13 <(sort -u "$SEEN" 2>/dev/null) <(printf '%s\n' "$1" | sed '/^$/d'))
  printf '%s\n' "$1" | sed '/^$/d' > "$SEEN"
  if [ -n "$news" ]; then
    printf '%s\n' "$news"
  fi
  return 0
}

# validate_inventory: reject malformed inventories at write time (arm), not
# at probe time. Every active line needs four tab fields, a known art, and an
# existing repo directory.
validate_inventory() {
  local n=0 name repo dir rest art
  while IFS="$TAB" read -r name repo dir rest; do
    n=$((n + 1))
    case "$name" in ''|'#'*) continue ;; esac
    if [ -z "$repo" ] || [ -z "$dir" ] || [ -z "$rest" ]; then
      printf 'error: %s line %s: expected <name>\\t<owner/repo>\\t<repo-dir>\\t<art> [args][\\t<path-patterns>]\n' "$SERVICES" "$n" >&2
      return 1
    fi
    art=${rest%% *}
    case "$art" in
      image-tag|cmd) ;;
      *)
        echo "error: $SERVICES line $n: unknown probe art '$art' (image-tag|cmd)" >&2
        return 1
        ;;
    esac
    if [ ! -d "$dir" ]; then
      echo "error: $SERVICES line $n: repo dir '$dir' does not exist" >&2
      return 1
    fi
  done < "$SERVICES"
  return 0
}

cmd="${1:-}"
case "$cmd" in
  check)
    mkdir -p "$STATE"
    case "$(inventory_state)" in
      edited)
        refusal_edited
        exit 0
        ;;
      armed-missing)
        refusal_armed_missing
        exit 0
        ;;
      missing|empty)
        unpruefbar_line
        news_since_seen "$(owed_findings)"
        exit 0
        ;;
    esac
    current=$(gather_findings check)
    news_since_seen "$current"
    exit 0
    ;;
  report)
    case "$(inventory_state)" in
      edited) refusal_edited ;;
      armed-missing) refusal_armed_missing ;;
      missing|empty)
        unpruefbar_line
        owed_findings
        ;;
      ready)
        current=$(gather_findings report)
        if [ -n "$current" ]; then printf '%s\n' "$current"; else echo "(all services in sync; nothing owed)"; fi
        ;;
    esac
    ;;
  owe)
    shift
    repo=${1:-}; task=${2:-}; pr=${3:-}
    if [ -z "$repo" ] || [ -z "$task" ] || [ -z "$pr" ]; then
      echo "error: owe requires <owner/repo> <task-id> <pr-url>" >&2
      exit 2
    fi
    if [ ! -f "$SERVICES" ]; then
      echo "error: kein Inventar unter $SERVICES - unpruefbar: cannot verify whether $repo is a service repo; rollout deposit REFUSED (remind by hand or restore the inventory)" >&2
      exit 1
    fi
    if [ "$(active_line_count)" -eq 0 ]; then
      echo "error: leeres Inventar unter $SERVICES - unpruefbar: cannot verify whether $repo is a service repo; rollout deposit REFUSED (remind by hand or restore the inventory)" >&2
      exit 1
    fi
    if ! cut -f2 "$SERVICES" | grep -qx "$repo"; then
      exit 0
    fi
    mkdir -p "$STATE"
    if [ -f "$OWED" ] && grep -qF "$TAB$repo$TAB$task$TAB$pr" "$OWED"; then
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\n' "$(utc_now)" "$repo" "$task" "$pr" >> "$OWED"
    echo "ROLLOUT OWED: $repo is a service repo - this merge is an intermediate state until the running service carries it (KEIN PUSH OHNE AUSROLLEN); the drift guard will keep reminding until a probe confirms the deploy or 'fm-gex-drift.sh clear $repo' records the verified rollout."
    ;;
  clear)
    shift
    repo=${1:-}
    [ -n "$repo" ] || { echo "error: clear requires <owner/repo>" >&2; exit 2; }
    if [ -f "$OWED" ] && grep -qF "$TAB$repo$TAB" "$OWED"; then
      grep -vF "$TAB$repo$TAB" "$OWED" > "$OWED.tmp.$$" || true
      mv -f "$OWED.tmp.$$" "$OWED"
      echo "cleared owed rollouts for $repo"
    else
      echo "nothing owed for $repo"
    fi
    ;;
  relevant)
    shift
    dir=${1:-}; from=${2:-}; to=${3:-}
    if [ "$#" -lt 3 ] || [ -z "$dir" ] || [ -z "$from" ] || [ -z "$to" ]; then
      echo "error: relevant requires <repo-dir> <from-sha> <to-sha> <pattern...>" >&2
      exit 2
    fi
    shift 3
    if [ "$#" -eq 0 ]; then
      echo "error: relevant requires at least one path pattern" >&2
      exit 2
    fi
    [ -d "$dir" ] || { echo "error: not a directory: $dir" >&2; exit 2; }
    from_full=$(git -C "$dir" rev-parse --verify --quiet "${from}^{commit}" 2>/dev/null) \
      || { echo "error: from sha unknown to repo $dir: $from" >&2; exit 2; }
    to_full=$(git -C "$dir" rev-parse --verify --quiet "${to}^{commit}" 2>/dev/null) \
      || { echo "error: to sha unknown to repo $dir: $to" >&2; exit 2; }
    # shellcheck disable=SC2086 # patterns arrive as separate words on purpose
    if ! matches=$(window_matches "$dir" "$from_full" "$to_full" "$@"); then
      echo "error: window diff failed in $dir" >&2
      exit 2
    fi
    if [ -n "$matches" ]; then
      printf 'relevant %s..%s:\n' "$from" "$to"
      printf '%s\n' "$matches"
      exit 0
    fi
    printf 'irrelevant %s..%s: no path matching the given patterns changed\n' "$from" "$to"
    exit 1
    ;;
  arm)
    if [ ! -f "$SERVICES" ]; then
      echo "error: kein Inventar unter $SERVICES - unpruefbar; deposit it first (see --help)" >&2
      exit 1
    fi
    if [ "$(active_line_count)" -eq 0 ]; then
      echo "error: inventory at $SERVICES has no active service lines - refusing to arm an unpruefbar guard" >&2
      exit 1
    fi
    if ! validate_inventory; then
      exit 1
    fi
    mkdir -p "$STATE"
    services_sha > "$ARMED"
    tmp="$CHECK_SHIM.tmp.$$"
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf '%s\n' '# Auto-generated by fm-gex-drift.sh - deployed-state drift poll shim.'
      printf 'export FM_HOME=%q\n' "$FM_HOME"
      printf 'exec %q check\n' "$SCRIPT_DIR/fm-gex-drift.sh"
    } > "$tmp"
    chmod 0700 "$tmp"
    mv -f "$tmp" "$CHECK_SHIM"
    if ! FM_HOME="$FM_HOME" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
      rm -f "$CHECK_SHIM" "$ARMED"
      echo "error: could not register $CHECK_SHIM" >&2
      exit 1
    fi
    echo "armed: state/$CHECK_ID.check.sh ($(active_line_count) service line(s))"
    ;;
  disarm)
    rm -f "$CHECK_SHIM" "$CHECK_TRUST" "$ARMED" "$SEEN"
    echo "disarmed: state/$CHECK_ID.check.sh"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
