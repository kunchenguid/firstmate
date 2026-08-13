#!/usr/bin/env bash
# Trusted root-side payload for one isolated Azure no-mistakes cell.
#
# Azure Managed Run Command supplies unlock material and optional gate response
# only as protected parameters. This script clears those values before starting
# the credentialed coordinator. Repository commands are not run here: the
# trusted no-mistakes command seam delegates lint/test and requested behavior
# parallelism to identity-less Azure shard VMs through the shard exchange.
set -euo pipefail
set +x
umask 077

[ "$#" -ge 15 ] || { echo "validation guest: incomplete protected parameter set" >&2; exit 125; }
MODE=$1
INPUT_DIGEST=$2
REQUEST_DIGEST=$3
CELL=$4
ATTEMPT=$5
VM_RESOURCE_ID=$6
VM_INSTANCE_ID=$7
WORKTREE_DISK_ID=$8
CREDENTIAL_DISK_ID=$9
STORAGE_ACCOUNT=${10}
STORAGE_CONTAINER=${11}
IDENTITY_CLIENT_ID=${12}
shift 12
INPUT_URL=
OUTPUT_URL=
RESPONSE=
case "$MODE" in
  start)
    [ "$#" -eq 4 ] || { echo "validation guest: start parameter shape mismatch" >&2; exit 125; }
    INPUT_URL=$1
    OUTPUT_URL=$2
    WORKTREE_KEY=$3
    CREDENTIAL_KEY=$4
    ;;
  reattach)
    [ "$#" -eq 3 ] || { echo "validation guest: reattach parameter shape mismatch" >&2; exit 125; }
    OUTPUT_URL=$1
    WORKTREE_KEY=$2
    CREDENTIAL_KEY=$3
    ;;
  respond)
    [ "$#" -eq 4 ] || { echo "validation guest: respond parameter shape mismatch" >&2; exit 125; }
    OUTPUT_URL=$1
    RESPONSE=$2
    WORKTREE_KEY=$3
    CREDENTIAL_KEY=$4
    ;;
  *)
    echo "validation guest: unsupported mode" >&2
    exit 125
    ;;
esac
set --

case "$INPUT_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "validation guest: input digest is malformed" >&2; exit 125 ;; esac
case "$REQUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "validation guest: request digest is malformed" >&2; exit 125 ;; esac
case "$CELL" in azv-[a-z0-9][a-z0-9]*) ;; *) echo "validation guest: cell identity is malformed" >&2; exit 125 ;; esac
case "$ATTEMPT" in ''|*[!0-9]*) echo "validation guest: attempt is malformed" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) if [ "$MODE" != respond ]; then echo "validation guest: output capability is not HTTPS" >&2; exit 125; fi ;; esac
case "$INPUT_URL" in https://*) ;; *) if [ "$MODE" = start ]; then echo "validation guest: input capability is not HTTPS" >&2; exit 125; fi ;; esac
[ -n "$WORKTREE_KEY" ] && [ -n "$CREDENTIAL_KEY" ] || { echo "validation guest: disk unlock material is absent" >&2; exit 125; }

BOOTSTRAP=/var/lib/fm-azure-validation
install -d -m 0700 -o root -g root "$BOOTSTRAP"
WORKTREE_KEY_FILE=$BOOTSTRAP/worktree.key
CREDENTIAL_KEY_FILE=$BOOTSTRAP/credential.key
printf '%s' "$WORKTREE_KEY" >"$WORKTREE_KEY_FILE"
printf '%s' "$CREDENTIAL_KEY" >"$CREDENTIAL_KEY_FILE"
unset WORKTREE_KEY CREDENTIAL_KEY

missing=()
for tool in curl git python3 sha256sum tar systemd-run cryptsetup lsblk findmnt jq mount umount useradd runuser; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    ca-certificates curl git python3 cryptsetup-bin util-linux jq systemd tar passwd
fi
for tool in curl git python3 sha256sum tar systemd-run cryptsetup lsblk findmnt jq mount umount useradd runuser; do
  command -v "$tool" >/dev/null 2>&1 || { echo "validation guest: fixed bootstrap closure is incomplete" >&2; exit 125; }
done

# Azure LUN identity is part of the ARM contract, but the guest also re-reads
# IMDS and rejects a disk swap before opening either encrypted volume.
METADATA=$BOOTSTRAP/metadata.json
curl --fail --silent --show-error --noproxy '*' \
  -H Metadata:true \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01' >"$METADATA"
python3 - "$METADATA" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" "$WORKTREE_DISK_ID" "$CREDENTIAL_DISK_ID" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
compute = value.get("compute", {})
if str(compute.get("resourceId", "")).lower() != sys.argv[2].lower():
    raise SystemExit("validation guest: IMDS VM resource identity mismatch")
