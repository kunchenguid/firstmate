#!/usr/bin/env python3
"""Queue and drive exact-head no-mistakes runs on isolated Azure cells.

This host controller never executes a repository validation command. It may use
Git to bind and bundle a clean exact head, Azure CLI to create/control private
capacity, and storage data-plane calls to exchange digest-bound protocol files.
The durable contract is documented in docs/azure-validation.md.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-validation" / "cell.json"
GUEST = ROOT / "bin" / "fm-azure-validation-guest.sh"
SHARD_BRIDGE = ROOT / "bin" / "fm-azure-validation-shard-bridge.py"
CREDENTIAL_EXPIRY = ROOT / "bin" / "fm-credential-expiry.py"
CONTAINER = "validation-shards"
SCHEMA = "fm.azure-validation/v1"
PURGE_SCHEMA = "fm.azure-validation-purge/v1"
RESULT_SCHEMA = "fm.azure-validation-result/v1"
CREDENTIALS_SCHEMA = "fm.azure-validation-credentials/v1"
RUNTIME_SCHEMA = "fm.azure-validation-runtime/v1"
RUNTIME_MANIFEST_FIELDS = frozenset({
    "schema", "provider", "no_mistakes_version", "no_mistakes_path",
    "provider_path", "gh_path", "node_path", "gh_axi_path",
    "gh_axi_entrypoint", "gh_axi_closure", "files",
})
RUNTIME_FILE_FIELDS = frozenset({"path", "digest"})
NO_MISTAKES_VERSION = re.compile(
    r"^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"
)
GH_AXI_WRAPPER = (
    b"#!/usr/bin/env bash\n"
    b"# Runtime-bundle wrapper: bind gh-axi to the bundled Node interpreter.\n"
    b"set -euo pipefail\n"
    b'runtime_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)\n'
    b'exec "$runtime_root/bin/node" "$runtime_root/gh-axi/dist/bin/gh-axi.js" "$@"\n'
)
GH_AXI_ENTRYPOINT = "gh-axi/dist/bin/gh-axi.js"
JS_MODULE_SPECIFIER = re.compile(
    r"""
    (?:\b(?:import|export)\s+(?:[^;]*?\s+from\s+)?[\"']([^\"']+)[\"'])
    |(?:\bimport\s*\(\s*[\"']([^\"']+)[\"']\s*\))
    |(?:\brequire\s*\(\s*[\"']([^\"']+)[\"']\s*\))
    """,
    re.VERBOSE,
)
NODE_BUILTINS = {
    "assert", "assert/strict", "async_hooks", "buffer", "child_process",
    "cluster", "console", "constants", "crypto", "dgram", "diagnostics_channel",
    "dns", "dns/promises", "domain", "events", "fs", "fs/promises", "http",
    "http2", "https", "module", "net", "os", "path", "path/posix",
    "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline",
    "readline/promises", "repl", "stream", "stream/consumers", "stream/promises",
    "stream/web", "string_decoder", "sys", "timers", "timers/promises", "tls",
    "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi",
    "worker_threads", "zlib",
}
# Byte-identical to CELL_HOST_CAPABILITY_DECLARATION in
# bin/fm-azure-validation-shard-bridge.py. This side is the refusal: a behavior
# shard command that does not carry exactly this declaration is not the sealed
# planner route, so the cell cannot quietly widen or drop the skip set.
CELL_HOST_CAPABILITY_DECLARATION = (
    "FM_TEST_HOST_CAPABILITIES_ABSENT="
    "real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress"
)
# Azure firstmate is powered entirely by pi-codex; the single claude profile
# exists only for the cross-check lane. Add further providers here only when
# a lane actually consumes them.
PROVIDERS = ("codex", "claude")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
SAFE_CELL = re.compile(r"^azv-[a-z0-9]{12}$")
HEX_OBJECT = re.compile(r"^[0-9a-f]{40,64}$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
PR_URL = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*$")
NM_RUN_ID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
RUNNER_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a[2-9][0-9]*)?$")
# The authenticated result marker. `attempt` is required: every other field
# a control-plane read can see is identical across the attempts of one run
# (same VM, same boot, same run id), so without it an unbound view cannot be
# told from this attempt's own answer.
MARKER = re.compile(
    r"FM_AZURE_VALIDATION_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})"
    r"\s+outcome=([a-z-]+)\s+attempt=([0-9]{1,18})"
)
# The pre-attempt marker shape. A guest sealed into a cell BEFORE the attempt
# stamp existed cannot be changed (the request is digest-sealed), so its output
# must stay readable or every cell in flight across that upgrade is stranded.
# Only consulted when the output carries no stamped marker at all: MARKER's
# prefix is exactly this shape, so a stamped marker would match it too.
LEGACY_MARKER = re.compile(
    r"FM_AZURE_VALIDATION_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})"
    r"\s+outcome=([a-z-]+)"
)
# Whether a guest CAN name its attempt is a property of the guest, read from the
# sealed bytes that actually run. It must never be inferred from whether a
# marker parsed: LEGACY_MARKER is MARKER minus the attempt group, so ANY
# malformation of the attempt field satisfies "no stamped marker matched".
GUEST_STAMPS_ATTEMPT = re.compile(r"^[^\n]*FM_AZURE_VALIDATION_RESULT[^\n]*attempt=", re.MULTILINE)
MARKER_SETTLE_SECONDS = 300
RUNTIME_HYDRATION_TIMEOUT_SECONDS = 1800
# Shard transports legitimately run VM creation plus admission plus command
# submission in one subprocess: near 300 seconds unloaded and well past it
# under any operator-host load. The old 300-second cap manufactured
# failed-retained shards whenever two transports ran concurrently
# (generations 044/046 ground truth); 900 still bounds a genuine hang.
LOCAL_TIMEOUT = 900
REGIONAL_ADMISSION_CEILING_VCPUS = 128
BUDGET_TARGET_USD = 1000.0
BUDGET_CEILING_USD = 1500.0
MAX_CELL_LIFETIME_HOURS = 24
FOUNDATION_METER_RESERVE_USD = 210.0
VALIDATION_METER_RESERVE_USD = 80.0
BLOB_DATA_CONTRIBUTOR_ROLE = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
# Storage File Data Privileged Contributor: the role OAuth FileREST access
# needs so the per-cell UAMI can sync the persistent fm-auth-home share.
FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE = "69566ab7-960f-475b-8e7c-b3118f30c6bd"

# Control cells use the allocator's reviewed eight-vCPU control lane inside
# the same unrestricted v6 families as the fleet; the old v5 candidates are
# NotAvailableForSubscription in East US and their family collides with the
# pilot supervisor. Live SKU, capability, and retail evidence is re-read
# before every allocation; family and regional capacity are adjudicated only
# by the shared allocator's atomic shape admission.
VALIDATION_SKUS = (
    "Standard_D8as_v6",
    "Standard_D8s_v6",
    "Standard_D8ads_v6",
    "Standard_D8ds_v6",
)

# Coordinator SKU spread: four concurrent coordinator cells cannot share one
# family cap, so lane index maps deterministically onto four reviewed
# eight-vCPU SKUs in four distinct families (Dasv6, Dsv6, Dadsv6, Ddsv6).
COORDINATOR_SKU_POOL = VALIDATION_SKUS

# Phases in which a cell occupies a dispatch lane (compute exists or is
# reserved). Queued, collected, closed, and retained-failure cells do not.
LANE_PHASES = (
    "starting", "running", "reattaching", "responding",
    "needs-decision", "result-published",
)

RESOURCE_CLASSES = {
    "validation-heavy": {
        "vcpus": 8,
        "memory_gib": 32,
        "memory_max_bytes": 28 * 1024**3,
        "tasks_max": 8192,
        "worktree_gib": 256,
        "wall_seconds": 6 * 3600,
        "behavior_shards": 8,
    },
    "validation-standard": {
        "vcpus": 8,
        "memory_gib": 32,
        "memory_max_bytes": 24 * 1024**3,
        "tasks_max": 4096,
        "worktree_gib": 192,
        "wall_seconds": 3 * 3600,
        "behavior_shards": 4,
    },
}

FORBIDDEN_RUNTIME_COMPONENTS = frozenset({
    ".azure", ".claude", ".codex", ".credentials", ".credentials.json",
    ".docker", ".env", ".git-credentials", ".netrc", ".npmrc", ".pypirc",
    ".ssh", "auth.json", "cookies", "credentials", "credentials.json",
    "hosts.yml", "keychain",
})
FORBIDDEN_RUNTIME_PATHS = ((".config", "gh"),)
FORBIDDEN_RUNTIME_STEMS = frozenset({
    "access_key", "access_token", "access_tokens", "accesskey", "accesstoken",
    "accesstokens", "api_key", "apikey", "auth", "authentication",
    "authorization", "client_secret", "client_secrets", "clientsecret",
    "clientsecrets", "cookie", "cookies", "credential", "credentials",
    "private_key", "private_keys", "privatekey", "privatekeys", "id_dsa",
    "id_ecdsa", "id_ed25519", "id_rsa", "oauth_token", "passphrase",
    "passphrases", "passwd", "password", "passwords", "refresh_token",
    "refresh_tokens", "refreshtoken", "refreshtokens", "secret", "secret_key",
    "secret_keys", "secretkey", "secretkeys", "secrets", "token", "tokens",
})
FORBIDDEN_RUNTIME_COMPACT_SUFFIXES = frozenset(
    value.replace("_", "") for value in FORBIDDEN_RUNTIME_STEMS
)
FORBIDDEN_RUNTIME_DATA_SUFFIXES = (
    ".conf", ".ini", ".json", ".toml", ".txt", ".yaml", ".yml",
)
FORBIDDEN_RUNTIME_KEY_SUFFIXES = (
    ".jks", ".key", ".keystore", ".p12", ".pem", ".pfx",
)
SAFE_RUNTIME_CODE_SUFFIXES = (
    ".c", ".cc", ".cjs", ".cpp", ".d.ts", ".go", ".h", ".hpp", ".js",
    ".map", ".md", ".mjs", ".py", ".rs", ".ts",
)
RESOURCE_API = {
    "vm": "2024-03-01",
    "nic": "2023-09-01",
    "disk": "2023-10-02",
    "run-command": "2024-03-01",
    "identity": "2023-01-31",
    "ttl-schedule": "2018-09-15",
    "container": "2023-05-01",
}
RUNNER_SHARD_SKUS = (
    "Standard_D4as_v6", "Standard_D4as_v7", "Standard_D4s_v6",
    "Standard_D4ads_v7", "Standard_D4ds_v6", "Standard_D4s_v7",
    "Standard_D4ds_v7", "Standard_D4ads_v6",
)


class ValidationError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def sha256_hex(value):
    return hashlib.sha256(value).hexdigest()


def sha256_bytes(value):
    return "sha256:" + sha256_hex(value)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return "sha256:" + digest.hexdigest()
            digest.update(block)


class DuplicateJSONKey(ValueError):
    pass


def reject_duplicate_json_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateJSONKey("duplicate JSON key: {}".format(key))
        value[key] = item
    return value


def strict_json_loads(value, label):
    try:
        return json.loads(value, object_pairs_hook=reject_duplicate_json_pairs)
    except (json.JSONDecodeError, DuplicateJSONKey) as exc:
        raise ValidationError(
            "{} is not valid duplicate-free JSON: {}".format(label, exc)
        )


def runtime_path_is_unsafe(name):
    raw = str(name)
    components = normalized_runtime_components(raw)
    return bool(
        not raw
        or "\x00" in raw
        or raw.startswith(("/", "\\"))
        or ".." in components
    )


def normalized_runtime_components(name):
    return tuple(
        component.casefold()
        for component in raw_runtime_components(name)
    )


def raw_runtime_components(name):
    return tuple(
        component
        for component in str(name).replace("\\", "/").split("/")
        if component not in ("", ".")
    )


def normalized_runtime_credential_stem(component):
    candidate = component
    for suffix in FORBIDDEN_RUNTIME_DATA_SUFFIXES:
        if candidate.casefold().endswith(suffix):
            candidate = candidate[:-len(suffix)]
            break
    candidate = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", candidate)
    candidate = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", candidate)
    return re.sub(
        r"[^a-z0-9]+", "_", candidate.casefold().strip(".")
    ).strip("_")


def compact_runtime_credential_stem(component):
    candidate = component
    for suffix in FORBIDDEN_RUNTIME_DATA_SUFFIXES:
        if candidate.casefold().endswith(suffix):
            candidate = candidate[:-len(suffix)]
            break
    return re.sub(r"[^a-z0-9]+", "", candidate.casefold().strip("."))


def runtime_path_is_credential_like(name):
    raw_components = raw_runtime_components(name)
    components = tuple(component.casefold() for component in raw_components)
    forbidden_path = any(
        tuple(components[index:index + len(path)]) == path
        for path in FORBIDDEN_RUNTIME_PATHS
        for index in range(len(components) - len(path) + 1)
    )
    for raw_component, component in zip(raw_components, components):
        if component in FORBIDDEN_RUNTIME_COMPONENTS:
            return True
        if component.startswith(".env."):
            return True
        if component.endswith(FORBIDDEN_RUNTIME_KEY_SUFFIXES):
            return True
        stem = normalized_runtime_credential_stem(raw_component)
        compact_stem = compact_runtime_credential_stem(raw_component)
        if (
            not component.endswith(SAFE_RUNTIME_CODE_SUFFIXES)
            and (
                any(
                    stem == value or "_{}_".format(value) in "_{}_".format(stem)
                    for value in FORBIDDEN_RUNTIME_STEMS
                )
                or any(
                    compact_stem.endswith(value)
                    for value in FORBIDDEN_RUNTIME_COMPACT_SUFFIXES
                )
            )
        ):
            return True
    return forbidden_path


def require_runtime_input_path(name):
    if runtime_path_is_unsafe(name):
        raise ValidationError("runtime bundle input path is unsafe: {}".format(name))
    if runtime_path_is_credential_like(name):
        raise ValidationError(
            "runtime bundle input has a credential-like path: {}".format(name)
        )


def require_runtime_source_path(source, label):
    normalized = os.path.abspath(str(Path(source).expanduser()))
    canonical = os.path.realpath(normalized)
    if (
        runtime_path_is_credential_like(normalized)
        or runtime_path_is_credential_like(canonical)
    ):
        raise ValidationError(
            "{} source has a credential-like path: {}".format(label, source)
        )


@contextlib.contextmanager
def open_runtime_path_no_follow(source, label, directory=False):
    absolute = Path(os.path.abspath(str(Path(source).expanduser())))
    parts = absolute.parts
    if not parts or parts[0] != os.path.sep or len(parts) < 2:
        raise ValidationError("{} path is not an absolute file path".format(label))
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags = flags | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    descriptor = None
    try:
        descriptor = os.open(os.path.sep, directory_flags)
        for component in parts[1:-1]:
            child = os.open(
                component,
                directory_flags | nofollow,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
        final_flags = flags | nofollow
        if directory:
            final_flags |= getattr(os, "O_DIRECTORY", 0)
        child = os.open(parts[-1], final_flags, dir_fd=descriptor)
        os.close(descriptor)
        descriptor = child
        yield descriptor
    except OSError as exc:
        raise ValidationError(
            "{} path must exist without symlink components: {}".format(label, exc)
        )
    finally:
        if descriptor is not None:
            os.close(descriptor)


def runtime_source_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
    )


def linux_x86_64_elf_header_is_valid(header):
    return bool(
        len(header) >= 20
        and header[:4] == b"\x7fELF"
        and header[4] == 2
        and header[5] == 1
        and header[7] in (0, 3)
        and int.from_bytes(header[16:18], "little") in (2, 3)
        and int.from_bytes(header[18:20], "little") == 62
    )


@contextlib.contextmanager
def open_runtime_source(source, expected, label="runtime bundle input"):
    require_runtime_source_path(source, label)
    with open_runtime_path_no_follow(source, label) as descriptor:
        observed = os.fstat(descriptor)
        if (
            not stat.S_ISREG(observed.st_mode)
            or runtime_source_identity(observed) != expected
        ):
            raise ValidationError(
                "runtime bundle input changed while it was being packaged: {}".format(
                    source
                )
            )
        with os.fdopen(os.dup(descriptor), "rb") as handle:
            yield handle
            if runtime_source_identity(os.fstat(handle.fileno())) != expected:
                raise ValidationError(
                    "runtime bundle input changed while it was being packaged: {}".format(
                        source
                    )
                )
def require_linux_x86_64_elf(source, expected, label):
    with open_runtime_source(source, expected, label) as handle:
        header = handle.read(20)
    if not linux_x86_64_elf_header_is_valid(header):
        raise ValidationError(
            "{} must be a Linux x86-64 ELF executable".format(label)
        )


def runtime_file_record(source, name, label, executable=False, elf=False):
    require_runtime_input_path(name)
    require_runtime_source_path(source, label)
    source, observed = regular_runtime_source(source, label)
    if observed.st_size > 512 * 1024**2:
        raise ValidationError("{} exceeds 512 MiB".format(label))
    if executable and observed.st_mode & 0o111 == 0:
        raise ValidationError("{} must be executable".format(label))
    expected = runtime_source_identity(observed)
    if elf:
        require_linux_x86_64_elf(source, expected, label)
    digest = hashlib.sha256()
    with open_runtime_source(source, expected, label) as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return {
        "name": name,
        "source": source,
        "identity": expected,
        "size": observed.st_size,
        "mode": 0o755 if observed.st_mode & 0o111 else 0o644,
        "digest": "sha256:" + digest.hexdigest(),
    }


def runtime_bytes_record(name, value, mode):
    require_runtime_input_path(name)
    return {
        "name": name,
        "data": value,
        "size": len(value),
        "mode": mode,
        "digest": sha256_bytes(value),
    }


def read_runtime_record(record, label, maximum_bytes):
    if record["size"] > maximum_bytes:
        raise ValidationError("{} exceeds {} bytes".format(label, maximum_bytes))
    if "data" in record:
        value = record["data"][:maximum_bytes + 1]
    elif "archive" in record:
        handle = record["archive"].extractfile(record["member"])
        if handle is None:
            raise ValidationError("{} is not a regular archive member".format(label))
        value = handle.read(maximum_bytes + 1)
    else:
        with open_runtime_source(record["source"], record["identity"]) as handle:
            value = handle.read(maximum_bytes + 1)
    if len(value) > maximum_bytes:
        raise ValidationError("{} exceeds {} bytes".format(label, maximum_bytes))
    return value


def read_runtime_json_record(record, label):
    try:
        source = read_runtime_record(record, label, 1024 * 1024).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError("{} is not valid UTF-8 JSON: {}".format(label, exc))
    value = strict_json_loads(source, label)
    if not isinstance(value, dict):
        raise ValidationError("{} must contain a JSON object".format(label))
    return value


def normalize_runtime_module_path(directory, relative, label):
    if not relative or relative.startswith("/"):
        raise ValidationError("{} is unsafe: {}".format(label, relative))
    normalized = posixpath.normpath(posixpath.join(directory, relative))
    if normalized == ".." or normalized.startswith("../"):
        raise ValidationError("{} escapes the gh-axi package: {}".format(label, relative))
    return normalized


def runtime_module_target(records_by_name, candidate, label):
    candidates = [candidate]
    if not posixpath.splitext(candidate)[1]:
        candidates.extend(
            candidate + suffix for suffix in (".js", ".mjs", ".cjs", ".json")
        )
        candidates.extend(
            posixpath.join(candidate, name)
            for name in ("index.js", "index.mjs", "index.cjs", "index.json")
        )
    for name in candidates:
        if name in records_by_name:
            return name
    raise ValidationError("{} is absent: {}".format(label, candidate))


def package_name_and_subpath(specifier):
    parts = specifier.split("/")
    if specifier.startswith("@"):
        if len(parts) < 2 or not parts[0] or not parts[1]:
            raise ValidationError("gh-axi import has a malformed package name: {}".format(specifier))
        return "/".join(parts[:2]), "/".join(parts[2:])
    return parts[0], "/".join(parts[1:])


def package_export_target(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        for candidate in value:
            resolved = package_export_target(candidate)
            if resolved is not None:
                return resolved
        return None
    if isinstance(value, dict):
        for key in ("import", "node", "default", "require"):
            if key in value:
                resolved = package_export_target(value[key])
                if resolved is not None:
                    return resolved
    return None


def package_entry_relative(manifest, subpath, label):
    exports = manifest.get("exports")
    if exports is not None:
        selected = exports
        if isinstance(exports, dict) and any(str(key).startswith(".") for key in exports):
            key = "." if not subpath else "./" + subpath
            if key not in exports:
                raise ValidationError("{} does not export {}".format(label, key))
            selected = exports[key]
        elif subpath:
            raise ValidationError("{} does not export ./{}".format(label, subpath))
        target = package_export_target(selected)
        if target is None:
            raise ValidationError("{} has no Node import target".format(label))
    elif subpath:
        target = "./" + subpath
    else:
        target = manifest.get("module") or manifest.get("main") or "./index.js"
    if not isinstance(target, str) or not target.startswith("./"):
        raise ValidationError("{} has an unsafe package entry".format(label))
    return target


def javascript_without_comments(source):
    """Mask JavaScript comments while preserving strings and byte positions."""
    masked = list(source)
    index = 0
    quote = None
    escaped = False
    while index < len(masked):
        character = masked[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == quote:
                quote = None
            index += 1
            continue
        if character in ("'", '"', "`"):
            quote = character
            index += 1
            continue
        if character != "/" or index + 1 >= len(masked):
            index += 1
            continue
        following = masked[index + 1]
        if following == "/":
            masked[index] = masked[index + 1] = " "
            index += 2
            while index < len(masked) and masked[index] not in ("\r", "\n"):
                masked[index] = " "
                index += 1
            continue
        if following == "*":
            masked[index] = masked[index + 1] = " "
            index += 2
            while index < len(masked):
                if (
                    masked[index] == "*"
                    and index + 1 < len(masked)
                    and masked[index + 1] == "/"
                ):
                    masked[index] = masked[index + 1] = " "
                    index += 2
                    break
                if masked[index] not in ("\r", "\n"):
                    masked[index] = " "
                index += 1
            continue
        index += 1
    return "".join(masked)


def validate_gh_axi_runtime(records):
    records_by_name = {record["name"]: record for record in records}
    root_manifest_name = "gh-axi/package.json"
    if root_manifest_name not in records_by_name:
        raise ValidationError("gh-axi package is missing package.json")
    root_manifest = read_runtime_json_record(
        records_by_name[root_manifest_name], "gh-axi package.json"
    )
    if root_manifest.get("name") != "gh-axi":
        raise ValidationError("gh-axi package.json has the wrong package name")
    package_bin = root_manifest.get("bin")
    if (
        not isinstance(package_bin, dict)
        or package_bin.get("gh-axi") != "./dist/bin/gh-axi.js"
    ):
        raise ValidationError("gh-axi package.json does not bind the runtime entrypoint")
    if GH_AXI_ENTRYPOINT not in records_by_name:
        raise ValidationError(
            "gh-axi package is missing the runtime entrypoint dist/bin/gh-axi.js"
        )

    package_manifests = {"gh-axi": root_manifest}
    package_queue = [("gh-axi", "gh-axi", root_manifest)]
    module_queue = [GH_AXI_ENTRYPOINT]
    visited_modules = set()
    visited_packages = set()

    def resolve_package(specifier, importer):
        package_name, subpath = package_name_and_subpath(specifier)
        importer_directory = posixpath.dirname(importer)
        parts = importer_directory.split("/")
        package_root = None
        package_manifest_name = None
        for length in range(len(parts), 0, -1):
            candidate_root = "/".join(parts[:length] + ["node_modules", package_name])
            candidate_manifest = candidate_root + "/package.json"
            if candidate_manifest in records_by_name:
                package_root = candidate_root
                package_manifest_name = candidate_manifest
                break
        if package_root is None or package_manifest_name is None:
            raise ValidationError(
                "gh-axi package dependency is absent for import {} from {}".format(
                    specifier, importer
                )
            )
        if package_root not in package_manifests:
            manifest = read_runtime_json_record(
                records_by_name[package_manifest_name],
                "gh-axi dependency {} package.json".format(package_name),
            )
            if manifest.get("name") != package_name:
                raise ValidationError(
                    "gh-axi dependency {} has the wrong package name".format(package_name)
                )
            package_manifests[package_root] = manifest
            package_queue.append((package_root, package_root, manifest))
        manifest = package_manifests[package_root]
        target = package_entry_relative(
            manifest,
            subpath,
            "gh-axi dependency {}".format(package_name),
        )
        candidate = normalize_runtime_module_path(
            package_root,
            target,
            "gh-axi dependency {} entry".format(package_name),
        )
        package_prefix = package_root.rstrip("/") + "/"
        if (
            candidate != package_root
            and not candidate.startswith(package_prefix)
        ):
            raise ValidationError(
                "gh-axi dependency {} entry escapes its package root: {}".format(
                    package_name, target
                )
            )
        return runtime_module_target(
            records_by_name,
            candidate,
            "gh-axi package entry",
        )

    while package_queue or module_queue:
        while package_queue:
            identity, importer_root, manifest = package_queue.pop()
            if identity in visited_packages:
                continue
            visited_packages.add(identity)
            dependencies = manifest.get("dependencies", {})
            if not isinstance(dependencies, dict):
                raise ValidationError("gh-axi package dependencies must be an object")
            peers = manifest.get("peerDependencies", {})
            if not isinstance(peers, dict):
                raise ValidationError("gh-axi package peerDependencies must be an object")
            peer_meta = manifest.get("peerDependenciesMeta", {})
            if not isinstance(peer_meta, dict):
                raise ValidationError("gh-axi package peerDependenciesMeta must be an object")
            required = set(dependencies)
            required.update(
                name
                for name in peers
                if not isinstance(peer_meta.get(name), dict)
                or not peer_meta[name].get("optional")
            )
            importer = importer_root + "/package.json"
            for dependency in sorted(required):
                module_queue.append(resolve_package(dependency, importer))

        if not module_queue:
            continue
        module_name = module_queue.pop()
        if module_name in visited_modules:
            continue
        visited_modules.add(module_name)
        if posixpath.splitext(module_name)[1] not in (".js", ".mjs", ".cjs"):
            continue
        try:
            source = read_runtime_record(
                records_by_name[module_name],
                "gh-axi JavaScript module {}".format(module_name),
                16 * 1024 * 1024,
            ).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValidationError(
                "gh-axi JavaScript module {} is not UTF-8: {}".format(module_name, exc)
            )
        for match in JS_MODULE_SPECIFIER.finditer(
            javascript_without_comments(source)
        ):
            specifier = next(value for value in match.groups() if value is not None)
            if specifier.startswith("node:") or specifier in NODE_BUILTINS:
                continue
            if specifier.startswith(("./", "../")):
                candidate = normalize_runtime_module_path(
                    posixpath.dirname(module_name),
                    specifier,
                    "gh-axi import target",
                )
                module_queue.append(
                    runtime_module_target(
                        records_by_name,
                        candidate,
                        "gh-axi import target",
                    )
                )
            elif specifier.startswith(("/", "#")):
                raise ValidationError(
                    "gh-axi import target is unsupported: {}".format(specifier)
                )
            else:
                module_queue.append(resolve_package(specifier, module_name))
    return sorted(
        visited_modules
        | {package_root + "/package.json" for package_root in visited_packages}
    )


def collect_gh_axi_runtime(package):
    package = Path(package).expanduser()
    require_runtime_source_path(package, "gh-axi package")
    try:
        package_stat = os.lstat(str(package))
    except OSError as exc:
        raise ValidationError("gh-axi package is unreadable: {}".format(exc))
    if not stat.S_ISDIR(package_stat.st_mode):
        raise ValidationError("gh-axi package must be a symlink-free directory")
    with open_runtime_path_no_follow(
        package, "gh-axi package", directory=True
    ) as descriptor:
        if runtime_source_identity(os.fstat(descriptor)) != runtime_source_identity(
            package_stat
        ):
            raise ValidationError("gh-axi package changed during validation")
    records = []

    def visit(directory, relative):
        try:
            entries = sorted(os.scandir(str(directory)), key=lambda entry: entry.name)
        except OSError as exc:
            raise ValidationError("gh-axi package is unreadable: {}".format(exc))
        for entry in entries:
            child_relative = relative / entry.name
            name = "gh-axi/" + child_relative.as_posix()
            require_runtime_input_path(name)
            try:
                entry_stat = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ValidationError(
                    "gh-axi package entry is unreadable: {}: {}".format(name, exc)
                )
            if stat.S_ISLNK(entry_stat.st_mode):
                raise ValidationError(
                    "gh-axi package contains a symlink: {}".format(name)
                )
            if stat.S_ISDIR(entry_stat.st_mode):
                visit(Path(entry.path), child_relative)
            elif stat.S_ISREG(entry_stat.st_mode):
                records.append(
                    runtime_file_record(
                        Path(entry.path), name, "gh-axi package file {}".format(name)
                    )
                )
            else:
                raise ValidationError(
                    "gh-axi package entry is not a regular file or directory: {}".format(
                        name
                    )
                )

    visit(package, Path())
    closure = validate_gh_axi_runtime(records)
    return records, closure


def runtime_tar_info(name, size, mode):
    info = tarfile.TarInfo(name=name)
    info.type = tarfile.REGTYPE
    info.size = size
    info.mode = mode
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = 0
    return info


def output_path_exists(path):
    return path.exists() or path.is_symlink()


def regular_runtime_source(path, label, maximum_bytes=None):
    source = Path(path).expanduser()
    require_runtime_source_path(source, label)
    try:
        observed = os.lstat(str(source))
    except OSError as exc:
        raise ValidationError("{} is unreadable: {}".format(label, exc))
    if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
        raise ValidationError("{} must be a regular file with one link".format(label))
    if maximum_bytes is not None and observed.st_size > maximum_bytes:
        raise ValidationError("{} exceeds the one-GiB bound".format(label))
    with open_runtime_path_no_follow(source, label) as descriptor:
        if runtime_source_identity(os.fstat(descriptor)) != runtime_source_identity(
            observed
        ):
            raise ValidationError("{} changed during validation".format(label))
    return source, observed


def copy_identity_pinned_runtime(source, destination, label, expected_digest=None):
    source, observed = regular_runtime_source(source, label, 1024**3)
    expected = runtime_source_identity(observed)
    destination = Path(destination)
    descriptor = None
    completed = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(str(destination), flags, 0o600)
        with open_runtime_source(source, expected) as input_handle:
            with os.fdopen(descriptor, "wb") as output_handle:
                descriptor = None
                shutil.copyfileobj(input_handle, output_handle, 1024 * 1024)
                output_handle.flush()
                os.fsync(output_handle.fileno())
        copied = os.lstat(str(destination))
        if (
            not stat.S_ISREG(copied.st_mode)
            or copied.st_nlink != 1
            or copied.st_size != observed.st_size
        ):
            raise ValidationError("{} private copy changed during staging".format(label))
        digest = hashlib.sha256()
        with open_runtime_source(destination, runtime_source_identity(copied)) as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        copied_digest = "sha256:" + digest.hexdigest()
        if expected_digest is not None and copied_digest != expected_digest:
            raise ValidationError("{} private copy digest mismatch".format(label))
        completed = True
        return copied_digest
    except OSError as exc:
        raise ValidationError("{} private copy failed: {}".format(label, exc))
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if not completed:
            # A partial or mismatching copy is never available to payload assembly.
            with contextlib.suppress(OSError):
                destination.unlink()


@contextlib.contextmanager
def staged_runtime_bundle(env, source):
    ensure_dirs(env)
    staging_root = env["state_dir"] / ".runtime-staging"
    staging_root.mkdir(mode=0o700, exist_ok=True)
    os.chmod(staging_root, 0o700)
    directory = Path(tempfile.mkdtemp(prefix="runtime.", dir=str(staging_root)))
    os.chmod(directory, 0o700)
    staged = directory / "runtime.tar.gz"
    try:
        copy_identity_pinned_runtime(source, staged, "runtime bundle")
        yield staged
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def build_runtime_bundle(args):
    if not NO_MISTAKES_VERSION.fullmatch(args.no_mistakes_version):
        raise ValidationError(
            "--no-mistakes-version must be the exact artifact version"
        )
    output = Path(args.output).expanduser()
    if not output.name:
        raise ValidationError("runtime bundle output must name a file")
    output = Path(os.path.abspath(str(output)))
    if not output.parent.is_dir():
        raise ValidationError("runtime bundle output directory does not exist")
    if output_path_exists(output):
        raise ValidationError("runtime bundle output already exists")
    records = [
        runtime_file_record(
            args.no_mistakes,
            "bin/no-mistakes",
            "no-mistakes artifact",
            executable=True,
            elf=True,
        ),
        runtime_file_record(
            args.provider_binary,
            "bin/" + args.provider,
            "{} provider artifact".format(args.provider),
            executable=True,
            elf=True,
        ),
        runtime_file_record(
            args.gh,
            "bin/gh",
            "GitHub CLI artifact",
            executable=True,
            elf=True,
        ),
        runtime_file_record(
            args.node,
            "bin/node",
            "Node interpreter artifact",
            executable=True,
            elf=True,
        ),
        runtime_bytes_record("bin/gh-axi", GH_AXI_WRAPPER, 0o755),
    ]
    for value in args.provider_extra:
        basename = Path(value).name
        if not basename:
            raise ValidationError("provider extra must name a file")
        records.append(
            runtime_file_record(
                value,
                "bin/" + basename,
                "provider extra {}".format(basename),
                executable=True,
                elf=True,
            )
        )
    if args.provider == "codex" and "bin/codex-code-mode-host" not in {
        record["name"] for record in records
    }:
        raise ValidationError("Codex runtime requires bin/codex-code-mode-host")
    gh_axi_records, gh_axi_closure = collect_gh_axi_runtime(args.gh_axi_package)
    records.extend(gh_axi_records)
    names = [record["name"] for record in records]
    if len(names) != len(set(names)):
        raise ValidationError("runtime bundle inputs produce duplicate member names")
    records.sort(key=lambda record: record["name"])
    manifest = {
        "schema": RUNTIME_SCHEMA,
        "provider": args.provider,
        "no_mistakes_version": args.no_mistakes_version,
        "no_mistakes_path": "bin/no-mistakes",
        "provider_path": "bin/" + args.provider,
        "gh_path": "bin/gh",
        "node_path": "bin/node",
        "gh_axi_path": "bin/gh-axi",
        "gh_axi_entrypoint": GH_AXI_ENTRYPOINT,
        "gh_axi_closure": gh_axi_closure,
        "files": [
            {"path": record["name"], "digest": record["digest"]}
            for record in records
        ],
    }
    manifest_bytes = (
        json.dumps(manifest, sort_keys=True, indent=1, ensure_ascii=False).encode(
            "utf-8"
        )
        + b"\n"
    )
    manifest_record = runtime_bytes_record("runtime.json", manifest_bytes, 0o644)
    if len(records) + 1 > 10000:
        raise ValidationError("runtime bundle exceeds the bounded member inventory")
    if manifest_record["size"] > 512 * 1024**2 or sum(
        record["size"] for record in records
    ) + manifest_record["size"] > 2 * 1024**3:
        raise ValidationError("runtime bundle exceeds the decompressed size bounds")

    descriptor = None
    temporary = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=".{}.tmp.".format(output.name), dir=str(output.parent)
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as raw:
            descriptor = None
            with gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0
            ) as compressed:
                with tarfile.open(
                    fileobj=compressed, mode="w:", format=tarfile.PAX_FORMAT
                ) as archive:
                    archive.addfile(
                        runtime_tar_info(
                            manifest_record["name"],
                            manifest_record["size"],
                            manifest_record["mode"],
                        ),
                        io.BytesIO(manifest_record["data"]),
                    )
                    for record in records:
                        info = runtime_tar_info(
                            record["name"], record["size"], record["mode"]
                        )
                        if "data" in record:
                            archive.addfile(info, io.BytesIO(record["data"]))
                        else:
                            with open_runtime_source(
                                record["source"], record["identity"]
                            ) as handle:
                                archive.addfile(info, handle)
            raw.flush()
            os.fsync(raw.fileno())
        if temporary.stat().st_size > 1024**3:
            raise ValidationError("runtime bundle exceeds the one-GiB bound")
        validated_manifest, digest = validate_runtime_bundle(temporary, args.provider)
        if validated_manifest != manifest:
            raise ValidationError(
                "runtime bundle self-validation returned a different manifest"
            )
        try:
            os.link(str(temporary), str(output), follow_symlinks=False)
        except FileExistsError:
            raise ValidationError("runtime bundle output appeared during the build")
        print(
            "AZURE VALIDATION RUNTIME BUILT output={} digest={}".format(
                output, digest
            )
        )
    except OSError as exc:
        raise ValidationError("runtime bundle build failed: {}".format(exc))
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def marker_settle_seconds():
    """How long an unbound terminal control view may persist before it is believed."""
    raw = os.environ.get("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")
    if raw is None or not raw.strip():
        return MARKER_SETTLE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        raise ValidationError("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS must be a whole number of seconds")
    if value < 0:
        raise ValidationError("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS must not be negative")
    return value


def seconds_since(stamp):
    """Elapsed seconds since an exact recorded UTC stamp, or None when unreadable.

    None is never treated as "long enough": an unreadable stamp keeps an
    ambiguous view unsettled rather than authorizing a terminal decision.
    """
    try:
        return (now_utc() - parse_utc(stamp, "recorded stamp")).total_seconds()
    except (ValidationError, TypeError):
        return None


def parse_utc(value, label):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        raise ValidationError("{} must be an exact UTC timestamp".format(label))


def run(command, cwd=None, check=True, capture=True, timeout=LOCAL_TIMEOUT, env=None):
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ValidationError("bounded command timed out after {} seconds: {}".format(timeout, command[0]))
    if check and result.returncode != 0:
        detail = (result.stderr or "").strip()
        raise ValidationError("command failed ({}): {}{}".format(
            result.returncode,
            " ".join(command),
            ": " + detail if detail else "",
        ))
    return result


def git(repo, *args, check=True):
    return run(["git", "-C", str(repo)] + list(args), check=check)


def require_id(label, value):
    if not value or not SAFE_ID.match(value):
        raise ValidationError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_cell(value):
    if not value or not SAFE_CELL.match(value):
        raise ValidationError("validation cell id is malformed")
    return value


def require_sha256(label, value):
    if not isinstance(value, str) or not SHA256.match(value):
        raise ValidationError("{} is not a SHA-256 identity".format(label))
    return value


def environment(require_cloud=False):
    home_value = os.environ.get("FM_HOME")
    if not home_value:
        raise ValidationError("FM_HOME is required")
    home = Path(home_value).resolve()
    state_dir = Path(os.environ.get(
        "FM_AZURE_VALIDATION_STATE_DIR", str(home / "state" / "azure-validation")
    )).resolve()
    if "FM_AZURE_VALIDATION_RESERVED_VCPUS" in os.environ:
        raise ValidationError(
            "FM_AZURE_VALIDATION_RESERVED_VCPUS is obsolete; author and review demand share the fixed East US 128-vCPU admission ceiling"
        )
    env = {
        "home": home,
        "home_binding": sha256_bytes(str(home).encode("utf-8")),
        "state_dir": state_dir,
        "queue_limit": bounded_int("FM_AZURE_VALIDATION_QUEUE_LIMIT", 128, 1, 1000),
        "lanes": bounded_int("FM_AZURE_VALIDATION_LANES", 4, 1, 8),
        "budget_limit": bounded_float(
            "FM_AZURE_VALIDATION_BUDGET_LIMIT_USD", BUDGET_TARGET_USD,
            BUDGET_TARGET_USD, BUDGET_CEILING_USD,
        ),
    }
    if not require_cloud:
        return env
    required = (
        "FM_AZURE_TENANT_ID", "FM_AZURE_SUBSCRIPTION_ID", "FM_AZURE_NAMING_PREFIX",
        "FM_AZURE_STORAGE_NAME", "FM_AZURE_DEPLOYMENT_GENERATION",
        "FM_AZURE_OWNER_TAG", "FM_AZURE_RUNNER_OPERATOR_OBJECT_ID",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValidationError("required Azure environment is missing: " + ", ".join(missing))
    tenant = os.environ["FM_AZURE_TENANT_ID"]
    subscription = os.environ["FM_AZURE_SUBSCRIPTION_ID"]
    if not UUID.match(tenant) or not UUID.match(subscription):
        raise ValidationError("tenant and subscription must be exact UUIDs")
    if not UUID.match(os.environ["FM_AZURE_RUNNER_OPERATOR_OBJECT_ID"]):
        raise ValidationError("runner operator object id must be an exact UUID")
    prefix = os.environ["FM_AZURE_NAMING_PREFIX"]
    storage = os.environ["FM_AZURE_STORAGE_NAME"]
    if not re.match(r"^[a-z0-9]{3,12}$", prefix):
        raise ValidationError("FM_AZURE_NAMING_PREFIX must be 3-12 lowercase alphanumeric characters")
    if not re.match(r"^[a-z0-9]{3,24}$", storage):
        raise ValidationError("FM_AZURE_STORAGE_NAME is malformed")
    env.update({
        "tenant": tenant,
        "subscription": subscription,
        "prefix": prefix,
        "storage": storage,
        "operator_data_plane_ip": os.environ.get("FM_AZURE_OPERATOR_DATA_PLANE_IP", ""),
        "deployment_generation": require_id(
            "deployment generation", os.environ["FM_AZURE_DEPLOYMENT_GENERATION"]
        ),
        "resource_group": os.environ.get(
            "FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"
        ),
        "operator_object_id": os.environ["FM_AZURE_RUNNER_OPERATOR_OBJECT_ID"],
        "owner": require_id("Azure cleanup owner", os.environ["FM_AZURE_OWNER_TAG"]),
        "vnet": "vnet-{}-eus".format(prefix),
        "subnet": "snet-validation",
    })
    return env


def bounded_int(name, default, minimum, maximum):
    value = os.environ.get(name, str(default))
    try:
        parsed = int(value)
    except ValueError:
        raise ValidationError("{} must be an integer".format(name))
    if not minimum <= parsed <= maximum:
        raise ValidationError("{} must be between {} and {}".format(name, minimum, maximum))
    return parsed


def bounded_float(name, default, minimum, maximum):
    value = os.environ.get(name, str(default))
    try:
        parsed = float(value)
    except ValueError:
        raise ValidationError("{} must be numeric".format(name))
    if not minimum <= parsed <= maximum:
        raise ValidationError("{} must be between {} and {}".format(name, minimum, maximum))
    return parsed


def ensure_dirs(env):
    for path in (
        env["state_dir"], env["state_dir"] / "payloads", env["state_dir"] / "results"
    ):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path, 0o700)


@contextlib.contextmanager
def lock(env, name="queue"):
    ensure_dirs(env)
    path = env["state_dir"] / ("." + name + ".lock")
    with open(path, "a+", encoding="utf-8") as handle:
        os.chmod(path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def state_path(env, cell):
    return env["state_dir"] / (require_cell(cell) + ".json")


def save_state(env, state, create=False):
    path = state_path(env, state["cell"])
    if create and path.exists():
        raise ValidationError("validation cell state already exists")
    state["updated_at"] = iso_utc()
    temp = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        if create and path.exists():
            raise ValidationError("validation cell state already exists")
        os.replace(str(temp), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def load_state(env, cell):
    path = state_path(env, cell)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValidationError("unknown validation cell: {}".format(cell))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("validation state is unreadable: {}".format(exc))
    if value.get("schema") != SCHEMA or value.get("cell") != cell:
        raise ValidationError("validation state identity is corrupt")
    return value


def transition(env, state, phase, note="", **updates):
    state.update(updates)
    state["phase"] = phase
    state.setdefault("events", []).append({"at": iso_utc(), "phase": phase, "note": note})
    save_state(env, state)


def new_cell():
    return "azv-" + uuid.uuid4().hex[:12]


def count_queued(env):
    ensure_dirs(env)
    count = 0
    for path in env["state_dir"].glob("azv-*.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            if json.loads(path.read_text(encoding="utf-8")).get("phase") == "queued":
                count += 1
    return count


def all_states(env):
    ensure_dirs(env)
    states = []
    for path in env["state_dir"].glob("azv-*.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            value = json.loads(path.read_text(encoding="utf-8"))
            if value.get("schema") == SCHEMA and value.get("cell"):
                states.append(value)
    return states


def occupied_states(env, exclude_cell=None):
    return [
        state for state in all_states(env)
        if state.get("phase") in LANE_PHASES and state.get("cell") != exclude_cell
    ]


def lane_sku(lane):
    """Deterministic lane-index to coordinator-SKU mapping (family spread)."""
    return COORDINATOR_SKU_POOL[lane % len(COORDINATOR_SKU_POOL)]


def next_free_lane(used_lanes, lane_count):
    for index in range(lane_count):
        if index not in used_lanes:
            return index
    raise ValidationError("no validation lane is free")


def load_credentials(path):
    """Read the plain single-operator credentials descriptor.

    The descriptor names the provider plus host paths for a home-shaped auth
    directory (containing .codex/, .claude/, ... as they would sit in the
    agent user's home) and the GitHub token file. It carries no secret values
    itself; the auth directory ships to the cell inside the input archive as
    the first-boot seed (the fm-auth-home share overlays it afterwards) and
    the token flows at dispatch time as a run-command parameter.
    """
    source = Path(path).expanduser().resolve()
    try:
        value = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("credentials descriptor is unreadable: {}".format(exc))
    if not isinstance(value, dict) or value.get("schema") != CREDENTIALS_SCHEMA:
        raise ValidationError("credentials descriptor schema is invalid")
    provider = value.get("provider")
    if provider not in PROVIDERS:
        raise ValidationError("credentials provider is not a verified Firstmate adapter")
    auth_home = Path(str(value.get("auth_home", ""))).expanduser()
    if not str(value.get("auth_home", "")) or not auth_home.is_dir():
        raise ValidationError("credentials auth_home must be an existing home-shaped directory")
    token_file = Path(str(value.get("github_token_file", ""))).expanduser()
    if not str(value.get("github_token_file", "")) or not token_file.is_file():
        raise ValidationError("credentials github_token_file must be an existing file")
    return {
        "provider": provider,
        "auth_home": auth_home,
        "github_token_file": token_file,
    }


def auth_share_name():
    """Configured persistent auth share; empty disables the auth-home sync."""
    return os.environ.get("FM_AZURE_AUTH_SHARE", "fm-auth-home")


def storage_account_scope(env):
    return "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}".format(
        env["subscription"], env["resource_group"], env["storage"]
    )


def direct_role_assignments_at_scope(env, scope):
    """Return only direct assignments at one exact scope.

    Current Azure CLI rejects combining ``role assignment list --scope`` with
    ``--all``.  A scoped query already uses Azure's direct ``atScope()`` read;
    retain a local exact-scope fence as defense in depth.
    """
    assignments, _, _ = az_command(
        env, ["role", "assignment", "list", "--scope", scope]
    )
    return [
        item for item in assignments or []
        if str(item.get("scope", "")).lower() == scope.lower()
    ]


def read_github_token(state):
    """Read the current GitHub token for boot-time injection into the guest."""
    override = os.environ.get("FM_AZURE_GITHUB_TOKEN_FILE")
    path = Path(override) if override else Path(state["request"]["credentials"]["github_token_file"])
    try:
        token = path.expanduser().read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValidationError("GitHub token file is unreadable: {}".format(exc))
    if not token:
        raise ValidationError("GitHub token file is empty")
    return token


def pack_auth_home(auth_home, destination):
    with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source in sorted(auth_home.rglob("*")):
            if source.is_symlink():
                continue
            arcname = source.relative_to(auth_home).as_posix()
            info = archive.gettarinfo(str(source), arcname=arcname)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            if source.is_file():
                with open(source, "rb") as handle:
                    archive.addfile(info, handle)
            elif source.is_dir():
                archive.addfile(info)
    if destination.stat().st_size > 1024**3:
        raise ValidationError("auth home bundle exceeds one GiB")


def validate_runtime_bundle(path, provider):
    source, observed = regular_runtime_source(path, "runtime bundle", 1024**3)
    expected = runtime_source_identity(observed)
    try:
        with open_runtime_source(source, expected) as source_handle:
            digest = hashlib.sha256()
            for block in iter(lambda: source_handle.read(1024 * 1024), b""):
                digest.update(block)
            runtime_digest = "sha256:" + digest.hexdigest()
            source_handle.seek(0)
            with tarfile.open(fileobj=source_handle, mode="r:gz") as archive:
                members = archive.getmembers()
                names = [member.name for member in members]
                if (
                    len(members) > 10000
                    or sum(member.size for member in members) > 2 * 1024**3
                ):
                    raise ValidationError(
                        "runtime bundle exceeds the bounded member/decompressed inventory"
                    )
                if names.count("runtime.json") != 1 or len(names) != len(set(names)):
                    raise ValidationError(
                        "runtime bundle has no unique runtime.json/member inventory"
                    )
                for member in members:
                    if (
                        member.issym()
                        or member.islnk()
                        or member.isdev()
                        or runtime_path_is_unsafe(member.name)
                    ):
                        raise ValidationError("runtime bundle contains an unsafe member")
                    if runtime_path_is_credential_like(member.name):
                        raise ValidationError(
                            "runtime bundle contains a credential-like path: {}".format(
                                member.name
                            )
                        )
                    if member.size > 512 * 1024**2:
                        raise ValidationError("runtime bundle member exceeds 512 MiB")
                manifest_handle = archive.extractfile("runtime.json")
                if manifest_handle is None:
                    raise ValidationError("runtime manifest is not a regular file")
                manifest = strict_json_loads(
                    manifest_handle.read().decode("utf-8"), "runtime manifest"
                )
                if not isinstance(manifest, dict):
                    raise ValidationError("runtime manifest must contain a JSON object")
                if set(manifest) != RUNTIME_MANIFEST_FIELDS:
                    raise ValidationError("runtime manifest fields are not the exact schema")
                if (
                    manifest.get("schema") != RUNTIME_SCHEMA
                    or manifest.get("provider") != provider
                ):
                    raise ValidationError(
                        "runtime manifest schema/provider does not match the credential lease"
                    )
                if not NO_MISTAKES_VERSION.fullmatch(
                    str(manifest.get("no_mistakes_version", ""))
                ):
                    raise ValidationError(
                        "runtime manifest has no exact no-mistakes version"
                    )
                declared = manifest.get("files")
                if not isinstance(declared, list) or not declared:
                    raise ValidationError("runtime manifest file inventory is empty")
                declared_paths = set()
                records_by_path = {}
                for record in declared:
                    if not isinstance(record, dict):
                        raise ValidationError("runtime manifest file record is malformed")
                    if set(record) != RUNTIME_FILE_FIELDS:
                        raise ValidationError(
                            "runtime manifest file record fields are not the exact schema"
                        )
                    if not isinstance(record.get("path"), str):
                        raise ValidationError("runtime manifest file record is malformed")
                    relative = record["path"]
                    if (
                        runtime_path_is_unsafe(relative)
                        or relative in declared_paths
                    ):
                        raise ValidationError(
                            "runtime manifest file path is unsafe or duplicated"
                        )
                    require_sha256("runtime file digest", record.get("digest"))
                    if runtime_path_is_credential_like(relative):
                        raise ValidationError(
                            "runtime manifest contains a credential-like path: {}".format(
                                relative
                            )
                        )
                    declared_paths.add(relative)
                    records_by_path[relative] = record
                archive_files = {
                    member.name: member
                    for member in members
                    if member.isfile() and member.name != "runtime.json"
                }
                if set(archive_files) != declared_paths:
                    raise ValidationError(
                        "runtime manifest does not exactly inventory the bundle"
                    )
                gh_axi_records = [
                    {
                        "name": name,
                        "size": member.size,
                        "archive": archive,
                        "member": member,
                    }
                    for name, member in archive_files.items()
                    if name.startswith("gh-axi/")
                ]
                gh_axi_closure = validate_gh_axi_runtime(gh_axi_records)
                if (
                    manifest["gh_axi_entrypoint"] != GH_AXI_ENTRYPOINT
                    or manifest["gh_axi_closure"] != gh_axi_closure
                ):
                    raise ValidationError(
                        "runtime manifest does not bind the exact gh-axi package closure"
                    )
                for relative, record in records_by_path.items():
                    member_handle = archive.extractfile(relative)
                    if member_handle is None:
                        raise ValidationError(
                            "runtime manifest member is not a regular file"
                        )
                    member_digest = hashlib.sha256()
                    for block in iter(
                        lambda: member_handle.read(1024 * 1024), b""
                    ):
                        member_digest.update(block)
                    if (
                        "sha256:" + member_digest.hexdigest()
                        != record["digest"]
                    ):
                        raise ValidationError(
                            "runtime bundle file digest mismatch: {}".format(relative)
                        )
                required_executables = {
                    "no_mistakes_path": "bin/no-mistakes",
                    "provider_path": "bin/" + provider,
                    "gh_path": "bin/gh",
                    "node_path": "bin/node",
                    "gh_axi_path": "bin/gh-axi",
                }
                for field, expected_path in required_executables.items():
                    relative = manifest.get(field)
                    member = archive_files.get(relative)
                    if (
                        relative != expected_path
                        or member is None
                        or member.mode & 0o111 == 0
                    ):
                        raise ValidationError(
                            "runtime {} exact executable is absent or not executable".format(
                                field
                            )
                        )
                node_handle = archive.extractfile(manifest["node_path"])
                if (
                    node_handle is None
                    or not linux_x86_64_elf_header_is_valid(node_handle.read(20))
                ):
                    raise ValidationError(
                        "runtime node_path must bind a Linux x86-64 ELF interpreter"
                    )
                wrapper_handle = archive.extractfile(manifest["gh_axi_path"])
                if (
                    wrapper_handle is None
                    or wrapper_handle.read(len(GH_AXI_WRAPPER) + 1) != GH_AXI_WRAPPER
                ):
                    raise ValidationError(
                        "runtime gh_axi_path must bind the exact bundled-Node wrapper"
                    )
    except (tarfile.TarError, OSError, UnicodeDecodeError) as exc:
        raise ValidationError("runtime bundle is unreadable: {}".format(exc))
    return manifest, runtime_digest


def repository_identity(repo):
    repo = Path(repo).resolve()
    top = Path(git(repo, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    dirty = git(top, "status", "--porcelain", "--untracked-files=all").stdout
    if dirty:
        raise ValidationError("repository must be a clean exact committed snapshot")
    branch_result = git(top, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if branch_result.returncode != 0:
        raise ValidationError("repository must be on a named branch")
    branch = branch_result.stdout.strip()
    head = git(top, "rev-parse", "HEAD").stdout.strip()
    tree = git(top, "rev-parse", "HEAD^{tree}").stdout.strip()
    if not HEX_OBJECT.match(head) or not HEX_OBJECT.match(tree):
        raise ValidationError("repository head/tree identity is malformed")
    origin = git(top, "remote", "get-url", "origin").stdout.strip()
    slug_match = re.search(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$", origin)
    if not slug_match:
        raise ValidationError("origin must be an exact GitHub repository")
    repo_slug = "{}/{}".format(slug_match.group(1), slug_match.group(2))
    remote = git(top, "ls-remote", "--heads", "origin", "refs/heads/" + branch).stdout.split()
    if len(remote) != 2 or remote[1] != "refs/heads/" + branch or remote[0] != head:
        raise ValidationError("named branch is not pushed at the exact submitted head")
    return top, branch, head, tree, repo_slug


def project_resource_class(env, repo_slug, requested):
    path = env["home"] / "config" / "azure-validation-classes.json"
    if not path.exists():
        selected = requested or "validation-heavy"
        if selected not in RESOURCE_CLASSES:
            raise ValidationError("unknown validation resource class")
        return selected
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("per-project validation class policy is unreadable: {}".format(exc))
    if value.get("schema") != "fm.azure-validation-classes/v1":
        raise ValidationError("per-project validation class policy schema is invalid")
    default = value.get("default", "validation-heavy")
    projects = value.get("projects", {})
    if default not in RESOURCE_CLASSES or not isinstance(projects, dict):
        raise ValidationError("per-project validation class policy is malformed")
    unknown = [name for name in projects.values() if name not in RESOURCE_CLASSES]
    if unknown:
        raise ValidationError("per-project validation class policy names an unknown class")
    selected = projects.get(repo_slug, default)
    if requested and requested != selected:
        raise ValidationError("requested validation class differs from the exact project policy")
    return selected


def prepare_payload(env, state, runtime_source, runtime_digest, auth_home):
    payload = env["state_dir"] / "payloads" / state["cell"]
    if payload.exists():
        raise ValidationError("cell payload already exists")
    payload.mkdir(parents=True, mode=0o700)
    os.chmod(payload, 0o700)
    bundle = payload / "snapshot.bundle"
    git(state["repository_root"], "bundle", "create", str(bundle), "HEAD")
    run(["git", "bundle", "verify", str(bundle)])
    if bundle.stat().st_size > 1024**3:
        raise ValidationError("repository bundle exceeds one GiB")
    state["request"]["repository"]["snapshot_digest"] = sha256_file(bundle)
    state["request"]["repository"]["snapshot_bytes"] = bundle.stat().st_size
    runtime_copy = payload / "runtime.tar.gz"
    copy_identity_pinned_runtime(
        runtime_source,
        runtime_copy,
        "staged runtime bundle",
        expected_digest=runtime_digest,
    )
    runtime_copy_source, runtime_copy_stat = regular_runtime_source(
        runtime_copy, "payload runtime bundle", 1024**3
    )
    runtime_copy_identity = runtime_source_identity(runtime_copy_stat)
    credentials_copy = payload / "credentials.tar.gz"
    pack_auth_home(auth_home, credentials_copy)
    state["request"]["credentials"]["bundle_digest"] = sha256_file(credentials_copy)
    request_unsigned = dict(state["request"])
    request_unsigned.pop("request_digest", None)
    state["request_digest"] = sha256_bytes(canonical_bytes(request_unsigned))
    state["request"]["request_digest"] = state["request_digest"]
    request_path = payload / "request.json"
    request_path.write_bytes(canonical_bytes(state["request"]) + b"\n")
    for source, destination in ((GUEST, payload / "guest.sh"), (SHARD_BRIDGE, payload / "shard-bridge.py")):
        shutil.copyfile(str(source), str(destination))
    input_path = payload / "input.tar.gz"
    sources = (
        (request_path, "request.json"),
        (bundle, "snapshot.bundle"),
        (runtime_copy, "runtime.tar.gz"),
        (credentials_copy, "credentials.tar.gz"),
        (payload / "shard-bridge.py", "shard-bridge.py"),
    )
    with tarfile.open(input_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source, name in sources:
            if source == runtime_copy:
                info = tarfile.TarInfo(name=name)
                info.type = tarfile.REGTYPE
                info.size = runtime_copy_stat.st_size
                info.mode = 0o600
            else:
                info = archive.gettarinfo(str(source), arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            runtime_context = (
                open_runtime_source(runtime_copy_source, runtime_copy_identity)
                if source == runtime_copy
                else open(source, "rb")
            )
            with runtime_context as handle:
                archive.addfile(info, handle)
    with tarfile.open(input_path, "r:gz") as archive:
        packed_runtime = archive.extractfile("runtime.tar.gz")
        if packed_runtime is None:
            raise ValidationError("payload omitted its staged runtime bundle")
        packed_digest = hashlib.sha256()
        for block in iter(lambda: packed_runtime.read(1024 * 1024), b""):
            packed_digest.update(block)
        if "sha256:" + packed_digest.hexdigest() != runtime_digest:
            raise ValidationError("payload runtime bundle digest mismatch after packing")
    state["input_path"] = str(input_path)
    state["input_digest"] = sha256_file(input_path)
    state["input_bytes"] = input_path.stat().st_size
    return state


def submit(env, args):
    with staged_runtime_bundle(env, args.runtime_bundle) as runtime_source:
        submit_staged(env, args, runtime_source)


def submit_staged(env, args, runtime_source):
    with lock(env):
        if count_queued(env) >= env["queue_limit"]:
            raise ValidationError("validation queue depth limit reached; no compute was created")
        repo, branch, head, tree, repo_slug = repository_identity(args.repo or os.getcwd())
        task = require_id("task", args.task)
        generation = require_id("task generation", args.task_generation)
        validation_generation = require_id("validation generation", args.validation_generation)
        deployment_generation = require_id(
            "deployment generation", os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION")
        )
        resource_class = project_resource_class(env, repo_slug, args.resource_class)
        try:
            intent = Path(args.intent_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise ValidationError("intent file is unreadable: {}".format(exc))
        if not intent.strip() or len(intent.encode("utf-8")) > 64 * 1024:
            raise ValidationError("intent must contain 1-65536 bytes")
        credentials = load_credentials(args.credential_lease)
        runtime, runtime_digest = validate_runtime_bundle(
            runtime_source, credentials["provider"]
        )
        cell = new_cell()
        token = cell.split("-", 1)[1]
        resources = resource_names(env, token)
        shard_container = "fmval" + token
        fence = sha256_bytes(os.urandom(32))
        limits = dict(RESOURCE_CLASSES[resource_class])
        limits["reserved_vcpus"] = limits["vcpus"] + limits["behavior_shards"] * 4
        request = {
            "schema": SCHEMA,
            "cell": cell,
            "home_binding": env["home_binding"],
            "task": task,
            "task_generation": generation,
            "validation_generation": validation_generation,
            "deployment_generation": deployment_generation,
            "fence": fence,
            "intent": intent,
            "resource_bindings": {
                "vm_id": resources["vm_id"],
                "worktree_disk_id": resources["worktree_disk_id"],
                "identity_id": resources["identity_id"],
                "shard_container": shard_container,
            },
            "repository": {
                "slug": repo_slug,
                "branch": branch,
                "head": head,
                "tree": tree,
                "snapshot_digest": None,
                "snapshot_bytes": None,
            },
            "credentials": {
                "provider": credentials["provider"],
                "github_token_file": str(credentials["github_token_file"]),
                "bundle_digest": None,
            },
            "runtime": runtime,
            "runtime_digest": runtime_digest,
            "resource_class": resource_class,
            "limits": limits,
            "protocol": {
                "guest_digest": sha256_file(GUEST),
                "shard_bridge_digest": sha256_file(SHARD_BRIDGE),
                "result_schema": RESULT_SCHEMA,
            },
            "created_at": iso_utc(),
        }
        staging_prefix = "validation-cells/{}/{}/{}/{}/{}".format(
            env["home_binding"].split(":", 1)[1][:16], task, generation,
            validation_generation, cell,
        )
        state = {
            "schema": SCHEMA,
            "cell": cell,
            "phase": "preparing",
            "created_at": iso_utc(),
            "repository_root": str(repo),
            "request": request,
            "attempt": 1,
            "staging": {
                "container": shard_container,
                "input_blob": "control/input.tar.gz",
                "result_blob": "control/result.tar.gz",
                "evidence_prefix": "control/evidence",
                "lineage_prefix": staging_prefix,
            },
            "resources": resources,
            "events": [{"at": iso_utc(), "phase": "preparing", "note": "queue identity reserved"}],
        }
        ensure_dirs(env)
        save_state(env, state, create=True)
        try:
            prepare_payload(
                env, state, runtime_source, runtime_digest,
                credentials["auth_home"],
            )
            transition(env, state, "queued", "exact pushed head queued without local validation execution")
        except Exception:
            with contextlib.suppress(OSError):
                state_path(env, cell).unlink()
            shutil.rmtree(env["state_dir"] / "payloads" / cell, ignore_errors=True)
            raise
    print("AZURE VALIDATION QUEUED cell={} task={} head={} class={} shards={}".format(
        cell, task, head, resource_class, limits["behavior_shards"]
    ))


def resource_names(env, token):
    prefix = os.environ.get("FM_AZURE_NAMING_PREFIX", "")
    sub = os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "")
    group = os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001")
    if not re.match(r"^[a-z0-9]{3,12}$", prefix) or not UUID.match(sub):
        raise ValidationError("submit requires exact naming-prefix and subscription identity without contacting Azure")
    if not re.match(r"^[A-Za-z0-9._()\-]{1,90}$", group):
        raise ValidationError("Azure resource group name is malformed")
    base = "/subscriptions/{}/resourceGroups/{}/providers".format(sub, group)
    vm = "vm-{}-val-{}".format(prefix, token)
    nic = "nic-{}-val-{}".format(prefix, token)
    os_disk = "disk-{}-val-{}-os".format(prefix, token)
    worktree = "disk-{}-val-{}-work".format(prefix, token)
    identity = "id-{}-val-{}".format(prefix, token)
    return {
        "deployment": "fm-val-{}".format(token),
        "vm_name": vm,
        "nic_name": nic,
        "os_disk_name": os_disk,
        "worktree_disk_name": worktree,
        "identity_name": identity,
        "identity_id": base + "/Microsoft.ManagedIdentity/userAssignedIdentities/" + identity,
        "vm_id": base + "/Microsoft.Compute/virtualMachines/" + vm,
        "nic_id": base + "/Microsoft.Network/networkInterfaces/" + nic,
        "os_disk_id": base + "/Microsoft.Compute/disks/" + os_disk,
        "worktree_disk_id": base + "/Microsoft.Compute/disks/" + worktree,
        "run_command_name": "validate-a1",
        "run_commands": [],
        "safety_run_command_id": base + "/Microsoft.Compute/virtualMachines/{}/runCommands/safety-shutdown".format(vm),
        "ttl_schedule_name": "shutdown-computevm-{}".format(vm),
        "ttl_schedule_id": base + "/Microsoft.DevTestLab/schedules/shutdown-computevm-{}".format(vm),
        "identities": {},
    }


def az_command(env, args, check=True, parse_json=True, timeout=LOCAL_TIMEOUT):
    command = [os.environ.get("FM_AZURE_CLI", "az")] + list(args)
    command += ["--subscription", env["subscription"], "--only-show-errors"]
    if parse_json and "--output" not in command and "-o" not in command:
        command += ["--output", "json"]
    result = run(command, check=check, timeout=timeout)
    if not parse_json:
        return result.stdout.strip(), result.returncode, (result.stderr or "").strip()
    if result.returncode != 0:
        return None, result.returncode, (result.stderr or "").strip()
    try:
        return json.loads(result.stdout or "null"), result.returncode, (result.stderr or "").strip()
    except json.JSONDecodeError as exc:
        raise ValidationError("Azure CLI returned malformed JSON: {}".format(exc))


def write_private_json(env, prefix, value):
    ensure_dirs(env)
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".json", dir=str(env["state_dir"]))
    os.chmod(name, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
    return Path(name)


def scope_gate(env):
    account, _, _ = az_command(env, ["account", "show"])
    if (
        account.get("id") != env["subscription"]
        or account.get("tenantId") != env["tenant"]
        or account.get("state") != "Enabled"
    ):
        raise ValidationError("selected Azure tenant/subscription is not the exact enabled scope")


def foundation_gate(env):
    # The released runner owns the exact private-foundation contract: the
    # complete 29-resource inventory, controller-UAMI classification, private
    # endpoints, DNS, NAT, NSGs, and zero-RBAC reservation identities. The
    # validation dispatcher consumes that released proof instead of keeping a
    # partial parallel one, then re-proves only its own cell subnet below.
    runner = runner_module()
    try:
        runner_env = runner.environment()
        runner.scope_gate(runner_env)
        runner.foundation_gate(runner_env)
    except runner.RunnerError as exc:
        raise ValidationError("released foundation contract refused: {}".format(exc))
    storage, _, _ = az_command(env, [
        "storage", "account", "show", "--resource-group", env["resource_group"],
        "--name", env["storage"],
    ])
    tags = storage.get("tags") or {}
    network = storage.get("networkRuleSet") or storage.get("networkAcls") or {}
    if (
        storage.get("location") != "eastus"
        or storage.get("kind") != "StorageV2"
        or (storage.get("sku") or {}).get("name") != "Standard_ZRS"
        or not runner.storage_network_access_is_exact(
            storage, env["operator_data_plane_ip"], "ipAddressOrRange"
        )
        or storage.get("allowSharedKeyAccess") is not False
        or storage.get("allowBlobPublicAccess") is not False
        or storage.get("defaultToOAuthAuthentication") is not True
        or storage.get("minimumTlsVersion") != "TLS1_2"
        or network.get("defaultAction") != "Deny"
        or network.get("bypass") != "None"
        or tags.get("workload") != "firstmate"
        or tags.get("cleanup-owner") != env["owner"]
        or tags.get("deployment-generation") != env["deployment_generation"]
    ):
        raise ValidationError("foundation storage/private identity is not exact")
    vnet, _, _ = az_command(env, [
        "network", "vnet", "show", "--resource-group", env["resource_group"],
        "--name", env["vnet"],
    ])
    vnet_tags = vnet.get("tags") or {}
    if (
        vnet.get("location") != "eastus"
        or (vnet.get("addressSpace") or {}).get("addressPrefixes") != ["10.42.0.0/16"]
        or vnet_tags.get("workload") != "firstmate"
        or vnet_tags.get("cleanup-owner") != env["owner"]
        or vnet_tags.get("deployment-generation") != env["deployment_generation"]
    ):
        raise ValidationError("foundation VNet owner/generation/address identity is not exact")
    matches = [item for item in vnet.get("subnets", []) if item.get("name") == env["subnet"]]
    if len(matches) != 1:
        raise ValidationError("private validation-cell subnet is absent or ambiguous")
    subnet = matches[0]
    nsg = str((subnet.get("networkSecurityGroup") or {}).get("id", "")).lower()
    nat = str((subnet.get("natGateway") or {}).get("id", "")).lower()
    if (
        subnet.get("addressPrefix") != "10.42.4.0/24"
        or not nsg.endswith("/nsg-{}-elastic-isolated".format(env["prefix"]).lower())
        or not nat.endswith("/nat-{}-eus".format(env["prefix"]).lower())
        or subnet.get("privateEndpointNetworkPolicies") != "Enabled"
    ):
        raise ValidationError("validation-cell subnet private NSG/NAT/address contract is not exact")




def sku_candidates(env, required_vcpus, required_memory):
    """Select a reviewed, live-capable control SKU.

    Selection proves only existence, restriction-freedom, capability, zonal
    coverage, and rate; every capacity and family-headroom decision belongs to
    the released shared allocator's atomic shape admission.
    """
    skus, _, _ = az_command(env, [
        "vm", "list-skus", "--location", "eastus", "--resource-type", "virtualMachines", "--all",
    ])
    candidates = []
    by_name = {item.get("name"): item for item in skus}
    requested = os.environ.get("FM_AZURE_VALIDATION_SKU")
    names = (requested,) if requested else VALIDATION_SKUS
    for name in names:
        if name not in VALIDATION_SKUS:
            raise ValidationError("validation SKU is outside the reviewed 8-vCPU/32-GiB allowlist")
        item = by_name.get(name)
        if not item or item.get("restrictions"):
            continue
        capabilities = {entry.get("name"): entry.get("value") for entry in item.get("capabilities", [])}
        family = str(item.get("family") or capabilities.get("Family") or "")
        if not family:
            continue
        try:
            vcpus = int(capabilities.get("vCPUsAvailable", capabilities.get("vCPUs", "0")))
            memory = float(capabilities.get("MemoryGB", "0"))
        except ValueError:
            continue
        zones = set(item.get("locationInfo", [{}])[0].get("zones", []))
        if (
            vcpus != required_vcpus or memory < required_memory
            or capabilities.get("CpuArchitectureType") != "x64"
            or "V2" not in str(capabilities.get("HyperVGenerations", ""))
            or not {"1", "2", "3"}.issubset(zones)
        ):
            continue
        rate = retail_rate(env, name)
        candidates.append({"sku": name, "family": family, "vcpus": vcpus, "memory_gib": memory, "rate": rate})
    if not candidates:
        raise ValidationError("no reviewed validation control SKU is live, unrestricted, and capability-complete")
    return sorted(candidates, key=lambda item: (item["rate"], item["sku"]))


_RUNNER_MODULE = None


def runner_module():
    global _RUNNER_MODULE
    if _RUNNER_MODULE is None:
        spec = importlib.util.spec_from_file_location(
            "azure_runner_module", str(ROOT / "bin" / "fm-azure-runner.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _RUNNER_MODULE = module
    return _RUNNER_MODULE


_WORKER_LIFECYCLE_MODULE = None


def worker_lifecycle_module():
    global _WORKER_LIFECYCLE_MODULE
    if _WORKER_LIFECYCLE_MODULE is None:
        spec = importlib.util.spec_from_file_location(
            "worker_lifecycle_module", str(ROOT / "bin" / "fm-worker-lifecycle.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _WORKER_LIFECYCLE_MODULE = module
    return _WORKER_LIFECYCLE_MODULE


_CREDENTIAL_EXPIRY_MODULE = None


def credential_expiry_module():
    global _CREDENTIAL_EXPIRY_MODULE
    if _CREDENTIAL_EXPIRY_MODULE is None:
        spec = importlib.util.spec_from_file_location(
            "credential_expiry_module", str(CREDENTIAL_EXPIRY)
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CREDENTIAL_EXPIRY_MODULE = module
    return _CREDENTIAL_EXPIRY_MODULE


# What the fm-auth-home share actually is, verified against both consumers:
# the guest's auth_home_pull copies the WHOLE share into one cell home and the
# guest exports CODEX_HOME=$HOME/.codex or CLAUDE_CONFIG_DIR=$HOME/.claude, so
# the share is exactly one home-shaped tree holding at most one codex profile
# and one claude profile. Crosscheck reviewers never read the share at all;
# they receive a per-review credential archive. There is therefore no consumer
# for a multi-profile layout, and inventing one would write bytes nothing
# reads. Seeding keeps the layout the consumers already expect.
#
# Only the credential file itself is uploaded. Sessions, history, caches, and
# project state are cell-local by design and have no reason to sit on a shared
# Azure Files share.
AUTH_HOME_LAYOUT = {
    "codex": (".codex", "auth.json"),
    "claude": (".claude", ".credentials.json"),
}


def auth_seed_targets(args):
    """Resolve the requested harness/profile pairs for one seeding run."""

    selected = []
    for harness in PROVIDERS:
        value = getattr(args, harness, None)
        if not value:
            continue
        profile = Path(value).expanduser()
        if not profile.is_dir() or profile.is_symlink():
            raise ValidationError(
                "{} profile must be an existing non-symlink directory: {}".format(
                    harness, profile
                )
            )
        directory, credential = AUTH_HOME_LAYOUT[harness]
        source = profile.resolve() / credential
        if not source.is_file() or source.is_symlink():
            raise ValidationError(
                "{} profile holds no regular {} to seed: {}".format(
                    harness, credential, source
                )
            )
        selected.append({
            "harness": harness,
            "profile": profile.resolve(),
            "source": source,
            "share_directory": directory,
            "share_path": "{}/{}".format(directory, credential),
        })
    if not selected:
        raise ValidationError(
            "auth-seed requires at least one of --codex or --claude"
        )
    return selected


def auth_seed_preflight(targets):
    """Refuse to publish a credential the cells cannot authenticate with.

    Seeding exists to carry a freshly re-authenticated profile onto the share.
    A profile whose access token is already dead would be uploaded, pulled by
    every later boot, and fail there instead of here, so it is refused with
    its own expiry named.
    """

    expiry = credential_expiry_module()
    for target in targets:
        record = expiry.inspect_profile(
            target["profile"], harness=target["harness"]
        )
        try:
            expiry.require_state(record, "usable", "fm-auth-home seed")
        except expiry.CredentialExpiryError as exc:
            raise ValidationError(
                "{}; re-authenticate that profile and seed again".format(exc)
            )
        target["expiry"] = record
    return targets


def auth_seed(env, args):
    """Publish selected local credentials onto the persistent auth share.

    Plan is local and touches no Azure. Apply requires the exact subscription
    plus an explicit seed confirmation, uploads each credential to the exact
    path its consumer reads, and then re-reads the share to prove the upload.
    """

    targets = auth_seed_preflight(auth_seed_targets(args))
    share = auth_share_name()
    if not share:
        raise ValidationError("FM_AZURE_AUTH_SHARE is empty; the auth-home sync is disabled")
    if not args.apply:
        print("auth-seed plan (no Azure call made)")
        print("  share: {}".format(share))
        for target in targets:
            print("  {} {} -> {}".format(
                target["harness"], target["source"], target["share_path"]
            ))
            print("    state {} expires {}".format(
                target["expiry"]["state"], target["expiry"]["expires_at"]
            ))
        print("  apply with: --apply --confirm-seed --confirm-subscription <exact-id>")
        return
    if not args.confirm_seed:
        raise ValidationError("auth-seed --apply requires --confirm-seed")
    if args.confirm_subscription != env["subscription"]:
        raise ValidationError("auth-seed --apply requires the exact --confirm-subscription")
    scope_gate(env)
    backup = ["--auth-mode", "login", "--enable-file-backup-request-intent"]
    for target in targets:
        az_command(env, [
            "storage", "directory", "create",
            "--account-name", env["storage"],
            "--share-name", share,
            "--name", target["share_directory"],
        ] + backup)
        _, code, detail = az_command(env, [
            "storage", "file", "upload",
            "--account-name", env["storage"],
            "--share-name", share,
            "--source", str(target["source"]),
            "--path", target["share_path"],
        ] + backup, check=False)
        if code != 0:
            raise ValidationError("auth-seed upload failed for {}: {}".format(
                target["share_path"], detail
            ))
        # An accepted upload is not proof: re-read the share and require the
        # exact byte count, so a truncated or replaced object is caught here
        # instead of at the next cell boot.
        published, code, detail = az_command(env, [
            "storage", "file", "show",
            "--account-name", env["storage"],
            "--share-name", share,
            "--path", target["share_path"],
        ] + backup, check=False)
        expected = target["source"].stat().st_size
        published_size = ((published or {}).get("properties") or {}).get("contentLength")
        if code != 0 or published_size != expected:
            raise ValidationError(
                "auth-seed could not prove {} landed at its expected {} bytes: {}".format(
                    target["share_path"], expected, detail or published_size
                )
            )
        print("auth-seed published {} ({} bytes, expires {})".format(
            target["share_path"], expected, target["expiry"]["expires_at"]
        ))


def lifecycle_command(env, arguments):
    command_env = os.environ.copy()
    # The allocator store is fenced to its home identity, so the operator's
    # exported FM_HOME must win when the CLI runs from a different checkout;
    # the script root is only the fallback when no home is declared.
    command_env.setdefault("FM_HOME", str(ROOT))
    executable = os.environ.get(
        "FM_AZURE_VALIDATION_LIFECYCLE", str(ROOT / "bin" / "fm-worker-lifecycle.sh")
    )
    result = run([executable] + arguments, check=False, env=command_env)
    return result


def compose_shard_plan(selected_family, shards, rate_lookup):
    """Compose the exact shard constituents beside one selected control family.

    Pure beside the injected rate lookup: shards avoid the control family so
    the complete shape fits exact 10-vCPU families, ids are distinct so child
    runners re-admit their own constituent, and every amount is a cushioned
    worst-case bound at or above the child's exact first-day cost.
    """
    runner = runner_module()
    shard_skus = [
        sku for sku in RUNNER_SHARD_SKUS
        if runner.SKU_FAMILY[sku].lower() != str(selected_family).lower()
    ]
    if not shard_skus:
        raise ValidationError("no reviewed shard family remains beside the selected control family")
    plan = []
    shard_limits = dict(runner.RESOURCE_CLASSES["behavior-heavy"])
    for shard in range(1, int(shards) + 1):
        sku = shard_skus[(shard - 1) % len(shard_skus)]
        # The constituent must cover the child runner's own parent-managed
        # first-day itemized bound, or its idempotent re-admission can never
        # fit the cushion; the exact same bound model produces the amount.
        limits = dict(shard_limits, sku=sku, sku_family=runner.SKU_FAMILY[sku])
        bound = runner.itemized_cost_bound(
            float(rate_lookup(sku)), runner.MAX_BILLABLE_LIFETIME_HOURS,
            limits, parent_managed=True,
        )
        plan.append({
            "shard": shard,
            "invocation": "azr-" + uuid.uuid4().hex[:12],
            "sku": sku,
            "sku_family": runner.SKU_FAMILY[sku],
            "amount_usd": round(bound["total"] + 1.0, 6),
        })
    return plan


def shared_shape_reserve(env, state, selected):
    """Atomically reserve the complete control-plus-shards specialized shape.

    The released whole-fleet allocator is the single capacity authority: the
    complete maximum shape (one reviewed eight-vCPU control cell plus one
    four-vCPU constituent per behavior shard) is admitted all-or-nothing with
    exact constituent SKU, family, vCPU, and cushioned worst-case cost
    identities. Child runners later re-admit their exact pre-reserved
    constituent ids idempotently, so live shards are never double-counted.
    """
    request = state["request"]
    limits = request["limits"]
    fence = request["fence"].split(":", 1)[-1]
    shards = int(limits["behavior_shards"])
    runner = runner_module()
    admission = state.get("admission") or {}
    shard_plan = admission.get("shard_plan")
    if not shard_plan:
        shard_plan = compose_shard_plan(
            selected["family"], shards, lambda sku: retail_rate(env, sku)
        )
    control_amount = round(selected["rate"] * 24.0 * 1.5 + 5.0, 6)
    arguments = [
        "capacity-reserve-shape",
        "--shape-id", state["cell"],
        "--fence-binding", fence,
        "--confirm-subscription", env["subscription"],
        "--constituent",
        "reservation-id={},role=validation,sku={},sku-family={},vcpus=8,amount-usd={}".format(
            state["cell"], selected["sku"], selected["family"], control_amount
        ),
    ]
    for entry in shard_plan:
        arguments += [
            "--constituent",
            "reservation-id={},role=validation,sku={},sku-family={},vcpus=4,amount-usd={}".format(
                entry["invocation"], entry["sku"], entry["sku_family"], entry["amount_usd"]
            ),
        ]
    result = lifecycle_command(env, arguments)
    if result.returncode != 0:
        raise ValidationError("shared allocator shape reservation failed: {}".format(
            (result.stderr or result.stdout or "").strip()[-500:]
        ))
    try:
        shape = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError):
        raise ValidationError("shared allocator returned a malformed shape reservation")
    if shape.get("shape_id") != state["cell"] or shape.get("status") not in ("reserved", "queued"):
        raise ValidationError("shared allocator returned a shape with the wrong identity")
    shape["shard_plan"] = shard_plan
    shape["control_amount_usd"] = control_amount
    return shape


def release_shape_constituent(env, state, reservation_id, evidence):
    receipt = hashlib.sha256(json.dumps(
        {"cell": state["cell"], "reservation": reservation_id, "evidence": evidence},
        sort_keys=True, separators=(",", ":"),
    ).encode()).hexdigest()
    result = lifecycle_command(env, [
        "capacity-release",
        "--reservation-id", reservation_id,
        "--fence-binding", state["request"]["fence"].split(":", 1)[-1],
        "--cleanup-receipt", receipt,
        "--confirm-subscription", env["subscription"],
    ])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        # Release is a cleanup operation and must be idempotent: a
        # constituent already released under another recorded receipt (an
        # operator supersede raced a queued dispatch in generation 054)
        # leaves nothing reserved, so the released end state satisfies
        # this release instead of wedging close into cleanup-retained.
        # Both receipts remain in the durable ledger.
        if "already has a different cleanup receipt" in detail:
            return
        raise ValidationError("shared capacity release refused for {}: {}".format(
            reservation_id, detail[-400:]
        ))


def retire_purge_capacity_fence(env, retirement):
    arguments = [
        "capacity-retire-fence",
        "--fence-binding", retirement["fence_binding"],
        "--retirement-receipt", retirement["retirement_receipt"],
        "--confirm-subscription", env["subscription"],
    ]
    for reservation_id in retirement["reservation_ids"]:
        arguments += ["--reservation-id", reservation_id]
    result = lifecycle_command(env, arguments)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise ValidationError("shared capacity fence retirement refused: {}".format(
            detail[-500:]
        ))


RETAIL_RATE_CACHE_FRESH_SECONDS = 7 * 24 * 3600


def retail_rate(env, sku):
    """Resolve the SKU's hourly retail rate through a durable cache.

    Dispatch prices the cell plus the whole shard SKU pool in one burst, and
    prices.azure.com throttles bursts hard (generation 045 lost 21 minutes to
    HTTP 429 backoff before a single VM existed). The rate only feeds
    worst-case cost ceilings, so a same-week cached value bounds spend just as
    well: fresh cache entries skip the API, stale entries are refreshed
    best-effort and used verbatim when the API throttles, and only a SKU with
    no cached rate at all requires the live read to succeed.
    """
    # An environment without durable state (the transport contract drives
    # this function with a bare env) prices directly with no cache.
    state_dir = env.get("state_dir")
    if state_dir is None:
        return retail_rate_from_api(env, sku)
    cache_path = state_dir / "retail-rate-cache.json"
    try:
        cache = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    entry = cache.get(sku)
    now = time.time()
    if (
        isinstance(entry, dict)
        and isinstance(entry.get("rate"), (int, float))
        and entry["rate"] > 0
        and isinstance(entry.get("fetched_at"), (int, float))
        and now - entry["fetched_at"] < RETAIL_RATE_CACHE_FRESH_SECONDS
    ):
        return float(entry["rate"])
    try:
        rate = retail_rate_from_api(env, sku)
    except ValidationError as exc:
        if isinstance(entry, dict) and isinstance(entry.get("rate"), (int, float)) and entry["rate"] > 0:
            print(
                "azure-validation: retail rate API unavailable ({}); using cached ceiling for {}".format(
                    str(exc)[:120], sku
                ),
                file=sys.stderr,
            )
            return float(entry["rate"])
        raise
    cache[sku] = {"rate": rate, "fetched_at": now}
    tmp = cache_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(cache_path)
    return rate


def retail_rate_from_api(env, sku):
    escaped = sku.replace("_", "%5F")
    url = (
        "https://prices.azure.com/api/retail/prices?%24filter="
        "armRegionName%20eq%20%27eastus%27%20and%20armSkuName%20eq%20%27{}%27%20and%20priceType%20eq%20%27Consumption%27"
    ).format(escaped)
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "firstmate-azure-validation/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        raise ValidationError("Azure retail rate request failed with HTTP {}".format(exc.code))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ValidationError("Azure retail rate request is unreadable: {}".format(exc))
    rates = []
    for item in result.get("Items", []):
        product = str(item.get("productName", "")).lower()
        meter = str(item.get("meterName", "")).lower()
        if item.get("unitOfMeasure") == "1 Hour" and "windows" not in product and "spot" not in meter:
            with contextlib.suppress(TypeError, ValueError):
                rates.append(float(item["retailPrice"]))
    if not rates:
        raise ValidationError("current retail rate is unreadable for {}".format(sku))
    return min(rates)






def storage_upload(env, path, blob, overwrite=False, container=CONTAINER):
    az_command(env, [
        "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", container, "--name", blob, "--file", str(path),
        "--overwrite", "true" if overwrite else "false",
    ])


def storage_upload_after_role(env, path, blob, container):
    last = ""
    for _ in range(12):
        _, rc, stderr = az_command(env, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", env["storage"],
            "--container-name", container, "--name", blob, "--file", str(path), "--overwrite", "false",
        ], check=False)
        if rc == 0:
            return
        last = stderr
        time.sleep(5)
    raise ValidationError("cell-container data role did not converge within one minute: {}".format(last))


def storage_download(env, blob, path, container=CONTAINER):
    az_command(env, [
        "storage", "blob", "download", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", container, "--name", blob, "--file", str(path), "--overwrite", "true",
    ])


def storage_bytes_upload(env, data, blob, container):
    path = write_private_json(env, ".blob-bytes-", {"placeholder": True})
    try:
        path.write_bytes(data)
        os.chmod(path, 0o600)
        storage_upload(env, path, blob, overwrite=True, container=container)
    finally:
        path.unlink(missing_ok=True)


def blob_sas(env, blob, permissions, hours=MAX_CELL_LIFETIME_HOURS, container=CONTAINER):
    expiry = iso_utc(now_utc() + dt.timedelta(hours=hours))
    stdout, rc, stderr = az_command(env, [
        "storage", "blob", "generate-sas", "--as-user", "--auth-mode", "login", "--https-only",
        "--account-name", env["storage"], "--container-name", container, "--name", blob,
        "--permissions", permissions, "--expiry", expiry, "--full-uri", "--output", "tsv",
    ], parse_json=False)
    if rc != 0 or not stdout.startswith("https://"):
        raise ValidationError("exact-object SAS creation failed: {}".format(stderr))
    return stdout


def read_resource(env, resource_id, kind):
    url = "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind])
    result, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
    if rc == 0:
        return True, result
    listing, list_rc, list_stderr = az_command(env, ["resource", "list", "--resource-group", env["resource_group"]], check=False)
    if list_rc != 0:
        raise ValidationError("{} absence is ambiguous: {}; {}".format(kind, stderr, list_stderr))
    if any(str(item.get("id", "")).lower() == resource_id.lower() for item in listing):
        raise ValidationError("{} exists but immutable identity is unreadable".format(kind))
    return False, None


def immutable_identity(resource, kind):
    properties = resource.get("properties", resource)
    identity = {"id": str(resource.get("id", "")).lower(), "etag": resource.get("etag") or properties.get("etag")}
    if kind == "vm":
        identity["instance_id"] = properties.get("vmId") or resource.get("vmId")
    elif kind == "nic":
        identity["resource_guid"] = properties.get("resourceGuid")
    elif kind == "disk":
        identity["unique_id"] = properties.get("uniqueId")
        identity["etag"] = identity["etag"] or identity["unique_id"]
    elif kind == "identity":
        identity["client_id"] = properties.get("clientId")
        identity["principal_id"] = properties.get("principalId")
    stable_keys = {
        "vm": ("instance_id",),
        "nic": ("resource_guid",),
        "disk": ("unique_id",),
        "identity": ("client_id", "principal_id"),
        "run-command": (),
        "ttl-schedule": (),
    }
    if (
        not identity["id"]
        or (kind not in ("identity", "run-command", "ttl-schedule") and not identity["etag"])
        or any(not identity.get(key) for key in stable_keys.get(kind, ()))
    ):
        raise ValidationError("{} immutable identity is incomplete".format(kind))
    return identity


def same_stable_identity(recorded, live, kind):
    keys = {
        "vm": ("id", "instance_id"),
        "nic": ("id", "resource_guid"),
        "disk": ("id", "unique_id"),
        "identity": ("id", "client_id", "principal_id"),
        "run-command": ("id",),
        "ttl-schedule": ("id",),
    }.get(kind, ("id",))
    return bool(recorded) and all(
        recorded.get(key) and recorded.get(key) == live.get(key) for key in keys
    )


def disk_is_attached(resource):
    properties = resource.get("properties", resource)
    return bool(
        resource.get("managedBy")
        or properties.get("managedBy")
        or resource.get("managedByExtended")
        or properties.get("managedByExtended")
    )


def expected_tags(state, selected):
    request = state["request"]
    return {
        "workload": "firstmate",
        "firstmate-role": "validation-cell",
        "lifecycle": "elastic-scale-to-zero",
        "deployment-generation": request["deployment_generation"],
        "cleanup-owner": selected["owner"],
        "home-binding": request["home_binding"],
        "task-binding": request["task"],
        "task-generation": request["task_generation"],
        "validation-generation": request["validation_generation"],
        "validation-cell": state["cell"],
        "fence": request["fence"],
        "branch-binding": sha256_bytes(request["repository"]["branch"].encode("utf-8")),
        "head-binding": request["repository"]["head"],
        "worktree-binding": sha256_bytes(state["resources"]["worktree_disk_id"].encode("utf-8")),
        "resource-class": request["resource_class"],
        "selected-sku": selected["sku"],
        "sku-family": selected["family"],
        "reserved-vcpus": str(request["limits"]["reserved_vcpus"]),
        "behavior-shards": str(request["limits"]["behavior_shards"]),
        "cost-attribution": "validation-review",
    }


def deployment_parameters(env, state, selected, replacement=False):
    resources = state["resources"]
    request = state["request"]
    subnet_id = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/virtualNetworks/{}/subnets/{}".format(
        env["subscription"], env["resource_group"], env["vnet"], env["subnet"]
    )
    expiry_value = now_utc() + dt.timedelta(hours=MAX_CELL_LIFETIME_HOURS - 1)
    expiry = iso_utc(expiry_value)
    zone = os.environ.get("FM_AZURE_VALIDATION_ZONE", "1")
    if zone not in ("1", "2", "3"):
        raise ValidationError("FM_AZURE_VALIDATION_ZONE must be 1, 2, or 3")
    return {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "region": {"value": "eastus"},
            "zone": {"value": zone},
            "vmName": {"value": resources["vm_name"]},
            "nicName": {"value": resources["nic_name"]},
            "osDiskName": {"value": resources["os_disk_name"]},
            "worktreeDiskName": {"value": resources["worktree_disk_name"]},
            "worktreeDiskId": {"value": resources["worktree_disk_id"]},
            "createWorktreeDisk": {"value": not replacement},
            "authShareName": {"value": auth_share_name()},
            "identityName": {"value": resources["identity_name"]},
            "storageAccountName": {"value": env["storage"]},
            "shardContainerName": {"value": state["staging"]["container"]},
            "runnerOperatorPrincipalId": {"value": env["operator_object_id"]},
            "subnetId": {"value": subnet_id},
            "vmSize": {"value": selected["sku"]},
            "worktreeDiskGiB": {"value": request["limits"]["worktree_gib"]},
            "expiryUtc": {"value": expiry},
            "expiryTimeOfDay": {"value": expiry_value.strftime("%H%M")},
            "tags": {"value": expected_tags(state, selected)},
            # Optional golden image: an empty value keeps the marketplace
            # base; the guests re-verify every staged archive digest at
            # boot either way, so the image only caches the bootstrap.
            "imageId": {"value": os.environ.get("FM_AZURE_VM_IMAGE_ID", "")},
        },
    }


def adopt_resources(env, state):
    resources = state["resources"]
    request = state["request"]
    identities = {}
    for kind, resource_id, identity_key in (
        ("vm", resources["vm_id"], "vm"),
        ("nic", resources["nic_id"], "nic"),
        ("disk", resources["os_disk_id"], "disk"),
        ("run-command", resources["safety_run_command_id"], "run-command-safety"),
        ("ttl-schedule", resources["ttl_schedule_id"], "ttl-schedule"),
    ):
        exists, resource = read_resource(env, resource_id, kind)
        if not exists:
            raise ValidationError("created {} disappeared before identity adoption".format(kind))
        tags = resource.get("tags") or {}
        if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
            raise ValidationError("created {} has foreign validation identity".format(kind))
        identities[identity_key] = immutable_identity(resource, kind)
    exists, identity_resource = read_resource(env, resources["identity_id"], "identity")
    if not exists:
        raise ValidationError("cell-scoped storage identity is absent after deployment")
    identity = immutable_identity(identity_resource, "identity")
    client_id = identity_resource.get("properties", {}).get("clientId") or identity_resource.get("clientId")
    principal_id = identity_resource.get("properties", {}).get("principalId") or identity_resource.get("principalId")
    if not UUID.match(str(client_id)) or not UUID.match(str(principal_id)):
        raise ValidationError("cell-scoped storage identity lacks immutable client/principal ids")
    container_scope = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}/blobServices/default/containers/{}".format(
        env["subscription"], env["resource_group"], env["storage"], state["staging"]["container"]
    )
    assignments, _, _ = az_command(env, [
        "role", "assignment", "list", "--assignee-object-id", principal_id,
        "--all", "--include-inherited", "--include-groups",
    ])
    blob_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    file_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
    )
    expected_grants = {(container_scope.lower(), blob_role.lower())}
    if auth_share_name():
        # The deployment grants the cell identity file-data access for the
        # persistent auth share alongside its private-container blob grant.
        expected_grants.add((storage_account_scope(env).lower(), file_role.lower()))
    if (
        not isinstance(assignments, list)
        or any(
            str(item.get("principalId", "")).lower() != str(principal_id).lower()
            for item in assignments
        )
        or {
            (str(item.get("scope", "")).lower(), str(item.get("roleDefinitionId", "")).lower())
            for item in assignments
        } != expected_grants
    ):
        raise ValidationError("cell identity effective RBAC exceeds its exact container and auth-share grants")
    identities["identity"] = identity
    resources["identity_client_id"] = client_id
    resources["identity_principal_id"] = principal_id
    exists, worktree = read_resource(env, resources["worktree_disk_id"], "disk")
    if not exists:
        raise ValidationError("durable worktree disk is absent after deployment")
    tags = worktree.get("tags") or {}
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("durable worktree disk identity is foreign")
    identities["worktree"] = immutable_identity(worktree, "disk")
    resources["identities"] = identities
    resources["vm_instance_id"] = identities["vm"]["instance_id"]
    save_state(env, state)


def create_cell(env, state, selected, replacement=False):
    params = write_private_json(env, ".cell-params-", deployment_parameters(env, state, selected, replacement))
    try:
        az_command(env, [
            "deployment", "group", "create", "--resource-group", env["resource_group"],
            "--name", state["resources"]["deployment"], "--template-file", str(TEMPLATE),
            "--parameters", "@" + str(params), "--mode", "Incremental",
        ])
    finally:
        params.unlink(missing_ok=True)
    adopt_resources(env, state)


def sealed_guest_text(env, state):
    """The exact guest text this cell's request was sealed with.

    The seal binds the guest a cell was ADMITTED with. Reading the working tree
    instead made that seal depend on the tree never changing, so ANY later edit
    to the guest refused `respond`, `reattach` AND `replace` on every cell
    already in flight, stranding them with no recovery (`replace` is the only
    documented way out of `failed-retained`, and it routes through here too).
    `submit` stages a byte copy of the guest beside the request, so that copy is
    the sealed artifact and is what a resumed attempt must run. The working tree
    is used only when it still matches the seal, which keeps a cell whose
    payload was pruned behaving exactly as before. Neither source is trusted on
    provenance: the bytes are read ONCE, digested in memory, and those exact
    bytes are what is returned, so what executes on the cell is what was
    verified rather than whatever a later read would have found. This widens
    recovery without widening what may execute.
    """
    expected = state["request"]["protocol"]["guest_digest"]
    candidates = []
    state_dir = env.get("state_dir")
    if state_dir:
        candidates.append(Path(state_dir) / "payloads" / state["cell"] / "guest.sh")
    candidates.append(GUEST)
    for candidate in candidates:
        try:
            if not candidate.is_file() or candidate.is_symlink():
                continue
        except OSError:
            continue
        # ONE read. Digesting the file and then re-reading it to return would
        # verify bytes that are not the bytes returned: a writer landing between
        # the two reads passes the check and ships different content, and that
        # content is uploaded as the Run Command script and executes as root on
        # the cell. Digest exactly the bytes that are handed back.
        try:
            data = candidate.read_bytes()
        except OSError:
            continue
        if "sha256:" + hashlib.sha256(data).hexdigest() == expected:
            try:
                return data.decode("utf-8")
            except UnicodeDecodeError:
                continue
    raise ValidationError(
        "no guest matching this cell's exact sealed request digest is available; "
        "neither the staged payload copy nor the working tree carries {}".format(expected)
    )


def trusted_hydrator_text():
    """Return the exact current guest bytes used only for replacement hydration.

    A cell resume still executes its original digest-sealed guest. The current
    guest is a separate root-side bootstrap whose only authority is to restore
    the exact runtime and shard bridge from that cell's original sealed input.
    Read once so the digest recorded by the controller binds the bytes sent to
    Azure rather than a different read of a mutable working-tree file.
    """
    try:
        if not GUEST.is_file() or GUEST.is_symlink():
            raise ValidationError("replacement hydrator is not a regular file")
        data = GUEST.read_bytes()
        text = data.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ValidationError("replacement hydrator is unreadable: {}".format(exc))
    return text, sha256_bytes(data)


def guest_text_stamps_attempt(text):
    """Does this exact guest text emit an attempt-stamped result marker?"""
    return bool(GUEST_STAMPS_ATTEMPT.search(text))


def guest_stamps_attempt(env, state):
    """Whether this cell's SEALED guest can name the attempt in its marker.

    Read from the guest, never inferred from the output. Inferring it from "no
    stamped marker matched" hands the weaker pre-stamp contract to any cell
    whose marker is merely MALFORMED, and the marker is the guest's last line by
    design, which is exactly where an output cap lands. The consequence is not
    theoretical: a stale attempt-1 marker truncated inside its own attempt field
    makes the stamped set empty, binds legacy, sets the expected digest to
    attempt 1's own, matches the blob that still holds attempt 1's archive, and
    skips the attempt check - accepting attempt 1's result as attempt 2's
    answer, which is the exact silent false verdict this binding exists to
    prevent. Recorded at create time where the sealed text is already in hand,
    and derived from the sealed guest for a cell whose state predates that.
    An underivable answer takes the STRICT contract, never the weaker one.
    """
    recorded = state.get("guest_stamps_attempt")
    if isinstance(recorded, bool):
        return recorded
    try:
        return guest_text_stamps_attempt(sealed_guest_text(env, state))
    except (ValidationError, KeyError, TypeError, OSError):
        # A state that cannot answer the question at all - no seal recorded, no
        # staged payload, a truncated request - is not evidence that the guest
        # cannot stamp. Take the STRICT contract: the worst case is a cell that
        # must be observed again, never one that accepts another attempt's
        # result as this attempt's answer.
        return True


def create_run_command(env, state, mode, input_url=None, output_url=None, response=None):
    resources = state["resources"]
    guest_text = sealed_guest_text(env, state)
    # Recorded from the bytes that are about to run, so observe never has to
    # guess it from output that may be truncated.
    state["guest_stamps_attempt"] = guest_text_stamps_attempt(guest_text)
    attempt = state["attempt"]
    name = "{}-a{}".format(mode, attempt)
    run_id = resources["vm_id"] + "/runCommands/" + name
    arguments = [
        {"name": "mode", "value": mode},
        {"name": "input_digest", "value": state["input_digest"]},
        {"name": "request_digest", "value": state["request_digest"]},
        {"name": "cell", "value": state["cell"]},
        {"name": "attempt", "value": str(attempt)},
        {"name": "vm_resource_id", "value": resources["vm_id"]},
        {"name": "vm_instance_id", "value": resources["vm_instance_id"]},
        {"name": "worktree_disk_id", "value": resources["worktree_disk_id"]},
        {"name": "storage_account", "value": env["storage"]},
        {"name": "storage_container", "value": state["staging"]["container"]},
        {"name": "identity_client_id", "value": resources["identity_client_id"]},
        {"name": "auth_share", "value": auth_share_name()},
    ]
    protected = []
    if input_url:
        protected.append({"name": "input_url", "value": input_url})
    if output_url:
        protected.append({"name": "output_url", "value": output_url})
    if response is not None:
        protected.append({"name": "response", "value": response})
    # Boot-time credential injection: the token reaches the guest as a
    # run-command parameter and never lands in durable state files.
    protected.append({"name": "github_token", "value": read_github_token(state)})
    selected = {
        "sku": state["allocation"]["sku"],
        "family": state["allocation"]["sku_family"],
        "owner": env["owner"],
    }
    run_tags = expected_tags(state, selected)
    run_tags["attempt"] = str(attempt)
    body_value = {
        "location": "eastus",
        "tags": run_tags,
        "properties": {
            "source": {"script": guest_text},
            "parameters": arguments,
            "protectedParameters": protected,
            "asyncExecution": True,
            "timeoutInSeconds": state["request"]["limits"]["wall_seconds"] + 1800,
            "treatFailureAsDeploymentFailure": False,
        },
    }
    body = write_private_json(env, ".cell-run-", body_value)
    try:
        az_command(env, [
            "rest", "--method", "put",
            "--url", "https://management.azure.com{}?api-version={}".format(run_id, RESOURCE_API["run-command"]),
            "--body", "@" + str(body),
        ])
    finally:
        body.unlink(missing_ok=True)
    exists, run_command = read_resource(env, run_id, "run-command")
    if not exists:
        raise ValidationError("created validation Run Command disappeared before identity adoption")
    tags = run_command.get("tags") or {}
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("created validation Run Command has foreign identity")
    resources["run_command_name"] = name
    resources["run_command_id"] = run_id
    # Every attempt starts its own settling window: a stamp left by the
    # previous attempt's unbound view must never shorten this one's.
    state.pop("unbound_view_since", None)
    resources.setdefault("run_commands", []).append({
        "id": run_id,
        "identity": immutable_identity(run_command, "run-command"),
    })
    save_state(env, state)


def hydration_marker(state, hydrator_digest):
    return (
        "FM_AZURE_VALIDATION_HYDRATED source={} input={} request={} "
        "runtime={} bridge={} attempt={}".format(
            hydrator_digest,
            state["input_digest"],
            state["request_digest"],
            state["request"]["runtime_digest"],
            state["request"]["protocol"]["shard_bridge_digest"],
            state["attempt"],
        )
    )


def hydration_command_binding_matches(resource, guest_text, arguments):
    properties = resource.get("properties") or {}
    source = properties.get("source") or {}
    if source.get("script") != guest_text:
        return False
    observed = properties.get("parameters")
    if not isinstance(observed, list):
        return False
    expected_by_name = {item["name"]: str(item["value"]) for item in arguments}
    observed_by_name = {
        item.get("name"): str(item.get("value"))
        for item in observed
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if (
        len(expected_by_name) != len(arguments)
        or len(observed_by_name) != len(observed)
        or observed_by_name != expected_by_name
    ):
        return False
    protected = properties.get("protectedParameters")
    if protected is not None:
        if not isinstance(protected, list):
            return False
        names = [
            item.get("name")
            for item in protected
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        ]
        if names != ["input_url"]:
            return False
    return True


def create_runtime_hydration_command(env, state, input_url):
    """Restore OS-disk-only sealed tools before the unchanged guest resumes."""
    resources = state["resources"]
    guest_text, hydrator_digest = trusted_hydrator_text()
    attempt = state["attempt"]
    name = "hydrate-a{}".format(attempt)
    run_id = resources["vm_id"] + "/runCommands/" + name
    arguments = [
        {"name": "mode", "value": "hydrate"},
        {"name": "input_digest", "value": state["input_digest"]},
        {"name": "request_digest", "value": state["request_digest"]},
        {"name": "cell", "value": state["cell"]},
        {"name": "attempt", "value": str(attempt)},
        {"name": "vm_resource_id", "value": resources["vm_id"]},
        {"name": "vm_instance_id", "value": resources["vm_instance_id"]},
        {"name": "worktree_disk_id", "value": resources["worktree_disk_id"]},
        {"name": "storage_account", "value": env["storage"]},
        {"name": "storage_container", "value": state["staging"]["container"]},
        {"name": "identity_client_id", "value": resources["identity_client_id"]},
        {"name": "auth_share", "value": auth_share_name()},
        {"name": "hydrator_digest", "value": hydrator_digest},
    ]
    selected = {
        "sku": state["allocation"]["sku"],
        "family": state["allocation"]["sku_family"],
        "owner": env["owner"],
    }
    run_tags = expected_tags(state, selected)
    run_tags["attempt"] = str(attempt)
    body_value = {
        "location": "eastus",
        "tags": run_tags,
        "properties": {
            "source": {"script": guest_text},
            "parameters": arguments,
            "protectedParameters": [{"name": "input_url", "value": input_url}],
            "asyncExecution": True,
            "timeoutInSeconds": RUNTIME_HYDRATION_TIMEOUT_SECONDS,
            "treatFailureAsDeploymentFailure": False,
        },
    }
    body = write_private_json(env, ".cell-hydrate-", body_value)
    try:
        az_command(env, [
            "rest", "--method", "put",
            "--url", "https://management.azure.com{}?api-version={}".format(
                run_id, RESOURCE_API["run-command"]
            ),
            "--body", "@" + str(body),
        ])
    finally:
        body.unlink(missing_ok=True)
    exists, run_command = read_resource(env, run_id, "run-command")
    if not exists:
        raise ValidationError("created runtime hydration command disappeared before identity adoption")
    tags = run_command.get("tags") or {}
    if (
        tags.get("validation-cell") != state["cell"]
        or tags.get("fence") != state["request"]["fence"]
        or not hydration_command_binding_matches(run_command, guest_text, arguments)
    ):
        raise ValidationError("created runtime hydration command has foreign identity")
    identity = immutable_identity(run_command, "run-command")
    resources.setdefault("run_commands", []).append({
        "id": run_id,
        "identity": identity,
        "purpose": "runtime-hydration",
        "source_digest": hydrator_digest,
    })
    save_state(env, state)
    execution, view = wait_run_command_terminal(
        env, run_id, RUNTIME_HYDRATION_TIMEOUT_SECONDS
    )
    completed_exists, completed = read_resource(env, run_id, "run-command")
    completed_tags = (completed.get("tags") or {}) if completed_exists else {}
    if (
        not completed_exists
        or completed_tags.get("validation-cell") != state["cell"]
        or completed_tags.get("fence") != state["request"]["fence"]
        or not hydration_command_binding_matches(completed, guest_text, arguments)
        or not same_stable_identity(
            identity, immutable_identity(completed, "run-command"), "run-command"
        )
    ):
        raise ValidationError(
            "runtime hydration command identity changed before completion proof"
        )
    if execution != "Succeeded":
        detail = str((view or {}).get("error", ""))[-2000:]
        raise ValidationError(
            "exact replacement runtime hydration {}: {}".format(
                execution.lower(), detail
            )
        )
    output = str((view or {}).get("output", ""))
    expected = hydration_marker(state, hydrator_digest)
    if output.splitlines().count(expected) != 1:
        raise ValidationError("replacement runtime hydration returned no unique exact digest marker")
    state.setdefault("runtime_hydrations", []).append({
        "attempt": attempt,
        "at": iso_utc(),
        "run_command_id": run_id,
        "run_command_identity": identity,
        "hydrator_digest": hydrator_digest,
        "input_digest": state["input_digest"],
        "request_digest": state["request_digest"],
        "runtime_digest": state["request"]["runtime_digest"],
        "shard_bridge_digest": state["request"]["protocol"]["shard_bridge_digest"],
    })
    save_state(env, state)


def dispatch_cell(env, state, lane):
    """Admit one queued/starting cell into its lane; returns started or queued."""
    if state["request"]["deployment_generation"] != env["deployment_generation"]:
        raise ValidationError("queued request deployment generation differs from the live foundation")
    live_resources = resource_names(env, state["cell"].split("-", 1)[1])
    expected_bindings = state["request"].get("resource_bindings") or {}
    actual_bindings = {
        "vm_id": live_resources["vm_id"],
        "worktree_disk_id": live_resources["worktree_disk_id"],
        "identity_id": live_resources["identity_id"],
        "shard_container": state["staging"]["container"],
    }
    if expected_bindings != actual_bindings:
        raise ValidationError("queued run resource bindings differ from the exact live foundation scope")
    recovering = state["phase"] == "starting"
    if recovering:
        for key, value in live_resources.items():
            if key.endswith("_id") and state.get("resources", {}).get(key) != value:
                raise ValidationError("starting cell resource bindings differ from its exact recorded identities")
    else:
        state["resources"] = live_resources
        state["lane"] = lane
        save_state(env, state)
    if recovering:
        lane = state.get("lane", lane)
        allocation = state.get("allocation") or {}
        admission = state.get("admission") or {}
        selected = {
            "sku": allocation.get("sku"),
            "family": allocation.get("sku_family"),
            "rate": admission.get("hourly_rate"),
            "owner": env["owner"],
        }
        if (
            selected["sku"] not in VALIDATION_SKUS
            or not selected["family"] or not isinstance(selected["rate"], (int, float))
            or admission.get("shape_id") != state["cell"]
            or len(admission.get("shard_plan") or []) != state["request"]["limits"]["behavior_shards"]
        ):
            raise ValidationError("starting cell lacks its exact allocation and shape reservation")
    else:
        limits = state["request"]["limits"]
        candidates = sku_candidates(env, limits["vcpus"], limits["memory_gib"])
        # The lane's deterministic pool SKU keeps concurrent coordinator
        # cells in distinct families; a lane SKU that is not currently live
        # falls back to the cheapest live candidate.
        preferred = lane_sku(lane)
        selected = next((item for item in candidates if item["sku"] == preferred), candidates[0])
        selected["owner"] = env["owner"]
        shape = shared_shape_reserve(env, state, selected)
        if shape["status"] != "reserved":
            state.setdefault("admission", {})["shard_plan"] = shape["shard_plan"]
            state["admission"]["last_refusal"] = {"at": iso_utc(), "reason": shape.get("reason", "")[:400]}
            save_state(env, state)
            print("AZURE VALIDATION QUEUED cell={} reason={}".format(state["cell"], shape.get("reason", "")))
            return "queued"
        state["allocation"] = {"sku": selected["sku"], "sku_family": selected["family"]}
        state["admission"] = {
            "at": iso_utc(), "sku": selected["sku"], "sku_family": selected["family"],
            "hourly_rate": selected["rate"],
            "actual_usd": shape.get("actual_usd"), "forecast_usd": shape.get("forecast_usd"),
            "admission_limit_usd": shape.get("admission_limit_usd"),
            "shape_id": state["cell"], "capacity_fence": state["request"]["fence"].split(":", 1)[-1],
            "control_amount_usd": shape["control_amount_usd"],
            "shard_plan": shape["shard_plan"],
        }
        transition(env, state, "starting", "shared allocator atomically reserved the complete specialized shape")
    create_cell(env, state, selected)
    storage_upload_after_role(
        env, Path(state["input_path"]), state["staging"]["input_blob"],
        state["staging"]["container"],
    )
    input_url = blob_sas(
        env, state["staging"]["input_blob"], "r", container=state["staging"]["container"]
    )
    output_url = blob_sas(
        env, state["staging"]["result_blob"], "cw", container=state["staging"]["container"]
    )
    create_run_command(env, state, "start", input_url=input_url, output_url=output_url)
    transition(env, state, "running", "isolated per-run no-mistakes cell started", started_at=iso_utc())
    print("AZURE VALIDATION STARTED cell={} lane={} sku={} head={}".format(
        state["cell"], state.get("lane"), selected["sku"], state["request"]["repository"]["head"]
    ))
    return "started"


def dispatch(env, args):
    """Admit queued generations FIFO into free lanes, one cell per lane.

    Recovery of a starting cell comes first (it already owns its lane), then
    queued cells oldest-first while a lane is free. Strict FIFO: a shape the
    allocator queues stops admission so younger work never jumps the line.
    """
    if not args.confirm_dispatch or args.confirm_subscription != env["subscription"]:
        raise ValidationError("billable dispatch requires --confirm-dispatch and the exact subscription")
    with lock(env):
        candidates = [
            state for state in all_states(env)
            if state.get("phase") in ("queued", "starting")
        ]
        candidates.sort(key=lambda item: (
            0 if item.get("phase") == "starting" else 1,
            item.get("created_at", ""), item.get("cell", ""),
        ))
        if not candidates:
            print("AZURE VALIDATION QUEUE empty active={}".format(len(occupied_states(env))))
            return
        # A queued submission whose shape reservation has been released is
        # a superseded corpse, not a candidate: dispatching it runs a cell
        # outside its capacity accounting and every shard transport fails
        # on its released constituent (generation 054 ground truth, where
        # an operator supersede raced this FIFO). Skip released fences.
        controller_path = env["home"] / "state" / "azure-workers" / "controller.json"
        try:
            reservations = json.loads(controller_path.read_text(encoding="utf-8")).get("capacity_reservations", {})
        except (OSError, json.JSONDecodeError):
            reservations = {}
        live = []
        for item in candidates:
            entry = reservations.get(item.get("cell"))
            if entry is not None and entry.get("status") == "released":
                print("AZURE VALIDATION SKIPPED cell={} shape reservation already released".format(item.get("cell")))
                continue
            live.append(item)
        candidates = live
        if not candidates:
            print("AZURE VALIDATION QUEUE empty active={}".format(len(occupied_states(env))))
            return
        scope_gate(env)
        foundation_gate(env)
        started = 0
        for candidate in candidates:
            occupied = occupied_states(env, exclude_cell=candidate["cell"])
            if candidate["phase"] == "queued" and len(occupied) >= env["lanes"]:
                print("AZURE VALIDATION LANES FULL used={}/{} queued={}".format(
                    len(occupied), env["lanes"], count_queued(env)
                ))
                break
            used_lanes = {
                state.get("lane") for state in occupied
                if isinstance(state.get("lane"), int)
            }
            lane = (
                candidate.get("lane")
                if candidate["phase"] == "starting" and isinstance(candidate.get("lane"), int)
                else next_free_lane(used_lanes, env["lanes"])
            )
            outcome = dispatch_cell(env, candidate, lane)
            if outcome != "started":
                break
            started += 1
        print("AZURE VALIDATION DISPATCH started={} lanes_used={}/{} queued={}".format(
            started, len(occupied_states(env)), env["lanes"], count_queued(env)
        ))


def run_command_status_for_id(env, run_id):
    url = "https://management.azure.com{}?api-version={}&$expand=instanceView".format(run_id, RESOURCE_API["run-command"])
    value, rc, stderr = az_command(env, ["rest", "--method", "get", "--url", url], check=False)
    if rc != 0:
        return "unreadable", stderr
    properties = value.get("properties", {})
    view = properties.get("instanceView") or {}
    execution = str(view.get("executionState", "Unknown"))
    return execution, view


def wait_run_command_terminal(env, run_id, timeout_seconds):
    deadline = time.monotonic() + timeout_seconds
    while True:
        execution, view = run_command_status_for_id(env, run_id)
        if execution in ("Succeeded", "Failed", "Canceled", "TimedOut"):
            return execution, view
        if execution == "unreadable":
            raise ValidationError(
                "runtime hydration status is unreadable; resume command was not started: {}".format(
                    view
                )
            )
        if time.monotonic() >= deadline:
            raise ValidationError(
                "runtime hydration did not finish inside its bounded timeout; resume command was not started"
            )
        time.sleep(5)


def run_command_status(env, state):
    run_id = state["resources"].get("run_command_id")
    if not run_id:
        return "missing", None
    return run_command_status_for_id(env, run_id)


def observe(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("running", "reattaching", "responding", "needs-decision"):
            print_status(state)
            return
        execution, view = run_command_status(env, state)
        if execution in ("Running", "Pending", "Unknown"):
            print("AZURE VALIDATION RUNNING cell={} head={} attempt={}".format(state["cell"], state["request"]["repository"]["head"], state["attempt"]))
            return
        if execution == "unreadable":
            raise ValidationError("cell status is unreadable; duplicate execution is forbidden: {}".format(view))
        if execution not in ("Succeeded", "Failed", "Canceled", "TimedOut"):
            print("AZURE VALIDATION RUNNING cell={} control_state={}".format(state["cell"], execution))
            return
        output = str((view or {}).get("output", ""))
        error = str((view or {}).get("error", ""))
        stamped = list(MARKER.finditer(output))
        # Accept ANY marker naming the attempt being observed, not merely the
        # first one in the output: re.search would hand back an earlier
        # attempt's line and retain an attempt that completed correctly.
        mine = {
            (found.group(1), found.group(2), found.group(3))
            for found in stamped
            if int(found.group(4)) == state["attempt"]
        }
        binding = "attempt"
        if len(mine) > 1:
            # Two different results claiming one attempt is not an answer.
            mine = set()
        if not mine and not stamped and not guest_stamps_attempt(env, state):
            # No stamped marker anywhere AND the sealed guest provably cannot
            # stamp. The second half is what keeps a malformed marker from
            # buying the weaker contract. Either nothing published, or the cell
            # runs a guest sealed BEFORE the stamp existed. That guest cannot be
            # changed, because the request is digest-sealed, so refusing to read
            # it would strand every cell in flight across this upgrade: the
            # attempt would be retained on a fully-published result and
            # `expected_result_digest` would never be set, making the result
            # unreachable. Fall back to the pre-stamp shape, which is consulted
            # ONLY here because MARKER's prefix is exactly that shape and would
            # otherwise match a stamped marker too. A stamped marker naming
            # another attempt never reaches this branch and still fails closed.
            legacy = LEGACY_MARKER.search(output)
            if legacy:
                mine = {(legacy.group(1), legacy.group(2), legacy.group(3))}
                binding = "legacy"
        if not mine:
            # A terminal control state whose output does not carry THIS
            # attempt's marker proves nothing about this attempt. The run
            # command, the VM, the boot, and every identity field in
            # result.json are shared across the attempts of one run, so an
            # unbound view is ambiguous between "the guest died before
            # publishing" and "the control plane has not caught up with the
            # attempt just created". Retaining on the first such read is
            # destructive and unrecoverable: failed-retained is a phase
            # observe itself refuses, so one premature poll strands a cell
            # whose attempt is still executing (generation azv-36b2 ground
            # truth: read nine seconds after the respond Run Command was
            # created). Fail closed by never ACCEPTING an unbound view, and
            # take the terminal decision only once the ambiguity persists.
            settle_seconds = marker_settle_seconds()
            since = state.get("unbound_view_since")
            if not since:
                state["unbound_view_since"] = iso_utc()
                save_state(env, state)
                since = state["unbound_view_since"]
            waited = seconds_since(since)
            if waited is None or waited < settle_seconds:
                observed = ",".join(sorted({found.group(4) for found in stamped})) or "none"
                print(
                    "AZURE VALIDATION UNSETTLED cell={} attempt={} control_state={} "
                    "marker_attempt={} waited={}s settle={}s".format(
                        state["cell"], state["attempt"], execution,
                        observed, "unknown" if waited is None else int(waited), settle_seconds,
                    )
                )
                return
            transition(env, state, "failed-retained", "cell ended without an authenticated result marker", control_error=error[-2000:])
            raise ValidationError("cell ended without an authenticated result; worktree and lease remain retained")
        state.pop("unbound_view_since", None)
        digest, boot_id, outcome = next(iter(mine))
        # How this observation was bound decides how strictly the collected
        # result is checked. A stamped marker means the guest can name its
        # attempt, so its result MUST; a legacy marker cannot, so it is held to
        # the pre-stamp contract instead of being refused.
        state["result_binding"] = binding
        # A republished byte-identical result is a non-answer, not a verdict.
        # An attempt that resumes a parked run without answering its gate, or
        # one whose upload never happened and left the previous attempt's
        # archive in place, publishes the exact bytes the previous attempt
        # did. Name that instead of surfacing a generic failure.
        previous = state.get("attempt_result_digests") or {}
        stale = sorted(
            key for key, value in previous.items()
            if value == digest and key != str(state["attempt"])
        )
        if stale:
            transition(
                env, state, "failed-retained",
                "attempt republished attempt {} result unchanged; the gate was not answered".format(
                    ", ".join(stale)
                ),
                control_error=error[-2000:],
            )
            raise ValidationError(
                "attempt {} published a byte-identical copy of attempt {}'s result; the operator "
                "response did not reach the in-cell pipeline, so this is a non-answer, not a "
                "verdict".format(state["attempt"], ", ".join(stale))
            )
        previous[str(state["attempt"])] = digest
        state["attempt_result_digests"] = previous
        state["expected_result_digest"] = digest
        state["expected_boot_id"] = boot_id
        if outcome == "needs-decision":
            transition(env, state, "needs-decision", "no-mistakes ask-user gate owns the exact run")
        else:
            transition(env, state, "result-published", "cell published an exact identity-bound result", reported_outcome=outcome)
        print_status(state)


def safe_extract_result(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        allowed = {"result.json", "run.log", "report.md", "evidence"}
        for member in members:
            name = member.name
            if name in allowed or name.startswith("evidence/"):
                pass
            else:
                raise ValidationError("result archive contains undeclared path: {}".format(name))
            if member.issym() or member.islnk() or member.isdev() or member.name.startswith("/") or ".." in member.name.split("/"):
                raise ValidationError("result archive contains unsafe member")
            target = (destination / name).resolve()
            if target != destination.resolve() and destination.resolve() not in target.parents:
                raise ValidationError("result archive escapes destination")
        archive.extractall(str(destination), members=members)


def verify_result_identity(state, result):
    expected = {
        "schema": RESULT_SCHEMA,
        "request_digest": state["request_digest"],
        "cell": state["cell"],
        "home_binding": state["request"]["home_binding"],
        "task": state["request"]["task"],
        "task_generation": state["request"]["task_generation"],
        "validation_generation": state["request"]["validation_generation"],
        "fence": state["request"]["fence"],
        "branch": state["request"]["repository"]["branch"],
        "submitted_head": state["request"]["repository"]["head"],
        "worktree_disk_id": state["resources"]["worktree_disk_id"],
        "vm_resource_id": state["resources"]["vm_id"],
        "vm_instance_id": state["resources"]["vm_instance_id"],
        "boot_id": state.get("expected_boot_id"),
    }
    for key, wanted in expected.items():
        if result.get(key) != wanted:
            raise ValidationError("validation result identity mismatch: {}".format(key))
    # The attempt is the only field separating one attempt's result from
    # another's on a resumed run, so where the guest can name it, it is required
    # rather than defaulted: a result that does not declare its attempt is
    # refused, never assumed to be the current one. `result_binding` is set by
    # observe from the marker it actually read, so a cell whose sealed guest
    # predates the stamp is held to the pre-stamp contract instead of being
    # refused, and every cell that CAN prove its attempt still must.
    if state.get("result_binding", "attempt") != "legacy":
        if not isinstance(result.get("attempt"), int) or isinstance(result.get("attempt"), bool):
            raise ValidationError("validation result does not declare the attempt that produced it")
        if result["attempt"] != state["attempt"]:
            raise ValidationError(
                "validation result was produced by attempt {}, not the observed attempt {}".format(
                    result["attempt"], state["attempt"]
                )
            )
    head = result.get("current_head")
    tree = result.get("current_tree")
    if (
        not isinstance(head, str) or not HEX_OBJECT.match(head)
        or not isinstance(tree, str) or not HEX_OBJECT.match(tree)
    ):
        raise ValidationError("validation result current head/tree is malformed")
    run_id = result.get("run_id")
    if not isinstance(run_id, str) or not NM_RUN_ID.match(run_id):
        raise ValidationError("validation result lacks the exact no-mistakes run id")
    if result.get("outcome") in ("passed", "checks-passed"):
        expected_pr_prefix = "https://github.com/{}/pull/".format(state["request"]["repository"]["slug"])
        if (
            not result.get("checks_green")
            or not PR_URL.match(str(result.get("pr_url", "")))
            or not str(result.get("pr_url", "")).startswith(expected_pr_prefix)
        ):
            raise ValidationError("successful result lacks repository-scoped CI-green PR proof")
        if result.get("remote_head") != head:
            raise ValidationError("successful result is not current with the exact remote head")
        shard_receipts = result.get("behavior_shards")
        expected_shards = state["request"]["limits"]["behavior_shards"]
        if not isinstance(shard_receipts, list) or len(shard_receipts) != expected_shards:
            raise ValidationError("successful result lacks the complete behavior-shard receipt set")
        expected_indexes = set(range(1, expected_shards + 1))
        indexes = set()
        boots = set()
        machines = set()
        invocations = set()
        rounds = set()
        receipt_heads = set()
        receipt_trees = set()
        # Receipts must be this cell's own shard round, not merely a
        # well-formed set at an ancestor head. The controller recorded every
        # shard it dispatched for this run in shard_runs (keyed by the shard
        # request digest, carrying the round, shard index, head, command, and
        # invocation it actually created), so an alien round smuggled onto the
        # durable disk cannot correspond and is refused here rather than
        # trusted on disk structure alone.
        dispatched = state.get("shard_runs") or {}
        for item in shard_receipts:
            if not isinstance(item, dict):
                raise ValidationError("behavior shard receipt is malformed")
            if (
                item.get("kind") != "behavior"
                or item.get("shard_count") != expected_shards
                or not HEX_OBJECT.match(str(item.get("head", "")))
                or not HEX_OBJECT.match(str(item.get("tree", "")))
                or not SHA256.match(str(item.get("request_digest", "")))
                or not SHA256.match(str(item.get("command_digest", "")))
                or not RUNNER_INVOCATION.match(str(item.get("invocation", "")))
                or not item.get("boot_id")
                or not item.get("vm_instance_id")
            ):
                raise ValidationError("behavior shard receipt identity is incomplete or stale")
            record = dispatched.get(str(item.get("request_digest")))
            if (
                not isinstance(record, dict)
                or record.get("round") != item.get("round")
                or record.get("shard") != item.get("shard")
                or record.get("head") != item.get("head")
                or record.get("command_digest") != item.get("command_digest")
                or record.get("invocation") != item.get("invocation")
            ):
                raise ValidationError("behavior shard receipts do not correspond to this cell's own dispatched shard round")
            receipt_heads.add(item["head"])
            receipt_trees.add(item["tree"])
            artifact = item.get("artifact")
            if (
                not isinstance(artifact, dict)
                or artifact.get("path") != "results/executed-{}.tsv".format(item.get("shard"))
                or not SHA256.match(str(artifact.get("digest", "")))
                or not isinstance(artifact.get("bytes"), int)
                or artifact.get("bytes") < 0
            ):
                raise ValidationError("behavior shard receipt artifact identity is invalid")
            indexes.add(item.get("shard"))
            boots.add(item["boot_id"])
            machines.add(item["vm_instance_id"])
            invocations.add(item["invocation"])
            rounds.add(item.get("round"))
        if (
            indexes != expected_indexes
            or len(boots) != expected_shards
            or len(machines) != expected_shards
            or len(invocations) != expected_shards
            or len(rounds) != 1
            or None in rounds
            or len(receipt_heads) != 1
            or len(receipt_trees) != 1
        ):
            raise ValidationError("behavior shards did not prove one complete round on independent Azure machines")
        receipt_head = next(iter(receipt_heads))
        receipt_tree = next(iter(receipt_trees))
        if receipt_head != head:
            # The pipeline commits documentation on top of the tested tree
            # after the shard round, so the receipts legitimately prove an
            # exact ancestor of the published head rather than the head
            # itself. The ancestor and its tree binding are verified in the
            # controller clone against the fetched published branch; any
            # receipt head outside the published history still refuses.
            repo_root = Path(state["repository_root"])
            git(repo_root, "fetch", "origin", "refs/heads/" + str(result.get("branch", "")))
            probe = git(repo_root, "merge-base", "--is-ancestor", receipt_head, head, check=False)
            if probe.returncode != 0:
                raise ValidationError("behavior shard receipts do not prove an ancestor of the published head")
            if git(repo_root, "rev-parse", receipt_head + "^{tree}").stdout.strip() != receipt_tree:
                raise ValidationError("behavior shard receipt tree does not match its receipt head")
    return True


def collect(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("result-published", "needs-decision"):
            raise ValidationError("cell has not published a collectible result")
        result_root = env["state_dir"] / "results" / state["cell"] / "attempt-{}".format(state["attempt"])
        result_root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if result_root.exists():
            raise ValidationError("result was already collected; refusing overwrite")
        temp = result_root.with_name(".{}.{}.tmp".format(result_root.name, uuid.uuid4().hex))
        temp.mkdir(parents=True, mode=0o700)
        try:
            archive = temp / "result.tar.gz"
            storage_download(
                env, state["staging"]["result_blob"], archive,
                container=state["staging"]["container"],
            )
            digest = sha256_file(archive)
            if digest != state.get("expected_result_digest"):
                raise ValidationError("downloaded result digest differs from the control-plane marker")
            extracted = temp / "extracted"
            extracted.mkdir(mode=0o700)
            safe_extract_result(archive, extracted)
            result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
            verify_result_identity(state, result)
            os.replace(str(temp), str(result_root))
        except Exception:
            shutil.rmtree(temp, ignore_errors=True)
            raise
        state["result"] = result
        state["result_path"] = str(result_root)
        if result.get("run_id"):
            state["run_id"] = result["run_id"]
        phase = "needs-decision" if result["outcome"] == "needs-decision" else "collected"
        transition(env, state, phase, "result and evidence passed exact identity verification")
    print_status(state)


def respond(env, args):
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] != "needs-decision":
            raise ValidationError("cell is not waiting on an ask-user decision")
        try:
            response = Path(args.response_file).read_text(encoding="utf-8")
        except OSError as exc:
            raise ValidationError("response file is unreadable: {}".format(exc))
        if not response.strip() or len(response.encode("utf-8")) > 64 * 1024:
            raise ValidationError("response must contain 1-65536 bytes")
        exists, vm = read_resource(env, state["resources"]["vm_id"], "vm")
        if (
            not exists
            or not same_stable_identity(
                state["resources"]["identities"]["vm"], immutable_identity(vm, "vm"), "vm"
            )
        ):
            raise ValidationError("exact cell VM identity is absent or changed; response retained")
        state["attempt"] += 1
        output_url = blob_sas(
            env, state["staging"]["result_blob"], "cw",
            container=state["staging"]["container"],
        )
        create_run_command(env, state, "respond", output_url=output_url, response=response)
        transition(env, state, "responding", "exact ask-user run received a protected response")
    print("AZURE VALIDATION RESPONDED cell={} attempt={}".format(state["cell"], state["attempt"]))


def replacement_allowed(state, vm_presence):
    """Minimum absence fence: VM gone plus a phase that owns recoverable work."""
    if vm_presence != "absent-proven":
        return False, "old VM absence is not proven"
    if state.get("phase") not in ("running", "needs-decision", "failed-retained", "responding", "reattaching"):
        return False, "cell phase does not own recoverable work"
    return True, "replacement admitted"


def replacement_run_mode(state):
    return "reattach" if state.get("run_id") is not None else "start"


def replace(env, args):
    if not args.confirm_replace or args.confirm_subscription != env["subscription"]:
        raise ValidationError("replacement requires --confirm-replace and the exact subscription")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        exists, _vm = read_resource(env, state["resources"]["vm_id"], "vm")
        if exists:
            raise ValidationError("old exact VM still exists; duplicate replacement is forbidden")
        work_exists, _worktree = read_resource(env, state["resources"]["worktree_disk_id"], "disk")
        if not work_exists:
            raise ValidationError("durable validation worktree disk is absent")
        allowed, reason = replacement_allowed(state, "absent-proven")
        if not allowed:
            raise ValidationError(reason)
        run_mode = replacement_run_mode(state)
        # Remove the old attempt's disposable remnants before their names
        # leave authoritative state. Durable worktree, identity, and private
        # container are retained.
        cleanup_compute(env, state)
        worktree_identity = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        state["attempt"] += 1
        token = state["cell"].split("-", 1)[1] + "a{}".format(state["attempt"])
        old_resources = state["resources"]
        old_worktree_id = old_resources["worktree_disk_id"]
        old_worktree_name = old_resources["worktree_disk_name"]
        state["resources"] = resource_names(env, token)
        state["resources"]["worktree_disk_id"] = old_worktree_id
        state["resources"]["worktree_disk_name"] = old_worktree_name
        for key in ("identity_name", "identity_id", "identity_client_id", "identity_principal_id"):
            state["resources"][key] = old_resources[key]
        state["resources"]["identities"] = {
            "worktree": worktree_identity,
            "identity": old_resources["identities"]["identity"],
        }
        selected = {
            "sku": state["allocation"]["sku"],
            "family": state["allocation"]["sku_family"],
            "owner": env["owner"],
        }
        transition(env, state, "reattaching", "old VM absence and exact durable identity proved")
        create_cell(env, state, selected, replacement=True)
        output_url = blob_sas(
            env, state["staging"]["result_blob"], "cw", hours=MAX_CELL_LIFETIME_HOURS,
            container=state["staging"]["container"],
        )
        input_url = blob_sas(
            env, state["staging"]["input_blob"], "r",
            container=state["staging"]["container"],
        )
        if run_mode == "start":
            create_run_command(env, state, "start", input_url=input_url, output_url=output_url)
            note = "replacement VM freshly starting because no no-mistakes run id was recorded"
        else:
            # The original guest remains byte-for-byte sealed, but its runtime
            # and shard bridge lived on the disposable OS disk. A separate
            # current-controller bootstrap restores those exact artifacts from
            # the original digest-bound input, proves completion, and exits
            # before the unchanged guest is allowed to reattach the run.
            create_runtime_hydration_command(env, state, input_url)
            create_run_command(env, state, "reattach", output_url=output_url)
            note = "replacement VM hydrated exact sealed tools and reattached the retained run"
        transition(env, state, "running", note)
    print("AZURE VALIDATION REPLACED cell={} attempt={}".format(state["cell"], state["attempt"]))


def verify_cleanup_resource(state, resource, kind, recorded_key=None):
    tags = resource.get("tags") or {}
    label = recorded_key or kind
    if tags.get("validation-cell") != state["cell"] or tags.get("fence") != state["request"]["fence"]:
        raise ValidationError("{} cleanup identity is foreign".format(label))
    recorded = state["resources"].get("identities", {}).get(label)
    if recorded and not same_stable_identity(recorded, immutable_identity(resource, kind), kind):
        raise ValidationError("{} immutable identity changed; cleanup retained".format(label))


def delete_resource(env, state, resource_id, kind, recorded_key=None):
    exists, resource = read_resource(env, resource_id, kind)
    if not exists:
        return
    verify_cleanup_resource(state, resource, kind, recorded_key)
    identity = immutable_identity(resource, kind)
    arguments = [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind]),
    ]
    if identity["etag"]:
        arguments += ["--headers", "If-Match={}".format(identity["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
    if rc != 0:
        raise ValidationError("exact {} deletion failed: {}".format(kind, stderr))
    for _ in range(60):
        remains, _ = read_resource(env, resource_id, kind)
        if not remains:
            return
        time.sleep(5)
    raise ValidationError("exact {} remains after bounded delete reconciliation".format(kind))


def delete_run_command(env, state, run_id, recorded):
    exists, run_command = read_resource(env, run_id, "run-command")
    if not exists:
        return
    tags = run_command.get("tags") or {}
    live = immutable_identity(run_command, "run-command")
    if (
        tags.get("validation-cell") != state["cell"]
        or tags.get("fence") != state["request"]["fence"]
        or not same_stable_identity(recorded, live, "run-command")
    ):
        raise ValidationError("run-command cleanup identity is foreign")
    arguments = [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(run_id, RESOURCE_API["run-command"]),
    ]
    if live["etag"]:
        arguments += ["--headers", "If-Match={}".format(live["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
    if rc != 0:
        raise ValidationError("exact run-command delete failed: {}".format(stderr))
    for _ in range(60):
        remains, _ = read_resource(env, run_id, "run-command")
        if not remains:
            return
        time.sleep(5)
    raise ValidationError("exact run-command remains after bounded delete reconciliation")


def cleanup_compute(env, state):
    resources = state["resources"]
    for record in resources.get("run_commands", []):
        delete_run_command(env, state, record["id"], record["identity"])
    safety_identity = resources.get("identities", {}).get("run-command-safety")
    if safety_identity:
        delete_run_command(env, state, resources["safety_run_command_id"], safety_identity)
    delete_resource(env, state, state["resources"]["vm_id"], "vm")
    delete_resource(env, state, state["resources"]["nic_id"], "nic")
    delete_resource(env, state, state["resources"]["os_disk_id"], "disk")
    delete_resource(env, state, state["resources"]["ttl_schedule_id"], "ttl-schedule")


def wait_exact_disk_detached(env, disk_id, recorded, label):
    for _ in range(60):
        exists, disk = read_resource(env, disk_id, "disk")
        if not exists:
            raise ValidationError("{} disk disappeared during detach reconciliation".format(label))
        live = immutable_identity(disk, "disk")
        if not same_stable_identity(recorded, live, "disk"):
            raise ValidationError("{} disk stable identity changed".format(label))
        if not disk_is_attached(disk):
            return live
        time.sleep(5)
    raise ValidationError("{} disk did not detach after bounded reconciliation".format(label))


def delete_auth_share_role(env, state):
    """Remove the cell identity's account-scoped auth-share file-data grant.

    Same lane as the container role cleanup: absent assignments are the
    desired end state, so a repeat run is a no-op.
    """
    if not auth_share_name():
        return
    principal = (state.get("resources") or {}).get("identity_principal_id")
    if not principal:
        return
    account_scope = storage_account_scope(env)
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
    )
    assignments = direct_role_assignments_at_scope(env, account_scope)
    for item in assignments:
        if (
            str(item.get("scope", "")).lower() == account_scope.lower()
            and str(item.get("principalId", "")).lower() == str(principal).lower()
            and str(item.get("roleDefinitionId", "")).lower() == expected_role.lower()
            and item.get("id")
        ):
            _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
            if rc != 0:
                raise ValidationError("exact auth-share role assignment deletion failed: {}".format(stderr))


def delete_cell_storage_scope(env, state):
    scope = "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}/blobServices/default/containers/{}".format(
        env["subscription"], env["resource_group"], env["storage"], state["staging"]["container"]
    )
    plan = state.get("storage_cleanup")
    container_exists, container = read_resource(env, scope, "container")
    direct = direct_role_assignments_at_scope(env, scope)
    expected_principals = {env["operator_object_id"].lower(), state["resources"]["identity_principal_id"].lower()}
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    if plan is None:
        if not container_exists:
            raise ValidationError("cell private container disappeared before cleanup was planned")
        properties = container.get("properties", container)
        container_etag = container.get("etag") or properties.get("etag")
        principals = {str(item.get("principalId", "")).lower() for item in direct}
        if (
            properties.get("publicAccess") not in (None, "None")
            or not container_etag
            or len(direct) != 2
            or principals != expected_principals
            or any(
                not item.get("id")
                or str(item.get("roleDefinitionId", "")).lower() != expected_role.lower()
                for item in direct
            )
        ):
            raise ValidationError("cell container/role cleanup inventory is foreign or incomplete")
        plan = {
            "scope": scope,
            "container_etag": container_etag,
            "role_ids": sorted(item["id"] for item in direct),
            "roles_absent": False,
            "container_absent": False,
        }
        state["storage_cleanup"] = plan
        save_state(env, state)
    if plan.get("scope") != scope or not plan.get("container_etag") or len(plan.get("role_ids", [])) != 2:
        raise ValidationError("stored cell-container cleanup plan is corrupt")
    planned_ids = set(plan["role_ids"])
    current_ids = {item.get("id") for item in direct}
    if (
        not current_ids.issubset(planned_ids)
        or any(
            str(item.get("principalId", "")).lower() not in expected_principals
            or str(item.get("roleDefinitionId", "")).lower() != expected_role.lower()
            for item in direct
        )
    ):
        raise ValidationError("cell role cleanup inventory changed or gained foreign authority")
    for item in direct:
        _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
        if rc != 0:
            raise ValidationError("exact cell role assignment deletion failed: {}".format(stderr))
    for _ in range(60):
        current = direct_role_assignments_at_scope(env, scope)
        if not current:
            break
        if not {item.get("id") for item in current}.issubset(planned_ids):
            raise ValidationError("foreign role assignment appeared during cleanup")
        time.sleep(5)
    else:
        raise ValidationError("cell role assignments remain after bounded deletion reconciliation")
    plan["roles_absent"] = True
    save_state(env, state)
    container_exists, container = read_resource(env, scope, "container")
    if container_exists:
        properties = container.get("properties", container)
        live_etag = container.get("etag") or properties.get("etag")
        if live_etag != plan["container_etag"] or properties.get("publicAccess") not in (None, "None"):
            raise ValidationError("cell private container changed after cleanup planning")
        _, rc, stderr = az_command(env, [
            "rest", "--method", "delete",
            "--url", "https://management.azure.com{}?api-version={}".format(scope, RESOURCE_API["container"]),
            "--headers", "If-Match={}".format(live_etag),
        ], check=False)
        if rc != 0:
            raise ValidationError("exact cell container deletion failed: {}".format(stderr))
    for _ in range(60):
        remains, _ = read_resource(env, scope, "container")
        if not remains:
            break
        time.sleep(5)
    else:
        raise ValidationError("cell container remains after bounded exact deletion")
    plan["container_absent"] = True
    save_state(env, state)
    delete_auth_share_role(env, state)
    delete_resource(env, state, state["resources"]["identity_id"], "identity")


def close(env, args):
    if not args.confirm_close or args.confirm_subscription != env["subscription"]:
        raise ValidationError("close requires --confirm-close and the exact subscription")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("collected", "cleanup-retained"):
            raise ValidationError("only an exact collected terminal result or its retained cleanup may close")
        result = state.get("result") or {}
        if result.get("outcome") not in ("passed", "checks-passed"):
            raise ValidationError("failed or unfinished validation retains durable storage")
        if args.confirm_head != result.get("current_head"):
            raise ValidationError("close head confirmation does not match the exact validated head")
        remote = git(Path(state["repository_root"]), "ls-remote", "--heads", "origin", "refs/heads/" + result["branch"]).stdout.split()
        if len(remote) != 2 or remote[0] != result["current_head"]:
            raise ValidationError("remote branch is not current with the exact validated head")
        try:
            cleanup_compute(env, state)
            # Worktree deletion is authorized only after result/evidence collection,
            # current remote proof, CI green, and exact head confirmation.
            delete_resource(env, state, state["resources"]["worktree_disk_id"], "disk", recorded_key="worktree")
            delete_cell_storage_scope(env, state)
            # Return the shared shape capacity: the control constituent after
            # proven compute absence, plus any pre-reserved shard constituent
            # whose child runner never started. Dispatched children release
            # their own constituents through the runner's cleanup path.
            admission = state.get("admission") or {}
            if admission.get("shape_id"):
                release_shape_constituent(env, state, state["cell"], "control-compute-absent")
                dispatched = {
                    record.get("invocation")
                    for record in (state.get("shard_runs") or {}).values()
                }
                for entry in admission.get("shard_plan", []):
                    if entry["invocation"] not in dispatched:
                        release_shape_constituent(env, state, entry["invocation"], "shard-never-dispatched")
        except ValidationError as exc:
            transition(env, state, "cleanup-retained", "exact close was partial or ambiguous: {}".format(str(exc)[:300]))
            raise
        started = parse_utc(state.get("started_at"), "cell start")
        elapsed = max(0.0, (now_utc() - started).total_seconds())
        transition(env, state, "closed", "exact run closed; compute zero and credential lease detached", billable_seconds=elapsed)
    print("AZURE VALIDATION CLOSED cell={} head={} compute=zero".format(state["cell"], result["current_head"]))


def fail_retain(env, args):
    if not args.confirm_retain or args.confirm_subscription != env["subscription"]:
        raise ValidationError("retained failure cleanup requires exact confirmation")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        if state["phase"] not in ("failed-retained", "result-published", "needs-decision", "running", "reattaching", "collected"):
            raise ValidationError("cell phase does not own retainable failure capacity")
        if state["phase"] == "collected" and (state.get("result") or {}).get("outcome") in ("passed", "checks-passed"):
            raise ValidationError("a passed collected cell closes with its exact head; retain-failure owns only failed outcomes")
        cleanup_compute(env, state)
        state["resources"]["identities"]["worktree"] = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        transition(env, state, "failed-retained", "exact disposable compute removed; worktree retained")
    print("AZURE VALIDATION RETAINED cell={} compute=zero worktree=retained".format(state["cell"]))


def purge_role_identity(item):
    identity = {
        "id": str(item.get("id", "")),
        "scope": str(item.get("scope", "")),
        "principal_id": str(item.get("principalId", "")),
        "role_definition_id": str(item.get("roleDefinitionId", "")),
    }
    if any(not value for value in identity.values()):
        raise ValidationError("purge RBAC identity is incomplete")
    return identity


def same_purge_role(left, right):
    return all(
        str(left.get(key, "")).lower() == str(right.get(key, "")).lower()
        for key in ("id", "scope", "principal_id", "role_definition_id")
    )


def purge_compute_ids(resources):
    required = (
        ("vm", resources.get("vm_id")),
        ("nic", resources.get("nic_id")),
        ("disk", resources.get("os_disk_id")),
        ("ttl-schedule", resources.get("ttl_schedule_id")),
    )
    if any(not resource_id for _, resource_id in required):
        raise ValidationError("purge compute identity inventory is incomplete")
    values = list(required)
    safety = resources.get("safety_run_command_id")
    if safety:
        values.append(("run-command", safety))
    elif resources.get("vm_id"):
        values.append(("run-command", resources["vm_id"] + "/runCommands/safety-shutdown"))
    for record in resources.get("run_commands") or []:
        if not isinstance(record, dict) or not record.get("id"):
            raise ValidationError("purge run-command inventory is incomplete")
        values.append(("run-command", record["id"]))
    managed = resources.get("run_command_name")
    if managed:
        values.append(("run-command", resources["vm_id"] + "/runCommands/" + managed))
    return sorted(set(values))


def prove_compute_zero(env, compute_ids, label):
    for kind, resource_id in compute_ids:
        exists, _ = read_resource(env, resource_id, kind)
        if exists:
            raise ValidationError("{} still has live {} compute".format(label, kind))


def shared_capacity_authority(env):
    configured = Path(os.environ.get(
        "FM_AZURE_VALIDATION_LIFECYCLE", str(ROOT / "bin" / "fm-worker-lifecycle.sh")
    )).resolve()
    if configured != (ROOT / "bin" / "fm-worker-lifecycle.sh").resolve():
        raise ValidationError("purge cannot inspect an overridden shared capacity authority")
    module = worker_lifecycle_module()
    try:
        lifecycle_env = module.environment()
        if lifecycle_env["subscription"] != env["subscription"]:
            raise ValidationError("shared capacity authority subscription differs during purge")
        return module, lifecycle_env
    except module.LifecycleError as exc:
        raise ValidationError("shared capacity authority is unreadable during purge: {}".format(exc))


def capacity_authority_snapshot(env):
    module, lifecycle_env = shared_capacity_authority(env)
    try:
        with module.controller_lock(lifecycle_env):
            lifecycle_state = module.load_state(lifecycle_env)
            reservations = lifecycle_state.get("capacity_reservations") or {}
            reservations = json.loads(json.dumps(reservations))
        response = module.provider_call(lifecycle_env, "inventory")
        provider_reservations = response["inventory"]["capacity_reservations"]
        return reservations, json.loads(json.dumps(provider_reservations))
    except module.LifecycleError as exc:
        raise ValidationError("shared capacity authority is unreadable during purge: {}".format(exc))


def require_complete_purge_capacity_census(
    reservations, provider_reservations, fence, allowed_ids, boundary
):
    provider_active = {
        item.get("reservation_id"): item
        for item in provider_reservations
        if isinstance(item, dict) and item.get("active") is True
    }
    for reservation_id, provider in provider_active.items():
        controller = reservations.get(reservation_id)
        if (
            not isinstance(controller, dict)
            or controller.get("schema") != "fm.capacity-reservation/v1"
            or controller.get("reservation_id") != reservation_id
            or not isinstance(controller.get("fence_binding"), str)
            or not controller.get("fence_binding")
            or not isinstance(controller.get("workload_role"), str)
            or not controller.get("workload_role")
            or controller.get("discretionary") is not True
            or controller.get("role") != provider.get("role")
            or controller.get("sku") != provider.get("sku")
            or str(controller.get("sku_family", "")).lower()
            != str(provider.get("sku_family", "")).lower()
            or controller.get("vcpus") != provider.get("vcpus")
            or isinstance(controller.get("amount_usd"), bool)
            or not isinstance(controller.get("amount_usd"), (int, float))
            or abs(
                float(controller["amount_usd"])
                - float(provider.get("amount_usd", -1.0))
            ) > 1e-6
        ):
            raise ValidationError(
                "provider-active capacity constituent {} lacks exact controller "
                "identity at the {} boundary".format(reservation_id, boundary)
            )
    for reservation_key, reservation in reservations.items():
        if (
            isinstance(reservation, dict)
            and reservation.get("fence_binding") == fence
            and (
                reservation.get("reservation_id") != reservation_key
                or reservation_key not in allowed_ids
            )
        ):
            raise ValidationError(
                "same-fence capacity constituent {} is outside the exact "
                "purge census at the {} boundary".format(reservation_key, boundary)
            )


def exact_purge_capacity_constituents(
    state, shard_plan, runner_states, reservations, provider_reservations
):
    admission = state["admission"]
    allocation = state.get("allocation") or {}
    expected = [{
        "reservation_id": state["cell"],
        "sku": allocation.get("sku"),
        "sku_family": allocation.get("sku_family"),
        "vcpus": 8,
        "amount_usd": admission.get("control_amount_usd"),
    }] + [{
        "reservation_id": entry.get("invocation"),
        "sku": entry.get("sku"),
        "sku_family": entry.get("sku_family"),
        "vcpus": 4,
        "amount_usd": entry.get("amount_usd"),
    } for entry in shard_plan]
    fence = state["request"]["fence"].split(":", 1)[-1]
    census = {item["reservation_id"] for item in expected} | set(runner_states)
    require_complete_purge_capacity_census(
        reservations, provider_reservations, fence, census, "initial-plan"
    )
    snapshots = {}
    for item in expected:
        reservation = reservations.get(item["reservation_id"])
        if (
            not isinstance(reservation, dict)
            or reservation.get("schema") != "fm.capacity-reservation/v1"
            or reservation.get("reservation_id") != item["reservation_id"]
            or reservation.get("fence_binding") != fence
            or reservation.get("shape_id") != state["cell"]
            or reservation.get("role") != "specialized"
            or reservation.get("workload_role") != "validation"
            or reservation.get("discretionary") is not True
            or reservation.get("sku") != item["sku"]
            or str(reservation.get("sku_family", "")).lower() != str(item["sku_family"] or "").lower()
            or reservation.get("vcpus") != item["vcpus"]
            or not isinstance(item["amount_usd"], (int, float))
            or isinstance(item["amount_usd"], bool)
            or abs(float(reservation.get("amount_usd", -1.0)) - float(item["amount_usd"])) > 1e-6
            or reservation.get("status") not in ("queued", "reserved", "released")
            or (
                reservation.get("status") == "released"
                and not re.match(
                    r"^(?:sha256:)?[0-9a-f]{64}$",
                    str(reservation.get("cleanup_receipt", "")),
                )
            )
        ):
            raise ValidationError(
                "shared capacity constituent {} has no exact durable shape identity".format(
                    item["reservation_id"]
                )
            )
        snapshots[item["reservation_id"]] = {
            key: reservation.get(key) for key in (
                "schema", "reservation_id", "fence_binding", "shape_id", "role",
                "workload_role", "discretionary", "sku", "sku_family", "vcpus", "amount_usd",
                "status", "cleanup_receipt",
            )
        }
    return snapshots


def bind_purge_provider_capacity_absence(capacity, provider_reservations):
    by_id = {
        item["reservation_id"]: item
        for item in provider_reservations
        if isinstance(item, dict) and isinstance(item.get("reservation_id"), str)
    }
    for reservation_id, expected in capacity.items():
        observed = by_id.get(reservation_id)
        if observed is None:
            expected["provider"] = {"present": False, "active": False}
            continue
        if (
            observed.get("reservation_id") != reservation_id
            or observed.get("role") != expected.get("role")
            or observed.get("sku") != expected.get("sku")
            or str(observed.get("sku_family", "")).lower()
            != str(expected.get("sku_family", "")).lower()
            or observed.get("vcpus") != expected.get("vcpus")
            or isinstance(observed.get("amount_usd"), bool)
            or not isinstance(observed.get("amount_usd"), (int, float))
            or abs(
                float(observed["amount_usd"])
                - float(expected.get("amount_usd", -1.0))
            ) > 1e-6
            or observed.get("active") is not False
        ):
            raise ValidationError(
                "provider capacity constituent {} is active or has drifted from "
                "the exact purge lineage".format(reservation_id)
            )
        expected["provider"] = {
            key: observed.get(key) for key in (
                "reservation_id", "role", "sku", "sku_family", "vcpus",
                "amount_usd", "active",
            )
        }


def prove_purge_capacity_released(
    env, capacity_constituents, release_ids, require_released=True
):
    reservations, provider_reservations = capacity_authority_snapshot(env)
    expected = {
        item["reservation_id"]: json.loads(json.dumps(item))
        for item in capacity_constituents
    }
    fences = {item.get("fence_binding") for item in expected.values()}
    if len(fences) != 1 or not next(iter(fences)):
        raise ValidationError("sealed purge capacity fence is incomplete")
    require_complete_purge_capacity_census(
        reservations, provider_reservations, next(iter(fences)), set(expected),
        "retry/pre-artifact",
    )
    release_ids = set(release_ids)
    for reservation_id, planned in expected.items():
        observed = reservations.get(reservation_id)
        receipt = str((observed or {}).get("cleanup_receipt", ""))
        if (
            (reservation_id in release_ids and not isinstance(observed, dict))
            or (
                isinstance(observed, dict)
                and any(
                    str(observed.get(key) or "").lower()
                    != str(planned.get(key) or "").lower()
                    for key in (
                        "schema", "reservation_id", "fence_binding", "shape_id", "role",
                        "workload_role", "sku", "sku_family",
                    )
                )
            )
            or (
                isinstance(observed, dict)
                and (
                    observed.get("discretionary") is not True
                    or observed.get("vcpus") != planned.get("vcpus")
                    or isinstance(observed.get("amount_usd"), bool)
                    or not isinstance(observed.get("amount_usd"), (int, float))
                    or abs(
                        float(observed["amount_usd"])
                        - float(planned.get("amount_usd", -1.0))
                    ) > 1e-6
                )
            )
            or (
                isinstance(observed, dict)
                and reservation_id in release_ids
                and require_released
                and (
                    observed.get("status") != "released"
                    or not re.match(r"^(?:sha256:)?[0-9a-f]{64}$", receipt)
                )
            )
            or (
                isinstance(observed, dict)
                and reservation_id in release_ids
                and not require_released
                and (
                    observed.get("status") not in ("queued", "reserved", "released")
                    or (
                        observed.get("status") == "released"
                        and not re.match(r"^(?:sha256:)?[0-9a-f]{64}$", receipt)
                    )
                )
            )
            or (
                isinstance(observed, dict)
                and reservation_id not in release_ids
                and (
                    observed.get("status") != "released"
                    or not re.match(r"^(?:sha256:)?[0-9a-f]{64}$", receipt)
                )
            )
        ):
            raise ValidationError(
                "purge capacity constituent {} lacks its exact durable {} identity".format(
                    reservation_id,
                    "release" if require_released or reservation_id not in release_ids
                    else "pre-release",
                )
            )
    bind_purge_provider_capacity_absence(expected, provider_reservations)


def exact_purge_retry_constituent(state, value, reservations):
    invocation = value["invocation"]
    request = value.get("request") or {}
    limits = request.get("limits") or {}
    runner_reservation = value.get("shared_capacity_reservation") or {}
    reservation = reservations.get(invocation)
    fence = state["request"]["fence"].split(":", 1)[-1]
    if (
        not isinstance(reservation, dict)
        or reservation.get("schema") != "fm.capacity-reservation/v1"
        or reservation.get("reservation_id") != invocation
        or reservation.get("fence_binding") != fence
        or reservation.get("shape_id") is not None
        or reservation.get("role") != "specialized"
        or reservation.get("workload_role") != "validation"
        or reservation.get("discretionary") is not True
        or reservation.get("sku") != limits.get("sku")
        or str(reservation.get("sku_family", "")).lower() != str(limits.get("sku_family", "")).lower()
        or reservation.get("vcpus") != 4
        or not isinstance(runner_reservation.get("amount_usd"), (int, float))
        or isinstance(runner_reservation.get("amount_usd"), bool)
        or abs(
            float(reservation.get("amount_usd", -1.0))
            - float(runner_reservation["amount_usd"])
        ) > 1e-6
        or reservation.get("status") != "released"
        or reservation.get("cleanup_receipt") != runner_reservation.get("cleanup_receipt")
    ):
        raise ValidationError(
            "retry shard constituent {} has no exact durable released identity".format(invocation)
        )
    return {
        key: reservation.get(key) for key in (
            "schema", "reservation_id", "fence_binding", "shape_id", "role",
            "workload_role", "discretionary", "sku", "sku_family", "vcpus", "amount_usd",
            "status", "cleanup_receipt",
        )
    }


def load_purge_runner_states(env, state):
    directory = runner_state_dir(env)
    if not directory.is_dir():
        raise ValidationError("shard runner state directory is absent")
    values = {}
    for path in sorted(directory.glob("azr-*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValidationError("shard runner state is unreadable during purge: {}".format(exc))
        invocation = value.get("invocation")
        if value.get("schema") != "fm.azure-command/v1" or not RUNNER_INVOCATION.match(str(invocation or "")):
            raise ValidationError("shard runner state identity is corrupt during purge")
        if path.stem != invocation or invocation in values:
            raise ValidationError("shard runner state filename or invocation is ambiguous")
        values[invocation] = value
    return {
        invocation: value
        for invocation, value in values.items()
        if (value.get("request") or {}).get("capacity_parent") == state["cell"]
    }


def purge_runner_compute_ids(value):
    resources = value.get("resources") or {}
    values = purge_compute_ids(resources)
    vm_id = resources.get("vm_id")
    execute_name = resources.get("run_command_name") or "execute"
    safety_name = resources.get("safety_run_command_name") or "safety-shutdown"
    values.extend((
        ("run-command", vm_id + "/runCommands/" + execute_name),
        ("run-command", vm_id + "/runCommands/" + safety_name),
    ))
    return sorted(set(values))


def plan_purge_shards(env, state):
    admission = state.get("admission") or {}
    shard_plan = admission.get("shard_plan") or []
    roots = [entry.get("invocation") for entry in shard_plan]
    expected_shards = (state.get("request") or {}).get("limits", {}).get("behavior_shards")
    if (
        admission.get("shape_id") != state["cell"]
        or not isinstance(expected_shards, int)
        or len(shard_plan) != expected_shards
        or {entry.get("shard") for entry in shard_plan} != set(range(1, expected_shards + 1))
        or any(not RUNNER_INVOCATION.match(str(root or "")) for root in roots)
        or len(roots) != len(set(roots))
    ):
        raise ValidationError("purge shard capacity plan is incomplete or ambiguous")
    runner_states = load_purge_runner_states(env, state)
    reservations, provider_reservations = capacity_authority_snapshot(env)
    capacity = exact_purge_capacity_constituents(
        state, shard_plan, runner_states, reservations, provider_reservations
    )
    fence = state["request"]["fence"].split(":", 1)[-1]
    planned = []
    for invocation, value in sorted(runner_states.items()):
        request = value.get("request") or {}
        root = request.get("lineage_root_invocation") or invocation
        parent = value.get("parent_invocation")
        reservation = value.get("shared_capacity_reservation") or {}
        if invocation not in capacity:
            capacity[invocation] = exact_purge_retry_constituent(state, value, reservations)
        if (
            root not in roots
            or request.get("schema") != "fm.azure-command/v1"
            or request.get("invocation") != invocation
            or request.get("parent_invocation") != parent
            or request.get("capacity_fence") != fence
            or value.get("request_digest") != request.get("request_digest")
            or not SHA256.match(str(request.get("request_digest", "")))
            or not SHA256.match(str(request.get("command_digest", "")))
            or value.get("phase") not in ("complete", "absent-fenced")
            or reservation.get("reservation_id") != invocation
            or reservation.get("fence_binding") != fence
            or reservation.get("status") != "released"
            or not re.match(r"^(?:sha256:)?[0-9a-f]{64}$", str(reservation.get("cleanup_receipt", "")))
            or capacity[invocation].get("status") != "released"
            or capacity[invocation].get("cleanup_receipt") != reservation.get("cleanup_receipt")
        ):
            raise ValidationError("shard lineage {} is not terminal, compute-zero, and released".format(invocation))
        if parent:
            parent_state = runner_states.get(parent)
            if not parent_state or (parent_state.get("request") or {}).get("lineage_root_invocation", parent) != root:
                raise ValidationError("shard retry lineage is incomplete during purge")
        elif invocation != root:
            raise ValidationError("shard lineage root identity is inconsistent")
        compute_ids = purge_runner_compute_ids(value)
        prove_compute_zero(env, compute_ids, "shard {}".format(invocation))
        planned.append({
            "invocation": invocation,
            "lineage_root_invocation": root,
            "parent_invocation": parent,
            "phase": value["phase"],
            "request_digest": request["request_digest"],
            "command_digest": request["command_digest"],
            "cleanup_receipt": reservation["cleanup_receipt"],
            "compute_ids": [[kind, resource_id] for kind, resource_id in compute_ids],
        })
    shard_runs = state.get("shard_runs") or {}
    if not isinstance(shard_runs, dict):
        raise ValidationError("cell shard dispatch ledger is corrupt")
    for record in shard_runs.values():
        if not isinstance(record, dict):
            raise ValidationError("cell shard dispatch record is corrupt")
        live = runner_states.get(record.get("invocation"))
        if not live or (live.get("request") or {}).get("command_digest") != record.get("command_digest"):
            raise ValidationError("dispatched shard lineage lacks exact terminal runner evidence")
    dispatched_roots = {
        (value.get("request") or {}).get("lineage_root_invocation") or invocation
        for invocation, value in runner_states.items()
    }
    releases = []
    if capacity[state["cell"]]["status"] != "released":
        releases.append({"reservation_id": state["cell"], "evidence": "purge-control-compute-absent"})
    recorded_invocations = {record.get("invocation") for record in shard_runs.values()}
    for root in roots:
        if root not in dispatched_roots:
            if root in recorded_invocations:
                raise ValidationError("recorded shard dispatch has no runner lineage")
            if capacity[root]["status"] != "released":
                releases.append({"reservation_id": root, "evidence": "purge-shard-never-dispatched"})
    bind_purge_provider_capacity_absence(capacity, provider_reservations)
    ordered_capacity = [state["cell"]] + roots + sorted(set(capacity) - {state["cell"]} - set(roots))
    return planned, releases, [capacity[key] for key in ordered_capacity]


def purge_container_scope(env, state):
    return (
        "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}"
        "/blobServices/default/containers/{}"
    ).format(env["subscription"], env["resource_group"], env["storage"], state["staging"]["container"])


def build_purge_plan(env, state):
    control_compute = purge_compute_ids(state["resources"])
    prove_compute_zero(env, control_compute, "control cell")
    recorded_worktree = (state.get("resources") or {}).get("identities", {}).get("worktree")
    worktree_id = state["resources"].get("worktree_disk_id")
    exists, worktree = read_resource(env, worktree_id, "disk")
    if not exists:
        raise ValidationError("retained worktree disk is absent before purge planning")
    verify_cleanup_resource(state, worktree, "disk", "worktree")
    worktree_identity = immutable_identity(worktree, "disk")
    if (
        not same_stable_identity(recorded_worktree, worktree_identity, "disk")
        or not worktree_identity.get("etag")
        or disk_is_attached(worktree)
    ):
        raise ValidationError("retained worktree disk is not exact and detached")
    identity_id = state["resources"].get("identity_id")
    exists, identity_resource = read_resource(env, identity_id, "identity")
    if not exists:
        raise ValidationError("cell storage identity is absent before purge planning")
    verify_cleanup_resource(state, identity_resource, "identity")
    identity = immutable_identity(identity_resource, "identity")
    principal = identity["principal_id"]
    if principal.lower() != str(state["resources"].get("identity_principal_id", "")).lower():
        raise ValidationError("cell storage principal changed before purge planning")
    scope = purge_container_scope(env, state)
    exists, container = read_resource(env, scope, "container")
    if not exists:
        raise ValidationError("cell private container is absent before purge planning")
    properties = container.get("properties", container)
    container_etag = container.get("etag") or properties.get("etag")
    if properties.get("publicAccess") not in (None, "None") or not container_etag:
        raise ValidationError("cell container is not private with an exact ETag")
    blob_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    assignments = direct_role_assignments_at_scope(env, scope)
    direct = [
        purge_role_identity(item) for item in assignments or []
    ]
    expected_principals = {env["operator_object_id"].lower(), principal.lower()}
    if (
        len(direct) != 2
        or {item["principal_id"].lower() for item in direct} != expected_principals
        or any(item["role_definition_id"].lower() != blob_role.lower() for item in direct)
    ):
        raise ValidationError("cell container RBAC is foreign or incomplete before purge")
    account_scope = storage_account_scope(env)
    file_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
    )
    account_assignments = direct_role_assignments_at_scope(env, account_scope)
    auth_roles = [
        purge_role_identity(item) for item in account_assignments or []
        if str(item.get("principalId", "")).lower() == principal.lower()
    ]
    expected_auth_count = 1 if auth_share_name() else 0
    if len(auth_roles) != expected_auth_count or any(
        item["role_definition_id"].lower() != file_role.lower() for item in auth_roles
    ):
        raise ValidationError("cell auth-share RBAC is foreign or incomplete before purge")
    effective, _, _ = az_command(env, [
        "role", "assignment", "list", "--assignee-object-id", principal,
        "--all", "--include-inherited", "--include-groups",
    ])
    expected_effective = [item for item in direct if item["principal_id"].lower() == principal.lower()] + auth_roles
    effective_roles = [purge_role_identity(item) for item in effective or []]
    if len(effective_roles) != len(expected_effective) or any(
        not any(same_purge_role(item, expected) for expected in expected_effective)
        for item in effective_roles
    ):
        raise ValidationError("cell identity effective RBAC exceeds the purge plan")
    shard_lineages, capacity_releases, capacity_constituents = plan_purge_shards(env, state)
    capacity_fences = {item.get("fence_binding") for item in capacity_constituents}
    if len(capacity_fences) != 1 or not next(iter(capacity_fences)):
        raise ValidationError("purge capacity fence identity is incomplete")
    retirement_identity = {
        "schema": "fm.azure-validation-capacity-retirement/v1",
        "cell": state["cell"],
        "request_digest": state["request_digest"],
        "fence_binding": next(iter(capacity_fences)),
        "reservation_ids": sorted(
            item["reservation_id"] for item in capacity_constituents
        ),
    }
    immutable = {
        "cell": state["cell"],
        "subscription": env["subscription"],
        "request_digest": state["request_digest"],
        "control_compute_ids": [[kind, resource_id] for kind, resource_id in control_compute],
        "shard_lineages": shard_lineages,
        "capacity_constituents": capacity_constituents,
        "capacity_fence_retirement": dict(
            retirement_identity,
            # The shared allocator's binding contract is deliberately the
            # narrow raw lowercase digest, unlike validation protocol digests
            # that carry an explicit sha256: prefix.
            retirement_receipt=sha256_hex(canonical_bytes(retirement_identity)),
        ),
        "worktree": {"resource_id": worktree_id, "identity": worktree_identity},
        "storage": {
            "container_scope": scope,
            "container_etag": container_etag,
            "container_roles": sorted(direct, key=lambda item: item["id"].lower()),
            "auth_share_roles": sorted(auth_roles, key=lambda item: item["id"].lower()),
            "identity_resource_id": identity_id,
            "identity": identity,
        },
        "capacity_releases": capacity_releases,
    }
    return {
        "schema": PURGE_SCHEMA,
        "created_at": iso_utc(),
        "plan": immutable,
        "plan_digest": sha256_bytes(canonical_bytes(immutable)),
        "progress": {
            "worktree_absent": False,
            "container_roles_absent": False,
            "container_absent": False,
            "auth_share_roles_absent": False,
            "identity_absent": False,
            "capacity_fence_retired": False,
            "released_capacity": [],
        },
    }


def verify_purge_record(state, env):
    purge = state.get("purge") or {}
    plan = purge.get("plan") or {}
    if (
        purge.get("schema") != PURGE_SCHEMA
        or purge.get("plan_digest") != sha256_bytes(canonical_bytes(plan))
        or plan.get("cell") != state["cell"]
        or plan.get("subscription") != env["subscription"]
        or plan.get("request_digest") != state.get("request_digest")
        or not isinstance(purge.get("progress"), dict)
    ):
        raise ValidationError("stored retained-purge plan is corrupt or rebound")
    if state.get("phase") == "purged":
        terminal = purge.get("terminal") or {}
        if (
            terminal.get("phase") != "purged"
            or terminal.get("plan_digest") != purge["plan_digest"]
            or not terminal.get("completed_at")
        ):
            raise ValidationError("terminal retained-purge tombstone is incomplete")
    return purge


def save_purge_progress(env, state, key, value=True):
    state["purge"]["progress"][key] = value
    save_state(env, state)


def delete_planned_purge_resource(env, state, resource_id, kind, planned_identity, label):
    exists, resource = read_resource(env, resource_id, kind)
    if not exists:
        return
    verify_cleanup_resource(state, resource, kind, "worktree" if label == "worktree" else None)
    live = immutable_identity(resource, kind)
    if not same_stable_identity(planned_identity, live, kind):
        raise ValidationError("planned {} stable identity changed".format(label))
    if planned_identity.get("etag") and live.get("etag") != planned_identity["etag"]:
        raise ValidationError("planned {} mutation identity changed".format(label))
    if kind == "disk" and disk_is_attached(resource):
        raise ValidationError("planned {} disk reattached before deletion".format(label))
    arguments = [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind]),
    ]
    if planned_identity.get("etag"):
        arguments += ["--headers", "If-Match={}".format(planned_identity["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
    if rc != 0:
        raise ValidationError("exact planned {} deletion failed: {}".format(label, stderr))
    for _ in range(60):
        remains, _ = read_resource(env, resource_id, kind)
        if not remains:
            return
        time.sleep(5)
    raise ValidationError("exact planned {} remains after bounded deletion".format(label))


def current_planned_roles(env, state, plan):
    storage = plan["storage"]
    scope = storage["container_scope"]
    assignments = direct_role_assignments_at_scope(env, scope)
    current_container = [
        purge_role_identity(item) for item in assignments or []
    ]
    planned_container = storage["container_roles"]
    if any(not any(same_purge_role(item, expected) for expected in planned_container) for item in current_container):
        raise ValidationError("cell container gained foreign RBAC after purge planning")
    account_scope = storage_account_scope(env)
    account = direct_role_assignments_at_scope(env, account_scope)
    principal = storage["identity"]["principal_id"]
    current_auth = [
        purge_role_identity(item) for item in account or []
        if str(item.get("principalId", "")).lower() == principal.lower()
    ]
    planned_auth = storage["auth_share_roles"]
    if any(not any(same_purge_role(item, expected) for expected in planned_auth) for item in current_auth):
        raise ValidationError("cell identity gained foreign auth-share RBAC after purge planning")
    effective, _, _ = az_command(env, [
        "role", "assignment", "list", "--assignee-object-id", principal,
        "--all", "--include-inherited", "--include-groups",
    ])
    planned_effective = [
        item for item in planned_container if item["principal_id"].lower() == principal.lower()
    ] + planned_auth
    current_effective = [purge_role_identity(item) for item in effective or []]
    if any(not any(same_purge_role(item, expected) for expected in planned_effective) for item in current_effective):
        raise ValidationError("cell identity gained foreign effective RBAC after purge planning")
    return current_container, current_auth


def purge_storage(env, state, purge):
    plan = purge["plan"]
    progress = purge["progress"]
    storage = plan["storage"]
    container_roles, auth_roles = current_planned_roles(env, state, plan)
    for item in container_roles:
        _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
        if rc != 0:
            raise ValidationError("planned container RBAC deletion failed: {}".format(stderr))
    for _ in range(60):
        remaining, _ = current_planned_roles(env, state, plan)
        if not remaining:
            break
        time.sleep(5)
    else:
        raise ValidationError("planned container RBAC remains after bounded deletion")
    if not progress.get("container_roles_absent"):
        save_purge_progress(env, state, "container_roles_absent")
    exists, container = read_resource(env, storage["container_scope"], "container")
    if exists:
        properties = container.get("properties", container)
        live_etag = container.get("etag") or properties.get("etag")
        if live_etag != storage["container_etag"] or properties.get("publicAccess") not in (None, "None"):
            raise ValidationError("planned private container changed before deletion")
        _, rc, stderr = az_command(env, [
            "rest", "--method", "delete",
            "--url", "https://management.azure.com{}?api-version={}".format(
                storage["container_scope"], RESOURCE_API["container"]
            ),
            "--headers", "If-Match={}".format(storage["container_etag"]),
        ], check=False)
        if rc != 0:
            raise ValidationError("planned private container deletion failed: {}".format(stderr))
    for _ in range(60):
        remains, _ = read_resource(env, storage["container_scope"], "container")
        if not remains:
            break
        time.sleep(5)
    else:
        raise ValidationError("planned private container remains after bounded deletion")
    if not progress.get("container_absent"):
        save_purge_progress(env, state, "container_absent")
    _, auth_roles = current_planned_roles(env, state, plan)
    for item in auth_roles:
        _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
        if rc != 0:
            raise ValidationError("planned auth-share RBAC deletion failed: {}".format(stderr))
    for _ in range(60):
        _, remaining = current_planned_roles(env, state, plan)
        if not remaining:
            break
        time.sleep(5)
    else:
        raise ValidationError("planned auth-share RBAC remains after bounded deletion")
    if not progress.get("auth_share_roles_absent"):
        save_purge_progress(env, state, "auth_share_roles_absent")
    delete_planned_purge_resource(
        env, state, storage["identity_resource_id"], "identity", storage["identity"], "storage identity"
    )
    if not progress.get("identity_absent"):
        save_purge_progress(env, state, "identity_absent")


def execute_purge_plan(env, state, purge):
    plan = purge["plan"]
    progress = purge["progress"]
    prove_compute_zero(env, [(kind, resource_id) for kind, resource_id in plan["control_compute_ids"]], "control cell")
    for lineage in plan["shard_lineages"]:
        prove_compute_zero(
            env, [(kind, resource_id) for kind, resource_id in lineage["compute_ids"]],
            "shard {}".format(lineage["invocation"]),
        )
    released = set(progress.get("released_capacity") or [])
    planned_release_ids = [entry["reservation_id"] for entry in plan["capacity_releases"]]
    prove_purge_capacity_released(
        env, plan["capacity_constituents"], planned_release_ids,
        require_released=False,
    )
    for entry in plan["capacity_releases"]:
        reservation_id = entry["reservation_id"]
        if reservation_id not in released:
            release_shape_constituent(env, state, reservation_id, entry["evidence"])
            released.add(reservation_id)
            save_purge_progress(env, state, "released_capacity", sorted(released))
    prove_purge_capacity_released(
        env, plan["capacity_constituents"], planned_release_ids
    )
    # This command performs one last entire allocator/provider census while
    # holding the shared admission lock, then durably retires the exact fence.
    # Both reserve entry points reject the tombstone before they can insert or
    # re-admit capacity, closing the former proof-to-disk-delete race.
    retire_purge_capacity_fence(env, plan["capacity_fence_retirement"])
    if not progress.get("capacity_fence_retired"):
        save_purge_progress(env, state, "capacity_fence_retired")
    worktree = plan["worktree"]
    delete_planned_purge_resource(
        env, state, worktree["resource_id"], "disk", worktree["identity"], "worktree"
    )
    if not progress.get("worktree_absent"):
        save_purge_progress(env, state, "worktree_absent")
    purge_storage(env, state, purge)


def purge_retained(env, args):
    cell = require_cell(args.cell)
    if (
        not args.confirm_purge
        or args.confirm_subscription != env["subscription"]
        or args.confirm_cell != cell
    ):
        raise ValidationError("purge-retained requires exact purge, subscription, and cell confirmation")
    require_sha256("purge request digest confirmation", args.confirm_request_digest)
    with lock(env, cell + "-shards"):
        with lock(env, cell):
            state = load_state(env, cell)
            if args.confirm_request_digest != state.get("request_digest"):
                raise ValidationError("purge request digest confirmation does not match the retained cell")
            if (state.get("result") or {}).get("outcome") in ("passed", "checks-passed"):
                raise ValidationError("a passed result cannot enter retained-failure purge")
            if state["phase"] == "purged":
                purge = verify_purge_record(state, env)
                print("AZURE VALIDATION PURGED cell={} plan={} compute=zero retained=zero".format(
                    cell, purge["plan_digest"]
                ))
                return
            if state["phase"] == "failed-retained":
                purge = build_purge_plan(env, state)
                transition(
                    env, state, "purging",
                    "immutable retained-resource purge plan sealed before destructive mutation",
                    purge=purge,
                )
            elif state["phase"] == "purging":
                purge = verify_purge_record(state, env)
            else:
                raise ValidationError("purge-retained owns only an exact failed-retained cell or its purge retry")
            try:
                execute_purge_plan(env, state, purge)
            except ValidationError as exc:
                state.setdefault("events", []).append({
                    "at": iso_utc(), "phase": "purging",
                    "note": "retained purge remains resumable: {}".format(str(exc)[:300]),
                })
                save_state(env, state)
                raise
            purge["terminal"] = {
                "phase": "purged", "completed_at": iso_utc(),
                "plan_digest": purge["plan_digest"],
            }
            transition(env, state, "purged", "sealed retained-resource purge completed", purge=purge)
    print("AZURE VALIDATION PURGED cell={} plan={} compute=zero retained=zero".format(
        cell, state["purge"]["plan_digest"]
    ))


def list_cell_blobs(env, state, prefix="shards/"):
    values, _, _ = az_command(env, [
        "storage", "blob", "list", "--auth-mode", "login", "--account-name", env["storage"],
        "--container-name", state["staging"]["container"], "--prefix", prefix,
    ])
    return [item.get("name") for item in values if isinstance(item, dict) and isinstance(item.get("name"), str)]


def extract_shard_request(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        if {member.name for member in members} != {"request.json", "snapshot.bundle"}:
            raise ValidationError("shard request archive member set is invalid")
        for member in members:
            if not member.isfile() or member.issym() or member.islnk() or member.isdev() or member.size > 1024**3:
                raise ValidationError("shard request archive contains an unsafe member")
        archive.extractall(str(destination), members=members)


def validate_shard_request(state, request, bundle_path, blob):
    if request.get("schema") != "fm.azure-validation-shard/v1":
        raise ValidationError("shard request schema is invalid")
    unsigned = dict(request)
    supplied = unsigned.pop("request_digest", None)
    if supplied != sha256_bytes(canonical_bytes(unsigned)):
        raise ValidationError("shard request digest mismatch")
    repository = request.get("repository") or {}
    expected_repository = state["request"]["repository"]
    if request.get("cell") != state["cell"]:
        raise ValidationError("shard request belongs to another cell")
    if (
        repository.get("slug") != expected_repository["slug"]
        or repository.get("branch") != expected_repository["branch"]
    ):
        raise ValidationError("shard request repository/branch differs from the exact validation run")
    if repository.get("snapshot_digest") != sha256_file(bundle_path):
        raise ValidationError("shard request bundle digest mismatch")
    if (
        not HEX_OBJECT.match(str(repository.get("head", "")))
        or not HEX_OBJECT.match(str(repository.get("tree", "")))
    ):
        raise ValidationError("shard request head/tree is malformed")
    match = re.match(r"^shards/(round-[a-z0-9]{12})/request-([1-8])\.tar\.gz$", blob)
    if not match or request.get("round") != match.group(1) or int(request.get("shard", 0)) != int(match.group(2)):
        raise ValidationError("shard request blob identity is malformed")
    count = int(request.get("shard_count", 0))
    shard = int(request.get("shard", 0))
    if count < 1 or count > 8 or shard < 1 or shard > count:
        raise ValidationError("shard request index/count is outside 1-8")
    command = request.get("command", {}).get("argv")
    if not isinstance(command, list) or not command or any(not isinstance(item, str) or "\x00" in item for item in command):
        raise ValidationError("shard command argv is malformed")
    if request.get("command_digest") != sha256_bytes(canonical_bytes({"argv": command})):
        raise ValidationError("shard command digest mismatch")
    kind = request.get("kind")
    if kind == "behavior":
        exact = [
            "bin/fm-azure-runner-command.sh", "bash", "-c",
            "{} FM_TEST_SKIP_HERDR=1 bin/fm-behavior-shards.sh --run {} {} results/executed-{}.tsv".format(
                CELL_HOST_CAPABILITY_DECLARATION, shard, count, shard
            ),
        ]
        if command != exact or request.get("artifacts") != ["results/executed-{}.tsv".format(shard)]:
            raise ValidationError("behavior shard command differs from the sealed planner route")
    elif kind == "lint":
        exact = [
            "bin/fm-azure-runner-command.sh", "bash", "-c",
            "bin/fm-lint.sh && uv run --directory tools/agent-fleet --locked ruff check .",
        ]
        if count != 1 or shard != 1 or request.get("artifacts") != [] or command != exact:
            raise ValidationError("lint shard differs from the trusted default-branch command")
    else:
        raise ValidationError("shard kind is unsupported")
    return supplied


def runner_state_dir(env):
    return Path(os.environ.get(
        "FM_AZURE_RUNNER_STATE_DIR", str(env["home"] / "state" / "azure-runner")
    )).resolve()


def shard_plan_entry(state, shard):
    plan = (state.get("admission") or {}).get("shard_plan") or []
    for entry in plan:
        if entry.get("shard") == shard:
            return entry
    raise ValidationError("shard {} has no pre-reserved shape constituent".format(shard))


def materialize_shard_repo(request, extracted):
    repo = extracted / "repo"
    git_bundle = extracted / "snapshot.bundle"
    run(["git", "clone", "--no-local", str(git_bundle), str(repo)])
    git(repo, "checkout", "-B", request["repository"]["branch"], request["repository"]["head"])
    if git(repo, "rev-parse", "HEAD").stdout.strip() != request["repository"]["head"]:
        raise ValidationError("materialized shard head mismatch")
    if git(repo, "rev-parse", "HEAD^{tree}").stdout.strip() != request["repository"]["tree"]:
        raise ValidationError("materialized shard tree mismatch")
    public_remote = "https://github.com/{}.git".format(request["repository"]["slug"])
    git(repo, "remote", "set-url", "origin", public_remote)
    return repo


def prepare_shard_runner(env, state, blob, request, extracted, plan):
    sku = plan["sku"]
    key = request["request_digest"]
    existing = state.setdefault("shard_runs", {}).get(key)
    if existing:
        expected = {
            "blob": blob,
            "sku": sku,
            "round": request["round"],
            "shard": request["shard"],
            "head": request["repository"]["head"],
            "command_digest": request["command_digest"],
        }
        if any(existing.get(name) != value for name, value in expected.items()):
            raise ValidationError("recorded shard runner identity differs from the exact request")
        # Every pass re-downloads a still-pending request into a clean
        # extraction, which drops the previously materialized clone; the
        # retry and resume paths both need the exact repo back at its
        # recorded path.
        if not Path(existing["repo"]).is_dir():
            materialize_shard_repo(request, extracted)
        return existing
    repo = materialize_shard_repo(request, extracted)
    invocation = plan["invocation"]
    # A round may stage more than one request on the same shard constituent
    # (behavior tests plus lint). The constituent's invocation id is one-shot,
    # so only the first record may claim it; every later record derives its
    # own deterministic invocation from its request digest.
    claimed = any(
        value.get("invocation") == invocation
        and value.get("request_digest") != key
        for value in state.get("shard_runs", {}).values()
    )
    if claimed:
        invocation = "azr-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]
    record = {
        "blob": blob,
        "request_digest": key,
        "invocation": invocation,
        "sku": sku,
        "round": request["round"],
        "shard": request["shard"],
        "head": request["repository"]["head"],
        "command_digest": request["command_digest"],
        "repo": str(repo),
        "snapshot_bundle": str(extracted / "snapshot.bundle"),
        "source_ref": "refs/heads/" + request["repository"]["branch"],
        "task": "{}-s{}".format(state["cell"], request["shard"]),
        "generation": request["round"],
        "resource_class": request["resource_class"],
        "artifacts": list(request.get("artifacts", [])),
        "command": list(request["command"]["argv"]),
        "response_uploaded": False,
    }
    state["shard_runs"][key] = record
    save_state(env, state)
    return record


def follow_shard_lineage(env, record):
    """Rebind the record to the newest retry descendant of its invocation.

    A runner retry after proven absence creates a fresh invocation whose
    parent_invocation points at the fenced one; the shard record must follow
    that chain or every later resume and response collection would keep
    addressing the permanently fenced ancestor.
    """
    directory = runner_state_dir(env)
    current = record["invocation"]
    while True:
        advanced = None
        for path in directory.glob("azr-*.json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if (
                value.get("parent_invocation") == current
                and (value.get("request") or {}).get("command_digest") == record["command_digest"]
            ):
                advanced = value["invocation"]
                break
        if advanced is None:
            return current
        current = advanced


def run_shard_invocations(env, state, records):
    processes = []
    runner = ROOT / "bin" / "fm-azure-runner.sh"
    rebound = False
    for record in records:
        followed = follow_shard_lineage(env, record)
        if followed != record["invocation"]:
            record["invocation"] = followed
            rebound = True
    if rebound:
        save_state(env, state)
    for record in records:
        runner_state = runner_state_dir(env) / (record["invocation"] + ".json")
        if runner_state.is_file():
            try:
                probe = json.loads(runner_state.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError("recorded shard runner state is unreadable: {}".format(exc))
            probe_digest = (probe.get("request") or {}).get("command_digest")
            if probe_digest is not None and probe_digest != record["command_digest"]:
                # The state at this invocation belongs to a different request
                # that shared the id (two records on one shard constituent):
                # retrying it would rerun the other record's command forever.
                # Rebind this record to its own derived invocation instead.
                record["invocation"] = "azr-" + hashlib.sha256(
                    record["request_digest"].encode("utf-8")
                ).hexdigest()[:12]
                save_state(env, state)
                runner_state = runner_state_dir(env) / (record["invocation"] + ".json")
        operation = [str(runner), "resume", "--invocation", record["invocation"]]
        if runner_state.is_file():
            try:
                value = json.loads(runner_state.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError("recorded shard runner state is unreadable: {}".format(exc))
            if value.get("phase") == "complete":
                continue
            if value.get("phase") == "absent-fenced":
                # The fenced invocation can never rerun; the runner's retry
                # lane reproves absence and creates the lineage descendant
                # that the next pass rebinds to.
                operation = [
                    str(runner), "retry",
                    "--invocation", record["invocation"],
                    "--confirm-run",
                    "--confirm-subscription", env["subscription"],
                ]
        else:
            operation = [
                str(runner), "run", "--confirm-run",
                "--confirm-subscription", env["subscription"],
                "--repo", record["repo"],
                "--task", record["task"],
                "--generation", record["generation"],
                "--invocation", record["invocation"],
                "--resource-class", record["resource_class"],
                "--capacity-parent", state["cell"],
                "--capacity-reservation-vcpus", str(state["request"]["limits"]["reserved_vcpus"]),
                "--capacity-fence", state["request"]["fence"].split(":", 1)[-1],
                "--source-ref", record["source_ref"],
                "--private-snapshot-bundle", record["snapshot_bundle"],
            ]
            for artifact in record["artifacts"]:
                operation += ["--artifact", artifact]
            operation += ["--"] + record["command"]
        process_env = os.environ.copy()
        process_env["FM_AZURE_RUNNER_SKU"] = record["sku"]
        process_env["FM_AZURE_RUNNER_MAX_CONCURRENCY"] = "8"
        process = subprocess.Popen(
            operation, env=process_env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        processes.append((record, process))
    failures = []
    for record, process in processes:
        stdout, stderr = process.communicate()
        record["runner_stdout_tail"] = stdout[-2000:]
        record["runner_stderr_tail"] = stderr[-2000:]
        # A retry that completed inside this pass created a lineage
        # descendant; rebind before response collection addresses the record.
        followed = follow_shard_lineage(env, record)
        if followed != record["invocation"]:
            record["invocation"] = followed
            rebound = True
        if process.returncode == 125 or process.returncode < 0:
            failures.append("{} rc={}".format(record["invocation"], process.returncode))
    # The tails and any rebind must survive the failure raise below, or a
    # refused transport leaves no durable ground truth for the operator.
    save_state(env, state)
    if failures:
        raise ValidationError("one or more shard transports retained ambiguous state: " + ", ".join(failures))


def extract_runner_archive(path, destination):
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            if not (
                member.name in ("result.json", "stdout.log", "stderr.log", "artifacts")
                or member.name.startswith("artifacts/")
            ):
                raise ValidationError("runner result archive contains an undeclared path")
            if (
                member.issym() or member.islnk() or member.isdev()
                or member.name.startswith("/") or ".." in member.name.split("/")
                or member.size > 256 * 1024**2
            ):
                raise ValidationError("runner result archive contains an unsafe member")
        archive.extractall(str(destination), members=members)


def package_shard_response(env, state, request, record, destination):
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = runner_state_dir(env) / (record["invocation"] + ".json")
    try:
        runner_state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("shard runner state is unreadable: {}".format(exc))
    if runner_state.get("phase") != "complete":
        raise ValidationError("shard runner has not reached safe collected cleanup")
    runner_result = runner_state.get("result") or {}
    runner_request = runner_state.get("request") or {}
    repository = runner_request.get("repository") or {}
    if (
        repository.get("source_mode") != "private-parent-bundle"
        or repository.get("commit") != request["repository"]["head"]
        or repository.get("tree") != request["repository"]["tree"]
        or repository.get("source_ref") != "refs/heads/" + request["repository"]["branch"]
        or repository.get("source_head") != request["repository"]["head"]
    ):
        raise ValidationError("shard runner executed the wrong public branch head/tree")
    if (
        runner_request.get("command_digest") != request["command_digest"]
        or runner_request.get("capacity_parent") != state["cell"]
        or runner_request.get("capacity_reservation_vcpus") != state["request"]["limits"]["reserved_vcpus"]
    ):
        raise ValidationError("shard runner executed the wrong command or capacity parent")
    private_archive = destination / "runner-result.tar.gz"
    storage_download(
        env, runner_state["staging"]["output_blob"], private_archive,
        container=CONTAINER,
    )
    if sha256_file(private_archive) != runner_state.get("result_digest"):
        raise ValidationError("shard runner private archive digest differs from collected control state")
    extracted = destination / "runner-result"
    extracted.mkdir(mode=0o700)
    extract_runner_archive(private_archive, extracted)
    try:
        archive_result = json.loads((extracted / "result.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("shard runner private result is unreadable: {}".format(exc))
    if archive_result != runner_result:
        raise ValidationError("shard runner private/control-plane result identities differ")
    artifact_records = runner_result.get("artifacts")
    artifacts = request.get("artifacts", [])
    if not isinstance(artifact_records, list) or len(artifact_records) != len(artifacts):
        raise ValidationError("shard runner artifact manifest differs from the request")
    artifact_record = artifact_records[0] if artifact_records else None
    if artifact_record is not None and artifact_record.get("path") != artifacts[0]:
        raise ValidationError("shard runner returned the wrong manifest artifact")
    result = {
        "schema": "fm.azure-validation-shard-result/v1",
        "cell": state["cell"], "round": request["round"], "kind": request["kind"],
        "shard": request["shard"], "shard_count": request["shard_count"],
        "head": request["repository"]["head"], "tree": request["repository"]["tree"],
        "request_digest": request["request_digest"], "command_digest": request["command_digest"],
        "invocation": record["invocation"], "vm_instance_id": runner_result.get("vm_instance_id"),
        "boot_id": runner_result.get("boot_id"), "exit_code": runner_result.get("exit_code"),
        "artifact": artifact_record,
        "duration_seconds": runner_result.get("duration_seconds"),
        "cost_usd": round(float(runner_state.get("cost", {}).get("hourly_rate", 0.0)) * float(runner_result.get("duration_seconds", 0.0)) / 3600.0, 6),
    }
    response_root = destination / "response"
    response_root.mkdir(mode=0o700)
    (response_root / "result.json").write_bytes(canonical_bytes(result) + b"\n")
    for name in ("stdout.log", "stderr.log"):
        source = extracted / name
        if source.is_file():
            shutil.copyfile(str(source), str(response_root / name))
    if artifact_record is not None:
        source = extracted / "artifacts" / artifacts[0]
        if (
            not source.is_file() or source.is_symlink()
            or source.stat().st_size != artifact_record.get("bytes")
            or sha256_file(source) != artifact_record.get("digest")
        ):
            raise ValidationError("shard runner returned a mismatched manifest artifact")
        shutil.copyfile(str(source), str(response_root / "executed.tsv"))
    archive = destination / "response.tar.gz"
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as output:
        for source in sorted(response_root.iterdir()):
            info = output.gettarinfo(str(source), arcname=source.name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(source, "rb") as handle:
                output.addfile(info, handle)
    return archive


def drive(env, args):
    deadline = time.monotonic() + args.wait_seconds
    control_probe_at = time.monotonic()
    cell = require_cell(args.cell)
    # The shard-driver lock serializes duplicate drivers without holding the
    # cell-state lock across hours of Azure execution. Observe/status/respond
    # therefore retain bounded access while independent command VMs are busy.
    with lock(env, cell + "-shards"):
        while True:
            with lock(env, cell):
                state = load_state(env, cell)
                if state["phase"] not in ("running", "responding", "reattaching", "needs-decision"):
                    print_status(state)
                    return
                names = list_cell_blobs(env, state)
                requests = [name for name in names if re.match(r"^shards/round-[a-z0-9]{12}/request-[1-8]\.tar\.gz$", name)]
                pending = []
                work_root = env["state_dir"] / "shards" / state["cell"]
                work_root.mkdir(parents=True, exist_ok=True, mode=0o700)
                for blob in sorted(requests):
                    response_blob = blob.replace("/request-", "/response-")
                    if response_blob in names:
                        continue
                    blob_key = sha256_bytes(blob.encode("utf-8")).split(":", 1)[1][:16]
                    request_root = work_root / blob_key
                    if request_root.exists():
                        shutil.rmtree(request_root)
                    request_root.mkdir(mode=0o700)
                    archive = request_root / "request.tar.gz"
                    storage_download(env, blob, archive, container=state["staging"]["container"])
                    extracted = request_root / "extracted"
                    extracted.mkdir(mode=0o700)
                    extract_shard_request(archive, extracted)
                    request = json.loads((extracted / "request.json").read_text(encoding="utf-8"))
                    validate_shard_request(state, request, extracted / "snapshot.bundle", blob)
                    plan = shard_plan_entry(state, int(request["shard"]))
                    record = prepare_shard_runner(env, state, blob, request, extracted, plan)
                    pending.append((request, record, request_root, response_blob))
            if pending:
                run_shard_invocations(env, state, [item[1] for item in pending])
                with lock(env, cell):
                    live = load_state(env, cell)
                    if live["request_digest"] != state["request_digest"]:
                        raise ValidationError("cell identity changed while shard VMs were running")
                    for _request, record, _root, _blob in pending:
                        live_record = live.get("shard_runs", {}).get(record["request_digest"])
                        if not live_record or live_record.get("invocation") != record["invocation"]:
                            raise ValidationError("shard invocation identity changed while running")
                        live_record.update({
                            "runner_stdout_tail": record.get("runner_stdout_tail", ""),
                            "runner_stderr_tail": record.get("runner_stderr_tail", ""),
                        })
                    save_state(env, live)
                for request, record, request_root, response_blob in pending:
                    archive = package_shard_response(env, live, request, record, request_root)
                    storage_upload(
                        env, archive, response_blob, overwrite=False,
                        container=live["staging"]["container"],
                    )
                with lock(env, cell):
                    live = load_state(env, cell)
                    for _request, record, _root, _blob in pending:
                        live["shard_runs"][record["request_digest"]]["response_uploaded"] = True
                    save_state(env, live)
                print("AZURE VALIDATION SHARDS DISPATCHED cell={} count={}".format(cell, len(pending)))
                return
            if time.monotonic() >= deadline:
                print("AZURE VALIDATION SHARDS WAITING cell={} pending=0".format(cell))
                return
            # A guest whose control command already ended can never publish
            # another shard request, so waiting out the deadline only delays
            # the observe that records the terminal outcome. Attempt 1 of
            # generation 005 burned its whole 47-minute wall budget this way
            # after the guest died in bootstrap. Probe at most every 30
            # seconds; observe stays the sole owner of the state transition.
            if time.monotonic() >= control_probe_at:
                control_probe_at = time.monotonic() + 30
                execution, _view = run_command_status(env, state)
                if execution in ("Succeeded", "Failed", "Canceled", "TimedOut"):
                    print("AZURE VALIDATION CONTROL TERMINAL cell={} control_state={} pending=0".format(cell, execution))
                    return
            time.sleep(5)


def queue(env):
    ensure_dirs(env)
    rows = []
    for path in sorted(env["state_dir"].glob("azv-*.json")):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            value = json.loads(path.read_text(encoding="utf-8"))
            rows.append((value.get("created_at", ""), value))
    rows.sort(key=lambda item: (item[0], item[1].get("cell", "")))
    if not rows:
        print("AZURE VALIDATION QUEUE empty active=0 queued=0 lanes_used=0/{}".format(env["lanes"]))
        return
    occupied = [state for _, state in rows if state.get("phase") in LANE_PHASES]
    queued = [state for _, state in rows if state.get("phase") == "queued"]
    print("AZURE VALIDATION LANES used={}/{} queued={}".format(
        len(occupied), env["lanes"], len(queued)
    ))
    for _, state in rows:
        lane = state.get("lane")
        print("cell={} phase={} lane={} task={} head={} class={} attempt={}".format(
            state.get("cell"), state.get("phase"),
            lane if isinstance(lane, int) else "-",
            state.get("request", {}).get("task"),
            state.get("request", {}).get("repository", {}).get("head"),
            state.get("request", {}).get("resource_class"), state.get("attempt"),
        ))


def print_status(state):
    result = state.get("result") or {}
    fields = [
        "AZURE VALIDATION", "cell=" + state["cell"], "phase=" + state["phase"],
        "task=" + state["request"]["task"], "head=" + state["request"]["repository"]["head"],
        "attempt=" + str(state["attempt"]),
    ]
    if state.get("run_id"):
        fields.append("run=" + str(state["run_id"]))
    if result.get("current_head"):
        fields.append("current_head=" + result["current_head"])
    if result.get("pr_url"):
        fields.append("pr=" + result["pr_url"])
    print(" ".join(fields))


def status(env, args):
    with lock(env, require_cell(args.cell)):
        print_status(load_state(env, args.cell))


def pure_check(args):
    value = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
    operation = value.get("operation")
    if operation == "shape-plan":
        rates = value.get("rates") or {}
        plan = compose_shard_plan(
            value["selected_family"], value["behavior_shards"],
            lambda sku: rates[sku],
        )
        print(json.dumps({
            "plan": plan,
            "total_vcpus": 8 + 4 * len(plan),
            "distinct_invocations": len({entry["invocation"] for entry in plan}),
        }, sort_keys=True))
        return
    if operation == "result-identity":
        verify_result_identity(value["state"], value["result"])
        print(json.dumps({"valid": True}, sort_keys=True))
        return
    if operation == "replacement":
        allowed, reason = replacement_allowed(value["state"], value["vm_presence"])
        print(json.dumps({"allowed": allowed, "reason": reason}, sort_keys=True))
        return
    raise ValidationError("unknown focused pure-check operation")


def parser():
    root = argparse.ArgumentParser(prog="fm-azure-validation.sh")
    commands = root.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser(
        "build-runtime-bundle",
        help="build a deterministic credential-free Linux runtime bundle",
    )
    build_parser.add_argument("--provider", required=True, choices=PROVIDERS)
    build_parser.add_argument("--no-mistakes", required=True)
    build_parser.add_argument("--provider-binary", required=True)
    build_parser.add_argument("--provider-extra", action="append", default=[])
    build_parser.add_argument("--gh", required=True)
    build_parser.add_argument("--node", required=True)
    build_parser.add_argument("--gh-axi-package", required=True)
    build_parser.add_argument("--no-mistakes-version", required=True)
    build_parser.add_argument("--output", required=True)
    submit_parser = commands.add_parser("submit")
    submit_parser.add_argument("--repo")
    submit_parser.add_argument("--task", required=True)
    submit_parser.add_argument("--task-generation", required=True)
    submit_parser.add_argument("--validation-generation", required=True)
    submit_parser.add_argument("--intent-file", required=True)
    submit_parser.add_argument("--credential-lease", required=True)
    submit_parser.add_argument("--runtime-bundle", required=True)
    submit_parser.add_argument("--resource-class", choices=sorted(RESOURCE_CLASSES))
    dispatch_parser = commands.add_parser("dispatch")
    dispatch_parser.add_argument("--confirm-dispatch", action="store_true")
    dispatch_parser.add_argument("--confirm-subscription")
    for name in ("observe", "collect", "status"):
        item = commands.add_parser(name)
        item.add_argument("--cell", required=True)
    drive_parser = commands.add_parser("drive")
    drive_parser.add_argument("--cell", required=True)
    drive_parser.add_argument("--wait-seconds", type=int, default=0, choices=range(0, 301))
    respond_parser = commands.add_parser("respond")
    respond_parser.add_argument("--cell", required=True)
    respond_parser.add_argument("--response-file", required=True)
    replace_parser = commands.add_parser("replace")
    replace_parser.add_argument("--cell", required=True)
    replace_parser.add_argument("--confirm-replace", action="store_true")
    replace_parser.add_argument("--confirm-subscription")
    close_parser = commands.add_parser("close")
    close_parser.add_argument("--cell", required=True)
    close_parser.add_argument("--confirm-close", action="store_true")
    close_parser.add_argument("--confirm-subscription")
    close_parser.add_argument("--confirm-head", required=True)
    retain_parser = commands.add_parser("retain-failure")
    retain_parser.add_argument("--cell", required=True)
    retain_parser.add_argument("--confirm-retain", action="store_true")
    retain_parser.add_argument("--confirm-subscription")
    purge_parser = commands.add_parser("purge-retained")
    purge_parser.add_argument("--cell", required=True)
    purge_parser.add_argument("--confirm-purge", action="store_true")
    purge_parser.add_argument("--confirm-subscription")
    purge_parser.add_argument("--confirm-cell", required=True)
    purge_parser.add_argument("--confirm-request-digest", required=True)
    commands.add_parser("queue")
    seed_parser = commands.add_parser("auth-seed")
    seed_parser.add_argument("--codex")
    seed_parser.add_argument("--claude")
    seed_parser.add_argument("--apply", action="store_true")
    seed_parser.add_argument("--confirm-seed", action="store_true")
    seed_parser.add_argument("--confirm-subscription")
    pure = commands.add_parser("pure-check", help=argparse.SUPPRESS)
    pure.add_argument("--fixture", required=True)
    return root


def main():
    args = parser().parse_args()
    try:
        if args.command == "pure-check":
            pure_check(args)
            return 0
        if args.command == "build-runtime-bundle":
            build_runtime_bundle(args)
            return 0
        cloud = args.command in (
            "dispatch", "drive", "observe", "collect", "respond", "replace",
            "close", "retain-failure", "purge-retained",
        )
        # Planning a seed is a purely local credential read; only the upload
        # needs a cloud scope, so a plan works without Azure environment.
        if args.command == "auth-seed" and args.apply:
            cloud = True
        env = environment(require_cloud=cloud)
        if args.command == "submit":
            submit(env, args)
        elif args.command == "dispatch":
            dispatch(env, args)
        elif args.command == "drive":
            drive(env, args)
        elif args.command == "observe":
            observe(env, args)
        elif args.command == "collect":
            collect(env, args)
        elif args.command == "respond":
            respond(env, args)
        elif args.command == "replace":
            replace(env, args)
        elif args.command == "close":
            close(env, args)
        elif args.command == "retain-failure":
            fail_retain(env, args)
        elif args.command == "purge-retained":
            purge_retained(env, args)
        elif args.command == "queue":
            queue(env)
        elif args.command == "status":
            status(env, args)
        elif args.command == "auth-seed":
            auth_seed(env, args)
        return 0
    except ValidationError as exc:
        print("AZURE VALIDATION FAILED: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
