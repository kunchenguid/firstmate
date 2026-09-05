#!/usr/bin/env bash
# Provision the FM_HOME selected by the fixed remote entrypoint.
#
# Usage:
#   fm-remote-home-provision.sh < manifest
#
# Manifest schema fm-remote-home-provision.v1 carries a base64 charter, the
# base64 parent SSH alias, and one base64 project record per line. Each project
# record's origin is the URL the parent resolved and named, so this host clones
# from it and re-validates it through bin/fm-project-origin-lib.sh instead of
# trusting the sender. A registry line marked +external-contract must arrive with
# that project's complete private contract in the same record; this host publishes
# the contract before the registry row that marks it and refuses the whole
# provisioning otherwise, so a home never holds the marker alone. Every contract a
# manifest publishes or clears is snapshotted into the same before/ set that owns
# data/projects.md, so a failed converge of an existing home restores both halves
# together instead of stranding one. Because data/projects.md is rebuilt from the
# manifest alone, a converge that drops a project clears that project's contract
# too: never a marker without its contract, never a contract without its marker. The remote code root is cloned into an absent home,
# project origins are cloned on this host, the project registry and charter are
# published, the durable .fm-secondmate-parent record names this home's route to its parent as
# "remote" - read by bin/fm-teardown.sh's cleanup gate so a delegated public
# reply promise, which the subsystem can only carry on the parent's own
# filesystem, is never mistaken for one this child could hold - and the
# .fm-secondmate-home marker commits the complete seed last.
# A newly created home is removed on failure. An existing matching seeded home
# is converged only through guarded ordinary-file updates and new project clones.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_MANIFEST_BYTES=1048576

# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

base64_decode_to() {
  if printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null; then return 0; fi
  if printf '%s' "$1" | base64 -D > "$2" 2>/dev/null; then return 0; fi
  return 1
}

