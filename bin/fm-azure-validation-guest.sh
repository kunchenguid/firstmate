#!/usr/bin/env bash
# Trusted root-side payload for one isolated Azure no-mistakes cell.
#
# Azure Managed Run Command supplies the GitHub token and optional gate
# response as run-command parameters at boot time; nothing durable carries
# credentials. The worktree data disk is a plain ext4 filesystem. Repository
# commands are not run here: the trusted no-mistakes command seam delegates
# lint/test and requested behavior parallelism to identity-less Azure shard
# VMs through the shard exchange.
set -euo pipefail
set +x
umask 077

[ "$#" -eq 0 ] || { echo "validation guest: positional parameters are forbidden" >&2; exit 125; }
MODE=${mode:-}
INPUT_DIGEST=${input_digest:-}
REQUEST_DIGEST=${request_digest:-}
CELL=${cell:-}
ATTEMPT=${attempt:-}
VM_RESOURCE_ID=${vm_resource_id:-}
VM_INSTANCE_ID=${vm_instance_id:-}
WORKTREE_DISK_ID=${worktree_disk_id:-}
STORAGE_ACCOUNT=${storage_account:-}
STORAGE_CONTAINER=${storage_container:-}
IDENTITY_CLIENT_ID=${identity_client_id:-}
AUTH_SHARE=${auth_share:-fm-auth-home}
INPUT_URL=${input_url:-}
OUTPUT_URL=${output_url:-}
RESPONSE=${response:-}
GITHUB_TOKEN_VALUE=${github_token:-}
unset mode input_digest request_digest cell attempt vm_resource_id vm_instance_id
unset worktree_disk_id storage_account storage_container identity_client_id auth_share
unset input_url output_url response github_token
case "$MODE" in
  start)
    [ -n "$INPUT_URL" ] && [ -n "$OUTPUT_URL" ] || { echo "validation guest: start capability is absent" >&2; exit 125; }
    ;;
  reattach)
    [ -n "$OUTPUT_URL" ] || { echo "validation guest: reattach capability is absent" >&2; exit 125; }
    ;;
  respond)
    [ -n "$RESPONSE" ] || { echo "validation guest: response is absent" >&2; exit 125; }
    ;;
  *)
    echo "validation guest: unsupported mode" >&2
    exit 125
    ;;
esac
case "$INPUT_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "validation guest: input digest is malformed" >&2; exit 125 ;; esac
case "$REQUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "validation guest: request digest is malformed" >&2; exit 125 ;; esac
case "$CELL" in azv-[a-z0-9][a-z0-9]*) ;; *) echo "validation guest: cell identity is malformed" >&2; exit 125 ;; esac
case "$ATTEMPT" in ''|*[!0-9]*) echo "validation guest: attempt is malformed" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) if [ "$MODE" != respond ]; then echo "validation guest: output capability is not HTTPS" >&2; exit 125; fi ;; esac
case "$INPUT_URL" in https://*) ;; *) if [ "$MODE" = start ]; then echo "validation guest: input capability is not HTTPS" >&2; exit 125; fi ;; esac
[ -n "$GITHUB_TOKEN_VALUE" ] || { echo "validation guest: GitHub token parameter is absent" >&2; exit 125; }

BOOTSTRAP=/var/lib/fm-azure-validation
install -d -m 0700 -o root -g root "$BOOTSTRAP"

missing=()
for tool in curl git python3 sha256sum tar systemd-run blkid findmnt jq mount umount useradd runuser; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  bootstrap_packages() {
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 util-linux jq systemd tar passwd
  }
  if ! bootstrap_packages; then
    # The regional azure.archive mirror rides plain port 80, whose egress can
    # die while 443 stays healthy (generation 044 ground truth: connection
    # timeouts to the mirror while storage uploads succeeded). apt-get update
    # exits 0 on failed fetches, so the install step is what surfaces it.
    sed -i 's|http://azure.archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu|g' \
      /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
    bootstrap_packages
  fi
fi
for tool in curl git python3 sha256sum tar systemd-run blkid findmnt jq mount umount useradd runuser; do
  command -v "$tool" >/dev/null 2>&1 || { echo "validation guest: fixed bootstrap closure is incomplete" >&2; exit 125; }
done

# Azure LUN identity is part of the ARM contract, but the guest also re-reads
# IMDS and rejects a disk swap before mounting the worktree.
METADATA=$BOOTSTRAP/metadata.json
curl --fail --silent --show-error --noproxy '*' \
  -H Metadata:true \
  'http://169.254.169.254/metadata/instance?api-version=2021-02-01' >"$METADATA"
python3 - "$METADATA" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" "$WORKTREE_DISK_ID" <<'PY'
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
if by_lun.get("0") != sys.argv[4].lower():
    raise SystemExit("validation guest: IMDS data-disk identity mismatch")
PY

# SCSI SKUs publish data disks under scsi1/lunN; NVMe-only SKUs (v6 families)
# publish them under data/by-lun/N via azure-vm-utils. Both are udev identity
# paths; never guess raw namespaces because mkfs runs on the resolved device.
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

WORK_MOUNT=/srv/fm-validation
install -d -m 0700 -o root -g root "$WORK_MOUNT"
set +e
WORKTREE_FS_TYPE=$(blkid -p -s TYPE -o value "$WORK_DEVICE" 2>/dev/null)
WORKTREE_FS_RC=$?
set -e
case "$WORKTREE_FS_RC:$WORKTREE_FS_TYPE" in
  2:)
    [ "$MODE" = start ] || { echo "validation guest: replacement worktree has no filesystem" >&2; exit 125; }
    mkfs.ext4 -q -F -L fm-validation-work "$WORK_DEVICE"
    ;;
  0:ext4)
    [ "$MODE" != start ] || { echo "validation guest: new cell found a pre-existing worktree filesystem" >&2; exit 125; }
    ;;
  0:*) echo "validation guest: worktree disk has a foreign filesystem" >&2; exit 125 ;;
  *) echo "validation guest: worktree filesystem identity is unreadable" >&2; exit 125 ;;