if compute.get("vmId") != sys.argv[3]:
    raise SystemExit("validation guest: IMDS immutable VM identity mismatch")
data = compute.get("storageProfile", {}).get("dataDisks", [])
by_lun = {str(item.get("lun")): str(item.get("managedDisk", {}).get("id", "")).lower() for item in data}
if by_lun.get("0") != sys.argv[4].lower() or by_lun.get("1") != sys.argv[5].lower():
    raise SystemExit("validation guest: IMDS data-disk identity mismatch")
PY

# SCSI SKUs publish data disks under scsi1/lunN; NVMe-only SKUs (v6 families)
# publish them under data/by-lun/N via azure-vm-utils. Both are udev identity
# paths; never guess raw namespaces because luksFormat runs on the resolved
# device.
resolve_data_disk() {
  lun="$1"
  deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    for link in "/dev/disk/azure/scsi1/lun$lun" "/dev/disk/azure/data/by-lun/$lun"; do
      candidate=$(readlink -f "$link" 2>/dev/null || true)
      if [ -n "$candidate" ] && [ -b "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
    sleep 2
  done
  echo "validation guest: attached data disk did not appear" >&2
  exit 125
}
WORK_DEVICE=$(resolve_data_disk 0)
CREDENTIAL_DEVICE=$(resolve_data_disk 1)

if cryptsetup isLuks "$WORK_DEVICE"; then
  [ "$MODE" != start ] || { echo "validation guest: new cell found a pre-existing LUKS worktree" >&2; exit 125; }
  WORKTREE_EXISTING=1
else
  [ "$MODE" = start ] || { echo "validation guest: replacement worktree is not LUKS2" >&2; exit 125; }
  cryptsetup luksFormat --type luks2 --batch-mode --key-file "$WORKTREE_KEY_FILE" "$WORK_DEVICE"
  WORKTREE_EXISTING=0
fi
cryptsetup isLuks "$CREDENTIAL_DEVICE" || { echo "validation guest: credential lease disk is not LUKS2" >&2; exit 125; }
cryptsetup open --key-file "$WORKTREE_KEY_FILE" "$WORK_DEVICE" fm-validation-work
cryptsetup open --key-file "$CREDENTIAL_KEY_FILE" "$CREDENTIAL_DEVICE" fm-validation-credentials
shred -u "$WORKTREE_KEY_FILE" "$CREDENTIAL_KEY_FILE" 2>/dev/null || rm -f "$WORKTREE_KEY_FILE" "$CREDENTIAL_KEY_FILE"

WORK_MOUNT=/srv/fm-validation
CREDENTIAL_MOUNT=/run/fm-validation-credentials
install -d -m 0700 -o root -g root "$WORK_MOUNT" "$CREDENTIAL_MOUNT"
if [ "${WORKTREE_EXISTING:-0}" -eq 0 ]; then
  mkfs.ext4 -q -F -L fm-validation-work /dev/mapper/fm-validation-work
fi
mount -o nodev,nosuid /dev/mapper/fm-validation-work "$WORK_MOUNT"
mount -o nodev,nosuid,noexec /dev/mapper/fm-validation-credentials "$CREDENTIAL_MOUNT"
cleanup_mounts() {
  umount "$CREDENTIAL_MOUNT" 2>/dev/null || true
  umount "$WORK_MOUNT" 2>/dev/null || true
  cryptsetup close fm-validation-credentials 2>/dev/null || true
  cryptsetup close fm-validation-work 2>/dev/null || true
}
trap cleanup_mounts EXIT

CELL_ROOT=$WORK_MOUNT/cell
STATE=$CELL_ROOT/state
LOGS=$CELL_ROOT/logs
EVIDENCE=$CELL_ROOT/evidence
SHARD_EXCHANGE=$CELL_ROOT/shards
HOME_DIR=$CELL_ROOT/home
NM_HOME=$CELL_ROOT/no-mistakes
CACHE=$CELL_ROOT/cache
TMP=$CELL_ROOT/tmp
REPO=$CELL_ROOT/repo
install -d -m 0700 -o root -g root "$CELL_ROOT" "$STATE" "$LOGS" "$EVIDENCE" "$SHARD_EXCHANGE"

if [ "$MODE" = start ]; then
  INPUT=$BOOTSTRAP/input.tar.gz
  CURL_CONFIG=$BOOTSTRAP/input.curl
  printf 'url = "%s"\nfail\nsilent\nshow-error\noutput = "%s"\n' "$INPUT_URL" "$INPUT" >"$CURL_CONFIG"
  unset INPUT_URL
  curl --config "$CURL_CONFIG"
  rm -f "$CURL_CONFIG"
  [ "sha256:$(sha256sum "$INPUT" | awk '{print $1}')" = "$INPUT_DIGEST" ] \
    || { echo "validation guest: input archive digest mismatch" >&2; exit 125; }
  EXTRACT=$BOOTSTRAP/input
  rm -rf "$EXTRACT"
  install -d -m 0700 -o root -g root "$EXTRACT"
  python3 - "$INPUT" "$EXTRACT" <<'PY'
import pathlib
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
allowed = {"request.json", "snapshot.bundle", "runtime.tar.gz", "shard-bridge.py"}
with tarfile.open(source, "r:gz") as archive:
    members = archive.getmembers()
    if {member.name for member in members} != allowed:
        raise SystemExit("validation guest: input member set mismatch")
    for member in members:
        if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 1024**3:
            raise SystemExit("validation guest: unsafe input member")
    archive.extractall(destination, members=members)
PY
  REQUEST=$EXTRACT/request.json
  python3 - "$REQUEST" "$REQUEST_DIGEST" "$CELL" "$WORKTREE_DISK_ID" "$CREDENTIAL_DISK_ID" "$EXTRACT/snapshot.bundle" "$EXTRACT/runtime.tar.gz" "$EXTRACT/shard-bridge.py" <<'PY'
import hashlib
import json
import pathlib
import sys

request_path = pathlib.Path(sys.argv[1])
request = json.loads(request_path.read_text(encoding="utf-8"))
unsigned = dict(request)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != sys.argv[2] or supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("validation guest: request digest mismatch")
if request.get("cell") != sys.argv[3]:
    raise SystemExit("validation guest: cell identity mismatch")
bindings = request.get("resource_bindings", {})
if (
    bindings.get("worktree_disk_id", "").lower() != sys.argv[4].lower()
    or bindings.get("credential_disk_id", "").lower() != sys.argv[5].lower()
    or request.get("credential_lease", {}).get("disk", {}).get("id", "").lower() != sys.argv[5].lower()
):
    raise SystemExit("validation guest: worktree/credential disk request mismatch")
def digest(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
if digest(sys.argv[6]) != request["repository"]["snapshot_digest"]:
    raise SystemExit("validation guest: repository bundle digest mismatch")
if digest(sys.argv[7]) != request["runtime_digest"]:
    raise SystemExit("validation guest: runtime bundle digest mismatch")
if digest(sys.argv[8]) != request["protocol"]["shard_bridge_digest"]:
    raise SystemExit("validation guest: shard bridge digest mismatch")
PY
  cp "$REQUEST" "$STATE/request.json"
  chmod 0600 "$STATE/request.json"
  RUNTIME=/opt/fm-azure-validation/runtime
  rm -rf "$RUNTIME"
  install -d -m 0755 -o root -g root "$RUNTIME"
  tar -xzf "$EXTRACT/runtime.tar.gz" -C "$RUNTIME" --no-same-owner --no-same-permissions
  python3 - "$RUNTIME" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest = json.loads((root / "runtime.json").read_text(encoding="utf-8"))
seen = set()
for record in manifest["files"]:
    path = (root / record["path"]).resolve()
    if root not in path.parents or not path.is_file() or path.is_symlink():
        raise SystemExit("validation guest: runtime file is escaping, absent, or linked")
    digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != record["digest"]:
        raise SystemExit("validation guest: runtime file digest mismatch")
    seen.add(path.relative_to(root).as_posix())
actual = {path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and path.name != "runtime.json"}
if actual != seen:
    raise SystemExit("validation guest: runtime inventory mismatch")
PY
  install -m 0755 -o root -g root "$EXTRACT/shard-bridge.py" /opt/fm-azure-validation/shard-bridge.py
  if [ -e "$REPO" ]; then
    echo "validation guest: new cell found an existing repository" >&2
    exit 125
  fi
  git clone --no-local "$EXTRACT/snapshot.bundle" "$REPO" >/dev/null
  BRANCH=$(jq -r '.repository.branch' "$REQUEST")
  HEAD=$(jq -r '.repository.head' "$REQUEST")
  SLUG=$(jq -r '.repository.slug' "$REQUEST")
  git -C "$REPO" checkout -B "$BRANCH" "$HEAD" >/dev/null
  git -C "$REPO" remote set-url origin "https://github.com/$SLUG.git"
  install -d -m 0700 "$HOME_DIR" "$NM_HOME" "$CACHE" "$TMP"
else
  REQUEST=$STATE/request.json
  [ -f "$REQUEST" ] || { echo "validation guest: retained request is absent" >&2; exit 125; }
fi

# Re-prove every durable identity after opening retained state.
python3 - "$REQUEST" "$REQUEST_DIGEST" "$CELL" "$WORKTREE_DISK_ID" "$CREDENTIAL_DISK_ID" <<'PY'
import hashlib
import json
import sys
request = json.load(open(sys.argv[1], encoding="utf-8"))
unsigned = dict(request)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != sys.argv[2] or supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("validation guest: retained request digest mismatch")
bindings = request.get("resource_bindings", {})
if (
    request["cell"] != sys.argv[3]
    or bindings.get("worktree_disk_id", "").lower() != sys.argv[4].lower()
    or bindings.get("credential_disk_id", "").lower() != sys.argv[5].lower()
    or request["credential_lease"]["disk"]["id"].lower() != sys.argv[5].lower()
):
    raise SystemExit("validation guest: retained run/disk identity mismatch")
PY

WORKTREE_LUKS_UUID=$(cryptsetup luksUUID "$WORK_DEVICE")
EXPECTED_LUKS=$(jq -r '.credential_lease.disk.luks_uuid' "$REQUEST")
[ "$(cryptsetup luksUUID "$CREDENTIAL_DEVICE")" = "$EXPECTED_LUKS" ] \
  || { echo "validation guest: credential lease LUKS UUID mismatch" >&2; exit 125; }
PROVIDER_PATH=$(jq -r '.credential_lease.paths.provider_home' "$REQUEST")
ACCOUNT_BINDING_PATH=$(jq -r '.credential_lease.paths.account_binding' "$REQUEST")
GITHUB_TOKEN_PATH=$(jq -r '.credential_lease.paths.github_token' "$REQUEST")
python3 - "$CREDENTIAL_MOUNT" "$PROVIDER_PATH" "$ACCOUNT_BINDING_PATH" "$GITHUB_TOKEN_PATH" "$REQUEST" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve()
provider_relative, account_relative, github_relative = sys.argv[2:5]
request = json.load(open(sys.argv[5], encoding="utf-8"))
paths = []
for relative in (provider_relative, account_relative, github_relative):
    path = (root / relative).resolve()
    if path != root and root not in path.parents:
        raise SystemExit("validation guest: credential lease path escapes disk")
    if not path.exists() or path.is_symlink():
        raise SystemExit("validation guest: credential lease path is absent or linked")
    paths.append(path)
provider, account_binding, github_token = paths
if not provider.is_dir() or not account_binding.is_file() or not github_token.is_file():
    raise SystemExit("validation guest: provider/account/GitHub lease path types are invalid")
expected_account = request["credential_lease"]["provider_account_binding"]
if account_binding.read_text(encoding="utf-8").strip() != expected_account:
    raise SystemExit("validation guest: provider account-binding marker mismatch")

# The content binding covers every regular file under the provider home plus
# the exact GitHub token. Anything else on the credential disk is rejected so
# a lease cannot silently carry a sibling account or unrelated credential.
allowed_files = []
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    current = pathlib.Path(directory)
    names[:] = sorted(name for name in names if not (current == root and name == "lost+found"))
    for name in names:
        child = current / name
        mode = child.lstat().st_mode
        if not stat.S_ISDIR(mode) or child.is_symlink():
            raise SystemExit("validation guest: credential lease contains a linked/non-directory path")
    for name in sorted(files):
        child = current / name
        info = child.lstat()
        if not stat.S_ISREG(info.st_mode) or child.is_symlink() or info.st_nlink != 1:
            raise SystemExit("validation guest: credential lease contains a linked/non-regular file")
        if child == github_token or provider in child.parents:
            allowed_files.append(child)
        else:
            raise SystemExit("validation guest: credential lease contains out-of-scope content")
digest = hashlib.sha256()
for child in sorted(allowed_files):
    relative = child.relative_to(root).as_posix().encode("utf-8")
    content = hashlib.sha256(child.read_bytes()).hexdigest().encode("ascii")
    size = child.stat().st_size
    digest.update(len(relative).to_bytes(4, "big"))
    digest.update(relative)
    digest.update(content)
    digest.update(size.to_bytes(8, "big"))
actual = "sha256:" + digest.hexdigest()
if actual != request["credential_lease"]["disk_content_binding"]:
    raise SystemExit("validation guest: credential disk content binding mismatch")
PY
PROVIDER_HOME=$CREDENTIAL_MOUNT/$PROVIDER_PATH
GITHUB_TOKEN_FILE=$CREDENTIAL_MOUNT/$GITHUB_TOKEN_PATH
[ -f "$GITHUB_TOKEN_FILE" ] || { echo "validation guest: exact GitHub token file is absent" >&2; exit 125; }

if ! id fmvalidate >/dev/null 2>&1; then
  useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin fmvalidate
fi
chown -R fmvalidate:fmvalidate "$CELL_ROOT" "$PROVIDER_HOME"
chown fmvalidate:fmvalidate "$GITHUB_TOKEN_FILE"
chmod 0700 "$CELL_ROOT" "$HOME_DIR" "$NM_HOME" "$CACHE" "$TMP" "$PROVIDER_HOME"
chmod 0600 "$GITHUB_TOKEN_FILE"

RUNTIME=/opt/fm-azure-validation/runtime
NM_BIN=$RUNTIME/$(jq -r '.runtime.no_mistakes_path' "$REQUEST")
PROVIDER_BIN=$RUNTIME/$(jq -r '.runtime.provider_path' "$REQUEST")
GH_BIN=$RUNTIME/$(jq -r '.runtime.gh_path' "$REQUEST")
GH_AXI_BIN=$RUNTIME/$(jq -r '.runtime.gh_axi_path' "$REQUEST")
for executable in "$NM_BIN" "$PROVIDER_BIN" "$GH_BIN" "$GH_AXI_BIN"; do
  [ -x "$executable" ] || { echo "validation guest: exact runtime executable is absent" >&2; exit 125; }
done
PROVIDER=$(jq -r '.credential_lease.provider' "$REQUEST")
ENV_FILE=$STATE/cell.env
{
  printf 'HOME=%s\n' "$HOME_DIR"
  printf 'NO_MISTAKES_HOME=%s\n' "$NM_HOME"
  printf 'XDG_CACHE_HOME=%s\n' "$CACHE"
  printf 'TMPDIR=%s\n' "$TMP"
  printf 'FM_AZURE_VALIDATION_CELL=1\n'
  printf 'FM_AZURE_VALIDATION_CELL_ID=%s\n' "$CELL"
  printf 'FM_AZURE_VALIDATION_SHARD_BRIDGE=/opt/fm-azure-validation/shard-bridge.py\n'
  printf 'FM_AZURE_VALIDATION_SHARD_EXCHANGE=%s\n' "$SHARD_EXCHANGE"
  printf 'FM_AZURE_VALIDATION_SHARD_COUNT=%s\n' "$(jq -r '.limits.behavior_shards' "$REQUEST")"
  printf 'FM_AZURE_VALIDATION_STORAGE_ACCOUNT=%s\n' "$STORAGE_ACCOUNT"
  printf 'FM_AZURE_VALIDATION_STORAGE_CONTAINER=%s\n' "$STORAGE_CONTAINER"
  printf 'FM_AZURE_VALIDATION_IDENTITY_CLIENT_ID=%s\n' "$IDENTITY_CLIENT_ID"
  printf 'GH_TOKEN_FILE=%s\n' "$GITHUB_TOKEN_FILE"
  printf 'FM_AZURE_VALIDATION_RUNTIME_PATH=%s\n' "$(dirname "$NM_BIN"):$(dirname "$PROVIDER_BIN"):$(dirname "$GH_BIN"):$(dirname "$GH_AXI_BIN")"
  case "$PROVIDER" in
    claude) printf 'CLAUDE_CONFIG_DIR=%s\nCLAUDE_SECURESTORAGE_CONFIG_DIR=%s\n' "$PROVIDER_HOME" "$PROVIDER_HOME" ;;
    codex) printf 'CODEX_HOME=%s\n' "$PROVIDER_HOME" ;;
    pi) printf 'PI_CODING_AGENT_DIR=%s\n' "$PROVIDER_HOME" ;;
    opencode) printf 'XDG_CONFIG_HOME=%s\n' "$PROVIDER_HOME" ;;
    grok) printf 'GROK_CONFIG_HOME=%s\n' "$PROVIDER_HOME" ;;
    *) echo "validation guest: provider is not verified" >&2; exit 125 ;;
  esac
} >"$ENV_FILE"
chmod 0600 "$ENV_FILE"

