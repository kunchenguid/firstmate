#!/usr/bin/env bash
# Trusted root-side controller. The repository command runs in a separate
# systemd network namespace and never receives the managed-identity token.
set -euo pipefail
umask 077

# Managed Run Command delivers parameters as environment variables named
# after each declared parameter, never as positional arguments; the
# validation cell guest proved this contract live.
[ "$#" -eq 0 ] || { echo "guest bootstrap: positional parameters are forbidden" >&2; exit 125; }
REQUEST_B64=${request_b64:-}
VM_RESOURCE_ID=${vm_resource_id:-}
VM_INSTANCE_ID=${vm_instance_id:-}
GUEST_DIGEST=${guest_digest:-}
STORAGE_ACCOUNT=${storage_account:-}
CONTAINER=${container:-}
OUTPUT_BLOB=${output_blob:-}
INPUT_BLOB=${input_blob:-}
IDENTITY_CLIENT_ID=${identity_client_id:-}
EXECUTOR_B64=${executor_b64:-}
unset request_b64 vm_resource_id vm_instance_id guest_digest storage_account
unset container output_blob input_blob identity_client_id executor_b64
for bound in "$REQUEST_B64" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID" "$GUEST_DIGEST" "$STORAGE_ACCOUNT" "$CONTAINER" "$OUTPUT_BLOB" "$INPUT_BLOB" "$IDENTITY_CLIENT_ID" "$EXECUTOR_B64"; do
  [ -n "$bound" ] || { echo "guest bootstrap: expected ten bound parameters" >&2; exit 125; }