esac
mount -o nodev,nosuid "$WORK_DEVICE" "$WORK_MOUNT"
cleanup_mounts() {
  umount "$WORK_MOUNT" 2>/dev/null || true
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

# Persistent-auth home sync (auth-once-ever): the fm-auth-home Azure Files
# share carries the agent user's home-shaped auth state (~/.codex, ~/.claude,
# ...) across every cell and runner boot. Pull overlays the share onto the
# cell home before the run; push writes refreshed token files back after the
# run. Transfers use the cell's managed identity over plain REST; failures
# warn and continue because the submit-time bundle still seeds a first boot.
AUTH_SYNC=$BOOTSTRAP/auth-sync.py
cat >"$AUTH_SYNC" <<'PY'
import json
import pathlib
import sys
import urllib.error
import urllib.request

# Azure firstmate is powered entirely by pi-codex; ~/.codex (including its
# multi-profile extension state) is the primary contents. Exactly one claude
# profile (~/.claude) rides along for the cross-check lane only.
AUTH_DIRS = (".codex", ".claude")
VERSION = "2024-11-04"


def token(client_id):
    request = urllib.request.Request(
        "http://169.254.169.254/metadata/identity/oauth2/token"
        "?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F"
        "&client_id=" + client_id,
        headers={"Metadata": "true"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)["access_token"]


def call(bearer, method, url, data=None, headers=None):
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + bearer)
    request.add_header("x-ms-version", VERSION)
    request.add_header("x-ms-file-request-intent", "backup")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def list_directory(bearer, base, directory):
    from xml.etree import ElementTree
    url = base + ("/" + directory if directory else "") + "?restype=directory&comp=list"
    tree = ElementTree.fromstring(call(bearer, "GET", url))
    files, directories = [], []
    for entry in tree.iter("File"):
        files.append((directory + "/" if directory else "") + entry.findtext("Name"))
    for entry in tree.iter("Directory"):
        directories.append((directory + "/" if directory else "") + entry.findtext("Name"))
    return files, directories


def pull(bearer, base, destination):
    count = 0
    pending = [""]
    while pending:
        directory = pending.pop()
        files, directories = list_directory(bearer, base, directory)
        pending.extend(directories)
        for relative in files:
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(call(bearer, "GET", base + "/" + relative))
            target.chmod(0o600)
            count += 1
    return count


def ensure_remote_directory(bearer, base, directory):
    try:
        call(bearer, "PUT", base + "/" + directory + "?restype=directory")
    except urllib.error.HTTPError as error:
        if error.code != 409:
            raise


def push(bearer, base, source):
    count = 0
    for name in AUTH_DIRS:
        root = source / name
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(source).as_posix()
            parts = relative.split("/")
            for depth in range(1, len(parts)):
                ensure_remote_directory(bearer, base, "/".join(parts[:depth]))
            data = path.read_bytes()
            call(bearer, "PUT", base + "/" + relative, headers={
                "x-ms-type": "file",
                "x-ms-content-length": str(len(data)),
                "Content-Length": "0",
            })
            offset = 0
            while offset < len(data) or (len(data) == 0 and offset == 0):
                if len(data) == 0:
                    break
                chunk = data[offset:offset + 4 * 1024 * 1024]
                call(
                    bearer, "PUT",
                    base + "/" + relative + "?comp=range",
                    data=chunk,
                    headers={
                        "x-ms-range": "bytes={}-{}".format(offset, offset + len(chunk) - 1),
                        "x-ms-write": "update",
                    },
                )
                offset += len(chunk)
            count += 1
    return count


def main():
    operation, account, share, client_id, local = sys.argv[1:6]
    base = "https://{}.file.core.windows.net/{}".format(account, share)
    bearer = token(client_id)
    home = pathlib.Path(local)
    if operation == "pull":
        count = pull(bearer, base, home)
        print(count)
    elif operation == "push":
        print(push(bearer, base, home))
    else:
        raise SystemExit("auth-sync: unknown operation")


main()
PY
chmod 0700 "$AUTH_SYNC"

auth_home_pull() {
  set +e
  pulled=$(python3 "$AUTH_SYNC" pull "$STORAGE_ACCOUNT" "$AUTH_SHARE" "$IDENTITY_CLIENT_ID" "$HOME_DIR" 2>>"$LOGS/auth-sync-a$ATTEMPT.log")
  pull_rc=$?
  set -e
  if [ "$pull_rc" -ne 0 ]; then
    echo "validation guest: auth-home pull failed; continuing with the seeded bundle" >&2
  elif [ "${pulled:-0}" -eq 0 ]; then
    # First-ever boot against an empty share: proceed, but leave a durable
    # marker so the operator knows one interactive auth is still needed.
    { printf 'auth share %s was empty at %s; interactive provider auth is needed once\n' \
      "$AUTH_SHARE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE/auth-needed" \
      && chmod 0600 "$STATE/auth-needed"; } || :
    echo "validation guest: auth share is empty; interactive auth marker written" >&2
  else
    rm -f "$STATE/auth-needed" || :
  fi
  # From here on this cell owns auth the share has not seen, whether it came
  # from the share, from the seeded bundle after a failed pull, or from a first
  # interactive auth against an empty share. The owed marker is durable on the
  # worktree disk, so a cell that dies before its clean shutdown - the only
  # place the push runs - carries the skipped write-back into its report
  # instead of losing it silently. Naming the actual origin keeps the marker
  # from asserting a pull that did not happen.
  if [ "$pull_rc" -ne 0 ]; then
    owed_origin="the seeded bundle after a failed pull from share $AUTH_SHARE"
  elif [ "${pulled:-0}" -eq 0 ]; then
    owed_origin="a first interactive auth against empty share $AUTH_SHARE"
  else
    owed_origin="a pull from share $AUTH_SHARE"
  fi
  { printf 'this cell owns auth from %s at %s; a write-back to %s is owed\n' \
    "$owed_origin" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$AUTH_SHARE" >"$STATE/auth-push-owed" \
    && chmod 0600 "$STATE/auth-push-owed"; } || :
}

auth_home_push() {
  set +e
  python3 "$AUTH_SYNC" push "$STORAGE_ACCOUNT" "$AUTH_SHARE" "$IDENTITY_CLIENT_ID" "$HOME_DIR" \
    >>"$LOGS/auth-sync-a$ATTEMPT.log" 2>&1
  push_rc=$?
  set -e
  if [ "$push_rc" -eq 0 ]; then
    rm -f "$STATE/auth-push-owed" "$STATE/auth-push-failed" || :
    return 0
  fi
  # A warning on stderr dies with the guest. The share is now stale, every
  # later boot starts from an older credential, and only a durable marker
  # carried into the operator report says so.
  { printf 'auth-home push to share %s failed with status %s at %s; refreshed tokens stay cell-local and the share is stale\n' \
    "$AUTH_SHARE" "$push_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE/auth-push-failed" \
    && chmod 0600 "$STATE/auth-push-failed"; } || :
  echo "validation guest: auth-home push failed; refreshed tokens stay cell-local" >&2
}

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
allowed = {"request.json", "snapshot.bundle", "runtime.tar.gz", "credentials.tar.gz", "shard-bridge.py"}
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
  python3 - "$REQUEST" "$REQUEST_DIGEST" "$CELL" "$WORKTREE_DISK_ID" "$EXTRACT/snapshot.bundle" "$EXTRACT/runtime.tar.gz" "$EXTRACT/credentials.tar.gz" "$EXTRACT/shard-bridge.py" <<'PY'
import hashlib
import json
import pathlib
import sys

request_path = pathlib.Path(sys.argv[1])
def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise SystemExit("validation guest: request has a duplicate JSON key")
        value[key] = item
    return value


request = json.loads(
    request_path.read_text(encoding="utf-8"), object_pairs_hook=unique_object
)
unsigned = dict(request)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != sys.argv[2] or supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("validation guest: request digest mismatch")
if request.get("cell") != sys.argv[3]:
    raise SystemExit("validation guest: cell identity mismatch")
bindings = request.get("resource_bindings", {})
if bindings.get("worktree_disk_id", "").lower() != sys.argv[4].lower():
    raise SystemExit("validation guest: worktree disk request mismatch")
def digest(path):
    return "sha256:" + hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
if digest(sys.argv[5]) != request["repository"]["snapshot_digest"]:
    raise SystemExit("validation guest: repository bundle digest mismatch")
if digest(sys.argv[6]) != request["runtime_digest"]:
    raise SystemExit("validation guest: runtime bundle digest mismatch")
if digest(sys.argv[7]) != request["credentials"]["bundle_digest"]:
    raise SystemExit("validation guest: credentials bundle digest mismatch")
if digest(sys.argv[8]) != request["protocol"]["shard_bridge_digest"]:
    raise SystemExit("validation guest: shard bridge digest mismatch")
PY
  cp "$REQUEST" "$STATE/request.json"
  chmod 0600 "$STATE/request.json"
  RUNTIME=/opt/fm-azure-validation/runtime
  rm -rf "$RUNTIME"
  # install -d applies -m only to the directories it is given; implicit
  # parent components are created at the process umask, and this run-command
  # context runs at umask 077, which left /opt/fm-azure-validation itself
  # 0700 root-only and untraversable for fmvalidate even with a correct
  # runtime tree below it. Name the parent explicitly.
  install -d -m 0755 -o root -g root /opt/fm-azure-validation "$RUNTIME"
  tar -xzf "$EXTRACT/runtime.tar.gz" -C "$RUNTIME" --no-same-owner --no-same-permissions
  # --no-same-permissions applies this process's umask, and the Azure run
  # command context runs with umask 077, so every runtime file lands
  # root-only and fmvalidate cannot execute no-mistakes. Assign exactly
  # 0755/0644 from the archive's own executable intent instead of raw
  # archive modes, so neither setuid nor world-write can ride in.
  python3 - "$EXTRACT/runtime.tar.gz" "$RUNTIME" <<'MODES'
import pathlib
import sys
import tarfile
root = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], "r:gz") as archive:
    for member in archive.getmembers():
        target = root / member.name
        if member.isdir():
            target.chmod(0o755)
        elif member.isfile():
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
# The bundle is built from a file list and carries zero directory members,
# so every intermediate directory is created at the extracting umask (077)
# and no member-driven chmod ever reaches it. Normalize the real tree.
for path in root.rglob("*"):
    if path.is_dir():
        path.chmod(0o755)