GIT_HELPER=$STATE/git-credential-helper.sh
cat >"$GIT_HELPER" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    printf 'username=x-access-token\\npassword='
    cat '$GITHUB_TOKEN_FILE'
    printf '\\n'
    ;;
  store|erase) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0700 "$GIT_HELPER"
git -C "$REPO" config credential.helper "$GIT_HELPER"
git -C "$REPO" config credential.useHttpPath true

IDENTITY=$STATE/identity.json
CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)
BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)
if [ "$MODE" = start ]; then
  jq -n \
    --arg cell "$CELL" --arg request "$REQUEST_DIGEST" --arg branch "$BRANCH" \
    --arg head "$CURRENT_HEAD" --arg worktree "$WORKTREE_DISK_ID" \
    --arg worktree_luks "$WORKTREE_LUKS_UUID" \
    --arg lease "$(jq -r '.credential_lease.lease_id' "$REQUEST")" \
    '{cell:$cell,request_digest:$request,branch:$branch,current_head:$head,worktree_disk_id:$worktree,worktree_luks_uuid:$worktree_luks,credential_lease_id:$lease,run_id:null}' \
    >"$IDENTITY"
  chmod 0600 "$IDENTITY"
else
  [ -f "$IDENTITY" ] || { echo "validation guest: retained run identity is absent" >&2; exit 125; }
  jq -e --arg cell "$CELL" --arg request "$REQUEST_DIGEST" --arg branch "$BRANCH" \
    --arg head "$CURRENT_HEAD" --arg worktree "$WORKTREE_DISK_ID" \
    --arg worktree_luks "$WORKTREE_LUKS_UUID" \
    '.cell==$cell and .request_digest==$request and .branch==$branch and .current_head==$head and .worktree_disk_id==$worktree and .worktree_luks_uuid==$worktree_luks and (.run_id|type=="string")' \
    "$IDENTITY" >/dev/null || { echo "validation guest: exact retained run identity refused reattach" >&2; exit 125; }
  RUN_ID=$(jq -r '.run_id' "$IDENTITY")
  STATUS_PROOF=$LOGS/reattach-status-a$ATTEMPT.log
  set +e
  # shellcheck disable=SC2016  # Inner shell intentionally expands its positional arguments.
  runuser -u fmvalidate -- /bin/bash -c \
    'set -a; . "$1"; set +a; exec "$2" axi status' \
    validation-reattach "$ENV_FILE" "$NM_BIN" >"$STATUS_PROOF" 2>&1
  STATUS_RC=$?
  set -e
  if [ "$STATUS_RC" -ne 0 ] || ! grep -F "$RUN_ID" "$STATUS_PROOF" >/dev/null; then
    echo "validation guest: no-mistakes database does not prove the exact retained run" >&2
    exit 125
  fi
