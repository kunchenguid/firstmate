#!/usr/bin/env bash
# fm-lens-lib.sh - the council's shared foreign-lens chain:
#   FM_LENS_CMD (custom) > Fugu > codex > none - degrades loudly, never silently.
# Consumed by fm-verify.sh (Quarterdeck, model fugu) and fm-intake.sh (Wardroom,
# model fugu-ultra). Source this; do not execute.
#
# fm_lens_run <payload-file> <review-out-file> <lens-prompt> <fugu-model> <workdir> <label>
#   Writes the review file, prints the lens used (custom|fugu|codex|none) on
#   stdout, warns on stderr when degrading to none. Never returns non-zero.
#   An operator-supplied FM_LENS_CMD that fails degrades straight to none by
#   design - an explicit override is not silently second-guessed.

fm_lens_run() {
  local payload=$1 review=$2 prompt=$3 model=$4 workdir=$5 label=$6 lens=none
  if [ -n "${FM_LENS_CMD:-}" ]; then
    if sh -c "$FM_LENS_CMD" < "$payload" > "$review" 2>/dev/null && [ -s "$review" ]; then
      lens=custom
    fi
  elif _fm_lens_fugu "$payload" "$review" "$prompt" "$model" 2>/dev/null; then
    lens=fugu
  elif _fm_lens_codex "$payload" "$review" "$prompt" "$workdir"; then
    lens=codex
  fi
  if [ "$lens" = none ]; then
    printf 'no foreign lens available (FUGU_API_KEY unset or failed; codex not on PATH)\n' > "$review"
    echo "warning: foreign lens degraded to none for $label" >&2
  fi
  printf '%s\n' "$lens"
}

_fm_lens_fugu() {  # <payload> <review> <prompt> <model>
  [ -n "${FUGU_API_KEY:-}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$3" "$4" <<'PY' > "$2" && [ -s "$2" ]
import json, os, sys, urllib.request
payload = open(sys.argv[1], errors="replace").read()
body = json.dumps({"model": sys.argv[3], "messages": [
    {"role": "system", "content": sys.argv[2]},
    {"role": "user", "content": payload}]}).encode()
req = urllib.request.Request(
    "https://api.sakana.ai/v1/chat/completions", data=body,
    headers={"Authorization": "Bearer " + os.environ["FUGU_API_KEY"],
             "Content-Type": "application/json"})
resp = json.load(urllib.request.urlopen(req, timeout=180))
content = resp["choices"][0]["message"]["content"]
if not content.strip():
    raise SystemExit("empty lens review")
print(content)
PY
}

_fm_lens_codex() {  # <payload> <review> <prompt> <workdir>
  command -v codex >/dev/null 2>&1 || return 1
  codex exec --cd "$4" \
    "$3 The material under review is in $1 (read it; the checkout around you is context)." \
    > "$2" 2>/dev/null && [ -s "$2" ]
}