MODES
  python3 - "$RUNTIME" "$REQUEST" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

def strict_json(path, label):
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise SystemExit(
                    "validation guest: {} has a duplicate JSON key".format(label)
                )
            value[key] = item
        return value

    try:
        return json.loads(
            pathlib.Path(path).read_text(encoding="utf-8"),
            object_pairs_hook=unique_object,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit(
            "validation guest: {} is not valid duplicate-free JSON".format(label)
        )


root = pathlib.Path(sys.argv[1]).resolve()
manifest = strict_json(root / "runtime.json", "runtime manifest")
request = strict_json(sys.argv[2], "sealed request")
if manifest != request.get("runtime"):
    raise SystemExit("validation guest: runtime manifest differs from the sealed request")
manifest_fields = {
    "schema", "provider", "no_mistakes_version", "no_mistakes_path",
    "provider_path", "gh_path", "node_path", "gh_axi_path",
    "gh_axi_entrypoint", "gh_axi_closure", "files",
}
file_fields = {"path", "digest"}
fixed_entrypoint = "gh-axi/dist/bin/gh-axi.js"
fixed_wrapper = (
    b"#!/usr/bin/env bash\n"
    b"# Runtime-bundle wrapper: bind gh-axi to the bundled Node interpreter.\n"
    b"set -euo pipefail\n"
    b'runtime_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)\n'
    b'exec "$runtime_root/bin/node" "$runtime_root/gh-axi/dist/bin/gh-axi.js" "$@"\n'
)
forbidden_components = {
    ".azure", ".claude", ".codex", ".credentials", ".credentials.json",
    ".docker", ".env", ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".ssh", "auth.json", "cookies", "credentials", "credentials.json",
    "hosts.yml", "keychain",
}
forbidden_stems = {
    "access_key", "access_token", "access_tokens", "accesskey", "accesstoken",
    "accesstokens", "api_key", "apikey", "auth", "authentication",
    "authorization", "client_secret", "client_secrets", "clientsecret",
    "clientsecrets", "cookie", "cookies", "credential", "credentials",
    "private_key", "private_keys", "privatekey", "privatekeys", "id_dsa",
    "id_ecdsa", "id_ed25519", "id_rsa", "oauth_token", "passphrase",
    "passphrases", "passwd", "password", "passwords", "refresh_token",
    "refresh_tokens", "refreshtoken", "refreshtokens", "secret", "secret_key",
    "secret_keys", "secretkey", "secretkeys", "secrets", "token", "tokens",
}
compact_suffixes = {value.replace("_", "") for value in forbidden_stems}
data_suffixes = (".conf", ".ini", ".json", ".toml", ".txt", ".yaml", ".yml")
key_suffixes = (".jks", ".key", ".keystore", ".p12", ".pem", ".pfx")
safe_code_suffixes = (
    ".c", ".cc", ".cjs", ".cpp", ".d.ts", ".go", ".h", ".hpp", ".js",
    ".map", ".md", ".mjs", ".py", ".rs", ".ts",
)


def normalized_components(value):
    return tuple(
        part.casefold() for part in raw_components(value)
    )


def raw_components(value):
    return tuple(
        part for part in str(value).replace("\\", "/").split("/")
        if part not in ("", ".")
    )


def credential_like(value):
    original_components = raw_components(value)
    components = tuple(part.casefold() for part in original_components)
    if any(
        tuple(components[index:index + 2]) == (".config", "gh")
        for index in range(len(components) - 1)
    ):
        return True
    for original_component, component in zip(original_components, components):
        if component in forbidden_components or component.startswith(".env."):
            return True
        if component.endswith(key_suffixes):
            return True
        candidate = original_component
        for suffix in data_suffixes:
            if candidate.casefold().endswith(suffix):
                candidate = candidate[:-len(suffix)]
                break
        compact_stem = re.sub(
            r"[^a-z0-9]+", "", candidate.casefold().strip(".")
        )
        candidate = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", candidate)
        candidate = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", candidate)
        stem = re.sub(
            r"[^a-z0-9]+", "_", candidate.casefold().strip(".")
        ).strip("_")
        if (
            not component.endswith(safe_code_suffixes)
            and (
                any(
                    stem == value or f"_{value}_" in f"_{stem}_"
                    for value in forbidden_stems
                )
                or any(compact_stem.endswith(value) for value in compact_suffixes)
            )
        ):
            return True
    return False


if not isinstance(manifest, dict) or set(manifest) != manifest_fields:
    raise SystemExit("validation guest: runtime manifest fields are not the exact schema")
provider = manifest.get("provider")
fixed_paths = {
    "no_mistakes_path": "bin/no-mistakes",
    "provider_path": "bin/" + provider if provider in ("codex", "claude") else None,
    "gh_path": "bin/gh",
    "node_path": "bin/node",
    "gh_axi_path": "bin/gh-axi",
    "gh_axi_entrypoint": fixed_entrypoint,
}
if any(manifest.get(field) != value for field, value in fixed_paths.items()):
    raise SystemExit("validation guest: runtime fixed executable or entrypoint path drifted")
closure = manifest["gh_axi_closure"]
if (
    not isinstance(closure, list)
    or not closure
    or not all(isinstance(item, str) for item in closure)
    or closure != sorted(set(closure))
    or fixed_entrypoint not in closure
):
    raise SystemExit("validation guest: runtime gh-axi closure is malformed")
if not isinstance(manifest["files"], list) or not manifest["files"]:
    raise SystemExit("validation guest: runtime file inventory is malformed")
seen = set()
for record in manifest["files"]:
    if not isinstance(record, dict) or set(record) != file_fields:
        raise SystemExit("validation guest: runtime file record fields are not exact")
    if not isinstance(record["path"], str):
        raise SystemExit("validation guest: runtime file path is malformed")
    components = normalized_components(record["path"])
    if (
        not components
        or record["path"].startswith(("/", "\\"))
        or ".." in components
        or credential_like(record["path"])
    ):
        raise SystemExit("validation guest: runtime file path is unsafe or credential-like")
    path = root / record["path"]
    try:
        observed = os.lstat(path)
    except OSError:
        raise SystemExit("validation guest: runtime file is escaping, absent, or linked")
    resolved = path.resolve()
    if (
        root not in resolved.parents
        or not stat.S_ISREG(observed.st_mode)
        or observed.st_nlink != 1
    ):
        raise SystemExit("validation guest: runtime file is escaping, absent, or linked")
    digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != record["digest"]:
        raise SystemExit("validation guest: runtime file digest mismatch")
    seen.add(path.relative_to(root).as_posix())
if len(seen) != len(manifest["files"]):
    raise SystemExit("validation guest: runtime file inventory has duplicates")
if not set(closure).issubset(seen):
    raise SystemExit("validation guest: runtime gh-axi closure is incomplete")
package = strict_json(root / "gh-axi/package.json", "gh-axi package manifest")
if (
    package.get("name") != "gh-axi"
    or not isinstance(package.get("bin"), dict)
    or package["bin"].get("gh-axi") != "./dist/bin/gh-axi.js"
    or (root / "bin/gh-axi").read_bytes() != fixed_wrapper
):
    raise SystemExit("validation guest: runtime gh-axi wrapper or entrypoint drifted")
actual = set()
for path in root.rglob("*"):
    observed = os.lstat(path)
    if stat.S_ISDIR(observed.st_mode):
        continue
    if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        raise SystemExit("validation guest: runtime inventory contains a link or special file")
    relative = path.relative_to(root).as_posix()
    if relative != "runtime.json":
        if credential_like(relative):
            raise SystemExit("validation guest: runtime inventory has a credential-like path")
        actual.add(relative)
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
  # The auth bundle is home-shaped (.codex/, .claude/, ...) and seeds the
  # agent home on the durable worktree disk; a later reattach keeps the
  # session state a provider run legitimately mutates.
  python3 - "$EXTRACT/credentials.tar.gz" "$HOME_DIR" <<'PY'
import pathlib
import sys
import tarfile

destination = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = archive.getmembers()
    for member in members:
        if member.issym() or member.islnk() or member.isdev() or member.name.startswith("/") or ".." in member.name.split("/"):
            raise SystemExit("validation guest: unsafe credentials member")
    archive.extractall(destination, members=members)
PY
else
  REQUEST=$STATE/request.json
  [ -f "$REQUEST" ] || { echo "validation guest: retained request is absent" >&2; exit 125; }
  [ -d "$HOME_DIR" ] || { echo "validation guest: retained agent home is absent" >&2; exit 125; }
fi

# Overlay the persistent auth home on every attempt so refreshed tokens from
# any earlier cell or runner win over the submit-time seed.
auth_home_pull

# Re-prove every durable identity after opening retained state.
python3 - "$REQUEST" "$REQUEST_DIGEST" "$CELL" "$WORKTREE_DISK_ID" <<'PY'
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
):
    raise SystemExit("validation guest: retained run/disk identity mismatch")
