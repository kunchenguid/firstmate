#!/usr/bin/env bash
# Real publication capture for done-done. Requires FM_PROOF_FORK=<Firstmate checkout>.
# Scratch is isolated and retained; no server, model, live board, or deletion here.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
fork=${FM_PROOF_FORK:?set FM_PROOF_FORK to a Firstmate checkout}
head=$(git -C "$repo" rev-parse HEAD)
work=$(mktemp -d /var/tmp/owner-rules-live.XXXXXX)
export HOME=$work/user XDG_DATA_HOME=$work/data XDG_CONFIG_HOME=$work/config XDG_CACHE_HOME=$work/cache
export TMPDIR=$work/tmp SIGN_OFF_HOME=$work/board FM_HOME=$work/home FM_ADDONS_DIR=$repo
mkdir -p "$HOME" "$TMPDIR" "$SIGN_OFF_HOME" "$FM_HOME/config" "$work/parent/state" "$FM_HOME/data/umer/.done-done/runs"
printf 'umer\n' > "$FM_HOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$work/parent" > "$FM_HOME/.fm-secondmate-parent"
bash "$repo/owner-rules/install.sh" "$FM_HOME" >/dev/null
board=$SIGN_OFF_HOME/decisions.json
printf '{"schema":2,"items":[]}\n' > "$board"
cp "$board" "$work/before.json"
# Fixture prerequisite for merge-card's screen-free path, confined to this private board.
jq -n --arg c "$head" '{schema:1,run_id:"fixture-only",commit:$c,dirty:false,exit:0,files:[{path:"proof.log"}]}' > "$FM_HOME/data/umer/.done-done/runs/run.json"
printf 'screen: none\n' > "$FM_HOME/data/umer/checks.md"
record() { # expected exit, description, actual command...
  local expected=$1 label=$2 out rc=0; shift 2
  printf '\n%s\n$ ' "$label"
  printf '%q ' "$@"; printf '\n'
  out=$("$@" 2>&1) || rc=$?
  printf '%s\nexit=%s (expected %s)\n' "$out" "$rc" "$expected"
  [ "$rc" -eq "$expected" ]
  if [ "$expected" -ne 0 ]; then [[ $out == *'use the sign-off board (sign-off-axi) instead'* ]]; fi
}
post() {
  jq -n --arg claim "$1" '{verdict:"pass",check:{claim:$claim,evidence:["proof.log"]}}' > "$FM_HOME/data/umer/merge-card.json"
  record "$2" "$3" "$repo/merge-card/merge-card" post --board "$board" umer - "$head" -
}
{
  printf 'Candidate commit: %s\n' "$head"
  printf 'sign-off-axi version: '; sign-off-axi --version
  record 2 'A secondmate Lavish link is refused before append.' bash "$fork/bin/fm-secondmate-report.sh" 'done' abcdef0123456789 'http://review.example:4387/session/umer'
  [ ! -e "$work/parent/state/umer.status" ]
  echo 'Refused secondmate note wrote no status file.'
  record 0 'A secondmate sign-off link is accepted.' bash "$fork/bin/fm-secondmate-report.sh" 'done' abcdef0123456789 'http://review.example:4388/board/umer'
  cat "$work/parent/state/umer.status"
  grep -qF 'http://review.example:4388/board/umer' "$work/parent/state/umer.status"
  post 'See http://review.example:4387/session/umer' 1 'A merge-card Lavish link is refused before posting.'
  post 'Review with lavish-axi' 1 'A merge-card CLI mention is refused before posting.'
  cmp "$board" "$work/before.json"
  echo 'Refused merge-card posts left the private board byte-for-byte unchanged.'
  post 'See http://review.example:4388/board/umer' 0 'A merge-card sign-off link is posted.'
  sign-off-axi list "$board" --json --full > "$work/posted.json"
  cat "$work/posted.json"
  jq -e '.decisions | length == 1 and .[0].evidence.outcome == "See http://review.example:4388/board/umer"' "$work/posted.json"
  echo 'The real sign-off writer holds exactly one clean card.'
} > "$evidence/publication.txt" 2>&1
cat "$evidence/publication.txt"
jq -n --arg version "$head" '{target:{version:$version},start:"An isolated secondmate home has owner-rules enabled and a private empty sign-off board.",steps:["Send a Lavish link through the real secondmate report helper and inspect the refusal and absent status file.","Send a sign-off link through that helper and read the appended status.","Post a Lavish link and a CLI mention through merge-card and compare the unchanged board.","Post a clean sign-off link through merge-card and inspect the single card with sign-off-axi list."],result:"Secondmate notes and merge-card posts refuse Lavish content and point to the sign-off board; clean sign-off links pass both real publishing commands."}' > "$evidence/steps.json"
