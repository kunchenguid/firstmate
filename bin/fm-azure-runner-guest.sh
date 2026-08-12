#!/usr/bin/env bash
# Trusted root-side Azure Managed Run Command payload.
# Protected parameters arrive as the last two positional values and are cleared
# before repository-controlled code starts. The child receives no Azure, GitHub,
# model-provider, browser, reviewer, author, control-home, or peer credentials.
set -euo pipefail
umask 077

[ "$#" -eq 6 ] || { echo "guest bootstrap: expected six bound parameters" >&2; exit 125; }
INPUT_DIGEST=$1
VM_RESOURCE_ID=$2
VM_INSTANCE_ID=$3
GUEST_DIGEST=$4
INPUT_URL=$5
OUTPUT_URL=$6
set --

case "$INPUT_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "guest bootstrap: bad input digest" >&2; exit 125 ;; esac
case "$GUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "guest bootstrap: bad protocol digest" >&2; exit 125 ;; esac
[ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] || { echo "guest bootstrap: missing VM identity" >&2; exit 125; }
case "$INPUT_URL" in https://*) ;; *) echo "guest bootstrap: input capability is not HTTPS" >&2; exit 125 ;; esac
case "$OUTPUT_URL" in https://*) ;; *) echo "guest bootstrap: output capability is not HTTPS" >&2; exit 125 ;; esac

# Install only this hard-coded Ubuntu transport/Linux-test closure before any
# repository bytes execute. Repository code never controls apt or gets root.
# All bootstrap traffic ends before the untrusted networkless command starts.
missing=()
for tool in curl git python3 sha256sum tar systemd-run mkfs.ext4 mount runuser groupadd useradd getent tmux jq node npm xz; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    ca-certificates curl git python3 python3-pip python3-venv e2fsprogs util-linux passwd systemd \
    tmux jq nodejs npm xz-utils ripgrep
fi
for tool in curl git python3 sha256sum tar systemd-run mkfs.ext4 mount runuser groupadd useradd getent tmux jq node npm xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "guest bootstrap: fixed tool closure is incomplete: $tool" >&2; exit 125; }
done

BASE=/var/lib/fm-azure-runner
rm -rf "$BASE"
install -d -m 0700 -o root -g root "$BASE"
INPUT=$BASE/input.tar.gz
CURL_CONFIG=$BASE/curl-input.conf
printf 'url = "%s"\nfail\nsilent\nshow-error\noutput = "%s"\n' "$INPUT_URL" "$INPUT" >"$CURL_CONFIG"
unset INPUT_URL
curl --config "$CURL_CONFIG"
rm -f "$CURL_CONFIG"
ACTUAL_INPUT=sha256:$(sha256sum "$INPUT" | awk '{print $1}')
[ "$ACTUAL_INPUT" = "$INPUT_DIGEST" ] || { echo "guest bootstrap: staged input digest mismatch" >&2; exit 125; }

python3 - "$INPUT" "$BASE" <<'PY'
import pathlib
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
allowed = {"request.json", "snapshot.bundle", "runner-exec.py"}
with tarfile.open(source, "r:gz") as archive:
    members = archive.getmembers()
    if {member.name for member in members} != allowed:
        raise SystemExit("guest bootstrap: input archive file set mismatch")
    for member in members:
        if not member.isfile() or member.issym() or member.islnk() or member.isdev():
            raise SystemExit("guest bootstrap: input archive contains a non-file")
        if member.size > 1024 * 1024 * 1024:
            raise SystemExit("guest bootstrap: input member exceeds one GiB")
    archive.extractall(destination, members=members)
PY

REQUEST=$BASE/request.json
BUNDLE=$BASE/snapshot.bundle
EXECUTOR=$BASE/runner-exec.py
python3 - "$REQUEST" "$BUNDLE" "$EXECUTOR" "$GUEST_DIGEST" <<'PY'
import hashlib
import json
import pathlib
import sys

request_path, bundle_path, executor_path = map(pathlib.Path, sys.argv[1:4])
expected_guest = sys.argv[4]
request = json.loads(request_path.read_text(encoding="utf-8"))
unsigned = dict(request)
supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != "sha256:" + hashlib.sha256(canonical).hexdigest():
    raise SystemExit("guest bootstrap: request digest mismatch")