manifest_value() { # <file> <key>
  local count
  count=$(grep -c "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$2=" "$1" | cut -d= -f2-
}

safe_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-provision.XXXXXX") || die "cannot create provisioning state"
CREATED_HOME=0
CREATED_BACKLOG=0
EXISTING_HOME=0
PUBLISHED=0
PROVISION_LOCK=
PROVISION_LOCK_HELD=0
CREATED_PROJECTS="$TMP/created-projects"
: > "$CREATED_PROJECTS"
TOUCHED_CONTRACTS="$TMP/touched-contracts"
: > "$TOUCHED_CONTRACTS"
release_provision_lock() {
  if [ "$PROVISION_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$PROVISION_LOCK"
    PROVISION_LOCK_HELD=0
  fi
}
restore_owned_file() { # <relative-path>
  local rel=$1 dest="$FM_HOME/$1" backup="$TMP/before/$1"
  if [ -f "$backup.present" ]; then
    mkdir -p "$(dirname "$dest")" || return 1
    cp -p -- "$backup" "$dest.tmp.rollback.$$" || return 1
    mv -f -- "$dest.tmp.rollback.$$" "$dest"
  else
    rm -f -- "$dest"
  fi
}
rollback() {
  local status=$? project
  if [ "$status" -ne 0 ] && [ "$PUBLISHED" -eq 0 ]; then
    if [ "$CREATED_HOME" -eq 1 ]; then
      rm -rf -- "$FM_HOME"
    elif [ "$EXISTING_HOME" -eq 1 ]; then
      while IFS= read -r project; do
        [ -n "$project" ] && rm -rf -- "$FM_HOME/projects/$project"
      done < "$CREATED_PROJECTS"
      restore_owned_file data/charter.md || true
      restore_owned_file data/projects.md || true
      restore_owned_file .fm-secondmate-home || true
      restore_owned_file .fm-secondmate-parent || true
      while IFS= read -r project; do
        [ -n "$project" ] || continue
        restore_owned_file "data/project-contracts/$project.md" || true
      done < "$TOUCHED_CONTRACTS"
      rmdir -- "$FM_HOME/data/project-contracts" 2>/dev/null || true
      [ "$CREATED_BACKLOG" -eq 0 ] || rm -f -- "$FM_HOME/data/backlog.md"
    fi
  fi
  release_provision_lock
  rm -rf -- "$TMP"
  exit "$status"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
head -c "$((MAX_MANIFEST_BYTES + 1))" > "$TMP/manifest" || die "cannot read provisioning manifest"
MANIFEST_BYTES=$(LC_ALL=C wc -c < "$TMP/manifest" | tr -d ' ')
[ "$MANIFEST_BYTES" -le "$MAX_MANIFEST_BYTES" ] || die "provisioning manifest exceeds its byte bound"
SCHEMA=$(manifest_value "$TMP/manifest" schema || true)
[ "$SCHEMA" = fm-remote-home-provision.v1 ] || die "incompatible provisioning manifest"
ID_B64=$(manifest_value "$TMP/manifest" id_b64 || true)
CHARTER_B64=$(manifest_value "$TMP/manifest" charter_b64 || true)
# Optional so a manifest sent by a not-yet-updated parent (predating this
# field) still provisions; the durable parent record below simply omits the
# host in that case rather than refusing the whole seed.
PARENT_HOST_B64=$(manifest_value "$TMP/manifest" parent_host_b64 || true)
COUNT=$(manifest_value "$TMP/manifest" project_count || true)
base64_decode_to "$ID_B64" "$TMP/id" || die "manifest id is not valid base64"
base64_decode_to "$CHARTER_B64" "$TMP/charter" || die "manifest charter is not valid base64"
PARENT_HOST=
if [ -n "$PARENT_HOST_B64" ]; then
  base64_decode_to "$PARENT_HOST_B64" "$TMP/parent-host" || die "manifest parent host is not valid base64"
  PARENT_HOST=$(cat "$TMP/parent-host")
fi
ID=$(cat "$TMP/id")
safe_id "$ID" || die "manifest carries an unsafe secondmate id"
case "$COUNT" in ''|*[!0-9]*) die "manifest project count is invalid" ;; esac
[ -s "$TMP/charter" ] || die "manifest charter is empty"
[ -z "$(LC_ALL=C tr -cd '\000' < "$TMP/charter")" ] || die "manifest charter contains NUL bytes"
RECORDS=$(grep -c '^project=' "$TMP/manifest" 2>/dev/null || true)
[ "$RECORDS" -eq "$COUNT" ] || die "manifest project count does not match its records"

HOME_PARENT=$(dirname "$FM_HOME")
HOME_PARENT_REAL=$(CDPATH='' cd -- "$HOME_PARENT" 2>/dev/null && pwd -P) \
  || die "remote home parent is unavailable"
[ "$HOME_PARENT_REAL" = "$HOME_PARENT" ] || die "remote home parent is not canonical"
PROVISION_LOCK_STATE="$HOME_PARENT/.firstmate-provision-locks"
if [ -e "$PROVISION_LOCK_STATE" ] || [ -L "$PROVISION_LOCK_STATE" ]; then
  [ -d "$PROVISION_LOCK_STATE" ] && [ ! -L "$PROVISION_LOCK_STATE" ] \
    || die "remote provisioning lock root is unsafe"
else
  mkdir "$PROVISION_LOCK_STATE" 2>/dev/null || true
  [ -d "$PROVISION_LOCK_STATE" ] && [ ! -L "$PROVISION_LOCK_STATE" ] \
    || die "cannot create remote provisioning lock root"
fi
if command -v shasum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$FM_HOME" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  HOME_LOCK_KEY=$(printf '%s' "$FM_HOME" | sha256sum | awk '{print $1}')
else
  die "no SHA-256 tool is available for provisioning serialization"
fi
FM_STATE_OVERRIDE="$PROVISION_LOCK_STATE"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
PROVISION_LOCK="$STATE/.remote-home-provision-$HOME_LOCK_KEY.lock"
fm_lock_acquire_wait "$PROVISION_LOCK"
PROVISION_LOCK_HELD=1

if [ -e "$FM_HOME" ] || [ -L "$FM_HOME" ]; then
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || die "remote home exists but is not a safe directory"
  [ -f "$FM_HOME/AGENTS.md" ] && [ ! -L "$FM_HOME/AGENTS.md" ] \
    && [ -d "$FM_HOME/bin" ] && [ ! -L "$FM_HOME/bin" ] || die "existing remote home is not a safe Firstmate checkout"
  for operational_dir in data state config projects; do
    operational_path="$FM_HOME/$operational_dir"
    if [ -e "$operational_path" ] || [ -L "$operational_path" ]; then
      [ -d "$operational_path" ] && [ ! -L "$operational_path" ] \
        || die "remote home has unsafe operational directory: $operational_dir"
    fi
  done
  mkdir -p "$TMP/before/data"
  for rel in data/charter.md data/projects.md .fm-secondmate-home .fm-secondmate-parent; do
    existing="$FM_HOME/$rel"
    if [ -e "$existing" ] || [ -L "$existing" ]; then
      [ -f "$existing" ] && [ ! -L "$existing" ] || die "existing remote home has unsafe owned file: $rel"
      mkdir -p "$(dirname "$TMP/before/$rel")"
      cp -p -- "$existing" "$TMP/before/$rel" || die "cannot snapshot existing remote home file: $rel"
      : > "$TMP/before/$rel.present"
    fi
  done
  EXISTING_HOME=1
  if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
    [ "$(cat "$FM_HOME/.fm-secondmate-home")" = "$ID" ] || die "existing remote home belongs to another secondmate"
  elif find "$FM_HOME/data" "$FM_HOME/state" "$FM_HOME/projects" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    die "unmarked existing remote home contains operational data"
  fi
else
  CREATED_HOME=1
  git clone --quiet -- "$FM_ROOT" "$FM_HOME" || die "could not clone the remote Firstmate home"
fi
for operational_dir in data state config projects; do
  operational_path="$FM_HOME/$operational_dir"
  if [ -e "$operational_path" ] || [ -L "$operational_path" ]; then
    [ -d "$operational_path" ] && [ ! -L "$operational_path" ] \
      || die "remote home has unsafe operational directory: $operational_dir"
  else
    mkdir "$operational_path" || die "cannot create remote operational directory: $operational_dir"
  fi
done
if [ -e "$FM_HOME/data/backlog.md" ] || [ -L "$FM_HOME/data/backlog.md" ]; then
  [ -f "$FM_HOME/data/backlog.md" ] && [ ! -L "$FM_HOME/data/backlog.md" ] \
    || die "remote backlog is not a safe regular file"
else
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
  CREATED_BACKLOG=1
fi

PROJECT_REG="$TMP/projects.md"
: > "$PROJECT_REG"
CONTRACT_NAMES="$TMP/contract-names"
: > "$CONTRACT_NAMES"
STALE_CONTRACT_NAMES="$TMP/stale-contract-names"
: > "$STALE_CONTRACT_NAMES"
CONTRACT_DIR="$FM_HOME/data/project-contracts"
MANIFEST_NAMES="$TMP/manifest-names"
: > "$MANIFEST_NAMES"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  encoded=${record#project=}
  old_ifs=$IFS
  IFS='|'
  read -r NAME_B64 ORIGIN_B64 REGISTRY_B64 MODE_B64 CONTRACT_B64 <<EOF
$encoded
EOF
  IFS=$old_ifs
  for field in NAME_B64 ORIGIN_B64 REGISTRY_B64 MODE_B64; do
    eval "value=\${$field}"
    [ -n "$value" ] || die "project manifest record is incomplete"
  done
  base64_decode_to "$NAME_B64" "$TMP/name" || die "project name is not valid base64"
  base64_decode_to "$ORIGIN_B64" "$TMP/origin" || die "project origin is not valid base64"
  base64_decode_to "$REGISTRY_B64" "$TMP/registry" || die "project registry line is not valid base64"
  base64_decode_to "$MODE_B64" "$TMP/mode" || die "project mode is not valid base64"
  NAME=$(cat "$TMP/name")
  ORIGIN=$(cat "$TMP/origin")
  REGISTRY_LINE=$(cat "$TMP/registry")
  MODE=$(cat "$TMP/mode")
  safe_id "$NAME" || die "project name is unsafe: $NAME"
  [ -n "$ORIGIN" ] || die "project $NAME has no origin"
  fm_project_origin_safe "$ORIGIN" || die "project $NAME origin is not an accepted clone URL: $ORIGIN"
  case "$MODE" in no-mistakes|direct-PR) ;; *) die "project $NAME has unsupported remote mode: $MODE" ;; esac
  case "$REGISTRY_LINE" in "- $NAME "*) ;; *) die "project $NAME registry line is malformed" ;; esac
  mkdir -p "$TMP/registry-probe"
  printf '%s\n' "$REGISTRY_LINE" > "$TMP/registry-probe/projects.md"
  CONTRACT_PATH=$(FM_DATA_OVERRIDE="$TMP/registry-probe" \
    "$SCRIPT_DIR/fm-project-mode.sh" --external-contract "$NAME") \
    || die "project $NAME registry line cannot be read for its external-contract setting"
  if [ -n "$CONTRACT_PATH" ]; then
    [ -n "$CONTRACT_B64" ] \
      || die "project $NAME is marked +external-contract but the manifest carried no private contract; refusing to publish the marker alone"
    base64_decode_to "$CONTRACT_B64" "$TMP/contract.$NAME" \
      || die "project $NAME private contract is not valid base64"
    [ -s "$TMP/contract.$NAME" ] \
      || die "project $NAME private contract arrived empty; refusing to publish the marker alone"
    printf '%s\n' "$NAME" >> "$CONTRACT_NAMES"
  else
    [ -z "$CONTRACT_B64" ] \
      || die "project $NAME carries a private contract but is not marked +external-contract"
    printf '%s\n' "$NAME" >> "$STALE_CONTRACT_NAMES"
  fi
  DEST="$FM_HOME/projects/$NAME"
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    [ -d "$DEST" ] && [ ! -L "$DEST" ] && [ -d "$DEST/.git" ] \
      || die "project destination exists but is not a safe clone: $DEST"
    EXISTING_ORIGIN=$(git -C "$DEST" remote get-url origin 2>/dev/null || true)
    [ "$EXISTING_ORIGIN" = "$ORIGIN" ] || die "project $NAME origin differs from the requested route"
  else
    printf '%s\n' "$NAME" >> "$CREATED_PROJECTS"
    git clone --quiet -- "$ORIGIN" "$DEST" || die "could not clone project $NAME on the remote host"
    if [ "$MODE" = no-mistakes ]; then
      command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is unavailable for project $NAME"
      (cd "$DEST" && no-mistakes init >/dev/null && no-mistakes doctor >/dev/null) \
        || die "no-mistakes initialization failed for project $NAME"
    fi
  fi
  printf '%s\n' "$NAME" >> "$MANIFEST_NAMES"
  printf '%s\n' "$REGISTRY_LINE" >> "$PROJECT_REG"