PY

# The token arrives fresh on every attempt as a run-command parameter and
# lives only in this per-cell state file for the run user's tooling.
GITHUB_TOKEN_FILE=$STATE/github-token
printf '%s' "$GITHUB_TOKEN_VALUE" >"$GITHUB_TOKEN_FILE"
unset GITHUB_TOKEN_VALUE
chmod 0600 "$GITHUB_TOKEN_FILE"

if ! id fmvalidate >/dev/null 2>&1; then
  useradd --system --home-dir "$HOME_DIR" --shell /usr/sbin/nologin fmvalidate
fi
chown -R fmvalidate:fmvalidate "$CELL_ROOT"
chmod 0700 "$CELL_ROOT" "$HOME_DIR" "$NM_HOME" "$CACHE" "$TMP"
chmod 0600 "$GITHUB_TOKEN_FILE"
# The chown above hands the cloned repository to fmvalidate, so every later
# root-run git command in this script trips the dubious-ownership guard
# (CVE-2022-24765); git config's variant of that refusal is the bare
# "fatal: not in a git directory". Authorize exactly this repository for the
# rest of the process; fmvalidate children inherit it harmlessly (own repo).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=$REPO

RUNTIME=/opt/fm-azure-validation/runtime
NM_BIN=$RUNTIME/$(jq -r '.runtime.no_mistakes_path' "$REQUEST")
PROVIDER_BIN=$RUNTIME/$(jq -r '.runtime.provider_path' "$REQUEST")
GH_BIN=$RUNTIME/$(jq -r '.runtime.gh_path' "$REQUEST")
NODE_BIN=$RUNTIME/$(jq -r '.runtime.node_path' "$REQUEST")
GH_AXI_BIN=$RUNTIME/$(jq -r '.runtime.gh_axi_path' "$REQUEST")
for executable in "$NM_BIN" "$PROVIDER_BIN" "$GH_BIN" "$NODE_BIN" "$GH_AXI_BIN"; do
  [ -x "$executable" ] || { echo "validation guest: exact runtime executable is absent" >&2; exit 125; }