def digest(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
if digest(bundle_path) != request["repository"]["snapshot_digest"]:
    raise SystemExit("guest bootstrap: bundle digest mismatch")
if digest(executor_path) != request["protocol"]["executor_digest"]:
    raise SystemExit("guest bootstrap: executor digest mismatch")
if request["protocol"]["guest_digest"] != expected_guest:
    raise SystemExit("guest bootstrap: guest protocol digest mismatch")
limits = request["limits"]
hard = {
    "cpu_cores": (1, 8), "memory_bytes": (1024**3, 56 * 1024**3),
    "pid_max": (16, 4096), "disk_bytes": (1024**3, 52 * 1024**3),
    "log_bytes": (1024, 32 * 1024**2), "artifact_bytes": (0, 512 * 1024**2),
    "network_bytes": (0, 0), "wall_seconds": (1, 14400),
}
for name, (minimum, maximum) in hard.items():
    value = limits.get(name)
    if not isinstance(value, int) or not minimum <= value <= maximum:
        raise SystemExit("guest bootstrap: unsafe resource request " + name)
PY

read_request() {
  python3 - "$REQUEST" "$1" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}
INVOCATION=$(read_request invocation)
COMMIT=$(read_request repository.commit)
TREE=$(read_request repository.tree)
CPU_CORES=$(read_request limits.cpu_cores)
MEMORY_BYTES=$(read_request limits.memory_bytes)
PID_MAX=$(read_request limits.pid_max)
DISK_BYTES=$(read_request limits.disk_bytes)
WALL_SECONDS=$(read_request limits.wall_seconds)
ARTIFACT_BYTES=$(read_request limits.artifact_bytes)
NETWORK_BYTES=$(read_request limits.network_bytes)

# A loop-mounted task filesystem bounds repository, dependencies, temp, and all
# untrusted writes independently of the root/bootstrap filesystem.
WORK_IMAGE=$BASE/work.ext4
truncate -s "$DISK_BYTES" "$WORK_IMAGE"
mkfs.ext4 -q -F "$WORK_IMAGE"
install -d -m 0700 -o root -g root /work
mount -o loop,nodev,nosuid "$WORK_IMAGE" /work
trap 'umount /work 2>/dev/null || true; rm -rf "$BASE"' EXIT

if ! getent group fmrunner >/dev/null 2>&1; then
  groupadd --system fmrunner
fi
if ! id fmrunner >/dev/null 2>&1; then
  useradd --system --gid fmrunner --home-dir /work/home --shell /usr/sbin/nologin fmrunner
fi
RUNNER_UID=$(id -u fmrunner)
RUNNER_GID=$(id -g fmrunner)
install -d -m 0700 -o fmrunner -g fmrunner /work/home /work/repo
chown fmrunner:fmrunner /work
runuser -u fmrunner -- git clone --no-local "$BUNDLE" /work/repo >/dev/null
runuser -u fmrunner -- git -C /work/repo checkout --detach "$COMMIT" >/dev/null
[ "$(git -C /work/repo rev-parse HEAD)" = "$COMMIT" ] || { echo "guest bootstrap: commit mismatch after clone" >&2; exit 125; }
[ "$(git -C /work/repo rev-parse 'HEAD^{tree}')" = "$TREE" ] || { echo "guest bootstrap: tree mismatch after clone" >&2; exit 125; }
[ -z "$(git -C /work/repo status --porcelain --untracked-files=all)" ] || { echo "guest bootstrap: cloned snapshot is dirty" >&2; exit 125; }

python3 - "$REQUEST" /work/repo <<'PY'
import hashlib
import json
import pathlib
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
repo = pathlib.Path(sys.argv[2]).resolve()
def file_digest(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_size
def tree_digest(path):
    digest = hashlib.sha256()
    total = 0
    for child in sorted(path.rglob("*")):
        if child.is_symlink():
            raise SystemExit("guest bootstrap: dependency contains symlink")
        if child.is_file():
            relative = child.relative_to(repo).as_posix().encode()
            content = hashlib.sha256(child.read_bytes()).hexdigest().encode()
            size = child.stat().st_size
            total += size
            digest.update(len(relative).to_bytes(4, "big"))
            digest.update(relative)
            digest.update(content)
            digest.update(size.to_bytes(8, "big"))
    return "sha256:" + digest.hexdigest(), total
for item in request.get("dependencies", []):
    path = (repo / item["path"]).resolve()
    if repo not in path.parents or not path.exists() or path.is_symlink():
        raise SystemExit("guest bootstrap: dependency path mismatch")
    actual = file_digest(path) if path.is_file() else tree_digest(path)
    if [actual[0], actual[1]] != [item["digest"], item["bytes"]]:
        raise SystemExit("guest bootstrap: dependency digest mismatch")
PY

# Hide root process environments and reject metadata from the command cgroup.
mount -o remount,hidepid=2 /proc
OUTPUT=$BASE/output
rm -rf "$OUTPUT"
UNIT=fm-azure-runner-${INVOCATION//:/-}
set +e
systemd-run --quiet --wait --collect --unit "$UNIT" \
  --property=Type=exec \
  --property=KillMode=control-group \
  --property="CPUQuota=$((CPU_CORES * 100))%" \
  --property="MemoryMax=$MEMORY_BYTES" \
  --property=MemorySwapMax=0 \
  --property="TasksMax=$PID_MAX" \
  --property="RuntimeMaxSec=$((WALL_SECONDS + 60))" \
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
  --property=IPAddressDeny=any \
  --property="ReadWritePaths=/work $BASE" \
  /usr/bin/python3 "$EXECUTOR" "$REQUEST" /work/repo "$OUTPUT" \
  "$RUNNER_UID" "$RUNNER_GID" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID"
EXECUTOR_STATUS=$?
set -e
[ "$NETWORK_BYTES" -eq 0 ] || { echo "guest bootstrap: only the reviewed networkless command contract is supported" >&2; exit 125; }
[ "$EXECUTOR_STATUS" -eq 0 ] || { echo "guest bootstrap: bounded executor failed before result publication" >&2; exit 125; }

# Copy only declared artifact paths, reject links/devices, enforce the aggregate
# artifact bound, and add exact artifact digests to the trusted result record.
python3 - "$REQUEST" /work/repo "$OUTPUT" "$ARTIFACT_BYTES" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
import stat
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
repo = pathlib.Path(sys.argv[2]).resolve()
output = pathlib.Path(sys.argv[3]).resolve()
limit = int(sys.argv[4])
artifact_root = output / "artifacts"
records = []
total = 0
for relative in request.get("artifacts", []):
    source = (repo / relative).resolve()
    if repo not in source.parents or not source.exists() or source.is_symlink():
        raise SystemExit("guest bootstrap: declared artifact is missing, escaping, or linked")
    paths = [source] if source.is_file() else sorted(path for path in source.rglob("*") if path.is_file())
    for path in paths:
        if path.is_symlink() or not stat.S_ISREG(path.stat(follow_symlinks=False).st_mode):
            raise SystemExit("guest bootstrap: artifact tree contains a non-regular file")
        item_relative = path.relative_to(repo).as_posix()
        size = path.stat().st_size
        total += size
        if total > limit:
            raise SystemExit("guest bootstrap: artifact bytes exceed bound")
        destination = artifact_root / item_relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "rb") as source_handle, open(destination, "xb") as destination_handle:
            shutil.copyfileobj(source_handle, destination_handle, 1024 * 1024)
        digest = "sha256:" + hashlib.sha256(destination.read_bytes()).hexdigest()
        records.append({"path": item_relative, "bytes": size, "digest": digest})
result_path = output / "result.json"
result = json.loads(result_path.read_text(encoding="utf-8"))
result["artifacts"] = records
payload = json.dumps(result, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
temp = output / ".result.tmp"
with open(temp, "xb") as handle:
    handle.write(payload)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temp, result_path)
PY

RESULT_ARCHIVE=$BASE/result.tar.gz
(
  cd "$OUTPUT"
  archive_paths=(result.json stdout.log stderr.log)
  [ ! -d artifacts ] || archive_paths+=(artifacts)
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$RESULT_ARCHIVE" "${archive_paths[@]}"
)
RESULT_DIGEST=sha256:$(sha256sum "$RESULT_ARCHIVE" | awk '{print $1}')
CURL_CONFIG=$BASE/curl-output.conf
printf 'url = "%s"\nfail\nsilent\nshow-error\nrequest = "PUT"\nheader = "x-ms-blob-type: BlockBlob"\nupload-file = "%s"\n' "$OUTPUT_URL" "$RESULT_ARCHIVE" >"$CURL_CONFIG"
unset OUTPUT_URL
curl --config "$CURL_CONFIG"
rm -f "$CURL_CONFIG"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf 'FM_AZURE_RESULT %s boot=%s\n' "$RESULT_DIGEST" "$BOOT_ID"