done < <(grep '^project=' "$TMP/manifest")

# data/projects.md is rebuilt from the manifest alone, so a project this converge
# drops loses its registry row entirely. Its contract has to go with it: the
# pairing invariant is symmetric, and a contract with no row left to mark it is
# private text stranded on this host past a converge that no longer references
# the project. Enumerated from the directory rather than the manifest, because a
# dropped project is by definition absent from the manifest.
if [ -d "$CONTRACT_DIR" ] && [ ! -L "$CONTRACT_DIR" ]; then
  for contract_file in "$CONTRACT_DIR"/*.md; do
    [ -e "$contract_file" ] || continue
    orphan_project=$(basename -- "$contract_file" .md)
    grep -Fxq -- "$orphan_project" "$MANIFEST_NAMES" 2>/dev/null && continue
    printf '%s\n' "$orphan_project" >> "$STALE_CONTRACT_NAMES"
  done
fi

cp "$TMP/charter" "$FM_HOME/data/charter.md.tmp.$$"
chmod 600 "$FM_HOME/data/charter.md.tmp.$$"
mv -f -- "$FM_HOME/data/charter.md.tmp.$$" "$FM_HOME/data/charter.md"
snapshot_owned_contract() {  # <project>
  local project=$1 rel existing
  rel="data/project-contracts/$project.md"
  existing="$FM_HOME/$rel"
  grep -Fxq -- "$project" "$TOUCHED_CONTRACTS" 2>/dev/null && return 0
  mkdir -p "$TMP/before/data/project-contracts" || die "cannot stage the contract rollback snapshot"
  rm -f -- "$TMP/before/$rel" "$TMP/before/$rel.present"
  if [ -e "$existing" ] || [ -L "$existing" ]; then
    [ -f "$existing" ] && [ ! -L "$existing" ] || die "existing remote home has unsafe owned file: $rel"
    cp -p -- "$existing" "$TMP/before/$rel" || die "cannot snapshot existing remote home file: $rel"
    : > "$TMP/before/$rel.present"
  fi
  printf '%s\n' "$project" >> "$TOUCHED_CONTRACTS"
}
publish_contract() {  # <project> <source>
  local project=$1 source=$2 dest parent_real home_real
  [ ! -L "$CONTRACT_DIR" ] || die "project contract directory is a symlink: $CONTRACT_DIR"
  mkdir -p "$CONTRACT_DIR" || die "cannot create the project contract directory"
  parent_real=$(CDPATH='' cd -- "$CONTRACT_DIR" && pwd -P) || die "project contract directory is unavailable"
  home_real=$(CDPATH='' cd -- "$FM_HOME" && pwd -P) || die "FM_HOME is unavailable"
  [ "$parent_real" = "$home_real/data/project-contracts" ] \
    || die "project contract directory escapes FM_HOME: $CONTRACT_DIR"
  dest="$parent_real/$project.md"
  [ ! -L "$dest" ] || die "project $project contract destination is a symlink"
  if [ -e "$dest" ]; then
    [ -f "$dest" ] || die "project $project contract destination is not a regular file"
  fi
  snapshot_owned_contract "$project"
  cp "$source" "$dest.tmp.$$" || die "cannot stage the private contract for project $project"
  chmod 600 "$dest.tmp.$$"
  mv -f -- "$dest.tmp.$$" "$dest" || die "cannot publish the private contract for project $project"
}
remove_stale_contract() {  # <project>
  local project=$1 dest
  [ ! -L "$CONTRACT_DIR" ] || die "project contract directory is a symlink: $CONTRACT_DIR"
  [ -d "$CONTRACT_DIR" ] || return 0
  dest="$CONTRACT_DIR/$project.md"
  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  [ -f "$dest" ] && [ ! -L "$dest" ] || die "project $project contract destination is not a regular file"
  snapshot_owned_contract "$project"
  rm -f -- "$dest" || die "cannot remove the stale private contract for project $project"
}
while IFS= read -r contract_project; do
  [ -n "$contract_project" ] || continue
  publish_contract "$contract_project" "$TMP/contract.$contract_project"
done < "$CONTRACT_NAMES"
while IFS= read -r contract_project; do
  [ -n "$contract_project" ] || continue
  remove_stale_contract "$contract_project"
done < "$STALE_CONTRACT_NAMES"
cp "$PROJECT_REG" "$FM_HOME/data/projects.md.tmp.$$"
mv -f -- "$FM_HOME/data/projects.md.tmp.$$" "$FM_HOME/data/projects.md"
{
  printf 'schema=fm-secondmate-parent.v1\n'
  printf 'route=remote\n'
  [ -z "$PARENT_HOST" ] || printf 'parent_host=%s\n' "$PARENT_HOST"
} > "$FM_HOME/.fm-secondmate-parent.tmp.$$"
mv -f -- "$FM_HOME/.fm-secondmate-parent.tmp.$$" "$FM_HOME/.fm-secondmate-parent"
printf '%s\n' "$ID" > "$FM_HOME/.fm-secondmate-home.tmp.$$"
mv -f -- "$FM_HOME/.fm-secondmate-home.tmp.$$" "$FM_HOME/.fm-secondmate-home"
PUBLISHED=1
release_provision_lock
trap - EXIT
rm -rf -- "$TMP"
printf 'provisioned: %s projects=%s\n' "$FM_HOME" "$COUNT"