done
PROVIDER=$(jq -r '.credentials.provider' "$REQUEST")
# Receipts are run-scoped, not attempt-scoped. The bridge writes them in the
# one attempt whose test step actually executes, and a resumed attempt
# (reattach after a teardown, respond after a gate) continues the exact same
# no-mistakes run - identity re-proved above - without re-executing an
# already-green test step, so the round's receipts on the durable shard
# exchange are that resumed attempt's only proof that sharding happened.
# Wiping them per attempt (the first cut of the receipt demotion) made every
# multi-attempt run assemble its final result with zero receipts, demote to
# failed, and lose the ability to close. Binding stays with the controller:
# collect accepts a receipt head only as the published head or a verified
# ancestor of it, with the receipt tree bound to that head, so a carried
# receipt can never vouch for history the run did not publish. Only a start
# boot - a fresh run - begins from no receipts, so a retained disk can never
# leak a previous run's proof into a new one. Belt-and-suspenders only: the
# filesystem gate above already refuses a start boot on a disk that carries a
# filesystem, and a fresh mkfs cannot carry receipts, so this wipe is not
# load-bearing today.
if [ "$MODE" = start ]; then
  rm -f "$SHARD_EXCHANGE/receipts.json" || :
fi
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
  # Auth state lives in the home-shaped persistent auth layout, so provider
  # config dirs are the conventional home-relative locations. pi-codex is the
  # only cell provider; the claude profile exists for cross-check reviews.
  case "$PROVIDER" in
    codex) printf 'CODEX_HOME=%s\n' "$HOME_DIR/.codex" ;;
    claude) printf 'CLAUDE_CONFIG_DIR=%s\nCLAUDE_SECURESTORAGE_CONFIG_DIR=%s\n' "$HOME_DIR/.claude" "$HOME_DIR/.claude" ;;
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
# A root git config rewrites .git/config through a lockfile created at this
# process's umask (077), leaving the file root-owned and unreadable to the
# fmvalidate run (generation 011 ground truth: fatal: unable to access
# '.git/config': Permission denied). Write repo-local config as the owner.
runuser -u fmvalidate -- git -C "$REPO" config credential.helper "$GIT_HELPER"
runuser -u fmvalidate -- git -C "$REPO" config credential.useHttpPath true
# The rebase and fix stages create commits inside the cell; without a
# configured identity git refuses with "empty ident name". Match the
# program's commit identity so pipeline commits attribute consistently.
runuser -u fmvalidate -- git -C "$REPO" config user.name "ruby-dlee"
runuser -u fmvalidate -- git -C "$REPO" config user.email "dongkeun@rubydata.ai"
# The pipeline's push step runs from the no-mistakes gate repo under the cell
# home, where repo-local config does not reach (generation 041 ground truth:
# "could not read Username for 'https://github.com': terminal prompts
# disabled"). User-level config covers every git context the cell user owns.
# -C keeps git's working directory inside the repo: without it git resolves
# the run-command handler's root-only download directory as cwd and fatals
# with EACCES before touching the global config (generation 042 ground truth).
runuser -u fmvalidate -- env HOME="$HOME_DIR" git -C "$REPO" config --global credential.helper "$GIT_HELPER"
runuser -u fmvalidate -- env HOME="$HOME_DIR" git -C "$REPO" config --global credential.useHttpPath true
runuser -u fmvalidate -- env HOME="$HOME_DIR" git -C "$REPO" config --global user.name "ruby-dlee"
runuser -u fmvalidate -- env HOME="$HOME_DIR" git -C "$REPO" config --global user.email "dongkeun@rubydata.ai"

IDENTITY=$STATE/identity.json
CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)
BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD)
# Gate steps run on detached snapshots where HEAD has no symbolic ref; the
# shard bridge falls back to this declared branch identity.
printf 'FM_AZURE_VALIDATION_BRANCH=%s\n' "$BRANCH" >>"$ENV_FILE"
if [ "$MODE" = start ]; then
  jq -n \
    --arg cell "$CELL" --arg request "$REQUEST_DIGEST" --arg branch "$BRANCH" \
    --arg head "$CURRENT_HEAD" --arg worktree "$WORKTREE_DISK_ID" \
    '{cell:$cell,request_digest:$request,branch:$branch,current_head:$head,worktree_disk_id:$worktree,run_id:null}' \
    >"$IDENTITY"
  chmod 0600 "$IDENTITY"