done
unset bound
case "$GUEST_DIGEST" in sha256:[0-9a-f][0-9a-f]*) ;; *) echo "guest bootstrap: bad protocol digest" >&2; exit 125 ;; esac
case "$STORAGE_ACCOUNT" in [a-z0-9][a-z0-9]*) ;; *) echo "guest bootstrap: bad storage name" >&2; exit 125 ;; esac
[ "$CONTAINER" = validation-shards ] || { echo "guest bootstrap: bad result container" >&2; exit 125; }
case "$OUTPUT_BLOB" in *..*|/*|*//*|*[!A-Za-z0-9._/@:-]*) echo "guest bootstrap: bad result blob" >&2; exit 125 ;; esac
case "$INPUT_BLOB" in none) ;; *..*|/*|*//*|*[!A-Za-z0-9._/@:-]*) echo "guest bootstrap: bad input blob" >&2; exit 125 ;; esac
[[ "$IDENTITY_CLIENT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "guest bootstrap: bad identity client id" >&2; exit 125; }
[ -n "$VM_RESOURCE_ID" ] && [ -n "$VM_INSTANCE_ID" ] || { echo "guest bootstrap: missing VM identity" >&2; exit 125; }

for tool in ip tc curl git python3 sha256sum tar systemd-run jq setsid; do
  command -v "$tool" >/dev/null 2>&1 || { echo "guest bootstrap: pinned image lacks $tool" >&2; exit 125; }
done
EGRESS_DEVICE=$(ip -o route show default | awk 'NR==1 {print $5}')
[ -n "$EGRESS_DEVICE" ] || { echo "guest bootstrap: default egress device unavailable" >&2; exit 125; }
tc qdisc replace dev "$EGRESS_DEVICE" root tbf rate 1mbit burst 32kbit latency 400ms
BOOTSTRAP_NETWORK_BYTE_CEILING=17179869184
BOOTSTRAP_NETWORK_START=$(( $(<"/sys/class/net/$EGRESS_DEVICE/statistics/rx_bytes") + $(<"/sys/class/net/$EGRESS_DEVICE/statistics/tx_bytes") ))
run_bootstrap_network() {
  local pid status current
  setsid "$@" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    current=$(( $(<"/sys/class/net/$EGRESS_DEVICE/statistics/rx_bytes") + $(<"/sys/class/net/$EGRESS_DEVICE/statistics/tx_bytes") ))
    if [ $((current - BOOTSTRAP_NETWORK_START)) -gt "$BOOTSTRAP_NETWORK_BYTE_CEILING" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true; sleep 1; kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "guest bootstrap: trusted-bootstrap network byte ceiling exceeded" >&2; exit 125
    fi
    sleep 0.1
  done
  if wait "$pid"; then status=0; else status=$?; fi
  return "$status"
}

# BEGIN FM_AZURE_RUNNER_APT_LOCK_HELPERS
wait_for_apt_locks() {
  local timeout=$1 poll=$2
  shift 2
  python3 - "$timeout" "$poll" "$@" <<'PY'
import errno
import fcntl
import os
import pathlib
import sys
import time

timeout = float(sys.argv[1])
poll = float(sys.argv[2])
paths = [pathlib.Path(value) for value in sys.argv[3:]]
if not 0 <= timeout <= 600 or not 0.01 <= poll <= 5 or not paths:
    raise SystemExit("guest bootstrap: unsafe apt/dpkg lock wait configuration")
deadline = time.monotonic() + timeout
while True:
    descriptors = []
    held = []
    try:
        for path in paths:
            try:
                descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
            except FileNotFoundError:
                continue
            descriptors.append(descriptor)
            try:
                fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as exc:
                if exc.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                held.append(str(path))
        if not held:
            raise SystemExit(0)
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        print(
            "guest bootstrap: timed out waiting for apt/dpkg lock(s): "
            + ", ".join(held),
            file=sys.stderr,
        )
        raise SystemExit(1)
    time.sleep(min(poll, remaining))
PY
}

APT_LOCK_WAIT_SECONDS=180
APT_LOCK_PATHS=(
  /var/lib/dpkg/lock-frontend
  /var/lib/dpkg/lock
  /var/cache/apt/archives/lock
  /var/lib/apt/lists/lock
)
run_bootstrap_apt() {
  local deadline=$((SECONDS + APT_LOCK_WAIT_SECONDS)) remaining stderr_file status
  stderr_file=$(mktemp)
  while true; do
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      echo "guest bootstrap: timed out retrying apt/dpkg lock contention" >&2
      rm -f "$stderr_file"
      return 1
    fi
    wait_for_apt_locks "$remaining" 0.2 "${APT_LOCK_PATHS[@]}" || {
      rm -f "$stderr_file"
      return 1
    }
    : >"$stderr_file"
    if run_bootstrap_network apt-get -o "DPkg::Lock::Timeout=$remaining" "$@" 2>"$stderr_file"; then
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 0
    else
      status=$?
    fi
    cat "$stderr_file" >&2
    if ! grep -Eq 'Could not (get|open) lock |Unable to acquire (the )?(dpkg frontend|download directory|lists directory|archive) lock|is another process using it' "$stderr_file"; then
      rm -f "$stderr_file"
      return "$status"
    fi
  done
}
# END FM_AZURE_RUNNER_APT_LOCK_HELPERS

missing=()
for tool in mkfs.ext4 mount runuser groupadd useradd getent tmux node npm xz; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
if [ "${#missing[@]}" -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  bootstrap_packages() {
    run_bootstrap_apt update -qq &&
    run_bootstrap_apt install -y --no-install-recommends ca-certificates curl git python3 python3-venv e2fsprogs util-linux passwd systemd tmux jq nodejs npm xz-utils ripgrep
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

BASE=/var/lib/fm-azure-runner
rm -rf "$BASE"
install -d -m 0700 -o root -g root "$BASE"
REQUEST=$BASE/request.json
EXECUTOR=$BASE/runner-exec.py
printf '%s' "$REQUEST_B64" | base64 -d >"$REQUEST"
printf '%s' "$EXECUTOR_B64" | base64 -d >"$EXECUTOR"
unset REQUEST_B64 EXECUTOR_B64

python3 - "$REQUEST" "$EXECUTOR" "$GUEST_DIGEST" <<'PY'
import hashlib, json, pathlib, sys
request_path, executor_path = map(pathlib.Path, sys.argv[1:3])
request = json.loads(request_path.read_text(encoding="utf-8"))
unsigned = dict(request); supplied = unsigned.pop("request_digest", None)
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
if supplied != "sha256:" + hashlib.sha256(canonical).hexdigest(): raise SystemExit("guest bootstrap: request digest mismatch")
if "sha256:" + hashlib.sha256(executor_path.read_bytes()).hexdigest() != request["protocol"]["executor_digest"]: raise SystemExit("guest bootstrap: executor digest mismatch")
if request["protocol"]["guest_digest"] != sys.argv[3]: raise SystemExit("guest bootstrap: guest digest mismatch")
repo = request["repository"]
if repo.get("source_mode") not in ("public-github-https", "private-parent-bundle", "private-exact-bundle") or not repo.get("remote", "").startswith("https://github.com/"): raise SystemExit("guest bootstrap: source mode mismatch")
if repo.get("source_mode") in ("private-parent-bundle", "private-exact-bundle"):
    if not repo.get("input_blob") or not repo.get("snapshot_digest") or not repo.get("snapshot_bytes"): raise SystemExit("guest bootstrap: private snapshot binding is incomplete")
else:
    if repo.get("input_blob") is not None or repo.get("snapshot_bytes") != 0: raise SystemExit("guest bootstrap: public source carries private staging")
limits = request["limits"]
hard = {"cpu_cores": (1,8), "memory_bytes": (2**30,56*2**30), "pid_max": (16,4096), "disk_bytes": (2**30,52*2**30), "log_bytes": (1024,32*2**20), "artifact_bytes": (0,512*2**20), "network_bytes": (0,0), "wall_seconds": (1,14400)}
for name, bounds in hard.items():
    value=limits.get(name)
    if not isinstance(value,int) or not bounds[0] <= value <= bounds[1]: raise SystemExit("guest bootstrap: unsafe resource request " + name)
PY

read_request() { python3 - "$REQUEST" "$1" <<'PY'
import json,sys
value=json.load(open(sys.argv[1],encoding="utf-8"))
for part in sys.argv[2].split("."): value=value[part]
print(value)
PY
}
INVOCATION=$(read_request invocation); COMMIT=$(read_request repository.commit); TREE=$(read_request repository.tree)
REMOTE=$(read_request repository.remote); SOURCE_MODE=$(read_request repository.source_mode)
SOURCE_REF=$(read_request repository.source_ref); SOURCE_HEAD=$(read_request repository.source_head)
CPU_CORES=$(read_request limits.cpu_cores); MEMORY_BYTES=$(read_request limits.memory_bytes)
PID_MAX=$(read_request limits.pid_max); DISK_BYTES=$(read_request limits.disk_bytes); WALL_SECONDS=$(read_request limits.wall_seconds)
ARTIFACT_BYTES=$(read_request limits.artifact_bytes); NETWORK_BYTES=$(read_request limits.network_bytes)

WORK_IMAGE=$BASE/work.ext4
truncate -s "$DISK_BYTES" "$WORK_IMAGE"; mkfs.ext4 -q -F "$WORK_IMAGE"
install -d -m 0700 -o root -g root /work; mount -o loop,nodev,nosuid "$WORK_IMAGE" /work
trap 'umount /work 2>/dev/null || true; rm -rf "$BASE"' EXIT
getent group fmrunner >/dev/null 2>&1 || groupadd --system fmrunner
id fmrunner >/dev/null 2>&1 || useradd --system --gid fmrunner --home-dir /work/home --shell /usr/sbin/nologin fmrunner
RUNNER_UID=$(id -u fmrunner); RUNNER_GID=$(id -g fmrunner)
install -d -m 0700 -o fmrunner -g fmrunner /work/home /work/repo /work/home/.fm-runner-tools/bin /work/home/.fm-runner-tools/uv /work/home/.fm-runner-tools/wheelhouse
# Same-device temp root for the repository command: the executor unit's
# PrivateTmp puts /tmp on its own tmpfs, which breaks tests that hard-link
# between their temp root and the work mount (generation 051 ground
# truth). Owned by the runner user and closed to everyone else: a
# world-writable mode here trips the repository's own path guard, which
# requires root sticky protection on world-writable ancestors
# (generation 052 ground truth). Created here because the unconfined
# bootstrap can always guarantee it; the executor only points TMPDIR at it.
install -d -m 0700 -o fmrunner -g fmrunner /work/tmp
chown fmrunner:fmrunner /work

runuser -u fmrunner -- git -C /work/repo init -q
runuser -u fmrunner -- git -C /work/repo remote add origin "$REMOTE"
# Root's read-only identity verification would refuse the runner-owned
# repository as dubious (CVE-2022-24765); scope the exception through the
# environment exactly as the validation cell guest does.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/work/repo
if [ "$SOURCE_MODE" = private-parent-bundle ] || [ "$SOURCE_MODE" = private-exact-bundle ]; then
  [ "$INPUT_BLOB" = "$(read_request repository.input_blob)" ] || { echo "guest bootstrap: private snapshot blob mismatch" >&2; exit 125; }
  SNAPSHOT=$BASE/snapshot.bundle
  TOKEN_FILE=$BASE/input-token
  run_bootstrap_network curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 10 -H Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=$IDENTITY_CLIENT_ID" \
    | jq -er .access_token >"$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
  DOWNLOAD_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${INPUT_BLOB}"
  run_bootstrap_network curl --fail --silent --show-error --connect-timeout 30 --max-time 1800 \
    --max-filesize "$(read_request repository.snapshot_bytes)" \
    -H "Authorization: Bearer $(<"$TOKEN_FILE")" -H 'x-ms-version: 2023-11-03' \
    --output "$SNAPSHOT" "$DOWNLOAD_URL"
  rm -f "$TOKEN_FILE"
  [ "$(stat -c %s "$SNAPSHOT")" = "$(read_request repository.snapshot_bytes)" ] \
    && [ "sha256:$(sha256sum "$SNAPSHOT" | awk '{print $1}')" = "$(read_request repository.snapshot_digest)" ] \
    || { echo "guest bootstrap: private snapshot digest/size mismatch" >&2; exit 125; }
  # The bootstrap base is root-only (umask 077), unreadable to the
  # unprivileged fetch; the digest-verified snapshot moves onto the
  # runner-owned work filesystem for the fetch and is removed after it.
  install -m 0400 -o fmrunner -g fmrunner "$SNAPSHOT" /work/snapshot.bundle
  rm -f "$SNAPSHOT"
  runuser -u fmrunner -- git -C /work/repo fetch /work/snapshot.bundle "$COMMIT"
  rm -f /work/snapshot.bundle
elif [ "$SOURCE_REF" != none ] && [ "$SOURCE_HEAD" = "$COMMIT" ]; then
  [ "$INPUT_BLOB" = none ] || { echo "guest bootstrap: public source received a private snapshot blob" >&2; exit 125; }
  run_bootstrap_network runuser -u fmrunner -- git -C /work/repo fetch --depth=1 origin "$SOURCE_REF"
  [ "$(git -C /work/repo rev-parse FETCH_HEAD)" = "$COMMIT" ] || { echo "guest bootstrap: source ref moved after admission" >&2; exit 125; }
else
  [ "$INPUT_BLOB" = none ] || { echo "guest bootstrap: public source received a private snapshot blob" >&2; exit 125; }
  run_bootstrap_network runuser -u fmrunner -- git -C /work/repo fetch --depth=1 origin "$COMMIT"
fi
runuser -u fmrunner -- git -C /work/repo checkout --detach "$COMMIT" >/dev/null
python3 - "$REQUEST" <<'PY' >"$BASE/source-ancestors"
import json,sys
for value in json.load(open(sys.argv[1],encoding="utf-8"))["repository"].get("source_ancestors", []): print(value)
PY
while IFS= read -r ancestor; do
  [ -n "$ancestor" ] || continue
  if [ "$SOURCE_MODE" = public-github-https ]; then
    run_bootstrap_network runuser -u fmrunner -- git -C /work/repo fetch --depth=1 origin "$ancestor"
    [ "$(git -C /work/repo rev-parse FETCH_HEAD)" = "$ancestor" ] || { echo "guest bootstrap: source ancestor identity mismatch" >&2; exit 125; }
    git -C /work/repo cat-file -e "$ancestor^{commit}" || { echo "guest bootstrap: source ancestor is absent" >&2; exit 125; }
  fi
done <"$BASE/source-ancestors"
if [ "$SOURCE_MODE" = private-parent-bundle ] || [ "$SOURCE_MODE" = private-exact-bundle ]; then
  /usr/bin/python3 "$EXECUTOR" --verify-private-source-ancestors "$REQUEST" /work/repo
fi
[ "$(git -C /work/repo rev-parse HEAD)" = "$COMMIT" ] && [ "$(git -C /work/repo rev-parse 'HEAD^{tree}')" = "$TREE" ] || { echo "guest bootstrap: source identity mismatch" >&2; exit 125; }
# Repository tests compare the snapshot against the default branch through
# the refs/remotes/origin view (generation 051 ground truth: a behavior
# shard died on "ambiguous argument 'refs/remotes/origin/main'"), but a
# bundle fetch materializes no remote-tracking refs. Recreate the admitted
# default-branch identity exactly: prefer the commit already in the
# snapshot history, otherwise fetch it by admitted digest exactly like
# source ancestors, and refuse anything that resolves differently.
DEFAULT_REF=$(read_request repository.default_ref)
DEFAULT_HEAD=$(read_request repository.default_head)
if [ "$DEFAULT_REF" != none ] && [ "$DEFAULT_HEAD" != none ]; then
  case "$DEFAULT_REF" in refs/heads/?*) DEFAULT_NAME=${DEFAULT_REF#refs/heads/} ;; *) DEFAULT_NAME= ;; esac
  if [ -n "$DEFAULT_NAME" ]; then
    if ! git -C /work/repo cat-file -e "$DEFAULT_HEAD^{commit}" 2>/dev/null; then
      run_bootstrap_network runuser -u fmrunner -- git -C /work/repo fetch --depth=1 origin "$DEFAULT_HEAD"
      [ "$(git -C /work/repo rev-parse FETCH_HEAD)" = "$DEFAULT_HEAD" ] || { echo "guest bootstrap: default head identity mismatch" >&2; exit 125; }
    fi
    runuser -u fmrunner -- git -C /work/repo update-ref "refs/remotes/origin/$DEFAULT_NAME" "$DEFAULT_HEAD"
    runuser -u fmrunner -- git -C /work/repo symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT_NAME"
  fi
fi

fetch_exact() { local url=$1 path=$2 bytes=$3 digest=$4 redirects=${5:-no} args=(); [ "$redirects" != yes ] || args+=(--location); run_bootstrap_network curl --fail --silent --show-error "${args[@]}" --connect-timeout 30 --max-time 300 --max-filesize "$bytes" --output "$path" "$url"; [ "$(stat -c %s "$path")" = "$bytes" ] && [ "sha256:$(sha256sum "$path" | awk '{print $1}')" = "$digest" ] || { echo "guest bootstrap: pinned download mismatch" >&2; exit 125; }; }
# The golden image stages the pinned archives under /opt/fm-tools; a copy
# whose byte-exact digest matches the admitted request skips the network
# fetch, and anything else falls through to the pinned download. The
# digest requirement is identical either way, so the image is a cache of
# the provenance chain, never a substitute for it.
staged_or_fetch() { local staged=$1 url=$2 path=$3 bytes=$4 digest=$5 redirects=${6:-no}
  if [ -f "$staged" ] && [ "$(stat -c %s "$staged")" = "$bytes" ] && [ "sha256:$(sha256sum "$staged" | awk '{print $1}')" = "$digest" ]; then
    cp "$staged" "$path"
    return 0
  fi
  fetch_exact "$url" "$path" "$bytes" "$digest" "$redirects"
}
staged_or_fetch /opt/fm-tools/shellcheck.tar.xz https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz "$BASE/shellcheck.tar.xz" 2559196 "$(read_request protocol.shellcheck_archive_digest)" yes
staged_or_fetch /opt/fm-tools/uv.tar.gz https://github.com/astral-sh/uv/releases/download/0.9.10/uv-x86_64-unknown-linux-gnu.tar.gz "$BASE/uv.tar.gz" 21427164 "$(read_request protocol.uv_archive_digest)" yes
tar -xJf "$BASE/shellcheck.tar.xz" -C "$BASE"; tar -xzf "$BASE/uv.tar.gz" -C "$BASE"
install -m 0755 -o fmrunner -g fmrunner "$BASE/shellcheck-v0.11.0/shellcheck" /work/home/.fm-runner-tools/bin/shellcheck
install -m 0755 -o fmrunner -g fmrunner "$BASE/uv-x86_64-unknown-linux-gnu/uv" /work/home/.fm-runner-tools/uv/uv
install -m 0755 -o fmrunner -g fmrunner "$BASE/uv-x86_64-unknown-linux-gnu/uvx" /work/home/.fm-runner-tools/uv/uvx
python3 - "$REQUEST" <<'PY' >"$BASE/wheels.tsv"
import json,sys
for item in json.load(open(sys.argv[1],encoding="utf-8"))["protocol"]["agent_fleet_python"]["wheels"]: print("\t".join((item["url"],item["file"],str(item["bytes"]),item["digest"])))
PY
while IFS=$'\t' read -r url file bytes digest; do
  case "$url" in https://files.pythonhosted.org/packages/*.whl) ;; *) echo "guest bootstrap: wheel origin mismatch" >&2; exit 125 ;; esac
  fetch_exact "$url" "/work/home/.fm-runner-tools/wheelhouse/$file" "$bytes" "$digest"
done <"$BASE/wheels.tsv"
chown -R fmrunner:fmrunner /work/home/.fm-runner-tools
LOCK_DIGEST=$(read_request protocol.agent_fleet_python.lock_digest)
if [ "$LOCK_DIGEST" != None ]; then
  [ "sha256:$(sha256sum /work/repo/tools/agent-fleet/uv.lock | awk '{print $1}')" = "$LOCK_DIGEST" ] || { echo "guest bootstrap: lock mismatch" >&2; exit 125; }
  # The run-command handler's download directory is root-only, so the
  # unprivileged uv invocations must not inherit it as their working
  # directory (uv's config discovery reads ./uv.toml and refuses on EACCES).
  cd /work/repo
  runuser -u fmrunner -- /work/home/.fm-runner-tools/uv/uv venv --python /usr/bin/python3 /work/repo/tools/agent-fleet/.venv >/dev/null
  runuser -u fmrunner -- env UV_OFFLINE=1 UV_NO_INDEX=1 /work/home/.fm-runner-tools/uv/uv pip install --python /work/repo/tools/agent-fleet/.venv/bin/python --offline --no-index --find-links /work/home/.fm-runner-tools/wheelhouse pytest ruff >/dev/null
elif [ -s "$BASE/wheels.tsv" ]; then
  echo "guest bootstrap: unbound Python wheels" >&2
  exit 125
fi

python3 - "$REQUEST" /work/repo <<'PY'
import hashlib,json,pathlib,sys
r=json.load(open(sys.argv[1],encoding="utf-8")); root=pathlib.Path(sys.argv[2]).resolve()
def identity(path):
    if path.is_file(): return "sha256:"+hashlib.sha256(path.read_bytes()).hexdigest(),path.stat().st_size
    h=hashlib.sha256(); total=0
    for child in sorted(path.rglob("*")):
        if child.is_symlink(): raise SystemExit("guest bootstrap: linked dependency")
        if child.is_file():
            rel=child.relative_to(root).as_posix().encode(); dig=hashlib.sha256(child.read_bytes()).hexdigest().encode(); size=child.stat().st_size; total+=size
            h.update(len(rel).to_bytes(4,"big")); h.update(rel); h.update(dig); h.update(size.to_bytes(8,"big"))
    return "sha256:"+h.hexdigest(),total
for item in r.get("dependencies",[]):
    path=(root/item["path"]).resolve()
    if root not in path.parents or not path.exists() or path.is_symlink() or identity(path)!=(item["digest"],item["bytes"]): raise SystemExit("guest bootstrap: dependency mismatch")
PY

mount -o remount,hidepid=2 /proc
OUTPUT=$BASE/output; install -d -m 0700 -o root -g root "$OUTPUT"
UNIT=fm-azure-runner-${INVOCATION//:/-}
set +e
systemd-run --quiet --wait --collect --unit "$UNIT" --property=Type=exec --property=KillMode=control-group \
  --property="CPUQuota=$((CPU_CORES * 100))%" --property="MemoryMax=$MEMORY_BYTES" --property=MemorySwapMax=0 \
  --property="TasksMax=$PID_MAX" --property="RuntimeMaxSec=$((WALL_SECONDS + 60))" --property=NoNewPrivileges=yes \
  --property=PrivateNetwork=yes --property=RestrictAddressFamilies=AF_UNIX --property=IPAddressDeny=any \
  --property=PrivateTmp=yes --property=PrivateDevices=yes --property=ProtectSystem=strict --property=ProtectHome=yes \
  --property=ProtectKernelTunables=yes --property=ProtectKernelModules=yes --property=ProtectControlGroups=yes \
  --property=RestrictRealtime=yes --property=RestrictSUIDSGID=yes --property=LockPersonality=yes \
  --property='CapabilityBoundingSet=CAP_SETUID CAP_SETGID' --property=AmbientCapabilities= \
  --property=TimeoutStopSec=15 --property="ReadWritePaths=/work $OUTPUT" /usr/bin/python3 "$EXECUTOR" "$REQUEST" /work/repo "$OUTPUT" "$RUNNER_UID" "$RUNNER_GID" "$VM_RESOURCE_ID" "$VM_INSTANCE_ID"
EXECUTOR_STATUS=$?
set -e
[ "$NETWORK_BYTES" -eq 0 ] || { echo "guest bootstrap: isolated executor failed" >&2; exit 125; }
if [ "$EXECUTOR_STATUS" -ne 0 ]; then
  # Lingering repository-test daemons can hold the cgroup past stop-sigterm
  # and fail the unit after the executor already finished its protocol; the
  # executor writes its result atomically as its last act, so that result is
  # the authority and only its absence makes the unit status fatal.
  [ -s "$OUTPUT/result.json" ] || { echo "guest bootstrap: isolated executor failed" >&2; exit 125; }
fi

python3 - "$REQUEST" /work/repo "$OUTPUT" "$ARTIFACT_BYTES" <<'PY'
import hashlib,json,os,pathlib,shutil,stat,sys
r=json.load(open(sys.argv[1],encoding="utf-8")); repo=pathlib.Path(sys.argv[2]).resolve(); out=pathlib.Path(sys.argv[3]).resolve(); limit=int(sys.argv[4]); records=[]; total=0
for relative in r.get("artifacts",[]):
    source=(repo/relative).resolve()
    if repo not in source.parents or not source.exists() or source.is_symlink(): raise SystemExit("guest bootstrap: bad artifact")
    for path in ([source] if source.is_file() else sorted(p for p in source.rglob("*") if p.is_file())):
        if path.is_symlink() or not stat.S_ISREG(path.stat(follow_symlinks=False).st_mode): raise SystemExit("guest bootstrap: linked artifact")
        rel=path.relative_to(repo).as_posix(); size=path.stat().st_size; total+=size
        if total>limit: raise SystemExit("guest bootstrap: artifact bound exceeded")
        dest=out/"artifacts"/rel; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(path,dest)
        records.append({"path":rel,"bytes":size,"digest":"sha256:"+hashlib.sha256(dest.read_bytes()).hexdigest()})
p=out/"result.json"; result=json.loads(p.read_text()); result["artifacts"]=records
payload=json.dumps(result,sort_keys=True,separators=(",", ":"),ensure_ascii=False).encode()+b"\n"
if len(payload)>1800: raise SystemExit("guest bootstrap: bounded control-plane result envelope exceeded")
tmp=out/".result.tmp"; tmp.write_bytes(payload); os.replace(tmp,p)
PY
RESULT_ARCHIVE=$BASE/result.tar.gz
( cd "$OUTPUT"; paths=(result.json stdout.log stderr.log); [ ! -d artifacts ] || paths+=(artifacts); tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$RESULT_ARCHIVE" "${paths[@]}" )
RESULT_DIGEST=sha256:$(sha256sum "$RESULT_ARCHIVE" | awk '{print $1}')

# Only the trusted wrapper now obtains a token. No token, SAS, environment, or
# open descriptor existed while repository code ran in its private namespace.
TOKEN_FILE=$BASE/storage-token
run_bootstrap_network curl --fail --silent --show-error --noproxy '*' --connect-timeout 2 --max-time 10 -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=$IDENTITY_CLIENT_ID" \
  | jq -er .access_token >"$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"
UPLOAD_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${OUTPUT_BLOB}"
run_bootstrap_network curl --fail --silent --show-error --connect-timeout 30 --max-time 600 -X PUT \
  -H "Authorization: Bearer $(<"$TOKEN_FILE")" -H 'x-ms-version: 2023-11-03' -H 'x-ms-blob-type: BlockBlob' \
  -H "x-ms-meta-result_digest: ${RESULT_DIGEST#sha256:}" --upload-file "$RESULT_ARCHIVE" "$UPLOAD_URL"
run_bootstrap_network curl --fail --silent --show-error --head --connect-timeout 30 --max-time 60 \
  -H "Authorization: Bearer $(<"$TOKEN_FILE")" -H 'x-ms-version: 2023-11-03' "$UPLOAD_URL" >"$BASE/result-head"
grep -qi "^x-ms-meta-result_digest: ${RESULT_DIGEST#sha256:}" "$BASE/result-head" || { echo "guest bootstrap: uploaded result verification failed" >&2; exit 125; }
rm -f "$TOKEN_FILE" "$BASE/result-head"
RESULT_B64=$(base64 -w0 "$OUTPUT/result.json")
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
printf 'FM_AZURE_RESULT %s boot=%s result=%s\n' "$RESULT_DIGEST" "$BOOT_ID" "$RESULT_B64"
