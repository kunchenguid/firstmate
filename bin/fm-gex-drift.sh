#!/usr/bin/env bash
# fm-gex-drift.sh - deployed-state drift guard for service repos (plan v3 U1.6):
# a merge into a service repo is an intermediate state until the running
# service carries it ("KEIN PUSH OHNE AUSROLLEN" - captain's order 23.08.;
# EN: no push without rollout), and a service running behind its repo is a
# finding, not a footnote (L01; measured three-of-four adrift on 23.08.,
# report data/lensclash-scan-ablauf-messung/report.md section 0).
#
# Usage:
#   fm-gex-drift.sh check    silent when in sync; one line per NEW finding
#   fm-gex-drift.sh report   every service, probe verdict, and owed rollout
#   fm-gex-drift.sh owe <owner/repo> <task-id> <pr-url>
#                            deposit an owed rollout; a repo with no service
#                            line is a silent no-op, so the merge hook may call
#                            this unconditionally and can never fail a merge
#   fm-gex-drift.sh clear <owner/repo>
#                            drop owed rollouts for a repo (verified deploy)
#   fm-gex-drift.sh arm      write + register state/gex-drift.check.sh
#   fm-gex-drift.sh disarm   remove shim, trust binding, and records
#   fm-gex-drift.sh --help
#
# SERVICE INVENTORY (deposit form): config/gex-drift.services - LOCAL,
# gitignored; one service per line, tab-separated:
#
#   <name>\t<owner/repo>\t<repo-dir>\t<art> [args...]
#
# arts, each read-only; probe verdicts: in sync, drifted, or failed - and a
# failed probe is reported as failed, never counted as in sync:
#   image-tag <ssh-host> <container>
#       docker-inspect the running container's image reference over ssh; in
#       sync when the reference carries the repo HEAD's short sha. This asks
#       the target, never memory.
#   cmd <one-line reading command>
#       Extension point: exit 0 = in sync, exit 1 = drifted, else failed.
#
# The inventory is HASH-BOUND at arm time: `arm` records its sha256 in
# state/.gex-drift-armed, and a `check` against an edited inventory refuses to
# probe (loudly, once per edit) until re-armed - an unnoticed edit must not
# silently change what the guard executes. A never-armed home probes directly;
# the binding protects the watcher path.
#
# State (this header is the single owner):
#   state/.gex-drift-armed   sha256 of the armed inventory
#   state/.gex-drift-seen    the finding set of the last report (a finding is
#                            news once, not every poll; changed or returning
#                            findings are news again)
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

usage() { sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
services_sha() { sha256sum "$SERVICES" 2>/dev/null | cut -d' ' -f1; }
repo_head() { git -C "$1" rev-parse --short=7 HEAD 2>/dev/null; }

# probe_service <repo-dir> <art> [args...]
# Prints exactly one verdict line: "insync <head>", "drift <deployed> <head>",
# or "failed <reason>".
probe_service() {
  local dir=$1 art=$2 head deployed rc host container
  shift 2
  head=$(repo_head "$dir") || head=""
  if [ -z "$head" ]; then
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
      deployed=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
        docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null | tr -d '[:space:]')
      if [ -z "$deployed" ]; then
        printf 'failed image-tag probe unreachable or empty (%s %s)\n' "$host" "$container"
        return 0
      fi
      case "$deployed" in
        *"$head"*) printf 'insync %s\n' "$head" ;;
        *) printf 'drift %s %s\n' "$deployed" "$head" ;;
      esac
      ;;
    cmd)
      bash -c "$*" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        0) printf 'insync %s\n' "$head" ;;
        1) printf 'drift cmd-verdict %s\n' "$head" ;;
        *) printf 'failed cmd probe rc=%s\n' "$rc" ;;
      esac
      ;;
    *)
      printf 'failed unknown probe art %s\n' "$art"
      ;;
  esac
}