else
  [ -f "$IDENTITY" ] || { echo "validation guest: retained run identity is absent" >&2; exit 125; }
  jq -e --arg cell "$CELL" --arg request "$REQUEST_DIGEST" --arg branch "$BRANCH" \
    --arg head "$CURRENT_HEAD" --arg worktree "$WORKTREE_DISK_ID" \
    '.cell==$cell and .request_digest==$request and .branch==$branch and .current_head==$head and .worktree_disk_id==$worktree and (.run_id|type=="string")' \
    "$IDENTITY" >/dev/null || { echo "validation guest: exact retained run identity refused reattach" >&2; exit 125; }
  RUN_ID=$(jq -r '.run_id' "$IDENTITY")
  STATUS_PROOF=$LOGS/reattach-status-a$ATTEMPT.log
  set +e
  # shellcheck disable=SC2016  # Inner shell intentionally expands its positional arguments.
  runuser -u fmvalidate -- /bin/bash -c \
    'set -a; . "$1"; set +a; cd "$3" && exec "$2" axi status' \
    validation-reattach "$ENV_FILE" "$NM_BIN" "$REPO" >"$STATUS_PROOF" 2>&1
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

# Build an argv-only launcher so run inputs never enter the unit definition or
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

ATTEMPT_NUMBER=$(basename "$RESPONSE_FILE" | sed -n 's/^response-a\([0-9][0-9]*\)\.txt$/\1/p')
[ -n "$ATTEMPT_NUMBER" ] || ATTEMPT_NUMBER=1

fetch_gate_response() {
  gate_index=$1
  destination=$2
  gate_token=$(curl --fail --silent --noproxy '*' --connect-timeout 5 --max-time 15 -H Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=$FM_AZURE_VALIDATION_IDENTITY_CLIENT_ID" \
    | jq -er .access_token) || return 1
  curl --fail --silent --noproxy '*' --connect-timeout 10 --max-time 60 \
    -H "Authorization: Bearer $gate_token" -H 'x-ms-version: 2023-11-03' \
    --output "$destination" \
    "https://${FM_AZURE_VALIDATION_STORAGE_ACCOUNT}.blob.core.windows.net/${FM_AZURE_VALIDATION_STORAGE_CONTAINER}/control/gate-response-a${ATTEMPT_NUMBER}-${gate_index}.txt"
}

adjudicate_gates() {
  # Runs are daemon-scoped: a parked gate can only be answered while this
  # unit's daemon owns it, so the operator's decision arrives through the
  # cell exchange and is applied here in place. Each parking prints exactly
  # one structured gate block, so an unanswered gate is a gate count above
  # the responses applied. Without a response inside the patience window
  # the attempt still ends needs-decision for the operator.
  responded=0
  gate_deadline=$((SECONDS + ${FM_AZURE_VALIDATION_GATE_WAIT_SECONDS:-5400}))
  while :; do
    gates=$(grep -c '^gate:' "$RUN_LOG" 2>/dev/null || printf 0)
    [ "$gates" -gt "$responded" ] || break
    [ "$SECONDS" -lt "$gate_deadline" ] || break
    next_response=$RESPONSE_FILE.gate$((responded + 1))
    if fetch_gate_response "$((responded + 1))" "$next_response"; then
      set --
      while IFS= read -r respond_arg || [ -n "$respond_arg" ]; do
        set -- "$@" "$respond_arg"
      done <"$next_response"
      "$NM_BIN" axi respond "$@" >>"$RUN_LOG" 2>&1 && "$NM_BIN" axi run >>"$RUN_LOG" 2>&1
      rc=$?
      responded=$((responded + 1))
    else
      sleep 30
    fi
  done
}

set +e
# A fresh cell clone carries the in-tree gate config but not the local gate
# state (bare gate repo, hook, no-mistakes remote, database record), so every
# axi command refuses with "repo not initialized". init sets up or refreshes
# that state and is safe to repeat on a retained worktree.
"$NM_BIN" init >"$RUN_LOG" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  case "$MODE" in
    start) "$NM_BIN" axi run --intent "$(cat "$INTENT_FILE")" >>"$RUN_LOG" 2>&1 ;;
    reattach) "$NM_BIN" axi run >>"$RUN_LOG" 2>&1 ;;
    respond)
      # The gated run was owned by the previous attempt's daemon, which died
      # with that attempt's unit; a reattaching axi run resurfaces the parked
      # gate for this fresh daemon before any respond can address it. The
      # reattach stops at the gate, so its exit status is not consulted.
      "$NM_BIN" axi run >>"$RUN_LOG" 2>&1 || true
      # axi respond takes its decision as required argv flags and reads
      # nothing from stdin, so the response file carries one argument per
      # line (e.g. "--action" / "fix" / "--findings" / "review-1"); values
      # must not contain newlines.
      set --
      while IFS= read -r respond_arg || [ -n "$respond_arg" ]; do
        set -- "$@" "$respond_arg"
      done <"$RESPONSE_FILE"
      "$NM_BIN" axi respond "$@" >>"$RUN_LOG" 2>&1
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
  adjudicate_gates
fi
if [ "$rc" -ne 0 ] && grep -q 'code: recover_custody' "$RUN_LOG"; then
  # A terminal run can complete with outcome passed while preserving
  # unpublished pipeline commits in the local gate; its structured
  # next_action prescribes exactly one guarded recovery. Run it so the
  # post-run status read reflects the true pipeline outcome instead of
  # the custody hand-back exit code.
  "$NM_BIN" axi sync --recover >>"$RUN_LOG" 2>&1
fi
set -e
if [ "$rc" -ne 0 ]; then
  # A refused run's one-line error rarely names the failing layer; capture
  # the ground truth the operator otherwise needs a live VM probe to see.
  {
    printf '=== launch diagnostics (exit %s) ===\n' "$rc"
    printf 'pwd: %s\n' "$(pwd)"
    id
    ls -ld "$REPO" "$REPO/.git"
    git -C "$REPO" rev-parse --show-toplevel
    git -C "$REPO" symbolic-ref --short HEAD
    "$NM_BIN" --version
  } >>"$RUN_LOG" 2>&1 || true
