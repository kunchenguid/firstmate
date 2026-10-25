#!/usr/bin/env bash
# delete-guard watcher check: prints one wake line for the delete-guard.log rows appended since the last sweep whose
# target is a literal path (or a variable the command set to one) outside temp and scratch folders, and nothing
# otherwise. Every other new row is counted, per UTC day, in state/delete-guard.counted for the daily fleet summary:
# a $VAR target with no literal value, a bare . .. * target, a temp or scratch target, a block from an agent working
# in a temp or scratch folder (a lab or probe), and a repeat the guard already woke on (same task, or cwd, within 10
# min). The blocks themselves never change. Usage: check.sh <fm-home>
set -u
LOG="$1/state/delete-guard.log" SEEN="$1/state/.delete-guard.seen" COUNTED="$1/state/delete-guard.counted"
[ -f "$LOG" ] || exit 0
total=$(wc -l < "$LOG")
seen=$(cat "$SEEN" 2>/dev/null || echo 0)
case "$seen" in '' | *[!0-9]*) seen=0 ;; esac
[ "$seen" -le "$total" ] || seen=0
[ "$total" -gt "$seen" ] || exit 0
# shellcheck disable=SC2016 # jq program
rows=$(head -n "$total" "$LOG" | jq -Rnr --argjson seen "$seen" --arg home "$HOME" '
  def ts: (.at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdate catch 0);
  def key: if (.task // "") == "" then .cwd else .task end;
  def tohome: sub("^(\\$HOME|\\$\\{HOME\\})(?=/|$)"; "~");
  def temp: test("^/(tmp|var/tmp|dev/shm)(/|$)|/\\.cache/fm-scratch(/|$)") and (test("(^|/)\\.\\.(/|$)") | not);
  # The absolute path a target names: itself, or the last literal value the command assigns to its variable ($HOME
  # unassigned is the home folder). null for anything else: a bare . .. * or a variable whose value is unknown.
  def path: (.target // "") as $t
    | if ($t | test("^(\\$\\w+|\\$\\{[^}]+\\})(/+(\\.?\\*|\\.)?)?$")) then
        ($t | capture("^\\$\\{?(?<n>\\w+)").n) as $n
        | ([(.command // "") | scan("(?:^|[^\\w$])" + $n + "=(\"[^\"]*\"|\\x27[^\\x27]*\\x27|[^\\s;&|)]*)")] | last) as $a
        | if $a == null then (if $n == "HOME" then "~" else "" end)
          else $a[0] | gsub("^[\"\\x27]|[\"\\x27]$"; "") | tohome | if test("^[~/][\\w~/.@%+=:,-]*$") then . else "" end end
      else $t | tohome end
    | if test("^[~/]") then sub("^~(?=/|$)"; $home) else null end;
  [inputs | fromjson? // {}] as $rows
  | range($seen; $rows | length) as $i | $rows[$i] as $r | ($r | ts) as $at | ($r | key) as $k | ($r | path) as $p
  | if $p != null and ($p | temp | not) and (($r.cwd // "") | temp | not)
      and ([$rows[:$i][] | select(key == $k and ts >= $at - 600)] | length == 0)
    then "W\t\(if ($r.task // "") == "" then "no task" else "task " + $r.task end) (\($r.runtime), home \(if ($r.home // "") == "" then "?" else $r.home end), cwd \($r.cwd), \(($r.at // "?")[11:16])Z) \($p): \(($r.command // "")[:160] | gsub("\\s+"; " "))"
    else "C\t\(($r.at // "unknown")[:10])" end' 2>&1) || { printf 'delete guard check could not read %s: %s\n' "$LOG" "$rows"; exit 0; }
if grep -q '^C' <<<"$rows"; then
  { cat "$COUNTED" 2>/dev/null; awk -F'\t' '$1 == "C" { print $2 "\t1" }' <<<"$rows"; } \
    | awk -F'\t' '{ n[$1] += $2 } END { for (d in n) print d "\t" n[d] }' | sort > "$COUNTED.$$" && mv "$COUNTED.$$" "$COUNTED"
fi
printf '%s\n' "$total" > "$SEEN.$$" && mv "$SEEN.$$" "$SEEN"
wakes=$(grep '^W' <<<"$rows" | cut -f2-)
[ -n "$wakes" ] || exit 0
printf 'delete guard blocked %s recursive delete(s) of a literal path outside temp and scratch folders, see %s; latest: %s\n' \
  "$(wc -l <<<"$wakes")" "$LOG" "$(tail -n 5 <<<"$wakes" | paste -sd ';' -)"