fi

RUN_LOG=$LOGS/run-a$ATTEMPT.log
RESPONSE_FILE=$STATE/response-a$ATTEMPT.txt
if [ "$MODE" = respond ]; then
  printf '%s' "$RESPONSE" >"$RESPONSE_FILE"
  unset RESPONSE
  chown fmvalidate:fmvalidate "$RESPONSE_FILE"
  chmod 0600 "$RESPONSE_FILE"
fi

# Build an argv-only launcher so protected values never enter the unit, logs, or
# process environment. The unit's cgroup is this cell's only restart boundary.
LAUNCH=$STATE/launch-a$ATTEMPT.sh
cat >"$LAUNCH" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE=$1
REPO=$2
NM_BIN=$3
MODE=$4
INTENT_FILE=$5
RESPONSE_FILE=$6
RUN_LOG=$7
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
export PATH="$FM_AZURE_VALIDATION_RUNTIME_PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GH_TOKEN="$(cat "$GH_TOKEN_FILE")"
cd "$REPO"
set +e
case "$MODE" in
  start) "$NM_BIN" axi run --intent "$(cat "$INTENT_FILE")" >"$RUN_LOG" 2>&1 ;;
  reattach) "$NM_BIN" axi run >"$RUN_LOG" 2>&1 ;;
  respond)
    "$NM_BIN" axi respond <"$RESPONSE_FILE" >>"$RUN_LOG" 2>&1
    response_rc=$?
    if [ "$response_rc" -eq 0 ]; then
      "$NM_BIN" axi run >>"$RUN_LOG" 2>&1
    else
      false
    fi
    ;;
  *) exit 125 ;;