fi
printf '%s\n' "$rc" >"$RUN_LOG.exit"
exit 0
SH
chmod 0755 "$LAUNCH"
chown fmvalidate:fmvalidate "$RUN_LOG" 2>/dev/null || true
INTENT_FILE=$STATE/intent.txt
jq -r '.intent' "$REQUEST" >"$INTENT_FILE"
chmod 0600 "$INTENT_FILE"
# The credential helper is executed by fmvalidate's git during fetch/push,
# so it must be owned by the run user like the other run inputs.
chown fmvalidate:fmvalidate "$INTENT_FILE" "$ENV_FILE" "$IDENTITY" "$LAUNCH" "$GIT_HELPER" "$GITHUB_TOKEN_FILE"

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
  --property="ReadWritePaths=$CELL_ROOT" \
  "$LAUNCH" "$ENV_FILE" "$REPO" "$NM_BIN" "$MODE" "$INTENT_FILE" "$RESPONSE_FILE" "$RUN_LOG"

END_EPOCH=$(date +%s)
END_LOAD=$(cat /proc/loadavg)
END_MEM_AVAILABLE_KIB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
RUN_EXIT=$(cat "$RUN_LOG.exit" 2>/dev/null || printf 125)
STATUS_LOG=$LOGS/status-a$ATTEMPT.log
set +e
# shellcheck disable=SC2016  # Inner shell intentionally expands its positional arguments.
# The status read is the sole input to outcome derivation and must run
# inside the repository like the run itself; without the cd it fails with
# "not in a git repository" from the guest's own working directory and
# every outcome derives as failed regardless of the pipeline result.
runuser -u fmvalidate -- /bin/bash -c \
  'set -a; . "$1"; set +a; cd "$3" && exec "$2" axi status' \
  validation-status "$ENV_FILE" "$NM_BIN" "$REPO" >"$STATUS_LOG" 2>&1
STATUS_RC=$?
set -e
RUN_ID=$(grep -hEo '[0-9A-HJKMNP-TV-Z]{26}' "$STATUS_LOG" "$RUN_LOG" | tail -n 1 || true)
if [ -n "$RUN_ID" ]; then
  tmp=$IDENTITY.tmp
  jq --arg run "$RUN_ID" '.run_id=$run' "$IDENTITY" >"$tmp"
  mv "$tmp" "$IDENTITY"
fi
# The pipeline daemon owns the branch and advances it past this checkout
# (document commits, CI-fix commits, monitor rebases are committed and
# pushed from the daemon's own workspace), so the checkout HEAD is not
# the pipeline's final state - generation 050 ground truth: the document
# step's pushed history commit left remote_head one commit ahead of
# current_head and the collect head-freshness invariant refused an
# otherwise checks-passed result. Fast-forward the checkout to the pushed
# branch before capturing heads: only a descendant of the local HEAD is
# accepted, so a foreign or rewritten remote still captures mismatched
# heads and fails collection exactly as before.
if runuser -u fmvalidate -- git -C "$REPO" fetch --quiet origin "refs/heads/$BRANCH" 2>>"$RUN_LOG"; then
  FETCHED=$(git -C "$REPO" rev-parse FETCH_HEAD 2>/dev/null || true)
  if [ -n "$FETCHED" ] && git -C "$REPO" merge-base --is-ancestor HEAD "$FETCHED" 2>/dev/null; then
    runuser -u fmvalidate -- git -C "$REPO" merge --ff-only --quiet "$FETCHED" >>"$RUN_LOG" 2>&1 || true
  fi
fi
CURRENT_HEAD=$(git -C "$REPO" rev-parse HEAD)
CURRENT_TREE=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
REMOTE_HEAD=$(git -C "$REPO" ls-remote --heads origin "refs/heads/$BRANCH" | awk 'NR==1 {print $1}')
tmp=$IDENTITY.tmp
jq --arg head "$CURRENT_HEAD" '.current_head=$head' "$IDENTITY" >"$tmp"
mv "$tmp" "$IDENTITY"

# Clean-shutdown sync: write any provider-refreshed token files back to the
# persistent auth share so the next boot anywhere starts authenticated.
auth_home_push

