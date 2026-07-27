#!/usr/bin/env bash

fm_worktree_pool_lookup() {  # <project> <absolute-worktree>
  local project=$1 worktree=$2 json parser result
  FM_WORKTREE_POOL_RESULT=unreadable
  FM_WORKTREE_POOL_STATUS=
  FM_WORKTREE_POOL_HOLDER=
  json=$(cd "$project" 2>/dev/null && treehouse status --json 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    parser=jq
  elif command -v python3 >/dev/null 2>&1; then
    parser=python3
  else
    return 1
  fi
  if [ "$parser" = jq ]; then
    result=$(printf '%s' "$json" | jq -r --arg p "$worktree" '
      [.. | objects
       | select((.path? // .worktree? // .worktree_path? // "") == $p)
       | [(.status? // .state? // ""), (.lease_holder? // .leaseHolder? // .holder? // "")]]
      | if length == 1 then .[0] | @tsv elif length == 0 then "absent\t" else error("ambiguous") end
    ' 2>/dev/null) || return 1
  else
    result=$(printf '%s' "$json" | python3 -c '
import json, sys
p = sys.argv[1]
found = []
def walk(v):
    if isinstance(v, dict):
        path = v.get("path", v.get("worktree", v.get("worktree_path", "")))
        if path == p:
            found.append((v.get("status", v.get("state", "")),
                          v.get("lease_holder", v.get("leaseHolder", v.get("holder", "")))))
        for child in v.values():
            walk(child)
    elif isinstance(v, list):
        for child in v:
            walk(child)
walk(json.load(sys.stdin))
if len(found) == 0:
    print("absent\t")
elif len(found) == 1:
    print("%s\t%s" % found[0])
else:
    raise SystemExit(1)
' "$worktree" 2>/dev/null) || return 1
  fi
  FM_WORKTREE_POOL_STATUS=${result%%	*}
  FM_WORKTREE_POOL_HOLDER=${result#*	}
  if [ "$FM_WORKTREE_POOL_STATUS" = absent ]; then
    FM_WORKTREE_POOL_RESULT=absent
  else
    [ -n "$FM_WORKTREE_POOL_STATUS" ] || return 1
    FM_WORKTREE_POOL_RESULT=present
  fi
}

fm_worktree_proven_lease() {  # <project> <absolute-worktree> <expected-holder>
  fm_worktree_pool_lookup "$1" "$2" || return 1
  [ "$FM_WORKTREE_POOL_RESULT" = present ] \
    && [ "$FM_WORKTREE_POOL_STATUS" = leased ] \
    && [ "$FM_WORKTREE_POOL_HOLDER" = "$3" ]
}

fm_worktree_acquire_existing_lease() {  # <absolute-worktree> <holder>
  local worktree=$1 holder=$2
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$worktree" "$holder" <<'PY'
import datetime
import fcntl
import json
import os
import secrets
import sys
import tempfile

worktree = os.path.realpath(sys.argv[1])
holder = sys.argv[2]
pool = os.path.dirname(os.path.dirname(worktree))
state_path = os.path.join(pool, "treehouse-state.json")
lock_path = os.path.join(pool, "treehouse-state.lock")

lock = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
try:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(state_path, "rb") as handle:
        state = json.load(handle)
    matches = [
        entry for entry in state.get("worktrees", [])
        if os.path.realpath(entry.get("path", "")) == worktree
    ]
    if len(matches) != 1:
        raise SystemExit(1)
    entry = matches[0]
    if entry.get("destroying") or entry.get("leased"):
        raise SystemExit(1)
    entry["leased"] = True
    entry["lease_id"] = secrets.token_hex(16)
    entry["lease_holder"] = holder
    entry["leased_at"] = datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat().replace("+00:00", "Z")
    entry.pop("owner_pid", None)
    entry.pop("owner_started_at", None)
    encoded = json.dumps(state, indent=2).encode()
    mode = os.stat(state_path).st_mode & 0o777
    fd, temporary = tempfile.mkstemp(
        prefix="treehouse-state.json.tmp-", dir=pool
    )
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, state_path)
        directory = os.open(pool, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
finally:
    os.close(lock)
PY
}

fm_worktree_content_manifest() {  # <absolute-worktree>
  local worktree=$1 output
  command -v python3 >/dev/null 2>&1 || return 1
  output=$(python3 - "$worktree" <<'PY'
import hashlib, os, subprocess, sys

root = os.path.realpath(sys.argv[1])
plain = subprocess.run(
    ["git", "-C", root, "status", "--porcelain", "--untracked-files=all"],
    check=True, stdout=subprocess.PIPE
).stdout.decode("utf-8", "surrogateescape").splitlines()
raw = subprocess.run(
    ["git", "-C", root, "status", "--porcelain", "-z", "--untracked-files=all"],
    check=True, stdout=subprocess.PIPE
).stdout.split(b"\0")
paths = []
i = 0
while i < len(raw) and raw[i]:
    entry = raw[i]
    paths.append(entry[3:])
    if entry[:2] in (b"R ", b" R", b"C ", b" C"):
        i += 1
    i += 1
body = ["status\t" + line for line in sorted(plain)]
for encoded in sorted(set(paths)):
    path = os.fsdecode(encoded)
    full = os.path.join(root, path)
    if os.path.isfile(full) and not os.path.islink(full):
        with open(full, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        body.append("sha256\t%s\t%s" % (digest, path))
manifest = "\n".join(body)
print(hashlib.sha256(manifest.encode("utf-8", "surrogateescape")).hexdigest())
print(manifest)
PY
) || return 1
  FM_WORKTREE_MANIFEST_DIGEST=${output%%$'\n'*}
  if [ "$output" = "$FM_WORKTREE_MANIFEST_DIGEST" ]; then
    FM_WORKTREE_MANIFEST_BODY=
  else
    FM_WORKTREE_MANIFEST_BODY=${output#*$'\n'}
  fi
}

fm_worktree_adoption_proves() {  # <record> <task> <worktree> <project> <expected-holder>
  local record=$1 task=$2 worktree=$3 project=$4 expected=$5 digest body
  [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] || return 1
  [ "$(grep -c '^task_id=' "$record" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(grep '^task_id=' "$record" | cut -d= -f2-)" = "$task" ] || return 1
  [ "$(grep -c '^worktree=' "$record" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(grep '^worktree=' "$record" | cut -d= -f2-)" = "$worktree" ] || return 1
  [ "$(grep -c '^project=' "$record" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(grep '^project=' "$record" | cut -d= -f2-)" = "$project" ] || return 1
  [ "$(grep -c '^expected_holder=' "$record" 2>/dev/null || true)" = 1 ] || return 1
  [ "$(grep '^expected_holder=' "$record" | cut -d= -f2-)" = "$expected" ] || return 1
  [ "$(grep -c '^manifest_digest=' "$record" 2>/dev/null || true)" = 1 ] || return 1
  digest=$(grep '^manifest_digest=' "$record" | cut -d= -f2-)
  body=$(sed -n '/^manifest_body_begin$/,/^manifest_body_end$/p' "$record" | sed '1d;$d')
  fm_worktree_content_manifest "$worktree" || return 1
  [ "$digest" = "$FM_WORKTREE_MANIFEST_DIGEST" ] \
    && [ "$body" = "$FM_WORKTREE_MANIFEST_BODY" ]
}