esac
rc=$?
set -e
printf '%s\n' "$rc" >"$RUN_LOG.exit"
exit 0
SH
chmod 0755 "$LAUNCH"
chown fmvalidate:fmvalidate "$RUN_LOG" 2>/dev/null || true
INTENT_FILE=$STATE/intent.txt
jq -r '.intent' "$REQUEST" >"$INTENT_FILE"
chmod 0600 "$INTENT_FILE"
chown fmvalidate:fmvalidate "$INTENT_FILE" "$ENV_FILE" "$IDENTITY" "$LAUNCH"

MEMORY_MAX=$(jq -r '.limits.memory_max_bytes' "$REQUEST")
TASKS_MAX=$(jq -r '.limits.tasks_max' "$REQUEST")
WALL_SECONDS=$(jq -r '.limits.wall_seconds' "$REQUEST")
UNIT=fm-validation-${CELL}-a${ATTEMPT}
START_EPOCH=$(date +%s)
START_LOAD=$(cat /proc/loadavg)
START_MEM_AVAILABLE_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
systemd-run --quiet --wait --collect --unit "$UNIT" \
  --uid=fmvalidate --gid=fmvalidate \
  --property=Type=exec \
  --property=KillMode=control-group \
  --property=CPUQuota=700% \
  --property="MemoryMax=$MEMORY_MAX" \
  --property=MemorySwapMax=0 \
  --property="TasksMax=$TASKS_MAX" \
  --property="RuntimeMaxSec=$((WALL_SECONDS + 600))" \
  --property=NoNewPrivileges=yes \
  --property=PrivateTmp=yes \
  --property=PrivateDevices=yes \
  --property=ProtectSystem=strict \
  --property=ProtectHome=yes \
  --property=ProtectKernelTunables=yes \
  --property=ProtectKernelModules=yes \
  --property=ProtectControlGroups=yes \
  --property=RestrictRealtime=yes \
  --property=RestrictSUIDSGID=yes \
  --property=LockPersonality=yes \
  --property=CapabilityBoundingSet= \
  --property="ReadWritePaths=$CELL_ROOT $CREDENTIAL_MOUNT" \
  "$LAUNCH" "$ENV_FILE" "$REPO" "$NM_BIN" "$MODE" "$INTENT_FILE" "$RESPONSE_FILE" "$RUN_LOG"

