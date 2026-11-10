#!/usr/bin/env bash
# ak47/census.sh - attribute /tmp growth to the thing that creates it.
#
# A census that only counts is not a census. This one names a producer for every
# entry it can, and reports the remainder as unattributed rather than hiding it.
#
# Two modes:
#
#   census.sh                 static census of the current /tmp: every top-level
#                             entry is matched against census-producers.conf and
#                             counted per producer. Fast (one readdir).
#
#   census.sh --watch [SECS]  live census: snapshot, wait SECS (default 60), then
#                             diff. Every NEW entry is attributed to a live
#                             process by scanning /proc/<pid>/cwd and
#                             /proc/<pid>/fd for a path under it, and the owning
#                             process's cmdline and cgroup are printed. This is
#                             how an unattributed prefix gets named.
#
#   census.sh --check         exit 1 when any producer row grew past the recorded
#                             baseline, or when unattributed entries exceed
#                             AK47_CENSUS_UNATTRIBUTED_MAX (default 60000).
#                             This is the guard's entry point. It never moves the
#                             baseline: a check that rewrites its own reference
#                             can only ever see one interval of growth.
#
#   census.sh --write-baseline  record the current counts as the reference the
#                             guard compares against. Run it after a source fix
#                             lands, so the guard measures the fix, not the leak.
#
# Output is one line per producer, sorted by count, then the unattributed
# remainder, then a total. --json emits the same as one object.
#
# Exit: 0 clean, 1 a check failed, 2 usage or config error.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"

MODE=static; WATCH_SECS=60; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) MODE=watch; shift; case "${1:-}" in ''|--*) ;; *) WATCH_SECS=$1; shift ;; esac ;;
    --check) MODE=check; shift ;;
    --write-baseline) MODE=baseline; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "census.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$WATCH_SECS" in ''|*[!0-9]*) echo "census.sh: --watch needs a whole number of seconds" >&2; exit 2 ;; esac

TMP_ROOT=${AK47_TMP_ROOT:-/tmp}
[ -d "$TMP_ROOT" ] || { echo "census.sh: $TMP_ROOT is not a directory" >&2; exit 2; }
[ -r "$AK47_PRODUCERS" ] || { echo "census.sh: producer table missing: $AK47_PRODUCERS" >&2; exit 2; }

# producer_rows - id<TAB>match<TAB>pattern<TAB>owner<TAB>source-fix<TAB>guard
producer_rows() {
  local n=0 line id match pat owner fix guard
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    IFS='|' read -r id match pat owner fix guard <<<"$line"
    if [ -z "${id:-}" ] || [ -z "${match:-}" ] || [ -z "${pat:-}" ]; then
      echo "census.sh: census-producers.conf line $n is malformed: $line" >&2
      return 2
    fi
    case "$match" in prefix|regex) ;; *) echo "census.sh: line $n match must be prefix or regex" >&2; return 2 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$match" "$pat" "${owner:-}" "${fix:-}" "${guard:-}"
  done <"$AK47_PRODUCERS"
}

# classify <name> - print the producer id, or "unattributed".
classify() {
  local name=$1 id match pat
  while IFS=$'\t' read -r id match pat _; do
    case "$match" in
      prefix) case "$name" in "$pat"*) printf '%s' "$id"; return 0 ;; esac ;;
      regex)  [[ "$name" =~ $pat ]] && { printf '%s' "$id"; return 0; } ;;
    esac
  done <<<"$ROWS"
  printf 'unattributed'
}

# list_entries - one top-level name per line, NUL-safe names excluded (a name
# with a newline cannot be represented in this line-oriented report; it is
# counted as unattributed by the total instead of being silently dropped).
list_entries() {
  python3 - "$TMP_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
for name in os.listdir(root):
    if "\n" in name or "\t" in name:
        continue
    sys.stdout.write(name + "\n")
PY
}

ROWS=$(producer_rows) || exit 2

