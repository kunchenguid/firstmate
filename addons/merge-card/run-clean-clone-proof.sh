#!/usr/bin/env bash
# Post a merge card with the real merge-card and sign-off-axi against a real throwaway git clone,
# with done-done's post opt-in emulated by a stub, and show the clone stays clean.
set -euo pipefail

: "${DONE_DONE_EVIDENCE_ROOT:?done-done must provide its run evidence folder}"
command -v sign-off-axi >/dev/null || { echo 'sign-off-axi is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
w=$DONE_DONE_EVIDENCE_ROOT/clean-clone
rm -rf -- "$w"
mkdir -p "$w/bin" "$w/home/data/demo" "$w/home/config"
git init -q "$w/clone" && git -C "$w/clone" -c user.name=Umer -c user.email=umer@example.com commit -q --allow-empty -m init
head=$(git -C "$w/clone" rev-parse HEAD)
python3 -I - "$w/home/data/demo/shot.png" <<'PY'
import struct, sys, zlib
w, h = 320, 200
rows = b"".join(b"\x00" + bytes((x * 255 // w, y * 255 // h, (x ^ y) & 255)[i % 3] for x in range(w) for i in range(3)) for y in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
PY
printf '## Checks\n\noutcome: A merge leaves the project clone clean\nrepro: n/a\nproof: no verify skill\nevidence: shot.png\n' >"$w/home/data/demo/checks.md"
# done-done stub: passes the check; `signoff` files into --board, else the nearest .sign-off/ board (the post opt-in).
cat >"$w/bin/done-done" <<'STUB'
#!/usr/bin/env bash
case $1 in
  --version) echo 0.6.7 ;;
  check)
    [ "${2:-}" = --help ] && { echo '--citation-base'; exit 0; }
    jq -n --arg e "$FM_HOME/data/demo/shot.png" '{claim: "A merge leaves the project clone clean", evidence: [$e]}' ;;
  signoff)
    b=$PWD/.sign-off/decisions.json
    while [ $# -gt 0 ]; do [ "$1" = --board ] && b=$2; shift; done
    mkdir -p "${b%/*}"
    cp "$FM_HOME/data/demo/shot.png" "${b%/*}/shot.png"
    printf '{"contract":1,"kind":"evidence","schema":1,"key":"dd-evidence-demo","title":"t","about":"a","link":"https://example.com/x","media":["shot.png"]}\n' >"${b%/*}/m.json"
    sign-off-axi post "$b" --kind evidence --from "${b%/*}/m.json" --filer done-done >/dev/null ;;
esac
STUB
# The pool pick merge-card asks for before it starts the judge.
mkdir -p "$w/pool/profile"
cat >"$w/bin/pool-claude" <<'STUB'
#!/usr/bin/env bash
jq -n --arg f "$POOL_FOLDER" '{ok: true, id: "acct1", set: {CLAUDE_CONFIG_DIR: $f}, unset: ["ANTHROPIC_API_KEY"]}'
STUB
printf 'command=%s\nstate=%s\n' "$w/bin/pool-claude" "$w/pool" >"$w/home/config/account-pool"
chmod +x "$w/bin/done-done" "$w/bin/pool-claude"
export POOL_FOLDER=$w/pool/profile
export PATH="$w/bin:$PATH" FM_HOME="$w/home"
out=$(bash "$here/merge-card" post --board "$w/board/decisions.json" demo "$w/clone" "$head" - 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
echo "merge-card post (done-done post opt-in on, the clone is the work copy):"
printf '%s\n' "$out" | sed 's/^/  /'
status=$(git -C "$w/clone" status --porcelain)
echo "git status --porcelain in the clone: [${status}] (empty means clean)"
[ -z "$status" ]
echo "clone entries: $(find "$w/clone" -mindepth 1 -maxdepth 1 -printf "%f ")"
[ ! -e "$w/clone/.sign-off" ]
keys=$(sign-off-axi list "$w/board/decisions.json" --json --full | jq -r '[.decisions[].key] | join(" ")')
echo "cards on the board outside the clone: $keys"
sign-off-axi list "$w/board/decisions.json" --json --full | jq -e '[.decisions[].key] | any(startswith("merge-")) and any(. == "dd-evidence-demo")' >/dev/null
mkdir "$w/clone/.sign-off"
out=$(bash "$here/merge-card" post --board "$w/board/decisions.json" demo "$w/clone" "$head" - 2>&1)
echo "post with a stray .sign-off folder already in the clone:"
printf '%s\n' "$out" | sed 's/^/  /'
[[ "$out" == *'stray board in the work copy'* ]]
echo "stray folder still there: $([ -d "$w/clone/.sign-off" ] && echo yes), entries inside: $(find "$w/clone/.sign-off" -mindepth 1 | wc -l)"
[ -d "$w/clone/.sign-off" ] && [ -z "$(find "$w/clone/.sign-off" -mindepth 1)" ]
jq -n '{target:{version:"merge-card post"},start:"A throwaway git clone is the merge'"'"'s work copy and done-done'"'"'s post opt-in is on.",steps:["Run merge-card post with a board outside the clone.","Check git status of the clone is clean and the cards are on the board.","Leave an empty .sign-off folder in the clone and post again."],result:"The clone stays clean, the merge card and done-done card sit on the board, and the stray folder is reported and left in place."}' >"$DONE_DONE_EVIDENCE_ROOT/steps.json"
printf '%s\n' 'merge-card clean-clone journey passed'