END_EPOCH=$(date +%s)
END_LOAD=$(cat /proc/loadavg)
END_MEM_AVAILABLE_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
RUN_EXIT=$(cat "$RUN_LOG.exit" 2>/dev/null || printf 125)
STATUS_LOG=$LOGS/status-a$ATTEMPT.log
set +e
# shellcheck disable=SC2016  # Inner shell intentionally expands its positional arguments.
runuser -u fmvalidate -- /bin/bash -c \
  'set -a; . "$1"; set +a; exec "$2" axi status' \
  validation-status "$ENV_FILE" "$NM_BIN" >"$STATUS_LOG" 2>&1
STATUS_RC=$?
set -e
RUN_ID=$(grep -hEo '[0-9A-HJKMNP-TV-Z]{26}' "$STATUS_LOG" "$RUN_LOG" | tail -n 1 || true)
if [ -n "$RUN_ID" ]; then
  tmp=$IDENTITY.tmp
  jq --arg run "$RUN_ID" '.run_id=$run' "$IDENTITY" >"$tmp"
  mv "$tmp" "$IDENTITY"
fi
CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)
CURRENT_TREE=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
REMOTE_HEAD=$(git -C "$REPO" ls-remote --heads origin "refs/heads/$BRANCH" | awk 'NR==1 {print $1}')
tmp=$IDENTITY.tmp
jq --arg head "$CURRENT_HEAD" '.current_head=$head' "$IDENTITY" >"$tmp"
mv "$tmp" "$IDENTITY"