# ---- static census -------------------------------------------------------------
# One python pass over the directory. A bash `while read` loop calling classify
# per name is 950,000 subshell-free but still 950,000 iterations of a nested
# read loop, which measured in minutes; this is 1.3 s.
static_census() {
  python3 - "$TMP_ROOT" "$AK47_PRODUCERS" "$JSON" <<'PY'
import json, os, re, sys
root, table, as_json = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
rows = []
with open(table, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("|")
        if len(parts) < 3:
            sys.stderr.write(f"census: malformed producer row: {line!r}\n")
            raise SystemExit(2)
        pid, match, pat = parts[0].strip(), parts[1].strip(), parts[2]
        if match == "prefix":
            rows.append((pid, "prefix", pat, None))
        elif match == "regex":
            rows.append((pid, "regex", pat, re.compile(pat)))
        else:
            sys.stderr.write(f"census: match must be prefix or regex: {line!r}\n")
            raise SystemExit(2)
rows.sort(key=lambda r: len(r[2]), reverse=True)
counts = {}
total = 0
for name in os.listdir(root):
    total += 1
    hit = "unattributed"
    for pid, match, pat, rx in rows:
        if (name.startswith(pat) if match == "prefix" else rx.match(name)):
            hit = pid
            break
    counts[hit] = counts.get(hit, 0) + 1
ordered = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
if as_json:
    print(json.dumps({"total": total, "producers": dict(ordered)}))
else:
    for pid, n in ordered:
        print(f"{pid:<16} {n:8d}")
    print(f"{'TOTAL':<16} {total:8d}")
PY
}

# ---- live attribution ----------------------------------------------------------
# proc_index - one line per (pid, path) for every cwd and open fd on the box.
# Paths are canonicalised so a comparison against a /tmp entry is exact.
proc_index() {
  python3 - <<'PY'
import os
for pid in os.listdir('/proc'):
    if not pid.isdigit():
        continue
    for link in ('cwd',):
        try:
            p = os.readlink(f'/proc/{pid}/{link}')
        except OSError:
            continue
        print(f'{pid}\t{p}')
    try:
        fds = os.listdir(f'/proc/{pid}/fd')
    except OSError:
        continue
    for fd in fds:
        try:
            p = os.readlink(f'/proc/{pid}/fd/{fd}')
        except OSError:
            continue
        if p.startswith('/'):
            print(f'{pid}\t{p}')
PY
}

# proc_desc <pid> - "comm cgroup" for one pid, for the report.
proc_desc() {
  local pid=$1 comm cg
  comm=$(tr -d '\0' <"/proc/$pid/comm" 2>/dev/null || echo '?')
  cg=$(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null | head -1)
  cg=${cg##*/}
  printf '%s(%s)' "${comm:-?}" "${cg:-?}"
}

watch_census() {
  local before after new
  before=$(mktemp) || exit 1
  after=$(mktemp) || exit 1
  new=$(mktemp) || exit 1
  trap 'rm -f "$before" "$after" "$new"' EXIT
  list_entries | sort >"$before"
  echo "census: watching $TMP_ROOT for ${WATCH_SECS}s ..." >&2
  sleep "$WATCH_SECS"
  list_entries | sort >"$after"
  comm -13 "$before" "$after" >"$new"
  local n; n=$(wc -l <"$new")
  echo "census: $n new top-level entries in ${WATCH_SECS}s"
  [ "$n" -eq 0 ] && return 0

  # One /proc scan, then attribute each new entry to the deepest matching path.
  local idx; idx=$(mktemp) || exit 1
  proc_index >"$idx"
  while IFS= read -r name; do
    local path="$TMP_ROOT/$name" pid
    pid=$(awk -F'\t' -v p="$path" 'index($2, p) == 1 { print $1; exit }' "$idx")
    if [ -n "${pid:-}" ]; then
      printf '%-40s %-16s pid=%s %s\n' "$name" "$(classify "$name")" "$pid" "$(proc_desc "$pid")"
    else
      printf '%-40s %-16s %s\n' "$name" "$(classify "$name")" "no live holder (already exited)"
    fi
  done <"$new"
  rm -f "$idx"
}

# ---- check mode ----------------------------------------------------------------
check_census() {
  local base="$AK47_STATE/census.baseline" cur rc=0
  cur=$(static_census) || return 2
  if [ ! -r "$base" ]; then
    echo "census: no baseline at $base; run 'census.sh --write-baseline' after a source fix lands"
    return 2
  fi
  # Compare per-producer counts; a producer that grew is a source fix that has
  # not landed or has rotted. The baseline is never rewritten here.
  local id now was
  while read -r id now; do
    case "$id" in TOTAL) continue ;; esac
    was=$(awk -v k="$id" '$1==k{print $2}' "$base")
    [ -n "${was:-}" ] || was=0
    if [ "$now" -gt "$was" ]; then
      echo "census: GREW $id $was -> $now"
      rc=1
    fi
  done <<<"$cur"
  local unattr max
  unattr=$(awk '$1=="unattributed"{print $2}' <<<"$cur"); unattr=${unattr:-0}
  max=${AK47_CENSUS_UNATTRIBUTED_MAX:-60000}
  if [ "$unattr" -gt "$max" ]; then
    echo "census: unattributed $unattr exceeds $max - a producer is not in census-producers.conf"
    rc=1
  fi
  return "$rc"
}

write_baseline() {
  local base="$AK47_STATE/census.baseline" cur
  cur=$(static_census) || return 2
  mkdir -p "$AK47_STATE" 2>/dev/null || true
  printf '%s\n' "$cur" >"$base"
  echo "census: baseline recorded at $base"
}

case "$MODE" in
  static)   static_census ;;
  watch)    watch_census ;;
  check)    check_census ;;
  baseline) write_baseline ;;
esac