# gather_findings <mode>: prints the CURRENT finding set (sorted, one line
# each) on stdout. In mode "report" additionally prints per-service verdicts to
# stderr. Clears owed rollouts that an in-sync probe just confirmed deployed,
# and reports each such confirmation as a finding once.
gather_findings() {
  local mode=$1 findings="" name repo dir rest verdict deployed head
  if [ -f "$ARMED" ] && [ -f "$SERVICES" ] && [ "$(cat "$ARMED")" != "$(services_sha)" ]; then
    printf 'GEX_DRIFT: inventory %s edited since arm - probes refused until re-armed (bin/fm-gex-drift.sh arm)\n' "$SERVICES"
    return 0
  fi
  if [ -f "$ARMED" ] && [ ! -f "$SERVICES" ]; then
    printf 'GEX_DRIFT: armed inventory %s is missing - probes refused until re-armed or disarmed\n' "$SERVICES"
    return 0
  fi
  if [ -f "$SERVICES" ]; then
    while IFS="$TAB" read -r name repo dir rest; do
      case "$name" in ''|'#'*) continue ;; esac
      # shellcheck disable=SC2086 # rest is the probe art plus its args, split on purpose
      verdict=$(probe_service "$dir" $rest)
      [ "$mode" = report ] && printf '%s (%s): %s\n' "$name" "$repo" "$verdict" >&2
      case "$verdict" in
        insync*)
          if [ -f "$OWED" ] && grep -qF "$TAB$repo$TAB" "$OWED"; then
            while IFS="$TAB" read -r _ orepo otask opr; do
              [ "$orepo" = "$repo" ] || continue
              findings="${findings}GEX_DRIFT: rollout CONFIRMED for $repo (service $name in sync at $(repo_head "$dir")) - owed entry cleared (task $otask, $opr)
"
            done < "$OWED"
            grep -vF "$TAB$repo$TAB" "$OWED" > "$OWED.tmp.$$" || true
            mv -f "$OWED.tmp.$$" "$OWED"
          fi
          ;;
        drift*)
          deployed=$(printf '%s' "$verdict" | cut -d' ' -f2)
          head=$(printf '%s' "$verdict" | cut -d' ' -f3)
          findings="${findings}GEX_DRIFT: $name ($repo) runs $deployed, repo is at $head - rollout owed or unexplained drift
"
          ;;
        failed*)
          findings="${findings}GEX_DRIFT: probe FAILED for $name ($repo): ${verdict#failed } - drift unknown, never assumed in sync
"
          ;;
      esac
    done < "$SERVICES"
  fi
  if [ -f "$OWED" ]; then
    while IFS="$TAB" read -r owhen orepo otask opr; do
      [ -n "$orepo" ] || continue
      findings="${findings}GEX_DRIFT: rollout owed for $orepo since $owhen (task $otask, $opr) - the merge is not done until the service carries it
"
    done < "$OWED"
  fi
  printf '%s' "$findings" | sort -u
}

cmd="${1:-check}"
case "$cmd" in
  check)
    mkdir -p "$STATE"
    current=$(gather_findings check)
    news=$(comm -13 <(sort -u "$SEEN" 2>/dev/null) <(printf '%s\n' "$current" | sed '/^$/d'))
    printf '%s\n' "$current" | sed '/^$/d' > "$SEEN"
    [ -n "$news" ] && printf '%s\n' "$news"
    exit 0
    ;;
  report)
    current=$(gather_findings report)
    if [ -n "$current" ]; then printf '%s\n' "$current"; else echo "(all services in sync; nothing owed)"; fi
    ;;
  owe)
    shift
    repo=${1:-}; task=${2:-}; pr=${3:-}
    if [ -z "$repo" ] || [ -z "$task" ] || [ -z "$pr" ]; then
      echo "error: owe requires <owner/repo> <task-id> <pr-url>" >&2
      exit 2
    fi
    if [ ! -f "$SERVICES" ] || ! cut -f2 "$SERVICES" | grep -qx "$repo"; then
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
  arm)
    if [ ! -f "$SERVICES" ]; then
      echo "error: no service inventory at $SERVICES - deposit it first (see --help)" >&2
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
    echo "armed: state/$CHECK_ID.check.sh ($(wc -l < "$SERVICES" | tr -d ' ') inventory line(s))"
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