# The durable no-mistakes database view, not free-form run output or intent,
# owns terminal outcome classification.
OUTCOME=failed
# A run that parked at a gate is a decision, not a failure, and the unit
# teardown kills the in-unit daemon before the status read, so the aborted
# post-mortem status can never say so. The run log's structured gate block
# is authoritative for gate detection; the status read stays authoritative
# for completed outcomes.
# A run parked at a gate when the unit tore down is a decision, not a
# failure - but the daemon marks the run failed on shutdown, so the durable
# status cannot say so (generation 047 ground truth: a rebase-conflict gate
# classified failed). Conversely, an ALREADY-ANSWERED gate leaves awaiting
# lines mid-log while the run continues to a genuine terminal failure
# (generation 041 ground truth: a failed push classified needs-decision).
# The discriminator is whether the run log ENDS parked: after the last
# awaiting line, a still-parked run shows only gate findings and help text,
# while an answered gate is followed by later step rows or terminal lines.
gate_parked=0
last_awaiting=$(grep -nEi 'status:[[:space:]]*awaiting[_ -](approval|user)' "$RUN_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
# A refused respond attempt prints an error line while the gate stays
# parked, so error lines cannot terminate the parked window; only later
# step-progress rows or a rendered run outcome prove the gate was answered.
if [ -n "$last_awaiting" ] && ! tail -n +"$((last_awaiting + 1))" "$RUN_LOG" | grep -Eq ',(completed|failed),|^outcome:'; then
  gate_parked=1
fi
if [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'needs[-_ ]decision|awaiting[_ -]user|awaiting[_ -]approval|ask-user' "$STATUS_LOG"; then
  OUTCOME=needs-decision
elif [ "$gate_parked" = 1 ]; then
  OUTCOME=needs-decision
elif [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'outcome:[[:space:]]*(passed|checks-passed)|checks[- ]passed|checks green' "$STATUS_LOG"; then
  OUTCOME=checks-passed
elif [ "$RUN_EXIT" -eq 0 ] && [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'outcome:[[:space:]]*passed' "$STATUS_LOG"; then
  OUTCOME=passed
elif [ "$STATUS_RC" -eq 0 ] && grep -Eiq 'outcome:[[:space:]]*failed' "$STATUS_LOG"; then
  # The ci step turns green and then stays running to monitor until merge,
  # so unit teardown kills it mid-monitor and the daemon marks the run
  # failed on shutdown - the same teardown artifact the gate discriminator
  # above handles (generation 049 ground truth: every step green, ci
  # verified "all CI checks passed", durable status still failed with
  # "daemon shutting down"). The run command's final rendered outcome is
  # written before teardown, so when the durable failure carries the
  # shutdown signature and the run's own terminal report was
  # checks-passed, the terminal report wins. The LAST outcome line guards
  # against checks that greened mid-run and regressed before the end.
  last_run_outcome=$(grep -Ei '^outcome:' "$RUN_LOG" 2>/dev/null | tail -n 1)
  if [ "$RUN_EXIT" -eq 0 ] && grep -q 'daemon shutting down' "$STATUS_LOG" \
    && printf '%s' "$last_run_outcome" | grep -Eiq 'outcome:[[:space:]]*checks-passed'; then
    OUTCOME=checks-passed
  else
    OUTCOME=failed
  fi
fi
PR=$(grep -hEo 'https://github\.com/[^ /]+/[^ /]+/pull/[0-9]+' "$STATUS_LOG" "$RUN_LOG" | tail -n 1 || true)
CHECKS_GREEN=false
case "$OUTCOME" in passed|checks-passed) CHECKS_GREEN=true ;; esac
SHARD_RECEIPTS=$SHARD_EXCHANGE/receipts.json
[ -f "$SHARD_RECEIPTS" ] || printf '[]\n' >"$SHARD_RECEIPTS"
# A passed outcome asserts the complete independent behavior-shard receipt set
# (docs/azure-validation.md: "A missing ... shard fails the no-mistakes test
# step"). When the bridge never ran, the substituted empty set above turns
# "sharding did not happen" into "passed with no receipts", and the controller
# then refuses the entire result as malformed. That refusal is correct but it
# lands too late to be useful: the cell never reaches `collected`, so it can
# neither close nor be retained on its own outcome, and its worktree disk stays
# allocated with nothing in the result saying why. Demote here instead, where
# the reason is still known.
# Both sentinels are out of band. A numeric default would sit inside the value
# space of real counts, and the obvious choice - zero - is exactly the observed
# value in the failure being guarded, so an unreadable request would compare
# equal to an empty receipt set and wave it through.
SHARD_EXPECTED=$(jq -r 'if (.limits.behavior_shards | type) == "number" then .limits.behavior_shards else "unreadable" end' "$REQUEST" 2>/dev/null || echo unreadable)
SHARD_OBSERVED=$(jq -r 'if type == "array" then length else "unreadable" end' "$SHARD_RECEIPTS" 2>/dev/null || echo unreadable)
SHARD_SHORTFALL=""
case "$OUTCOME" in
  passed|checks-passed)
    # Anything that is not a plain integer is a shortfall, not a comparison to
    # attempt: this fails closed on a truncated request, a malformed receipt
    # file, or a schema that stops emitting an integer count.
    case "$SHARD_EXPECTED" in ''|*[!0-9]*) SHARD_EXPECTED=unreadable ;; esac
    case "$SHARD_OBSERVED" in ''|*[!0-9]*) SHARD_OBSERVED=unreadable ;; esac
    if [ "$SHARD_EXPECTED" = unreadable ] || [ "$SHARD_OBSERVED" = unreadable ] \
      || [ "$SHARD_OBSERVED" -ne "$SHARD_EXPECTED" ]; then
      SHARD_SHORTFALL="expected $SHARD_EXPECTED behavior-shard receipts, found $SHARD_OBSERVED"
      echo "validation guest: $SHARD_SHORTFALL; demoting outcome $OUTCOME to failed" >&2
      OUTCOME=failed
      CHECKS_GREEN=false
    fi
    ;;
esac
install -d -m 0700 -o fmvalidate -g fmvalidate "$EVIDENCE/attempt-$ATTEMPT"
cp "$SHARD_RECEIPTS" "$EVIDENCE/attempt-$ATTEMPT/behavior-shards.json"
# The outcome derivation reads the status log; archive it with the evidence
# so a misclassified outcome is diagnosable from the result alone.
cp "$STATUS_LOG" "$EVIDENCE/attempt-$ATTEMPT/status.log" 2>/dev/null || true
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
  "$(cat /proc/sys/kernel/random/boot_id)" "$OUTCOME" "$CURRENT_HEAD" "$CURRENT_TREE" "$REMOTE_HEAD" "$PR" "$CHECKS_GREEN" "$SHARD_RECEIPTS" "$ATTEMPT" <<'PY'
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
    "run_id": identity.get("run_id"),
    "vm_resource_id": sys.argv[4],
    "vm_instance_id": sys.argv[5],
    "boot_id": sys.argv[6],
    "attempt": int(sys.argv[14]),
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
  if [ -n "$SHARD_SHORTFALL" ]; then
    printf -- "- Behavior shards: \`%s; outcome demoted to failed\`\n" "$SHARD_SHORTFALL"
  fi
  if [ -f "$STATE/auth-needed" ]; then
    printf -- "- Auth: \`interactive provider auth needed once (auth share empty)\`\n"
  fi
  if [ -f "$STATE/auth-push-failed" ]; then
    printf -- "- Auth write-back: \`FAILED - refreshed tokens stayed cell-local and %s is stale\`\n" "$AUTH_SHARE"
  elif [ -f "$STATE/auth-push-owed" ]; then
    printf -- "- Auth write-back: \`SKIPPED - an attempt ended without reaching its clean-shutdown push to %s\`\n" "$AUTH_SHARE"
  fi
} >"$REPORT"

RESULT_ARCHIVE=$BOOTSTRAP/result.tar.gz
rm -f "$RESULT_ARCHIVE"
(
  cd "$STATE"
  # The report already lives at $STATE/report.md, so an unconditional cp is a
  # same-file error that kills packaging after the run completed; guard both
  # protocol members against identity copies.
  [ "$RUN_LOG" -ef run.log ] || cp "$RUN_LOG" run.log
  [ "$REPORT" -ef report.md ] || cp "$REPORT" report.md
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
# The marker binds the published result to the ATTEMPT that produced it. A
# respond/reattach attempt runs on the same VM and the same boot, so boot_id
# and every identity field in result.json are identical across the attempts of
# one run: without the attempt there is nothing a control-plane read can see
# that tells attempt 1's completed marker from attempt 2's own answer
# (generation azv-36b2 ground truth).
printf 'FM_AZURE_VALIDATION_RESULT %s boot=%s outcome=%s attempt=%s\n' "$RESULT_DIGEST" "$BOOT_ID" "$OUTCOME" "$ATTEMPT"