# The durable no-mistakes database view, not free-form run output or intent,
# owns terminal outcome classification.
OUTCOME=failed
if [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'needs[-_ ]decision|awaiting[_ -]user|ask-user' "$STATUS_LOG"; then
  OUTCOME=needs-decision
elif [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'outcome:[[:space:]]*(passed|checks-passed)|checks[- ]passed|checks green' "$STATUS_LOG"; then
  OUTCOME=checks-passed
elif [ "$RUN_EXIT" -eq 0 ] && [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'outcome:[[:space:]]*passed' "$STATUS_LOG"; then
  OUTCOME=passed
fi
PR=$(grep -hEo 'https://github\.com/[^ /]+/[^ /]+/pull/[0-9]+' "$STATUS_LOG" "$RUN_LOG" | tail -n 1 || true)
CHECKS_GREEN=false
case "$OUTCOME" in passed|checks-passed) CHECKS_GREEN=true ;; esac
SHARD_RECEIPTS=$SHARD_EXCHANGE/receipts.json
[ -f "$SHARD_RECEIPTS" ] || printf '[]\n' >"$SHARD_RECEIPTS"
install -d -m 0700 -o fmvalidate -g fmvalidate "$EVIDENCE/attempt-$ATTEMPT"
cp "$SHARD_RECEIPTS" "$EVIDENCE/attempt-$ATTEMPT/behavior-shards.json"
cp "$STATUS_LOG" "$EVIDENCE/attempt-$ATTEMPT/no-mistakes-status.log"
python3 - "$EVIDENCE/attempt-$ATTEMPT/cell-metrics.json" "$START_EPOCH" "$END_EPOCH" \
  "$START_LOAD" "$END_LOAD" "$START_MEM_AVAILABLE_KIB" "$END_MEM_AVAILABLE_KIB" <<'PY'
import json
import pathlib
import sys
value = {
    "schema": "fm.azure-validation-metrics/v1",
    "start_epoch": int(sys.argv[2]),
    "end_epoch": int(sys.argv[3]),
    "wall_seconds": int(sys.argv[3]) - int(sys.argv[2]),
    "start_loadavg": sys.argv[4],
    "end_loadavg": sys.argv[5],
    "start_mem_available_kib": int(sys.argv[6]),
    "end_mem_available_kib": int(sys.argv[7]),
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
RESULT=$STATE/result-a$ATTEMPT.json
python3 - "$REQUEST" "$IDENTITY" "$RESULT" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" \
  "$(cat /proc/sys/kernel/random/boot_id)" "$OUTCOME" "$CURRENT_HEAD" "$CURRENT_TREE" "$REMOTE_HEAD" "$PR" "$CHECKS_GREEN" "$SHARD_RECEIPTS" <<'PY'
import json
import pathlib
import sys
request = json.load(open(sys.argv[1], encoding="utf-8"))
identity = json.load(open(sys.argv[2], encoding="utf-8"))
try:
    shards = json.load(open(sys.argv[13], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    shards = []
result = {
    "schema": request["protocol"]["result_schema"],
    "request_digest": request["request_digest"],
    "cell": request["cell"],
    "home_binding": request["home_binding"],
    "task": request["task"],
    "task_generation": request["task_generation"],
    "validation_generation": request["validation_generation"],
    "fence": request["fence"],
    "branch": request["repository"]["branch"],
    "submitted_head": request["repository"]["head"],
    "current_head": sys.argv[8],
    "current_tree": sys.argv[9],
    "remote_head": sys.argv[10],
    "worktree_disk_id": identity["worktree_disk_id"],
    "worktree_luks_uuid": identity["worktree_luks_uuid"],
    "credential_lease_id": identity["credential_lease_id"],
    "run_id": identity.get("run_id"),
    "vm_resource_id": sys.argv[4],
    "vm_instance_id": sys.argv[5],
    "boot_id": sys.argv[6],
    "outcome": sys.argv[7],
    "pr_url": sys.argv[11] or None,
    "checks_green": sys.argv[12] == "true",
    "behavior_shards": shards,
}
path = pathlib.Path(sys.argv[3])
path.write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

REPORT=$STATE/report.md
{
  printf '# Azure validation cell result\n\n'
  printf -- "- Cell: \`%s\`\n" "$CELL"
  printf -- "- Attempt: \`%s\`\n" "$ATTEMPT"
  printf -- "- Outcome: \`%s\`\n" "$OUTCOME"
  printf -- "- Submitted head: \`%s\`\n" "$(jq -r '.repository.head' "$REQUEST")"
  printf -- "- Current head: \`%s\`\n" "$CURRENT_HEAD"
  printf -- "- Run id: \`%s\`\n" "${RUN_ID:-unavailable}"
} >"$REPORT"

RESULT_ARCHIVE=$BOOTSTRAP/result.tar.gz
rm -f "$RESULT_ARCHIVE"
(
  cd "$STATE"
  cp "$RUN_LOG" run.log
  cp "$REPORT" report.md
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -czf "$RESULT_ARCHIVE" "$(basename "$RESULT")" run.log report.md
)
# Normalize the attempt-specific result name to the fixed protocol member.
TMP_RESULT=$BOOTSTRAP/result-normalized
rm -rf "$TMP_RESULT"
mkdir "$TMP_RESULT"
tar -xzf "$RESULT_ARCHIVE" -C "$TMP_RESULT"
mv "$TMP_RESULT/$(basename "$RESULT")" "$TMP_RESULT/result.json"
cp -R "$EVIDENCE/attempt-$ATTEMPT" "$TMP_RESULT/evidence"
tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
  -czf "$RESULT_ARCHIVE" -C "$TMP_RESULT" result.json run.log report.md evidence
RESULT_DIGEST=sha256:$(sha256sum "$RESULT_ARCHIVE" | awk '{print $1}')
if [ -n "$OUTPUT_URL" ]; then
  CURL_CONFIG=$BOOTSTRAP/output.curl
  printf 'url = "%s"\nfail\nsilent\nshow-error\nrequest = "PUT"\nheader = "x-ms-blob-type: BlockBlob"\nupload-file = "%s"\n' \
    "$OUTPUT_URL" "$RESULT_ARCHIVE" >"$CURL_CONFIG"
  unset OUTPUT_URL
  curl --config "$CURL_CONFIG"
  rm -f "$CURL_CONFIG"
fi
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf 'FM_AZURE_VALIDATION_RESULT %s boot=%s outcome=%s\n' "$RESULT_DIGEST" "$BOOT_ID" "$OUTCOME"
