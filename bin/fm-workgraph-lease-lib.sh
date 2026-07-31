#!/usr/bin/env bash
# WorkGraph Slice 5 durable lease authority.
#
# This file owns only the offline lease/fencing surface.  It intentionally has
# no dependency on dispatch, brief, spawn, teardown, gates, watchers, or
# operational services.
set -eu
umask 077

LEASE_COMMAND=${1:-}
case "$LEASE_COMMAND" in
  acquire|release|recover|status|fence|inspect)
    exec {FM_LEASE_BASH_FD}<"/proc/$$/exe"
    export FM_LEASE_BASH_FD
    exec python3 - "$0" "$@" <<'PY_BOOTSTRAP'
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import ctypes
import ctypes.util
import shutil
import time

os.umask(0o077)

def fail(code, exit_code=1):
    sys.stdout.write("")
    sys.stderr.write(f"fm-workgraph: WG-L-E-{code}: lease operation failed\n")
    raise SystemExit(exit_code)

def usage():
    fail("USAGE", 2)

script, *command_args = sys.argv[1:]
home = os.path.abspath(os.environ.get("FM_HOME", os.getcwd()))
data = os.path.abspath(os.environ.get("FM_DATA_OVERRIDE", os.path.join(home, "data")))
store = os.path.join(data, "workgraphs", ".leases", "v1")
uid = os.getuid()
id_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
hash_re = re.compile(r"^[0-9a-f]{64}$")
pos_dec_re = re.compile(r"^[1-9][0-9]*$")
dec_re = re.compile(r"^(0|[1-9][0-9]*)$")
boot_re = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
hostname_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$")
LOCAL_FS = {0x0000EF53, 0x58465342, 0x9123683E, 0x01021994, 0x794C7630, 0x2FC12FC1}

class DuplicateKey(ValueError):
    pass

def reject_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKey(key)
        value[key] = item
    return value

def canonical_json(value):
    return (json.dumps(value, ensure_ascii=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")

def no_symlink_prefix(path, code="CAPTURE"):
    absolute = os.path.abspath(path)
    current = os.sep
    parts = [part for part in absolute.split(os.sep) if part]
    for index, part in enumerate(parts):
        current = os.path.join(current, part)
        try:
            st = os.lstat(current)
        except OSError:
            fail(code)
        if stat.S_ISLNK(st.st_mode):
            fail(code)
        if index < len(parts) - 1 and not stat.S_ISDIR(st.st_mode):
            fail(code)
    return absolute

def stable_open(path, code="CAPTURE"):
    fd = None
    parent_fd = None
    try:
        absolute = os.path.abspath(path)
        parts = [part for part in absolute.split(os.sep) if part]
        if not parts:
            fail(code)
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        parent_fd = os.open(os.sep, flags)
        for part in parts[:-1]:
            child_fd = os.open(part, flags, dir_fd=parent_fd)
            child_stat = os.fstat(child_fd)
            if not stat.S_ISDIR(child_stat.st_mode):
                os.close(child_fd)
                fail(code)
            os.close(parent_fd)
            parent_fd = child_fd
        parent_before = os.fstat(parent_fd)
        leaf = parts[-1]
        before = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            fail(code)
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=parent_fd)
        current = os.fstat(fd)
        fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if (not stat.S_ISREG(current.st_mode) or
                any(getattr(current, field) != getattr(before, field) for field in fields)):
            fail(code)
        def read_exact():
            chunks = []
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks)
        data_bytes = read_exact()
        os.lseek(fd, 0, os.SEEK_SET)
        second_bytes = read_exact()
        after = os.fstat(fd)
        path_after = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        parent_after = os.fstat(parent_fd)
        if (any(getattr(after, field) != getattr(current, field) for field in fields) or
                any(getattr(path_after, field) != getattr(current, field) for field in fields) or
                any(getattr(parent_after, field) != getattr(parent_before, field) for field in fields) or
                len(data_bytes) != current.st_size or data_bytes != second_bytes):
            fail(code)
        os.lseek(fd, 0, os.SEEK_SET)
        os.set_inheritable(fd, True)
        return fd, data_bytes, {"fd": fd, "dev": current.st_dev, "ino": current.st_ino, "size": current.st_size,
                                "mode": current.st_mode, "uid": current.st_uid, "gid": current.st_gid,
                                "nlink": current.st_nlink, "mtime_ns": current.st_mtime_ns, "ctime_ns": current.st_ctime_ns,
                                "sha256": hashlib.sha256(data_bytes).hexdigest()}
    except SystemExit:
        raise
    except (OSError, UnicodeError):
        fail(code)
    finally:
        if parent_fd is not None:
            try:
                os.close(parent_fd)
            except OSError:
                pass

def parse_json(data_bytes, code="SCHEMA"):
    try:
        if not data_bytes.endswith(b"\n") or data_bytes.endswith(b"\n\n"):
            fail(code)
        value = json.loads(data_bytes[:-1].decode("utf-8"), object_pairs_hook=reject_duplicates)
        return value
    except SystemExit:
        raise
    except (ValueError, UnicodeError):
        fail(code)

def preflight_grammar(command_args):
    if not command_args:
        usage()
    command = command_args[0]
    if command == "acquire":
        if len(command_args) != 11 or command_args[3] != "--registry" or command_args[5] != "--lease-id" or command_args[7] != "--holder-id" or command_args[9] != "--holder-pid":
            usage()
    elif command == "release":
        if len(command_args) != 8 or command_args[2] != "--lease-id" or command_args[4] != "--holder-id" or command_args[6] != "--fencing-token":
            usage()
    elif command == "recover":
        if len(command_args) != 6 or command_args[2] != "--lease-id" or command_args[4] != "--actor-id":
            usage()
    elif command == "status":
        if len(command_args) != 2:
            usage()
    elif command == "fence":
        if len(command_args) != 8 or command_args[2] != "--lease-id" or command_args[4] != "--holder-id" or command_args[6] != "--fencing-token":
            usage()
    elif command == "inspect":
        if len(command_args) < 2:
            usage()
        seen_history = False
        seen_lease = False
        index = 2
        while index < len(command_args):
            if command_args[index] == "--history" and not seen_history:
                seen_history = True
                index += 1
            elif command_args[index] == "--lease-id" and not seen_lease and index + 1 < len(command_args) and not command_args[index + 1].startswith("--"):
                seen_lease = True
                index += 2
            else:
                usage()
    else:
        usage()

def preflight_filesystem():
    candidate = data
    while True:
        current = lst(candidate)
        if current is not None:
            if not stat.S_ISDIR(current.st_mode):
                fail("STORE")
            break
        parent = os.path.dirname(candidate)
        if parent == candidate:
            fail("STORE")
        candidate = parent
    class Statfs(ctypes.Structure):
        _fields_ = [("f_type", ctypes.c_long), ("rest", ctypes.c_byte * 256)]
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        fn = libc.statfs
        fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(Statfs)]
        fn.restype = ctypes.c_int
        info = Statfs()
        if fn(os.fsencode(candidate), ctypes.byref(info)) != 0 or (int(info.f_type) & 0xffffffff) not in LOCAL_FS:
            fail("STORE")
    except SystemExit:
        raise
    except (AttributeError, OSError):
        fail("STORE")

def verify_authority_readonly():
    """Prove the canonical D/authority path without following or creating it."""
    absolute_d = os.path.abspath(data)
    parts = absolute_d.split(os.sep)
    current = os.sep
    data_stat = None
    for part in [p for p in parts if p]:
        current = os.path.join(current, part)
        st = lst(current)
        if st is None:
            return
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
            fail("STORE")
        if current == absolute_d:
            if st.st_uid != uid:
                fail("STORE")
            data_stat = st
    if data_stat is None:
        return
    authority = absolute_d
    for part in ("workgraphs", ".leases", "v1"):
        authority = os.path.join(authority, part)
        st = lst(authority)
        if st is None:
            return
        if (stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or
                st.st_uid != uid or st.st_dev != data_stat.st_dev or
                (part != "workgraphs" and stat.S_IMODE(st.st_mode) != 0o700)):
            fail("STORE")
    lock_path = os.path.join(authority, ".transaction-lock")
    lock = lst(lock_path)
    if lock is not None and (stat.S_ISLNK(lock.st_mode) or not stat.S_ISREG(lock.st_mode) or
                             lock.st_nlink != 1 or lock.st_uid != uid or
                             stat.S_IMODE(lock.st_mode) != 0o600 or lock.st_dev != data_stat.st_dev):
        fail("STORE")

    namespace = lst(os.path.join(authority, "namespace.json"))
    if namespace is not None and (stat.S_ISLNK(namespace.st_mode) or not stat.S_ISREG(namespace.st_mode) or
                                  namespace.st_nlink != 1 or namespace.st_uid != uid or
                                  stat.S_IMODE(namespace.st_mode) != 0o600 or namespace.st_dev != data_stat.st_dev):
        fail("STORE")
    if namespace is not None and lock is None:
        fail("STORE")

def preflight_capabilities():
    if (not hasattr(os, "O_NOFOLLOW") or not callable(getattr(fcntl, "flock", None)) or
            not callable(getattr(os, "fsync", None)) or not callable(getattr(os, "memfd_create", None))):
        fail("STORE")
    requested_node = os.environ.get("NODE", "node")
    node_path = requested_node if os.path.sep in requested_node else shutil.which(requested_node)
    if not node_path:
        fail("STORE")
    node_fd = None
    python_fd = None
    bash_fd_for_cleanup = globals().get("bash_fd")
    closed_fds = set()
    def close_capability_fd(fd):
        if fd is None or fd in closed_fds:
            return
        closed_fds.add(fd)
        try:
            os.close(fd)
        except OSError:
            pass
    try:
        node_path_stat = os.stat(node_path, follow_symlinks=True)
        if not stat.S_ISREG(node_path_stat.st_mode) or not os.access(node_path, os.X_OK):
            fail("STORE")
        node_fd = os.open(node_path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        node_fd_stat = os.fstat(node_fd)
        node_fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(node_fd_stat, field) != getattr(node_path_stat, field) for field in node_fields):
            fail("STORE")
        os.set_inheritable(node_fd, True)
        node_exec_path = f"/proc/self/fd/{node_fd}"
        node_probe = subprocess.run(
            [node_exec_path, "--eval", "process.stdout.write(process.version + '\\n')"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            pass_fds=(node_fd,),
        )
        if node_probe.returncode != 0 or not re.fullmatch(rb"v[0-9]+\.[0-9]+\.[0-9]+\n", node_probe.stdout):
            fail("STORE")
    except (OSError, subprocess.SubprocessError):
        close_capability_fd(node_fd)
        fail("STORE")

    libc_name = ctypes.util.find_library("c")
    try:
        libc = ctypes.CDLL(libc_name, use_errno=True) if libc_name else None
        renameat2 = getattr(libc, "renameat2", None) if libc is not None else None
        if renameat2 is None:
            fail("STORE")
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
    except (AttributeError, OSError):
        fail("STORE")

    try:
        probe_fd = os.memfd_create("fm-workgraph-capability", getattr(os, "MFD_CLOEXEC", 0))
        try:
            os.fsync(probe_fd)
        finally:
            os.close(probe_fd)
        proc_fd = os.open("/proc/locks", os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.read(proc_fd, 65536)
        finally:
            os.close(proc_fd)
        for proc_path in ("/proc/self", "/proc/self/fd", "/proc/sys/kernel/random/boot_id", "/proc/sys/kernel/hostname"):
            os.stat(proc_path, follow_symlinks=False)
    except (OSError, UnicodeError):
        close_capability_fd(node_fd)
        close_capability_fd(bash_fd_for_cleanup)
        close_capability_fd(python_fd)
        fail("STORE")
    python_fd, python_exec_path = bind_runtime("python3", ["-c", "import sys; sys.stdout.write('python3\\n')"], lambda output: output == b"python3\n")
    return node_path, node_fd, node_exec_path, python_fd, python_exec_path

def memory_fd(label, data_bytes):
    try:
        flags = getattr(os, "MFD_CLOEXEC", 0) | getattr(os, "MFD_ALLOW_SEALING", 0)
        fd = os.memfd_create(label, flags)
        offset = 0
        while offset < len(data_bytes):
            offset += os.write(fd, data_bytes[offset:])
        seals = (getattr(fcntl, "F_SEAL_WRITE", 0) | getattr(fcntl, "F_SEAL_SHRINK", 0) |
                 getattr(fcntl, "F_SEAL_GROW", 0) | getattr(fcntl, "F_SEAL_SEAL", 0))
        if not seals or not hasattr(fcntl, "F_ADD_SEALS"):
            raise OSError("memfd sealing unavailable")
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
        memfd_stat = os.fstat(fd)
        if not stat.S_ISREG(memfd_stat.st_mode) or memfd_stat.st_nlink != 0 or memfd_stat.st_size != len(data_bytes):
            raise OSError("invalid memfd shape")
        os.lseek(fd, 0, os.SEEK_SET)
        os.set_inheritable(fd, True)
        return fd
    except OSError:
        try:
            os.close(fd)
        except (UnboundLocalError, OSError):
            pass
        fail("STORE")

def bind_runtime(name, probe_args, expected, required=True):
    runtime_path = shutil.which(name)
    if not runtime_path:
        if required:
            fail("STORE")
        return None, None
    runtime_fd = None
    try:
        path_stat = os.stat(runtime_path, follow_symlinks=True)
        if not stat.S_ISREG(path_stat.st_mode) or not os.access(runtime_path, os.X_OK):
            fail("STORE")
        runtime_fd = os.open(runtime_path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        fd_stat = os.fstat(runtime_fd)
        fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(fd_stat, field) != getattr(path_stat, field) for field in fields):
            fail("STORE")
        os.set_inheritable(runtime_fd, True)
        executable = f"/proc/self/fd/{runtime_fd}"
        result = subprocess.run([executable, *probe_args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                check=False, pass_fds=(runtime_fd,))
        if result.returncode != 0 or not expected(result.stdout):
            raise OSError("runtime probe failed")
        return runtime_fd, executable
    except (OSError, subprocess.SubprocessError):
        if runtime_fd is not None:
            try:
                os.close(runtime_fd)
            except OSError:
                pass
        if required:
            fail("STORE")
        return None, None
def prove_fresh_authority_absence():
    """Prove no authority artifact exists before deferred SELF may be emitted."""
    current = data
    for part in ("workgraphs", ".leases", "v1"):
        next_path = os.path.join(current, part)
        st = lst(next_path)
        if st is None:
            # The shared data boundary and workgraphs parent may contain
            # unrelated Slice 1-4 data.  Only the reserved lease namespace is
            # closed-world evidence: once .leases exists, a missing v1 is
            # fresh only when .leases itself is empty.
            if part == "v1":
                try:
                    if os.listdir(current):
                        fail("NOT-RECONSTRUCTABLE")
                except OSError:
                    fail("STORE")
            return True
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != uid:
            fail("STORE")
        current = next_path
    namespace = lst(os.path.join(current, "namespace.json"))
    if namespace is not None:
        return False
    try:
        if os.listdir(current):
            fail("NOT-RECONSTRUCTABLE")
    except OSError:
        fail("STORE")
    return True

def preflight_projection(command_args, capture_fds, capture_meta, helper_fd, bash_exec_path, bash_fd):
    if not command_args or command_args[0] != "acquire":
        return None, False
    graph_path = os.path.abspath(command_args[1])
    registry_path = os.path.abspath(command_args[4])
    for capture_fd in capture_fds:
        try:
            os.lseek(capture_fd, 0, os.SEEK_SET)
        except OSError:
            fail("CAPTURE")
    try:
        env = os.environ.copy()
        env["FM_WORKGRAPH_CAPTURED_GRAPH_FD"] = str(capture_fds[0])
        env["FM_WORKGRAPH_CAPTURED_CONTRACT_FD"] = str(capture_fds[1])
        env["FM_WORKGRAPH_CAPTURED_REGISTRY_FD"] = str(capture_fds[2])
        result = subprocess.run(
            [bash_exec_path, f"/proc/self/fd/{helper_fd}", "__lease-project", graph_path, command_args[2], "--registry", registry_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=env,
            pass_fds=tuple([*capture_fds, helper_fd, bash_fd]),
        )
    except OSError:
        fail("SCHEMA")
    for capture_fd in capture_fds:
        try:
            os.lseek(capture_fd, 0, os.SEEK_SET)
        except OSError:
            fail("CAPTURE")
    diagnostic = None
    try:
        lines = result.stderr.decode("utf-8").splitlines()
        if len(lines) == 1 and lines[0].startswith("fm-workgraph: "):
            fields = lines[0].split(": ", 2)
            if len(fields) == 3:
                diagnostic = fields[1]
    except UnicodeError:
        diagnostic = None
    if result.returncode != 0:
        if diagnostic == "WG-E-SELF":
            return None, True
        if diagnostic == "WG-E-CAPTURE":
            fail("CAPTURE")
        fail("SCHEMA")
    projection = result.stdout
    try:
        value = parse_json(projection)
    except SystemExit:
        fail("SCHEMA")
    if (not isinstance(value, dict) or value.get("schema_version") != "workgraph-slice4-lease-projection/v1" or
            value.get("slice_id") != command_args[2] or not isinstance(value.get("resources"), list) or not value["resources"]):
        fail("SCHEMA")
    if (value.get("goal_id") != capture_meta["goal_id"] or
            value.get("graph_sha256") != capture_meta["graph_sha256"] or
            value.get("contract_sha256") != capture_meta["contract_sha256"] or
            value.get("registry_sha256") != capture_meta["registry_sha256"]):
        fail("CAPTURE")
    return projection, False

def preflight_capture(command_args):
    if not command_args or command_args[0] != "acquire" or len(command_args) != 11:
        if command_args and command_args[0] == "acquire":
            usage()
        return {}, None
    _, graph_name, _, registry_flag, registry_name, lease_flag, _, holder_flag, _, pid_flag, _ = command_args
    if registry_flag != "--registry" or lease_flag != "--lease-id" or holder_flag != "--holder-id" or pid_flag != "--holder-pid":
        usage()
    graph_path = os.path.abspath(graph_name)
    graph_fd, graph_bytes, graph_info = stable_open(graph_path)
    registry_path = os.path.abspath(registry_name)
    registry_fd, registry_bytes, registry_info = stable_open(registry_path)
    return {
        "graph_path": graph_path,
        "graph_bytes": graph_bytes,
        "graph_info": graph_info,
        "registry_path": registry_path,
        "registry_bytes": registry_bytes,
        "registry_info": registry_info,
    }, [graph_fd, registry_fd]

def complete_capture(command_args, raw_capture, raw_fds):
    graph_path = raw_capture["graph_path"]
    graph_bytes = raw_capture["graph_bytes"]
    graph_info = raw_capture["graph_info"]
    registry_path = raw_capture["registry_path"]
    registry_bytes = raw_capture["registry_bytes"]
    registry_info = raw_capture["registry_info"]
    slice_id = command_args[2]
    graph_dir = os.path.dirname(graph_path)
    graph = parse_json(graph_bytes)
    if (not isinstance(graph, dict) or graph.get("schema_version") != "workgraph/v1" or
            not isinstance(graph.get("goal_id"), str) or not id_re.fullmatch(graph["goal_id"]) or
            not isinstance(graph.get("slices"), list) or not graph["slices"]):
        fail("SCHEMA")
    selected = [item for item in graph["slices"] if isinstance(item, dict) and item.get("slice_id") == slice_id]
    if len(selected) != 1:
        fail("CAPTURE")
    item = selected[0]
    if (not isinstance(item.get("contract_path"), str) or os.path.isabs(item["contract_path"]) or
            any(part in ("", ".", "..") for part in item["contract_path"].replace("\\", "/").split("/")) or
            not isinstance(item.get("contract_sha256"), str) or not hash_re.fullmatch(item["contract_sha256"])):
        fail("SCHEMA")
    contract_path = os.path.abspath(os.path.join(graph_dir, item["contract_path"]))
    try:
        if os.path.commonpath((graph_dir, contract_path)) != graph_dir:
            fail("SCHEMA")
    except ValueError:
        fail("SCHEMA")
    contract_fd, contract_bytes, contract_info = stable_open(contract_path)
    if hashlib.sha256(contract_bytes).hexdigest() != item["contract_sha256"]:
        fail("CAPTURE")
    registry = parse_json(registry_bytes)
    if (not isinstance(registry, dict) or set(registry) != {"schema_version", "instances"} or
            registry.get("schema_version") != "resource-registry/v1" or not isinstance(registry.get("instances"), list)):
        fail("SCHEMA")
    registry_ids = set()
    for instance in registry["instances"]:
        if (not isinstance(instance, dict) or set(instance) != {"id", "namespace", "resource", "aliases", "contains"} or
                not id_re.fullmatch(instance.get("id") or "") or instance["id"] in registry_ids or
                not isinstance(instance.get("namespace"), str) or not isinstance(instance.get("resource"), str) or
                not isinstance(instance.get("aliases"), list) or not isinstance(instance.get("contains"), list)):
            fail("SCHEMA")
        registry_ids.add(instance["id"])
    graph_info["sha256"] = hashlib.sha256(graph_bytes).hexdigest()
    contract_info["sha256"] = hashlib.sha256(contract_bytes).hexdigest()
    registry_info["sha256"] = hashlib.sha256(registry_bytes).hexdigest()
    capture = {
        graph_path: graph_info,
        contract_path: contract_info,
        registry_path: registry_info,
        "goal_id": graph["goal_id"],
        "slice_id": slice_id,
        "graph_sha256": graph_info["sha256"],
        "contract_sha256": contract_info["sha256"],
        "registry_sha256": registry_info["sha256"],
        "contract_bytes": contract_bytes,
        "contract_fds": {contract_path: contract_fd},
    }
    return capture, [raw_fds[0], contract_fd, raw_fds[1]]

def preflight_value_grammar(command_args):
    command = command_args[0]
    if command == "acquire":
        if (not id_re.fullmatch(command_args[6] or "") or
                not id_re.fullmatch(command_args[8] or "") or
                not pos_dec_re.fullmatch(command_args[10] or "")):
            fail("SCHEMA")
    elif command in {"release", "fence"}:
        if (not id_re.fullmatch(command_args[1] or "") or
                not id_re.fullmatch(command_args[3] or "") or
                not id_re.fullmatch(command_args[5] or "") or
                not pos_dec_re.fullmatch(command_args[7] or "")):
            fail("SCHEMA")
    elif command == "recover":
        if (not id_re.fullmatch(command_args[1] or "") or
                not id_re.fullmatch(command_args[3] or "") or
                not id_re.fullmatch(command_args[5] or "")):
            fail("SCHEMA")
    elif command == "status":
        if not id_re.fullmatch(command_args[1] or ""):
            fail("SCHEMA")
    elif command == "inspect":
        if not id_re.fullmatch(command_args[1] or ""):
            fail("SCHEMA")
        index = 2
        while index < len(command_args):
            if command_args[index] == "--history":
                index += 1
            elif command_args[index] == "--lease-id":
                if index + 1 >= len(command_args) or not id_re.fullmatch(command_args[index + 1] or ""):
                    fail("SCHEMA")
                index += 2
            else:
                usage()

def preflight_acquire_slice(command_args):
    if command_args and command_args[0] == "acquire" and not id_re.fullmatch(command_args[2] or ""):
        fail("SCHEMA")

def capture_holder_identity(command_args, failure_code="IDENTITY"):
    if not command_args or command_args[0] != "acquire":
        return None
    pid = command_args[10]
    if not pos_dec_re.fullmatch(pid or ""):
        fail(failure_code)
    def read_all(path):
        no_follow = getattr(os, "O_NOFOLLOW", None)
        if not isinstance(no_follow, int):
            fail(failure_code)
        try:
            fd = os.open(path, os.O_RDONLY | no_follow)
            chunks = []
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            os.close(fd)
            return b"".join(chunks)
        except OSError:
            fail(failure_code)
    def once():
        cmdline = read_all(f"/proc/{pid}/cmdline")
        stat_bytes = read_all(f"/proc/{pid}/stat")
        boot = read_all("/proc/sys/kernel/random/boot_id")
        hostname = read_all("/proc/sys/kernel/hostname")
        return cmdline, stat_bytes, boot, hostname
    first = once()
    second = once()
    try:
        def observation_tuple(observation):
            stat_text = observation[1].decode("utf-8")
            end = stat_text.rfind(")")
            fields = stat_text[end + 2:].split() if end >= 0 else []
            start = fields[19] if len(fields) > 19 else ""
            boot_bytes = observation[2][:-1] if observation[2].endswith(b"\n") else observation[2]
            hostname_bytes = observation[3][:-1] if observation[3].endswith(b"\n") else observation[3]
            return observation[0], start, boot_bytes, hostname_bytes
        first_tuple = observation_tuple(first)
        second_tuple = observation_tuple(second)
        if first_tuple != second_tuple:
            fail(failure_code)
        stat_text = first[1].decode("utf-8")
        cmdline_bytes, start_ticks, boot_bytes, hostname_bytes = first_tuple
        boot_id = boot_bytes.decode("ascii")
        hostname = hostname_bytes.decode("ascii")
    except UnicodeError:
        fail(failure_code)
    if (not cmdline_bytes or not pos_dec_re.fullmatch(start_ticks) or not boot_re.fullmatch(boot_id) or
            not hostname_re.fullmatch(hostname)):
        fail(failure_code)
    return {"pid": pid, "start_ticks": start_ticks,
            "cmdline_sha256": hashlib.sha256(cmdline_bytes).hexdigest(),
            "boot_id": boot_id, "hostname": hostname}

def revalidate_holder_identity(expected, failure_code="IDENTITY"):
    if expected is None:
        return
    actual = capture_holder_identity(["acquire", "", "", "", "", "", "", "", "", "", expected["pid"]], failure_code)
    if actual != expected:
        fail(failure_code)

def revalidate_capture(meta):
    for value in meta.values():
        if not isinstance(value, dict) or "fd" not in value:
            continue
        fd = value["fd"]
        try:
            before = os.fstat(fd)
            if (before.st_dev != value["dev"] or before.st_ino != value["ino"] or
                    before.st_mode != value["mode"] or before.st_uid != value["uid"] or
                    before.st_gid != value["gid"] or before.st_nlink != value["nlink"] or
                    before.st_size != value["size"] or before.st_mtime_ns != value["mtime_ns"] or
                    before.st_ctime_ns != value["ctime_ns"]):
                fail("CAPTURE")
            os.lseek(fd, 0, os.SEEK_SET)
            chunks = []
            while True:
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            data_bytes = b"".join(chunks)
            after = os.fstat(fd)
            if (len(data_bytes) != value["size"] or hashlib.sha256(data_bytes).hexdigest() != value["sha256"] or
                    after.st_dev != before.st_dev or after.st_ino != before.st_ino or
                    after.st_mode != before.st_mode or after.st_uid != before.st_uid or
                    after.st_gid != before.st_gid or after.st_nlink != before.st_nlink or
                    after.st_size != before.st_size or
                    after.st_mtime_ns != before.st_mtime_ns or after.st_ctime_ns != before.st_ctime_ns):
                fail("CAPTURE")
            os.lseek(fd, 0, os.SEEK_SET)
        except SystemExit:
            raise
        except OSError:
            fail("CAPTURE")

def rollback_authority(lock_path, remove_lock, created_paths):
    """Attempt every rollback step and fail closed if any proof step fails."""
    def fsync_parent_quiet(path):
        parent = os.path.dirname(path)
        fd = None
        result = False
        try:
            before = os.lstat(parent)
            if not stat.S_ISDIR(before.st_mode):
                return False
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            after = os.fstat(fd)
            if (after.st_ino != before.st_ino or after.st_dev != before.st_dev or
                    after.st_nlink != before.st_nlink or stat.S_IMODE(after.st_mode) != stat.S_IMODE(before.st_mode)):
                return False
            os.fsync(fd)
            result = True
        except OSError:
            result = False
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    result = False
        return result
    failures = []
    if remove_lock:
        try:
            os.unlink(lock_path)
            if not fsync_parent_quiet(lock_path):
                failures.append("lock:fsync")
        except OSError as error:
            failures.append(f"lock:{type(error).__name__}")
    for created_path in reversed(created_paths):
        try:
            os.rmdir(created_path)
            if not fsync_parent_quiet(created_path):
                failures.append(f"dir:{created_path}:fsync")
        except OSError as error:
            failures.append(f"dir:{created_path}:{type(error).__name__}")
    if failures:
        # The triggering fail() already emitted the one canonical public line.
        # Keep cleanup failure fail-closed without adding a second diagnostic.
        raise SystemExit(1)

def lst(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError:
        fail("STORE")

def fsync_parent(path):
    absolute = os.path.abspath(path)
    parts = [part for part in absolute.split(os.sep) if part]
    if not parts:
        fail("STORE")
    parent_parts, leaf = parts[:-1], parts[-1]
    fd = None
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(os.sep, flags)
        for part in parent_parts:
            child = os.open(part, flags, dir_fd=fd)
            old = fd
            fd = child
            os.close(old)
        target = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISDIR(target.st_mode):
            fail("STORE")
        os.fsync(fd)
    except SystemExit:
        raise
    except OSError:
        fail("STORE")
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

def walk_authority(path):
    absolute = os.path.abspath(path)
    parts = [p for p in absolute.split(os.sep) if p]
    current = os.sep
    fd = None
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
        fd = os.open(os.sep, flags)
        for index, part in enumerate(parts):
            current = os.path.join(current, part)
            try:
                st = os.stat(part, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                if current != data and not current.startswith(data + os.sep):
                    fail("STORE")
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                    created_authority_paths.append(current)
                    os.fsync(fd)
                    st = os.stat(part, dir_fd=fd, follow_symlinks=False)
                except OSError:
                    fail("STORE")
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
                fail("NOT-RECONSTRUCTABLE")
            authority = current == data or current.startswith(data + os.sep)
            if st.st_uid != uid and authority:
                fail("NOT-RECONSTRUCTABLE")
            if current != data and current != os.path.join(data, "workgraphs") and authority and stat.S_IMODE(st.st_mode) != 0o700:
                fail("NOT-RECONSTRUCTABLE")
            child = os.open(part, flags, dir_fd=fd)
            child_st = os.fstat(child)
            if (child_st.st_ino != st.st_ino or child_st.st_dev != st.st_dev or
                    child_st.st_mode != st.st_mode or child_st.st_uid != st.st_uid):
                os.close(child)
                fail("STORE")
            os.close(fd)
            fd = child
    except OSError:
        fail("STORE")
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass

def relocate_fd(fd):
    try:
        moved = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 64)
        os.set_inheritable(moved, True)
        os.close(fd)
        return moved
    except OSError:
        fail("STORE")

def close_python_capture_inputs():
    global source_fd, capture_fds
    for capture_fd in capture_fds or []:
        try:
            os.close(capture_fd)
        except OSError:
            pass
    capture_fds = []
    if source_fd is not None:
        try:
            os.close(source_fd)
        except OSError:
            pass
        source_fd = None

def reserve_child_descriptors(lock_fd=None, projection=None):
    global node_fd, node_exec_path, helper_fd, bash_fd, python_fd
    helper_fd = relocate_fd(helper_fd)
    bash_fd = relocate_fd(bash_fd)
    python_fd = relocate_fd(python_fd)
    node_fd = relocate_fd(node_fd)
    node_exec_path = f"/proc/self/fd/{node_fd}"
    if lock_fd is not None:
        lock_fd = relocate_fd(lock_fd)
    if projection is not None:
        projection = relocate_fd(projection)
    return lock_fd, projection

def inherited_bash():
    try:
        bash_fd = int(os.environ["FM_LEASE_BASH_FD"])
        bash_stat = os.fstat(bash_fd)
        if not stat.S_ISREG(bash_stat.st_mode) or not (bash_stat.st_mode & 0o111):
            fail("STORE")
        os.set_inheritable(bash_fd, True)
        return bash_fd, f"/proc/self/fd/{bash_fd}"
    except (KeyError, ValueError, OSError):
        fail("STORE")

created_authority_paths = []
preflight_grammar(command_args)
source_fd, source_bytes, source_info = stable_open(script, "CAPTURE")
helper_path = os.path.join(os.path.dirname(script), "fm-workgraph.sh")
helper_fd, helper_bytes, helper_info = stable_open(helper_path, "CAPTURE")
raw_capture, raw_capture_fds = preflight_capture(command_args)
if command_args and command_args[0] == "acquire":
    preflight_acquire_slice(command_args)
    pre_capture, capture_fds = complete_capture(command_args, raw_capture, raw_capture_fds)
    preflight_value_grammar(command_args)
else:
    pre_capture, capture_fds = raw_capture, raw_capture_fds
    preflight_value_grammar(command_args)
bash_fd, bash_exec_path = inherited_bash()
projection_bytes, deferred_self = preflight_projection(command_args, capture_fds or [], pre_capture, helper_fd, bash_exec_path, bash_fd)
try:
    source_text = source_bytes.decode("utf-8")
    begin = source_text.index("// NODE_SOURCE_BEGIN\n") + len("// NODE_SOURCE_BEGIN\n")
    end = source_text.index("// NODE_SOURCE_END\n", begin)
    node_source = source_text[begin:end].encode("utf-8")
except (UnicodeError, ValueError):
    fail("CAPTURE")
bound_capture_meta = dict(pre_capture)
bound_capture_meta[script] = source_info
bound_capture_meta[helper_path] = helper_info
projection_fd = None
if projection_bytes:
    projection_fd = memory_fd("fm-workgraph-projection", projection_bytes)
preflight_filesystem()
verify_authority_readonly()
node_path, node_fd, node_exec_path, python_fd, python_exec_path = preflight_capabilities()
holder_identity = capture_holder_identity(command_args)
readonly = command_args[0] in {"status", "fence", "inspect"}

def test_lock_admission(phase):
    """Deterministic lock-race seam; inert unless the complete test contract is set."""
    enabled = os.environ.get("FM_WORKGRAPH_TEST_HOOKS")
    root = os.environ.get("FM_LEASE_TEST_ADMISSION_ROOT")
    admission_id = os.environ.get("FM_LEASE_TEST_ADMISSION_ID")
    if root is None and admission_id is None:
        return
    if enabled != "1" or not root or not admission_id or not id_re.fullmatch(admission_id):
        fail("STORE")
    try:
        if not os.path.isabs(root) or os.path.realpath(root) != root:
            fail("STORE")
        root_stat = os.lstat(root)
        if (not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode) or
                root_stat.st_uid != uid or stat.S_IMODE(root_stat.st_mode) != 0o700):
            fail("STORE")
        marker = os.path.join(root, f"{admission_id}.{phase}")
        marker_fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(marker_fd, f"{phase}\n".encode("ascii"))
            os.fsync(marker_fd)
        finally:
            os.close(marker_fd)
        parent_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        wait_marker = None
        if phase == "ready":
            wait_marker = os.path.join(root, f"{admission_id}.go")
        elif phase == "locked" and os.environ.get("FM_LEASE_TEST_ADMISSION_HOLD") == "1":
            wait_marker = os.path.join(root, f"{admission_id}.continue")
        if wait_marker is not None:
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                try:
                    wait_stat = os.lstat(wait_marker)
                    if (stat.S_ISREG(wait_stat.st_mode) and not stat.S_ISLNK(wait_stat.st_mode) and
                            wait_stat.st_uid == uid and stat.S_IMODE(wait_stat.st_mode) == 0o600 and
                            wait_stat.st_nlink == 1):
                        return
                    fail("STORE")
                except FileNotFoundError:
                    time.sleep(0.01)
            fail("STORE")
    except SystemExit:
        raise
    except OSError:
        fail("STORE")

def exec_node_unlocked():
    revalidate_capture(bound_capture_meta)
    close_python_capture_inputs()
    bound_capture_meta.clear()
    reserve_child_descriptors()
    try:
        os.dup2(helper_fd, 3, inheritable=True)
        os.dup2(bash_fd, 4, inheritable=True)
        os.dup2(python_fd, 5, inheritable=True)
        node_input_fd = memory_fd("fm-workgraph-node", node_source)
        os.dup2(node_input_fd, 0, inheritable=True)
        env = os.environ.copy()
        env.pop("FM_LEASE_LOCKED", None)
        env.pop("FM_LEASE_LOCK_FD", None)
        env.pop("FM_LEASE_DEFERRED_SELF", None)
        env["FM_LEASE_CAPTURE_META"] = "{}"
        env["FM_WORKGRAPH_SCRIPT_DIR"] = os.path.dirname(script)
        env["FM_LEASE_HELPER_FD"] = "3"
        env["FM_LEASE_BASH_FD"] = "4"
        env["FM_LEASE_PYTHON_FD"] = "5"
        os.execve(node_exec_path, [node_path, "-", *command_args], env)
    except OSError:
        fail("STORE")

if readonly:
    exec_node_unlocked()

lock_path = os.path.join(store, ".transaction-lock")
existing_lock = None
fd = None
lock_created = False
mutation_started = False
try:
    if command_args[0] == "acquire":
        if deferred_self and prove_fresh_authority_absence():
            fail("SELF")
        mutation_started = True
        walk_authority(data)
        walk_authority(os.path.join(data, "workgraphs"))
        walk_authority(os.path.join(data, "workgraphs", ".leases"))
        walk_authority(store)
    else:
        namespace_path = os.path.join(store, "namespace.json")
        if lst(store) is None or lst(namespace_path) is None:
            exec_node_unlocked()
    existing_lock = lst(lock_path)
    if existing_lock is None:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        lock_created = True
    else:
        fd = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
    path_st = os.lstat(lock_path)
    fd_st = os.fstat(fd)
    if (not stat.S_ISREG(fd_st.st_mode) or fd_st.st_ino != path_st.st_ino or
            fd_st.st_dev != path_st.st_dev or fd_st.st_nlink != 1 or
            fd_st.st_uid != uid or stat.S_IMODE(fd_st.st_mode) != 0o600 or
            fd_st.st_dev != os.stat(store, follow_symlinks=False).st_dev):
        fail("STORE")
    if existing_lock is not None and (
            any(getattr(existing_lock, field) != getattr(fd_st, field)
                for field in ("st_dev", "st_ino", "st_mode", "st_uid", "st_nlink"))):
        fail("STORE")
    test_lock_admission("ready")
    test_lock_admission("contending")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError:
        fail("STORE")
    test_lock_admission("locked")
    revalidate_capture(bound_capture_meta)
    revalidate_holder_identity(holder_identity)
    close_python_capture_inputs()
    bound_capture_meta = {}
    os.set_inheritable(fd, True)
    fd, projection_fd = reserve_child_descriptors(fd, projection_fd)
    os.dup2(helper_fd, 3, inheritable=True)
    os.dup2(bash_fd, 4, inheritable=True)
    os.dup2(python_fd, 5, inheritable=True)
    node_input_fd = memory_fd("fm-workgraph-node", node_source)
    os.dup2(node_input_fd, 0, inheritable=True)
    env = os.environ.copy()
    env.pop("FM_LEASE_LOCKED", None)
    env.pop("FM_LEASE_LOCK_FD", None)
    env["FM_LEASE_CAPTURE_META"] = json.dumps(bound_capture_meta, separators=(",", ":"))
    env["FM_LEASE_LOCK_FD"] = str(fd)
    env["FM_LEASE_HELPER_FD"] = "3"
    env["FM_LEASE_BASH_FD"] = "4"
    env["FM_LEASE_PYTHON_FD"] = "5"
    if deferred_self:
        env["FM_LEASE_DEFERRED_SELF"] = "1"
    else:
        env.pop("FM_LEASE_DEFERRED_SELF", None)
    env["FM_WORKGRAPH_SCRIPT_DIR"] = os.path.dirname(script)
    if holder_identity is not None:
        env["FM_LEASE_HOLDER_IDENTITY"] = json.dumps(holder_identity, separators=(",", ":"))
    if projection_fd is not None:
        env["FM_LEASE_PROJECTION_FD"] = str(projection_fd)
        env["FM_LEASE_PROJECTION_SHA256"] = hashlib.sha256(projection_bytes).hexdigest()
    os.execve(node_exec_path, [node_path, "-", *command_args], env)
except SystemExit:
    if mutation_started:
        rollback_authority(lock_path, lock_created, created_authority_paths)
    raise
except OSError:
    if mutation_started:
        rollback_authority(lock_path, lock_created, created_authority_paths)
    fail("STORE")
finally:
    for capture_fd in locals().get("capture_fds", []) or []:
        try:
            os.close(capture_fd)
        except OSError:
            pass
    if fd is not None:
        try:
            os.close(fd)
        except OSError:
            pass
    if source_fd is not None:
        try:
            os.close(source_fd)
        except OSError:
            pass
    if helper_fd is not None:
        try:
            os.close(helper_fd)
        except OSError:
            pass
    if node_fd is not None:
        try:
            os.close(node_fd)
        except OSError:
            pass
    if bash_fd is not None:
        try:
            os.close(bash_fd)
        except OSError:
            pass
    if python_fd is not None:
        try:
            os.close(python_fd)
        except OSError:
            pass
    if projection_fd is not None:
        try:
            os.close(projection_fd)
        except OSError:
            pass
PY_BOOTSTRAP
    ;;
esac

exec node - "$@" <<'NODE'
// NODE_SOURCE_BEGIN
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const child = require("node:child_process");
const {TextDecoder} = require("node:util");

const MAX = 9223372036854775807n;
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u;
const DEC_RE = /^(0|[1-9][0-9]*)$/u;
const POS_DEC_RE = /^[1-9][0-9]*$/u;
const HASH_RE = /^[0-9a-f]{64}$/u;
const BOOT_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const MOD_DIR = 0o700;
const MOD_FILE = 0o600;
const LOCAL_FS = new Set([0x0000ef53, 0x58465342, 0x9123683e, 0x01021994, 0x794c7630, 0x2fc12fc1]);
const rootHome = process.env.FM_HOME || process.cwd();
const D = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(rootHome, "data"));
const S = path.resolve(process.env.FM_STATE_OVERRIDE || path.join(rootHome, "state"));
const STORE = path.join(D, "workgraphs", ".leases", "v1");
let activeTempParentFd = null; let activeTempBase = null; let publicationPreparation = false;
const PRECAPTURE = new Map();
try { for (const [file, meta] of Object.entries(JSON.parse(process.env.FM_LEASE_CAPTURE_META || "{}"))) PRECAPTURE.set(path.resolve(file), meta); } catch { fail("CAPTURE"); }

function clearActiveTemp() {
  if (activeTempParentFd === null) return true;
  const parentFd = activeTempParentFd;
  const tempBase = activeTempBase;
  let clean = true;
  if (tempBase !== null) {
    const boundTemp = `/proc/self/fd/${parentFd}/${tempBase}`;
    try { fs.lstatSync(boundTemp); fs.unlinkSync(boundTemp); } catch (error) { if (!error || error.code !== "ENOENT") clean = false; }
  }
  try { fs.fsyncSync(parentFd); } catch { clean = false; }
  try { fs.closeSync(parentFd); } catch { clean = false; }
  activeTempParentFd = null; activeTempBase = null;
  return clean;
}
function fail(code, exitCode = 1) {
  if (publicationPreparation && code === "STORE") code = "IO";
  if (!clearActiveTemp()) code = "IO";
  process.stdout.write("");
  process.stderr.write(`fm-workgraph: WG-L-E-${code}: lease operation failed\n`);
  process.exit(exitCode);
}
function usage() { fail("USAGE", 2); }
function safeId(value) { return typeof value === "string" && ID_RE.test(value); }
function hashBytes(bytes) { return crypto.createHash("sha256").update(bytes).digest("hex"); }
function asBig(value, positive = false) {
  if (typeof value !== "string" || !(positive ? POS_DEC_RE : DEC_RE).test(value)) fail("SCHEMA");
  let n;
  try { n = BigInt(value); } catch { fail("SCHEMA"); }
  if (n > MAX) fail("SCHEMA");
  return n;
}
function durableBig(value, positive = false) {
  if (typeof value !== "string" || !(positive ? POS_DEC_RE : DEC_RE).test(value)) fail("NOT-RECONSTRUCTABLE");
  let n; try { n = BigInt(value); } catch { fail("NOT-RECONSTRUCTABLE"); }
  if (n > MAX) fail("NOT-RECONSTRUCTABLE");
  return n;
}
function dec(n) { return n.toString(10); }
function compareBig(left, right) { const a = asBig(left, true); const b = asBig(right, true); return a < b ? -1 : a > b ? 1 : 0; }
function compareText(left, right) {
  const a = Buffer.from(left, "utf8"); const b = Buffer.from(right, "utf8");
  const length = Math.min(a.length, b.length);
  for (let i = 0; i < length; i += 1) if (a[i] !== b[i]) return a[i] - b[i];
  return a.length - b.length;
}
function compareRecords(a, b) { return compareText(a.goal_id, b.goal_id) || compareText(a.slice_id, b.slice_id) || compareBig(a.holder_fencing_token, b.holder_fencing_token) || compareText(a.lease_id, b.lease_id); }
function padToken(n) { return dec(n).padStart(20, "0"); }
function canonical(value) {
  const raw = JSON.stringify(value);
  return `${raw.replace(/[^\x00-\x7f]/gu, (ch) => {
    const code = ch.codePointAt(0);
    if (code <= 0xffff) return `\\u${code.toString(16).padStart(4, "0")}`;
    const x = code - 0x10000;
    return `\\u${(0xd800 + (x >> 10)).toString(16)}\\u${(0xdc00 + (x & 1023)).toString(16)}`;
  })}\n`;
}

function lstat(file, code = "STORE") {
  try { return fs.lstatSync(file, {bigint: false}); } catch (error) {
    if (error.code === "ENOENT") return null;
    fail(code);
  }
}
function assertShape(file, kind, expectedMode = undefined, requireOwner = false, failureCode = "NOT-RECONSTRUCTABLE") {
  const st = lstat(file);
  if (!st) return null;
  if ((kind === "file" && !st.isFile()) || (kind === "dir" && !st.isDirectory()) || (kind === "link" && !st.isSymbolicLink())) fail(failureCode);
  if (kind === "file" && st.nlink !== 1) fail(failureCode);
  if (expectedMode !== undefined && expectedMode !== null && (st.mode & 0o7777) !== expectedMode) fail(failureCode);
  if (requireOwner && kind !== "link" && st.uid !== process.getuid()) fail(failureCode);
  return st;
}
function readRegular(file, missing = false, expectedMode = MOD_FILE, failureCode = "NOT-RECONSTRUCTABLE") {
  const st = assertShape(file, "file", expectedMode, expectedMode !== null, failureCode);
  if (!st) { if (missing) return null; fail(failureCode); }
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const exactStat = (target) => fs.lstatSync(target, {bigint: true});
    const exactFdStat = (target) => fs.fstatSync(target, {bigint: true});
    const stExact = exactStat(file);
    const before = exactFdStat(fd);
    const same = (a, b) => a.isFile() && b.isFile() && a.dev === b.dev && a.ino === b.ino &&
      a.mode === b.mode && a.uid === b.uid && a.gid === b.gid && a.nlink === b.nlink &&
      a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
    if (before.nlink !== 1n) fail(failureCode);
    const bytes = fs.readFileSync(fd);
    const after = exactFdStat(fd);
    const pathname = exactStat(file);
    if (!same(stExact, before) || !same(before, after) || !same(before, pathname) || BigInt(bytes.length) !== before.size) fail(failureCode);
    return bytes;
  } catch (error) {
    if (error.code && error.code.startsWith("WG-L-E-")) throw error;
    fail(failureCode === "IO" ? "IO" : "STORE");
  } finally { if (fd !== undefined) { try { fs.closeSync(fd); } catch { fail("STORE"); } } }
}
function parseJson(bytes, errorCode = "SCHEMA") {
  let text;
  try { text = new TextDecoder("utf-8", {fatal: true}).decode(bytes); } catch { fail(errorCode); }
  if (!text.endsWith("\n") || text.endsWith("\n\n")) fail(errorCode);
  const body = text.slice(0, -1);
  let value;
  try { value = JSON.parse(body); } catch { fail(errorCode); }
  const seen = new Set();
  function scan(v) {
    if (v === null || typeof v !== "object") return;
    if (Array.isArray(v)) { v.forEach(scan); return; }
    Object.keys(v).forEach((key) => { if (seen.has(`${key}\u0000${JSON.stringify(v)}`)) return; });
    Object.keys(v).forEach((key) => scan(v[key]));
  }
  // JSON.parse loses duplicate-key information, so scan the source token stream.
  let i = 0;
  function ws() { while (i < body.length && /[ \t\r\n]/u.test(body[i])) i += 1; }
  function str() {
    if (body[i] !== '"') throw new Error();
    const start = i; i += 1;
    while (i < body.length) {
      const c = body[i++];
      if (c === "\\") { if (i >= body.length) throw new Error(); i += 1; continue; }
      if (c === '"') return JSON.parse(body.slice(start, i));
      if (c.charCodeAt(0) < 0x20) throw new Error();
    }
    throw new Error();
  }
  function val() {
    ws();
    if (body[i] === "{") {
      i += 1; ws(); const keys = new Set();
      if (body[i] === "}") { i += 1; return; }
      while (true) {
        const key = str(); if (keys.has(key)) throw new Error(); keys.add(key); ws();
        if (body[i++] !== ":") throw new Error(); val(); ws();
        if (body[i] === "}") { i += 1; return; }
        if (body[i++] !== ",") throw new Error(); ws();
      }
    }
    if (body[i] === "[") {
      i += 1; ws(); if (body[i] === "]") { i += 1; return; }
      while (true) { val(); ws(); if (body[i] === "]") { i += 1; return; } if (body[i++] !== ",") throw new Error(); }
    }
    if (body[i] === '"') { str(); return; }
    const m = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/u.exec(body.slice(i));
    if (!m) throw new Error(); i += m[0].length;
  }
  try { val(); ws(); if (i !== body.length) throw new Error(); } catch { fail(errorCode); }
  scan(value);
  return value;
}
function orderedObject(value, keys, nested = {}) {
  const result = {};
  keys.forEach((key) => {
    if (Object.prototype.hasOwnProperty.call(value, key)) {
      result[key] = nested[key] ? nested[key](value[key]) : value[key];
    }
  });
  return result;
}
function canonicalDurable(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return Buffer.from(canonical(value));
  const schema = value.schema_version;
  if (schema === "lease-namespace/v1") {
    return Buffer.from(canonical(orderedObject(value, ["schema_version", "namespace_id", "goal_scope", "counter_floor"])));
  }
  if (schema === "lease-event/v1") {
    return Buffer.from(canonical(orderedObject(value, ["schema_version", "event", "namespace_id", "goal_id", "slice_id", "lease_id", "holder_id", "transaction_generation", "fencing_token", "record_revision", "proof", "record_sha256"])));
  }
  if (schema === "lease-transaction-owner/v1") {
    return Buffer.from(canonical(orderedObject(value, ["schema_version", "namespace_id", "state", "generation", "pid", "start_ticks", "cmdline_sha256", "boot_id", "hostname"])));
  }
  if (schema === "workgraph-lease/v1") {
    const holder = (item) => orderedObject(item, ["pid", "start_ticks", "cmdline_sha256", "boot_id", "hostname"]);
    const resource = (item) => orderedObject(item, ["resource", "mode", "lock_scopes"]);
    const terminal = (item) => orderedObject(item, ["kind", "actor_id", "proof"]);
    return Buffer.from(canonical(orderedObject(value, ["schema_version", "namespace_id", "goal_id", "slice_id", "lease_id", "graph_sha256", "contract_sha256", "registry_sha256", "state", "revision", "holder_id", "holder_process", "transaction_generation", "holder_fencing_token", "current_fencing_token", "resources", "terminal"], {
      holder_process: holder,
      resources: (items) => Array.isArray(items) ? items.map(resource) : items,
      terminal,
    })));
  }
  if (schema === "lease-cache/v1") {
    return Buffer.from(canonical(orderedObject(value, ["schema_version", "namespace_id", "goal_id", "records"], {
      records: (items) => Array.isArray(items) ? items.map((item) => JSON.parse(canonicalDurable(item).toString("utf8"))) : items,
    })));
  }
  return Buffer.from(canonical(value));
}
function parseDurable(bytes) {
  const value = parseJson(bytes, "NOT-RECONSTRUCTABLE");
  if (!canonicalDurable(value).equals(bytes)) fail("NOT-RECONSTRUCTABLE");
  return value;
}
function strictObject(value, keys, errorCode = "SCHEMA") {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(errorCode);
  const allowed = new Set(keys);
  if (Object.keys(value).some((key) => !allowed.has(key))) fail(errorCode);
  return value;
}
function req(obj, key) { if (!Object.prototype.hasOwnProperty.call(obj, key)) fail("SCHEMA"); return obj[key]; }
function capture(file) {
  const precaptured = PRECAPTURE.get(path.resolve(file));
  if (precaptured) {
    try {
      const before = fs.fstatSync(Number(precaptured.fd));
      if (!before.isFile() || before.dev !== Number(precaptured.dev) || before.ino !== Number(precaptured.ino) || before.size !== Number(precaptured.size) || before.nlink !== 1) fail("CAPTURE");
      const bytes = fs.readFileSync(Number(precaptured.fd));
      const after = fs.fstatSync(Number(precaptured.fd));
      if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino || after.size !== before.size || after.nlink !== 1) fail("CAPTURE");
      return {bytes, digest: hashBytes(bytes)};
    } catch (error) { if (error && error.code && error.code.startsWith("WG-L-E-")) throw error; fail("CAPTURE"); }
  }
  const st = assertShape(file, "file");
  if (!st) fail("CAPTURE");
  const bytes = readRegular(file, false, null);
  const again = lstat(file);
  if (!again || again.dev !== st.dev || again.ino !== st.ino || again.size !== st.size) fail("CAPTURE");
  return {bytes, digest: hashBytes(bytes)};
}
let cachedProjection = null;
function leaseProjection() {
  if (cachedProjection) return cachedProjection;
  const rawFd = process.env.FM_LEASE_PROJECTION_FD;
  const fd = Number(rawFd);
  if (!Number.isInteger(fd) || fd < 0) fail("SCHEMA");
  let bytes;
  try {
    const before = fs.fstatSync(fd);
    if (!before.isFile() || before.nlink !== 0) fail("SCHEMA");
    bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd);
    if (!after.isFile() || after.dev !== before.dev || after.ino !== before.ino || after.size !== before.size || after.nlink !== 0) fail("CAPTURE");
  } catch (error) {
    if (error && error.code && error.code.startsWith("WG-L-E-")) throw error;
    fail("CAPTURE");
  }
  if (process.env.FM_LEASE_PROJECTION_SHA256 !== hashBytes(bytes)) fail("CAPTURE");
  const value = strictObject(parseJson(bytes), ["schema_version", "goal_id", "slice_id", "graph_sha256", "contract_sha256", "registry_sha256", "registry", "resources"]);
  if (value.schema_version !== "workgraph-slice4-lease-projection/v1" || !safeId(value.goal_id) || !safeId(value.slice_id) || !HASH_RE.test(value.graph_sha256) || !HASH_RE.test(value.contract_sha256) || !HASH_RE.test(value.registry_sha256) || !value.registry || value.registry.schema_version !== "resource-registry/v1" || !Array.isArray(value.registry.instances) || !Array.isArray(value.resources) || value.resources.length === 0) fail("SCHEMA");
  value.resources.forEach((item) => {
    strictObject(item, ["resource", "mode", "lock_scopes"], "SCHEMA");
    if (typeof item.resource !== "string" || !/^[a-z][a-z0-9+.-]*:\/\/[^\u0000-\u001f\u007f-\u009f\s]+$/u.test(item.resource) || !["read", "write", "exclusive"].includes(item.mode) || !Array.isArray(item.lock_scopes) || item.lock_scopes.length === 0) fail("SCHEMA");
    item.lock_scopes.forEach((scope) => { if (scope !== "global://all" && (typeof scope !== "string" || !/^[a-z][a-z0-9+.-]*:\/\/[^\u0000-\u001f\u007f-\u009f\s]+$/u.test(scope))) fail("SCHEMA"); });
  });
  cachedProjection = value;
  return value;
}
function openBoundDirectory(dir, create = false) {
  const absolute = path.resolve(dir); const parsed = path.parse(absolute);
  let fd;
  try {
    fd = fs.openSync(parsed.root, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    let current = parsed.root;
    for (const part of absolute.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
      const childPath = `/proc/self/fd/${fd}/${part}`;
      let child;
      try {
        child = fs.openSync(childPath, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
      } catch (error) {
        if (!create || error.code !== "ENOENT") throw error;
        fs.mkdirSync(childPath, {mode: MOD_DIR});
        fs.fsyncSync(fd);
        child = fs.openSync(childPath, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
      }
      current = path.join(current, part);
      const childStat = fs.fstatSync(child);
      if (!childStat.isDirectory()) throw new Error("authority component is not a directory");
      const relativeToData = path.relative(D, current);
      const authorityPath = current === D || (relativeToData !== "" && relativeToData !== ".." && !relativeToData.startsWith(`..${path.sep}`) && !path.isAbsolute(relativeToData));
      if (authorityPath && childStat.uid !== process.getuid()) fail("NOT-RECONSTRUCTABLE");
      if (authorityPath && current !== D && (childStat.mode & 0o7777) !== MOD_DIR) fail("NOT-RECONSTRUCTABLE");
      fs.closeSync(fd); fd = child;
    }
    return fd;
  } catch (error) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
    if (error && error.code && error.code.startsWith("WG-L-E-")) throw error;
    fail("STORE");
  }
}
function mkdirSafe(dir) {
  const fd = openBoundDirectory(dir, true);
  try { fs.fsyncSync(fd); } catch { fail("IO"); } finally { try { fs.closeSync(fd); } catch { fail("IO"); } }
}
function mkdirCacheSafe(dir) {
  const fd = openBoundDirectory(dir, true);
  try { fs.fsyncSync(fd); } catch { fail("IO"); } finally { try { fs.closeSync(fd); } catch { fail("IO"); } }
}
function sameDirectoryIdentity(before, after) { return before && after && before.isDirectory() && after.isDirectory() && before.dev === after.dev && before.ino === after.ino && before.nlink === after.nlink && before.uid === after.uid && (before.mode & 0o7777) === (after.mode & 0o7777); }
function fsyncDir(dir) {
  let fd;
  try {
    fd = openBoundDirectory(dir, false);
    const before = fs.fstatSync(fd); const data = fs.statSync(D);
    if (!before.isDirectory() || before.dev !== data.dev) fail("IO");
    fs.fsyncSync(fd);
  } catch (error) {
    if (error && error.code && error.code.startsWith("WG-L-E-")) throw error;
    fail("IO");
  } finally { if (fd !== undefined) { try { fs.closeSync(fd); } catch { fail("IO"); } } }
}
let testPublicationOrdinal = 0;
function testPublicationCrash(ordinal, phase) {
  const spec = process.env.FM_LEASE_TEST_CRASH_PUBLICATION;
  const enabled = process.env.FM_WORKGRAPH_TEST_HOOKS;
  if (spec === undefined) return;
  if (enabled !== "1" || typeof spec !== "string" || !/^[1-9][0-9]*:(before-rename|after-rename-before-parent-fsync|after-parent-fsync-before-readback|after-readback)$/u.test(spec)) fail("STORE");
  if (spec === `${ordinal}:${phase}`) process.kill(process.pid, "SIGKILL");
}
function publish(file, bytes, immutable = false, cacheParent = false) {
  let parent; let base; let temp; let tempBase; let fd; let parentFd; let parentIdentity; let tempIdentity; let publishedByUs = false;
  const publicationOrdinal = ++testPublicationOrdinal;
  publicationPreparation = true;
  try {
    parent = path.dirname(file);
    if (cacheParent) mkdirCacheSafe(parent); else mkdirSafe(parent);
    parentFd = openBoundDirectory(parent, false);
    activeTempParentFd = parentFd; activeTempBase = null;
    parentIdentity = fs.fstatSync(parentFd, {bigint: true});
    if (!parentIdentity.isDirectory()) fail("IO");
    base = path.basename(file);
    const boundTarget = `/proc/self/fd/${parentFd}/${base}`;
    if (immutable) {
      const existing = (() => { try { return fs.lstatSync(boundTarget, {bigint: true}); } catch (error) { if (error.code === "ENOENT") return null; throw error; } })();
      if (existing) {
        if (!existing.isFile() || existing.nlink !== 1n || existing.dev !== parentIdentity.dev) fail("IO");
        const old = readRegular(boundTarget);
        if (!old.equals(bytes)) fail("IO");
        if (!clearActiveTemp()) fail("IO");
        parentFd = undefined;
        return;
      }
    }
    tempBase = `.${base}.tmp.${crypto.randomBytes(4).toString("base64url").replace(/[^A-Za-z0-9]/gu, "A").slice(0, 6).padEnd(6, "A")}`;
    temp = `/proc/self/fd/${parentFd}/${tempBase}`;
    activeTempBase = tempBase;
    fd = fs.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, MOD_FILE);
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
    tempIdentity = fs.fstatSync(fd, {bigint: true});
    if (!tempIdentity.isFile() || tempIdentity.nlink !== 1n || tempIdentity.dev !== parentIdentity.dev || tempIdentity.uid !== BigInt(process.getuid()) || (tempIdentity.mode & 0o7777n) !== 0o600n || tempIdentity.size !== BigInt(bytes.length)) fail("IO");
    fs.closeSync(fd); fd = undefined;
    testPublicationCrash(publicationOrdinal, "before-rename");
    if (immutable) {
      if (renameNoReplace(temp, file, parentFd, tempBase, base, true)) {
        publishedByUs = true;
        testPublicationCrash(publicationOrdinal, "after-rename-before-parent-fsync");
        fs.fsyncSync(parentFd);
        testPublicationCrash(publicationOrdinal, "after-parent-fsync-before-readback");
      } else {
        const existingStat = fs.lstatSync(boundTarget, {bigint: true});
        if (!existingStat.isFile() || existingStat.nlink !== 1n || existingStat.dev !== parentIdentity.dev) fail("IO");
        const existing = readRegular(boundTarget);
        fs.unlinkSync(`/proc/self/fd/${parentFd}/${tempBase}`);
        fs.fsyncSync(parentFd);
        if (!existing.equals(bytes)) fail("IO");
      }
    } else {
      renameNoReplace(temp, file, parentFd, tempBase, base, false); publishedByUs = true;
      testPublicationCrash(publicationOrdinal, "after-rename-before-parent-fsync");
      fs.fsyncSync(parentFd);
      testPublicationCrash(publicationOrdinal, "after-parent-fsync-before-readback");
    }
    let readback;
    try { readback = readRegular(`/proc/self/fd/${parentFd}/${base}`, false, MOD_FILE, "IO"); } catch { fail("IO"); }
    if (!readback.equals(bytes)) fail("IO");
    testPublicationCrash(publicationOrdinal, "after-readback");
    if (publishedByUs) {
      const publishedStat = fs.lstatSync(boundTarget, {bigint: true});
      if (!publishedStat.isFile() || publishedStat.dev !== tempIdentity.dev || publishedStat.ino !== tempIdentity.ino || publishedStat.mode !== tempIdentity.mode || publishedStat.uid !== tempIdentity.uid || publishedStat.nlink !== 1n) fail("IO");
    }
    if (immutable && publishedByUs) {
      const st = lstat(boundTarget); if (!st || st.nlink !== 1) fail("IO");
    }
    if (!clearActiveTemp()) fail("IO");
    parentFd = undefined;
  } catch (error) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
    if (error && error.code && error.code.startsWith("WG-L-E-")) throw error;
    fail("IO");
  } finally {
    if (parentFd !== undefined) { try { fs.closeSync(parentFd); } catch { fail("IO"); } }
    publicationPreparation = false;
  }
}
function ensureStore() {
  mkdirSafe(D); mkdirSafe(path.join(D, "workgraphs")); mkdirSafe(path.join(D, "workgraphs", ".leases")); mkdirSafe(STORE);
  const nsPath = path.join(STORE, "namespace.json");
  if (!lstat(nsPath)) {
    const namespace_id = hashBytes(Buffer.from(`firstmate-workgraph-lease-namespace/v1\n${D}\n`, "utf8"));
    publish(nsPath, Buffer.from(canonical({schema_version: "lease-namespace/v1", namespace_id, goal_scope: "all-goals", counter_floor: "0"})), true);
    publish(path.join(STORE, "fencing-counter"), Buffer.from("0\n"), true);
    publish(path.join(STORE, "transaction-generation"), Buffer.from("0\n"), true);
  }
}
function authorityBoundary() {
  const absoluteD = path.resolve(D); const parts = absoluteD.slice(path.parse(absoluteD).root.length).split(path.sep).filter(Boolean); let current = path.parse(absoluteD).root; let dataStat = null;
  for (const part of parts) {
    current = path.join(current, part);
    const st = lstat(current);
    if (!st) return {absent: true};
    if (st.isSymbolicLink() || !st.isDirectory()) fail("STORE");
    if (current === absoluteD) { if (st.uid !== process.getuid()) fail("STORE"); dataStat = st; }
  }
  let authority = absoluteD;
  for (const part of ["workgraphs", ".leases", "v1"]) {
    authority = path.join(authority, part);
    const st = lstat(authority);
    if (!st) return {absent: true, data: dataStat};
    if (st.isSymbolicLink() || !st.isDirectory() || st.uid !== process.getuid() ||
        (part !== "workgraphs" && (st.mode & 0o7777) !== MOD_DIR) || st.dev !== dataStat.dev) fail("STORE");
  }
  const lockPath = path.join(authority, ".transaction-lock"); const lock = lstat(lockPath); if (lock && (lock.isSymbolicLink() || !lock.isFile() || lock.nlink !== 1 || lock.uid !== process.getuid() || (lock.mode & 0o7777) !== MOD_FILE || lock.dev !== dataStat.dev)) fail("STORE");
  return {absent: false, data: dataStat, store: lstat(authority)};
}
function boundAuthorityRead(storePath, expectedRoot) {
  const flags = fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW;
  const entries = [];
  let authorityDevice = null;
  const same = (left, right) => left.dev === right.dev && left.ino === right.ino && left.mode === right.mode &&
    left.uid === right.uid && left.gid === right.gid && left.nlink === right.nlink && left.size === right.size &&
    left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
  const openEntry = (parentFd, lexical, component, authority = false) => {
    const pathForOpen = parentFd === null ? lexical : "/proc/self/fd/" + parentFd + "/" + component;
    let before;
    try { before = fs.lstatSync(lexical, {bigint: true}); } catch { fail("NOT-RECONSTRUCTABLE"); }
    let fd;
    try { fd = fs.openSync(pathForOpen, flags); } catch { fail("NOT-RECONSTRUCTABLE"); }
    let opened;
    let openedShape;
    let after;
    try { opened = fs.fstatSync(fd, {bigint: true}); openedShape = fs.fstatSync(fd, {bigint: false}); after = fs.lstatSync(lexical, {bigint: true}); } catch { try { fs.closeSync(fd); } catch {} fail("NOT-RECONSTRUCTABLE"); }
    if (!openedShape.isDirectory() || openedShape.uid !== process.getuid() || opened.nlink < 2n ||
        (authority && (opened.mode & 0o7777n) !== BigInt(MOD_DIR)) ||
        (authorityDevice !== null && opened.dev !== authorityDevice)) { try { fs.closeSync(fd); } catch {} fail("NOT-RECONSTRUCTABLE"); }
    if (!same(before, opened) || !same(opened, after)) { try { fs.closeSync(fd); } catch {} fail("NOT-RECONSTRUCTABLE"); }
    entries.push({fd, lexical});
    return fd;
  };
  const close = () => { for (const entry of entries.slice().reverse()) { try { fs.closeSync(entry.fd); } catch { fail("STORE"); } } };
  const verify = () => {
    try {
      for (const entry of entries) {
        const lexical = fs.lstatSync(entry.lexical, {bigint: true});
        const bound = fs.fstatSync(entry.fd, {bigint: true});
        if (!same(lexical, bound)) fail("NOT-RECONSTRUCTABLE");
      }
    } catch (error) {
      if (error && typeof error.message === "string" && error.message.includes("WG-L-E-")) throw error;
      fail("NOT-RECONSTRUCTABLE");
    }
  };
  const dataFd = openEntry(null, path.resolve(D), null);
  authorityDevice = fs.fstatSync(dataFd, {bigint: true}).dev;
  const workgraphsFd = openEntry(dataFd, path.join(D, "workgraphs"), "workgraphs", false);
  const leasesFd = openEntry(workgraphsFd, path.join(D, "workgraphs", ".leases"), ".leases", true);
  const storeFd = openEntry(leasesFd, storePath, "v1", true);
  if (!same(expectedRoot, fs.fstatSync(storeFd, {bigint: false}))) { close(); fail("NOT-RECONSTRUCTABLE"); }
  const optional = (name) => {
    const lexical = path.join(storePath, name);
    let st;
    try { st = fs.lstatSync(lexical, {bigint: true}); } catch (error) { if (error.code === "ENOENT") return null; close(); fail("NOT-RECONSTRUCTABLE"); }
    if (!st.isDirectory()) { close(); fail("NOT-RECONSTRUCTABLE"); }
    return openEntry(storeFd, lexical, name, true);
  };
  const recordsFd = optional("records");
  const eventsFd = optional("events");
  return {
    storePath: "/proc/self/fd/" + storeFd,
    storeFd,
    recordsFd,
    recordsPath: recordsFd === null ? null : "/proc/self/fd/" + recordsFd,
    eventsFd,
    eventsPath: eventsFd === null ? null : "/proc/self/fd/" + eventsFd,
    openChild: (parentFd, lexical, component) => openEntry(parentFd, lexical, component, true),
    verify,
    close,
  };
}
function namespaceId(base = STORE) {
  const bytes = readRegular(path.join(base, "namespace.json"));
  const ns = strictObject(parseDurable(bytes), ["schema_version", "namespace_id", "goal_scope", "counter_floor"], "NOT-RECONSTRUCTABLE");
  if (ns.schema_version !== "lease-namespace/v1" || !HASH_RE.test(ns.namespace_id) || ns.goal_scope !== "all-goals" || ns.counter_floor !== "0") fail("NOT-RECONSTRUCTABLE");
  const expected = hashBytes(Buffer.from(`firstmate-workgraph-lease-namespace/v1\n${D}\n`, "utf8"));
  if (ns.namespace_id !== expected) fail("NOT-RECONSTRUCTABLE");
  return ns.namespace_id;
}
function identity(pid, strict = true) {
  if (!POS_DEC_RE.test(String(pid))) { if (strict) fail("IDENTITY"); return undefined; }
  const base = `/proc/${pid}`;
  let first, second;
  try {
    const targetCmdline = fs.readFileSync(`${base}/cmdline`);
    const targetStat = fs.readFileSync(`${base}/stat`, "utf8");
    let boot, hostname;
    try { boot = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8"); hostname = fs.readFileSync("/proc/sys/kernel/hostname", "utf8"); } catch { if (strict) fail("IDENTITY"); return undefined; }
    first = {cmdline: targetCmdline, stat: targetStat, boot, hostname};
    const targetCmdline2 = fs.readFileSync(`${base}/cmdline`);
    const targetStat2 = fs.readFileSync(`${base}/stat`, "utf8");
    let boot2, hostname2;
    try { boot2 = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8"); hostname2 = fs.readFileSync("/proc/sys/kernel/hostname", "utf8"); } catch { if (strict) fail("IDENTITY"); return undefined; }
    second = {cmdline: targetCmdline2, stat: targetStat2, boot: boot2, hostname: hostname2};
  } catch (error) {
    if (strict) fail("IDENTITY");
    return error && error.code === "ENOENT" ? null : undefined;
  }
  const cmdline = first.cmdline;
  const parseStartTicks = (stat) => {
    const end = stat.lastIndexOf(")");
    if (end < 0) return null;
    const fields = stat.slice(end + 2).split(/\s+/u);
    return fields[19] || null;
  };
  const startTicks = parseStartTicks(first.stat);
  const secondStartTicks = parseStartTicks(second.stat);
  const boot = first.boot.endsWith("\n") ? first.boot.slice(0, -1) : first.boot;
  const hostname = first.hostname.endsWith("\n") ? first.hostname.slice(0, -1) : first.hostname;
  const secondBoot = second.boot.endsWith("\n") ? second.boot.slice(0, -1) : second.boot;
  const secondHostname = second.hostname.endsWith("\n") ? second.hostname.slice(0, -1) : second.hostname;
  if (!cmdline.equals(second.cmdline) || startTicks !== secondStartTicks || boot !== secondBoot || hostname !== secondHostname) { if (strict) fail("IDENTITY"); return undefined; }
  if (!POS_DEC_RE.test(startTicks || "") || !BOOT_RE.test(boot) || !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/u.test(hostname) || cmdline.length === 0) { if (strict) fail("IDENTITY"); return undefined; }
  return {pid: String(pid), start_ticks: startTicks, cmdline_sha256: hashBytes(cmdline), boot_id: boot, hostname};
}
function identityProof(old) {
  if (!old || !old.pid) return null;
  let now;
  now = identity(old.pid, false); if (now === null) return "pid-absent"; if (now === undefined) return null;
  if (now.hostname !== old.hostname) return null;
  if (now.boot_id !== old.boot_id) return "boot-changed";
  if (now.start_ticks !== old.start_ticks || now.cmdline_sha256 !== old.cmdline_sha256) return "pid-identity-mismatch";
  return "live";
}
function stableOwnerIdentity() {
  return identity(process.pid, true);
}
function sameOwnerIdentity(left, right) {
  return left !== null && right !== null && left !== undefined && right !== undefined &&
    left.pid === right.pid && left.start_ticks === right.start_ticks &&
    left.cmdline_sha256 === right.cmdline_sha256 && left.boot_id === right.boot_id &&
    left.hostname === right.hostname;
}
function leaseModel() {
  const projection = leaseProjection();
  return {
    graph: {goal_id: projection.goal_id},
    graphCap: {digest: projection.graph_sha256},
    contract: {},
    contractCap: {digest: projection.contract_sha256},
    registry: {digest: projection.registry_sha256, value: projection.registry},
    resources: projection.resources,
    selfConflict: false,
    goalId: projection.goal_id,
    sliceId: projection.slice_id,
    graphFile: "",
  };
}
function canonicalProjectionResource(value) {
  if (typeof value !== "string") throw new Error();
  const helperFd = Number(process.env.FM_LEASE_HELPER_FD);
  const bashFd = Number(process.env.FM_LEASE_BASH_FD);
  if (!Number.isInteger(helperFd) || helperFd < 0 || !Number.isInteger(bashFd) || bashFd < 0) throw new Error();
  const result = child.spawnSync(`/proc/self/fd/${bashFd}`, ["/proc/self/fd/3", "__lease-normalize"], {input: canonical({value}), encoding: "utf8", stdio: ["pipe", "pipe", "pipe", helperFd, bashFd]});
  if (result.error || result.status !== 0 || !result.stdout.endsWith("\n")) throw new Error();
  return result.stdout.slice(0, -1);
}
function exactLeaseOverlap(left, right, registry) {
  const helperFd = Number(process.env.FM_LEASE_HELPER_FD);
  const bashFd = Number(process.env.FM_LEASE_BASH_FD);
  if (!Number.isInteger(helperFd) || helperFd < 0 || !Number.isInteger(bashFd) || bashFd < 0) fail("STORE");
  const result = child.spawnSync(`/proc/self/fd/${bashFd}`, ["/proc/self/fd/3", "__lease-overlap"], {
    input: canonical({registry, left_scopes: left.lock_scopes, right_scopes: right.lock_scopes}),
    encoding: "utf8",
    stdio: ["pipe", "pipe", "pipe", helperFd, bashFd],
  });
  if (result.error || result.status !== 0 || !/^(true|false)\n$/u.test(result.stdout)) fail("STORE");
  return result.stdout === "true\n";
}
const AUTHORITY_TMP_RE = /^\..+\.tmp\.[A-Za-z0-9]{6}$/u;
function validateAuthorityTemp(parent, name, device) {
  if (!AUTHORITY_TMP_RE.test(name)) return false;
  const st = lstat(path.join(parent, name));
  if (!st || !st.isFile() || st.isSymbolicLink() || st.uid !== process.getuid() ||
      st.nlink !== 1 || (st.mode & 0o7777) !== MOD_FILE || st.dev !== device) {
    fail("NOT-RECONSTRUCTABLE");
  }
  return true;
}
function stageOwnerGenerationSchema(base = STORE) {
  const bytes = readRegular(path.join(base, "transaction-owner.json"), true);
  if (!bytes) return;
  try {
    const text = new TextDecoder("utf-8", {fatal: true}).decode(bytes);
    if (!text.endsWith("\n") || text.endsWith("\n\n")) return;
    const owner = JSON.parse(text.slice(0, -1));
    if (owner && typeof owner === "object" && !Array.isArray(owner) && owner.schema_version === "lease-transaction-owner/v1" && owner.generation === "0") fail("SCHEMA");
  } catch {}
}
function validateRecord(record) {
  strictObject(record, ["schema_version", "namespace_id", "goal_id", "slice_id", "lease_id", "graph_sha256", "contract_sha256", "registry_sha256", "state", "revision", "holder_id", "holder_process", "transaction_generation", "holder_fencing_token", "current_fencing_token", "resources", "terminal"], "NOT-RECONSTRUCTABLE");
  if (record.schema_version !== "workgraph-lease/v1" || !HASH_RE.test(record.namespace_id) || !safeId(record.goal_id) || !safeId(record.slice_id) || !safeId(record.lease_id) || !HASH_RE.test(record.graph_sha256) || !HASH_RE.test(record.contract_sha256) || !HASH_RE.test(record.registry_sha256) || !["held", "released", "recovered"].includes(record.state) || !["1", "2"].includes(record.revision) || !safeId(record.holder_id)) fail("NOT-RECONSTRUCTABLE");
  strictObject(record.holder_process, ["pid", "start_ticks", "cmdline_sha256", "boot_id", "hostname"], "NOT-RECONSTRUCTABLE"); if (!POS_DEC_RE.test(record.holder_process.pid) || !POS_DEC_RE.test(record.holder_process.start_ticks) || !HASH_RE.test(record.holder_process.cmdline_sha256) || !BOOT_RE.test(record.holder_process.boot_id) || !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/u.test(record.holder_process.hostname)) fail("NOT-RECONSTRUCTABLE");
  durableBig(record.transaction_generation, true); const holder = durableBig(record.holder_fencing_token, true); const current = durableBig(record.current_fencing_token, true); if (!Array.isArray(record.resources) || record.resources.length < 1 || record.resources.length > 256) fail("NOT-RECONSTRUCTABLE");
  let previous = ""; const seen = new Set(); record.resources.forEach((r) => { strictObject(r, ["resource", "mode", "lock_scopes"], "NOT-RECONSTRUCTABLE"); let canonicalResource; try { canonicalResource = canonicalProjectionResource(r.resource); } catch { fail("NOT-RECONSTRUCTABLE"); } if (canonicalResource !== r.resource || !["read", "write", "exclusive"].includes(r.mode) || !Array.isArray(r.lock_scopes) || r.lock_scopes.length < 1 || r.lock_scopes.length > 256 || seen.has(r.resource) || (previous && compareText(previous, r.resource) >= 0)) fail("NOT-RECONSTRUCTABLE"); previous = canonicalResource; seen.add(r.resource); let last = ""; const scopeSeen = new Set(); r.lock_scopes.forEach((s) => { let validScope = s === "global://all"; if (!validScope) { try { validScope = canonicalProjectionResource(s) === s; } catch { validScope = false; } } if (!validScope || scopeSeen.has(s) || (last && compareText(last, s) >= 0)) fail("NOT-RECONSTRUCTABLE"); last = s; scopeSeen.add(s); }); if (r.lock_scopes.includes("global://all")) { if (r.lock_scopes.length !== 1) fail("NOT-RECONSTRUCTABLE"); } else if (!r.lock_scopes.includes(r.resource)) fail("NOT-RECONSTRUCTABLE"); });
  strictObject(record.terminal, ["kind", "actor_id", "proof"], "NOT-RECONSTRUCTABLE"); if (record.state === "held" && (record.revision !== "1" || record.terminal.kind !== "none" || record.terminal.actor_id !== "" || record.terminal.proof !== "" || holder !== current)) fail("NOT-RECONSTRUCTABLE");
  if (record.state === "released" && (record.revision !== "2" || record.terminal.kind !== "release" || record.terminal.actor_id !== record.holder_id || record.terminal.proof !== "holder-release" || current <= holder)) fail("NOT-RECONSTRUCTABLE");
  if (record.state === "recovered" && (record.revision !== "2" || record.terminal.kind !== "recover" || !safeId(record.terminal.actor_id) || record.terminal.actor_id === "" || !["pid-absent", "pid-identity-mismatch", "boot-changed"].includes(record.terminal.proof) || current <= holder)) fail("NOT-RECONSTRUCTABLE");
  return record;
}
function validateEvent(event) {
  strictObject(event, ["schema_version", "event", "namespace_id", "goal_id", "slice_id", "lease_id", "holder_id", "transaction_generation", "fencing_token", "record_revision", "proof", "record_sha256"], "NOT-RECONSTRUCTABLE");
  if (event.schema_version !== "lease-event/v1" || !["acquire", "release", "recover"].includes(event.event) || !HASH_RE.test(event.namespace_id) || !safeId(event.goal_id) || !safeId(event.slice_id) || !safeId(event.lease_id) || !safeId(event.holder_id) || !["1", "2"].includes(event.record_revision) || !["", "holder-release", "pid-absent", "pid-identity-mismatch", "boot-changed"].includes(event.proof) || !HASH_RE.test(event.record_sha256)) fail("NOT-RECONSTRUCTABLE"); durableBig(event.transaction_generation, true); durableBig(event.fencing_token, true);
  if ((event.event === "acquire" && (event.record_revision !== "1" || event.proof !== "")) || (event.event === "release" && (event.record_revision !== "2" || event.proof !== "holder-release")) || (event.event === "recover" && (event.record_revision !== "2" || !["pid-absent", "pid-identity-mismatch", "boot-changed"].includes(event.proof)))) fail("NOT-RECONSTRUCTABLE");
  return event;
}
function sameValue(left, right) { return canonical(left) === canonical(right); }
function linuxDevice(stDev) {
  const dev = BigInt(stDev);
  const major = ((dev >> 8n) & 0xfffn) | ((dev >> 32n) & 0xfffff000n);
  const minor = (dev & 0xffn) | ((dev >> 12n) & 0xffffff00n);
  return `${major.toString(16).padStart(2, "0")}:${minor.toString(16).padStart(2, "0")}`;
}
function unlockInherited(fd) {
  const pythonFd = Number(process.env.FM_LEASE_PYTHON_FD);
  if (!Number.isInteger(pythonFd) || pythonFd < 0) fail("IO");
  const unlocked = child.spawnSync(`/proc/self/fd/${pythonFd}`, ["-c", "import fcntl; fcntl.flock(3, fcntl.LOCK_UN)"], {stdio: ["ignore", "ignore", "pipe", fd, "ignore", pythonFd]});
  if (unlocked.status !== 0) fail("IO");
  try { fs.closeSync(fd); } catch { fail("IO"); }
}
function renameNoReplace(from, to, parentFd = undefined, fromBase = undefined, toBase = undefined, noReplace = true) {
  const script = "import ctypes,ctypes.util,os,sys; libc=ctypes.CDLL(ctypes.util.find_library('c'),use_errno=True); fn=getattr(libc,'renameat2',None); sys.exit(38) if fn is None else None; fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]; fn.restype=ctypes.c_int; d=int(sys.argv[1]); old=os.fsencode(sys.argv[2]); new=os.fsencode(sys.argv[3]); flags=int(sys.argv[4]); r=fn(ctypes.c_int(3 if d >= 0 else -100),old,ctypes.c_int(3 if d >= 0 else -100),new,ctypes.c_uint(flags)); sys.exit(0 if r == 0 else ctypes.get_errno())";
  const bound = parentFd === undefined ? [-100, from, to, noReplace ? 1 : 0] : [parentFd, fromBase, toBase, noReplace ? 1 : 0];
  const pythonFd = Number(process.env.FM_LEASE_PYTHON_FD);
  if (!Number.isInteger(pythonFd) || pythonFd < 0) fail("IO");
  const stdio = parentFd === undefined ? ["pipe", "pipe", "pipe", "ignore", "ignore", pythonFd] : ["pipe", "pipe", "pipe", parentFd, "ignore", pythonFd];
  const result = child.spawnSync(`/proc/self/fd/${pythonFd}`, ["-c", script, ...bound.map(String)], {encoding: "utf8", stdio});
  if (result.error || result.status === null) fail("IO");
  if (result.status === 0) return true;
  if (result.status === 17) return false;
  fail("IO");
}
function loadStore() {
  const storePath = STORE;
  const boundary = authorityBoundary(); const root = lstat(storePath); if (boundary.absent || !root) return {absent: true, namespace: null, records: [], events: new Map(), counter: 0n, generation: 0n, cache: "absent"};
  const bound = boundAuthorityRead(storePath, root);
  const readStore = bound.storePath;
  if (!root.isDirectory() || root.uid !== process.getuid() || (root.mode & 0o7777) !== MOD_DIR || root.nlink < 2 || root.dev !== boundary.data.dev) fail("STORE"); const ns = lstat(path.join(readStore, "namespace.json"));
  stageOwnerGenerationSchema(readStore);
  const canonicalNames = new Set(["namespace.json", "fencing-counter", "transaction-generation", "transaction-owner.json", ".transaction-lock", "records", "events"]);
  for (const name of fs.readdirSync(readStore)) if (!canonicalNames.has(name) && !validateAuthorityTemp(readStore, name, boundary.data.dev)) fail("NOT-RECONSTRUCTABLE");
  const lockPath = path.join(readStore, ".transaction-lock"); const lock = lstat(lockPath); if (lock) { if (!lock.isFile() || lock.nlink !== 1 || lock.uid !== process.getuid() || (lock.mode & 0o7777) !== MOD_FILE || lock.dev !== boundary.data.dev) fail("STORE"); } else if (ns) fail("STORE");
  if (!ns) { const residual = fs.readdirSync(readStore).filter((name) => name !== ".transaction-lock" && !validateAuthorityTemp(readStore, name, boundary.data.dev)); if (residual.length) fail("NOT-RECONSTRUCTABLE"); const absent = {absent: true, namespace: null, records: [], events: new Map(), counter: 0n, generation: 0n, cache: "absent"}; bound.verify(); bound.close(); return absent; }
  const namespace = namespaceId(readStore); const records = []; const refs = new Set();
  if (bound.recordsFd !== null) {
    const recordsRoot = bound.recordsPath;
    for (const goal of fs.readdirSync(recordsRoot)) {
      if (!safeId(goal)) fail("NOT-RECONSTRUCTABLE");
      const goalLexical = path.join(storePath, "records", goal);
      const goalFd = bound.openChild(bound.recordsFd, goalLexical, goal);
      const gd = "/proc/self/fd/" + goalFd;
      for (const lease of fs.readdirSync(gd)) {
        if (!safeId(lease)) fail("NOT-RECONSTRUCTABLE");
        const leaseLexical = path.join(goalLexical, lease);
        const leaseFd = bound.openChild(goalFd, leaseLexical, lease);
        const ld = "/proc/self/fd/" + leaseFd;
        const one = path.join(ld, "1.json"), two = path.join(ld, "2.json");
        for (const name of fs.readdirSync(ld)) if (!["1.json", "2.json"].includes(name) && !validateAuthorityTemp(ld, name, boundary.data.dev)) fail("NOT-RECONSTRUCTABLE");
        const b1 = readRegular(one, true); const b2 = readRegular(two, true);
        if (!b1 && b2) fail("NOT-RECONSTRUCTABLE");
        if (b1) {
          const r1 = validateRecord(parseDurable(b1));
          if (r1.namespace_id !== namespace || r1.goal_id !== goal || r1.lease_id !== lease || r1.revision !== "1" || r1.state !== "held") fail("NOT-RECONSTRUCTABLE");
          records.push({record: r1, bytes: b1, path: one, digest: hashBytes(b1)}); refs.add(r1.transaction_generation);
          if (b2) {
            const r2 = validateRecord(parseDurable(b2));
            const immutable = ["namespace_id", "goal_id", "slice_id", "lease_id", "graph_sha256", "contract_sha256", "registry_sha256", "holder_id", "holder_process", "holder_fencing_token", "resources"];
            if (r2.namespace_id !== namespace || r2.goal_id !== goal || r2.lease_id !== lease || r2.slice_id !== r1.slice_id || r2.revision !== "2" || ["released", "recovered"].indexOf(r2.state) < 0 || immutable.some((key) => !sameValue(r1[key], r2[key])) || durableBig(r2.transaction_generation, true) <= durableBig(r1.transaction_generation, true) || durableBig(r2.current_fencing_token, true) <= durableBig(r2.holder_fencing_token, true)) fail("NOT-RECONSTRUCTABLE");
            records[records.length - 1].terminal = {record: r2, bytes: b2, path: two, digest: hashBytes(b2)}; refs.add(r2.transaction_generation);
          }
        }
      }
    }
  }
  const events = new Map();
  if (bound.eventsFd !== null) {
    const eventsRoot = bound.eventsPath;
    for (const name of fs.readdirSync(eventsRoot)) {
      if (!/^\d{20}\.json$/u.test(name) && !validateAuthorityTemp(eventsRoot, name, boundary.data.dev)) fail("NOT-RECONSTRUCTABLE");
      if (!/^\d{20}\.json$/u.test(name)) continue;
      const token = name.slice(0, -5); let n;
      try { n = BigInt(token); } catch { fail("NOT-RECONSTRUCTABLE"); }
      if (n < 1n || n > MAX) fail("NOT-RECONSTRUCTABLE");
      const eventPath = path.join(eventsRoot, name);
      const bytes = readRegular(eventPath);
      const event = validateEvent(parseDurable(bytes));
      if (event.fencing_token !== dec(n)) fail("NOT-RECONSTRUCTABLE");
      if (events.has(event.lease_id + ":" + event.record_revision)) fail("NOT-RECONSTRUCTABLE");
      events.set(event.lease_id + ":" + event.record_revision, {event, bytes, path: eventPath, digest: hashBytes(bytes), token: n}); refs.add(event.transaction_generation);
    }
  }
  const leaseOwners = new Map(); records.forEach((x) => { const prior = leaseOwners.get(x.record.lease_id); if (prior !== undefined && prior !== x.record.goal_id) fail("NOT-RECONSTRUCTABLE"); leaseOwners.set(x.record.lease_id, x.record.goal_id); });
  const recordByKey = new Map(records.map((x) => [`${x.record.lease_id}:1`, x])); records.forEach((x) => { if (x.terminal) recordByKey.set(`${x.record.lease_id}:2`, x.terminal); });
  for (const [key, e] of events) { const target = recordByKey.get(key); const expectedEvent = target && target.record.revision === "1" ? "acquire" : target && target.record.state === "released" ? "release" : target && target.record.state === "recovered" ? "recover" : null; const expectedProof = target && target.record.revision === "1" ? "" : target && target.record.terminal.proof; if (!target || !expectedEvent || e.event.namespace_id !== namespace || e.event.goal_id !== target.record.goal_id || e.event.slice_id !== target.record.slice_id || e.event.lease_id !== target.record.lease_id || e.event.holder_id !== target.record.holder_id || e.event.transaction_generation !== target.record.transaction_generation || e.event.event !== expectedEvent || e.event.proof !== expectedProof || e.event.record_sha256 !== target.digest || e.event.fencing_token !== (e.event.record_revision === "1" ? target.record.holder_fencing_token : target.record.current_fencing_token)) fail("NOT-RECONSTRUCTABLE"); }
  const generationOwners = new Map(); const tokenOwners = new Map(); const bindUnique = (map, value, ownerKey) => { const prior = map.get(value); if (prior && prior !== ownerKey) fail("NOT-RECONSTRUCTABLE"); map.set(value, ownerKey); };
  records.forEach((x) => { bindUnique(generationOwners, x.record.transaction_generation, `${x.record.lease_id}:1`); bindUnique(tokenOwners, x.record.holder_fencing_token, `${x.record.lease_id}:1`); if (x.terminal) { bindUnique(generationOwners, x.terminal.record.transaction_generation, `${x.terminal.record.lease_id}:2`); bindUnique(tokenOwners, x.terminal.record.current_fencing_token, `${x.terminal.record.lease_id}:2`); } });
  events.forEach((x) => { bindUnique(generationOwners, x.event.transaction_generation, `${x.event.lease_id}:${x.event.record_revision}`); bindUnique(tokenOwners, x.event.fencing_token, `${x.event.lease_id}:${x.event.record_revision}`); });
  for (const x of records) { if (x.record.state === "held" && !x.terminal && events.has(`${x.record.lease_id}:2`)) fail("NOT-RECONSTRUCTABLE"); const e1 = events.get(`${x.record.lease_id}:1`); if (x.terminal && !e1) fail("NOT-RECONSTRUCTABLE"); if (x.terminal && x.terminal.record.state === "recovered" && x.terminal.record.terminal.actor_id === "") fail("NOT-RECONSTRUCTABLE"); }
  let counter = 0n; const counterBytes = readRegular(path.join(readStore, "fencing-counter"), true); if (counterBytes) { const text = counterBytes.toString("utf8"); if (!DEC_RE.test(text.endsWith("\n") ? text.slice(0, -1) : "")) fail("NOT-RECONSTRUCTABLE"); const candidate = BigInt(text.slice(0, -1)); if (candidate > MAX) fail("NOT-RECONSTRUCTABLE"); counter = candidate; }
  let generation = 0n; let generationInvalid = false; const genBytes = readRegular(path.join(readStore, "transaction-generation"), true); if (genBytes) { const text = genBytes.toString("utf8"); const body = text.endsWith("\n") ? text.slice(0, -1) : null; if (body === null || !DEC_RE.test(body)) generationInvalid = true; else { try { const candidate = BigInt(body); if (candidate > MAX) generationInvalid = true; else generation = candidate; } catch { generationInvalid = true; } } }
  let owner = null; let ownerProof = null; const ownerBytes = readRegular(path.join(readStore, "transaction-owner.json"), true); if (ownerBytes) { owner = parseDurable(ownerBytes); strictObject(owner, ["schema_version", "namespace_id", "state", "generation", "pid", "start_ticks", "cmdline_sha256", "boot_id", "hostname"], "NOT-RECONSTRUCTABLE"); if (owner.generation === "0") fail("SCHEMA"); if (owner.schema_version !== "lease-transaction-owner/v1" || owner.namespace_id !== namespace || !["held", "released"].includes(owner.state) || !POS_DEC_RE.test(owner.generation) || !POS_DEC_RE.test(owner.pid) || !POS_DEC_RE.test(owner.start_ticks) || !HASH_RE.test(owner.cmdline_sha256) || !BOOT_RE.test(owner.boot_id) || !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/u.test(owner.hostname)) fail("NOT-RECONSTRUCTABLE"); if (generationInvalid) fail("NOT-RECONSTRUCTABLE"); ownerProof = owner.state === "held" ? identityProof(owner) : "released"; if (owner.state === "held" && (ownerProof === "live" || ownerProof === null)) fail("STORE"); const ownerGeneration = durableBig(owner.generation, true); if (ownerGeneration !== generation && (ownerGeneration > generation || [...refs].some((x) => durableBig(x, true) >= generation))) fail("NOT-RECONSTRUCTABLE"); }
  const refsBig = [...refs].map((x) => durableBig(x, true)); const maxRef = refsBig.reduce((a, b) => a > b ? a : b, 0n); if (generationInvalid && (owner || refsBig.length > 0)) fail("NOT-RECONSTRUCTABLE"); if (owner && owner.generation === "0") fail("NOT-RECONSTRUCTABLE"); if (!owner && generation > 0n && refsBig.some((x) => x === generation)) fail("NOT-RECONSTRUCTABLE"); if (maxRef > generation) fail("NOT-RECONSTRUCTABLE");
  const maxToken = [...records.flatMap((x) => [durableBig(x.record.current_fencing_token, true), ...(x.terminal ? [durableBig(x.terminal.record.current_fencing_token, true)] : [])]), ...[...events.values()].map((x) => durableBig(x.event.fencing_token, true))].reduce((a, b) => a > b ? a : b, 0n); if (counter < maxToken) counter = maxToken;
  bound.verify(); bound.close();
  return {absent: false, namespace, records, events, counter, generation, owner, cache: "ready"};
}
function beginTx(store, ownerProof) {
  if (typeof fs.statfsSync !== "function" || typeof fs.constants.O_NOFOLLOW !== "number") fail("STORE");
  let dataFs, storeFs;
  try { dataFs = fs.statfsSync(D).type; storeFs = fs.statfsSync(STORE).type; } catch { fail("STORE"); }
  let dataDev, storeDev;
  try { dataDev = fs.statSync(D).dev; storeDev = fs.statSync(STORE).dev; } catch { fail("STORE"); }
  if (!LOCAL_FS.has(Number(dataFs)) || Number(dataFs) !== Number(storeFs) || dataDev !== storeDev) fail("STORE");
  const lockPath = path.join(STORE, ".transaction-lock"); const st = assertShape(lockPath, "file", MOD_FILE, true, "STORE"); if (!st) fail("STORE");
  const inherited = Number(process.env.FM_LEASE_LOCK_FD || "");
  if (!Number.isInteger(inherited) || inherited < 0) { try { fs.closeSync(fd); } catch {} fail("STORE"); }
  try {
    const inheritedStat = fs.fstatSync(inherited);
    const inheritedPath = fs.readlinkSync(`/proc/self/fd/${inherited}`);
    const target = fs.lstatSync(lockPath);
    const lockIdentity = `${linuxDevice(target.dev)}:${target.ino}`;
    const lockHeld = fs.readFileSync("/proc/locks", "utf8").split("\n").some((line) => {
      const fields = line.trim().split(/\s+/u);
      return fields.length >= 6 && fields[1] === "FLOCK" && fields[2] === "ADVISORY" && fields[3] === "WRITE" && fields[4] === String(process.pid) && fields[5] === lockIdentity;
    });
    if (!inheritedStat.isFile() || inheritedStat.ino !== target.ino || inheritedStat.dev !== target.dev || inheritedStat.nlink !== 1 || (inheritedStat.mode & 0o7777) !== MOD_FILE || path.resolve(inheritedPath) !== path.resolve(lockPath) || !lockHeld) fail("STORE");
  } catch { fail("STORE"); }
  const holder = ownerProof;
  if (!holder) fail("STORE");
  const current = loadStore();
  const verifiedOwner = stableOwnerIdentity();
  if (!sameOwnerIdentity(holder, verifiedOwner)) fail("STORE");
  const next = current.generation + 1n;
  if (next > MAX) fail("OVERFLOW");
  publish(path.join(STORE, "transaction-generation"), Buffer.from(`${dec(next)}\n`));
  const owner = {schema_version: "lease-transaction-owner/v1", namespace_id: current.namespace, state: "held", generation: dec(next), pid: holder.pid, start_ticks: holder.start_ticks, cmdline_sha256: holder.cmdline_sha256, boot_id: holder.boot_id, hostname: holder.hostname}; publish(path.join(STORE, "transaction-owner.json"), Buffer.from(canonical(owner)));
  let ownerReleased = false; let unlocked = false;
  return {store: current, generation: next, owner, holder,
    releaseOwner() { if (!ownerReleased) { publish(path.join(STORE, "transaction-owner.json"), Buffer.from(canonical({...owner, state: "released"}))); ownerReleased = true; } },
    unlock() { if (!unlocked) { unlockInherited(inherited); unlocked = true; } },
    finish() { this.releaseOwner(); this.unlock(); }
  };
}
function eventBytes(type, record) { return Buffer.from(canonical({schema_version: "lease-event/v1", event: type, namespace_id: record.namespace_id, goal_id: record.goal_id, slice_id: record.slice_id, lease_id: record.lease_id, holder_id: record.holder_id, transaction_generation: record.transaction_generation, fencing_token: type === "acquire" ? record.holder_fencing_token : record.current_fencing_token, record_revision: record.revision, proof: record.terminal.proof, record_sha256: hashBytes(Buffer.from(canonical(record)))})); }
function publishEvent(type, record) { const token = type === "acquire" ? asBig(record.holder_fencing_token, true) : asBig(record.current_fencing_token, true); const file = path.join(STORE, "events", `${padToken(token)}.json`); if (lstat(file)) { const existing = readRegular(file); if (!existing.equals(eventBytes(type, record))) fail("IO"); return; } publish(file, eventBytes(type, record), true); }
function recordPath(goal, lease, revision) { return path.join(STORE, "records", goal, lease, `${revision}.json`); }
function makeResult(command, record, actor) { return Buffer.from(canonical({schema_version: "lease-command-result/v1", command, goal_id: record.goal_id, slice_id: record.slice_id, lease_id: record.lease_id, state: record.state, actor_id: actor, holder_fencing_token: record.holder_fencing_token, current_fencing_token: record.current_fencing_token, resource_count: String(record.resources.length)})); }
function cachePath(goal) { return path.join(S, "workgraphs", goal, "leases.v1.json"); }
function updateCache(goal, store) { const current = store.records.filter((x) => x.record.goal_id === goal).map((x) => x.terminal ? x.terminal.record : x.record).sort(compareRecords); const bytes = Buffer.from(canonical({schema_version: "lease-cache/v1", namespace_id: store.namespace, goal_id: goal, records: current})); publish(cachePath(goal), bytes, false, true); }
function openCacheParent(goal) {
  let fd;
  try {
    const parts = ["workgraphs", goal];
    const identities = [];
    fd = fs.openSync(path.resolve(S), fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    identities.push(fs.fstatSync(fd, {bigint: true}));
    for (const part of parts) {
      const child = fs.openSync(`/proc/self/fd/${fd}/${part}`, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
      const childStat = fs.fstatSync(child, {bigint: true});
      if (!childStat.isDirectory()) throw new Error("cache parent is not a directory");
      identities.push(childStat);
      fs.closeSync(fd); fd = child;
    }
    return {fd, identities};
  } catch { if (fd !== undefined) { try { fs.closeSync(fd); } catch {} } return null; }
}
function cachePathPresence(goal) {
  const root = path.resolve(S);
  try {
    const rootStat = fs.lstatSync(root, {bigint: true});
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) return "present";
  } catch (error) { if (error.code === "ENOENT") return "absent"; return "present"; }
  let current = root;
  for (const part of ["workgraphs", goal, "leases.v1.json"]) {
    current = path.join(current, part);
    try {
      const st = fs.lstatSync(current, {bigint: true});
      if (part !== "leases.v1.json" && (!st.isDirectory() || st.isSymbolicLink())) return "present";
    }
    catch (error) { if (error.code === "ENOENT") return "absent"; return "present"; }
  }
  return "present";
}
function cacheParentStillBound(goal, identities) {
  const paths = [path.resolve(S), path.join(path.resolve(S), "workgraphs"), path.join(path.resolve(S), "workgraphs", goal)];
  try {
    const current = paths.map((item) => fs.lstatSync(item, {bigint: true}));
    return current.every((item, index) => {
      const bound = identities[index];
      return item.isDirectory() && !item.isSymbolicLink() && bound.isDirectory() && item.dev === bound.dev && item.ino === bound.ino && item.mode === bound.mode && item.uid === bound.uid && item.gid === bound.gid && item.nlink === bound.nlink && item.mtimeNs === bound.mtimeNs && item.ctimeNs === bound.ctimeNs;
    });
  } catch { return false; }
}
function probeCache(file, expected) {
  let fd; let parentFd;
  try {
    const goal = path.basename(path.dirname(file));
    const parent = openCacheParent(goal);
    if (parent === null) return "reconstructed";
    parentFd = parent.fd;
    const boundFile = `/proc/self/fd/${parentFd}/leases.v1.json`;
    const st = fs.lstatSync(boundFile, {bigint: true});
    if (!st.isFile() || st.nlink !== 1n || (st.mode & 0o7777n) !== 0o600n || st.uid !== BigInt(process.getuid())) return "reconstructed";
    fd = fs.openSync(boundFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const before = fs.fstatSync(fd, {bigint: true});
    const bytes = fs.readFileSync(fd);
    const after = fs.fstatSync(fd, {bigint: true});
    const pathAfter = fs.lstatSync(boundFile, {bigint: true});
    const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.mode === b.mode && a.uid === b.uid && a.gid === b.gid && a.nlink === b.nlink && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
    return cacheParentStillBound(goal, parent.identities) && same(st, before) && same(before, after) && same(pathAfter, before) && bytes.equals(Buffer.from(expected)) ? "present" : "reconstructed";
  } catch { return "reconstructed"; }
  finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
    if (parentFd !== undefined) { try { fs.closeSync(parentFd); } catch {} }
  }
}
function probeCachePresence(file) {
  return cachePathPresence(path.basename(path.dirname(file)));
}
function finishResult(command, tx, record, actor) {
  const out = makeResult(command, record, actor);
  tx.releaseOwner();
  try { updateCache(record.goal_id, loadStore()); } catch { tx.unlock(); fail("IO"); }
  tx.unlock();
  process.stdout.write(out);
}

function argsFor(command) {
  const a = process.argv.slice(2); if (a[0] !== command) usage(); return a;
}
function flag(args, name) { const i = args.indexOf(name); if (i < 0 || i + 1 >= args.length || args[i + 1].startsWith("--")) return null; return args[i + 1]; }
function requireFlag(args, name) { const v = flag(args, name); if (v === null) usage(); return v; }
function valueFlags(args, start, names) {
  const allowed = new Set(names); const out = {};
  for (let i = start; i < args.length; i += 2) {
    const name = args[i]; if (!allowed.has(name) || Object.prototype.hasOwnProperty.call(out, name) || i + 1 >= args.length || args[i + 1].startsWith("--")) usage();
    out[name] = args[i + 1];
  }
  names.forEach((name) => { if (!Object.prototype.hasOwnProperty.call(out, name)) usage(); });
  return out;
}

const argv = process.argv.slice(2); const command = argv[0] || "";
if (!["status", "acquire", "release", "recover", "fence", "inspect"].includes(command)) usage();
if (command === "status") {
  if (argv.length !== 2 || !safeId(argv[1])) usage();
  const store = loadStore(); const goal = argv[1]; let cache = "absent";
  const cp = cachePath(goal); if (store.absent) cache = probeCachePresence(cp); else { const expected = canonical({schema_version: "lease-cache/v1", namespace_id: store.namespace, goal_id: goal, records: store.records.filter((x) => x.record.goal_id === goal).map((x) => x.terminal ? x.terminal.record : x.record).sort(compareRecords)}); cache = probeCache(cp, expected); }
  const active = store.records.filter((x) => x.record.goal_id === goal && !x.terminal).length; const terminal = store.records.filter((x) => x.record.goal_id === goal && x.terminal).length;
  process.stdout.write(`lease_store=${store.absent ? "absent" : "ready"}\nlease_cache=${cache}\nlease_active_count=${active}\nlease_terminal_count=${terminal}\nlease_fencing=${store.absent ? "unavailable" : "monotonic"}\nlease_enforcement=${store.absent ? "unavailable" : "available"}\n`); process.exit(0);
}
if (command === "acquire") {
  if (argv.length < 3) usage(); const graphFile = argv[1], slice = argv[2]; if (!slice || !safeId(slice)) usage(); const options = valueFlags(argv, 3, ["--registry", "--lease-id", "--holder-id", "--holder-pid"]); const registryFile = options["--registry"], leaseId = options["--lease-id"], holderId = options["--holder-id"], holderPid = options["--holder-pid"]; if (!safeId(leaseId) || !safeId(holderId)) fail("SCHEMA");
  const preStore = loadStore();
  if (preStore.records.some((x) => x.record.lease_id === leaseId)) fail("LEASE-ID-REUSED");
  if (process.env.FM_LEASE_DEFERRED_SELF === "1") fail("SELF");
  const model = leaseModel();
  if (model.selfConflict) fail("SELF");
  let hp;
  try { hp = JSON.parse(process.env.FM_LEASE_HOLDER_IDENTITY || ""); } catch { fail("IDENTITY"); }
  if (!hp || hp.pid !== String(holderPid) || !POS_DEC_RE.test(hp.pid) || !POS_DEC_RE.test(hp.start_ticks) || !HASH_RE.test(hp.cmdline_sha256) || !BOOT_RE.test(hp.boot_id) || !/^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/u.test(hp.hostname)) fail("IDENTITY");
  const held = preStore.records.filter((r) => !r.terminal);
  const registryDrift = held.some((x) => x.record.registry_sha256 !== model.registry.digest);
  if (registryDrift && held.some((x) => model.resources.some((c) => x.record.resources.some((old) => !(c.mode === "read" && old.mode === "read"))))) fail("CONFLICT");
  const overlapRegistry = model.registry.value;
  let liveConflict = false;
  let recoveryRequired = false;
  for (const x of held) for (const c of model.resources) for (const old of x.record.resources) {
    if (exactLeaseOverlap(c, old, overlapRegistry) && !(c.mode === "read" && old.mode === "read")) {
      const proof = identityProof(x.record.holder_process);
      if (["pid-absent", "pid-identity-mismatch", "boot-changed"].includes(proof)) recoveryRequired = true;
      else liveConflict = true;
    }
  }
  if (liveConflict) fail("CONFLICT");
  if (recoveryRequired) fail("RECOVERY-REQUIRED");
  if (preStore.generation >= MAX || preStore.counter >= MAX) fail("OVERFLOW");
  const ownerProof = stableOwnerIdentity(); if (!ownerProof) fail("STORE");
  const lockedStore = loadStore();
  if (lockedStore.records.some((x) => x.record.lease_id === leaseId)) fail("LEASE-ID-REUSED");
  const lockedHeld = lockedStore.records.filter((r) => !r.terminal);
  const lockedRegistryDrift = lockedHeld.some((x) => x.record.registry_sha256 !== model.registry.digest);
  if (lockedRegistryDrift && lockedHeld.some((x) => model.resources.some((c) => x.record.resources.some((old) => !(c.mode === "read" && old.mode === "read"))))) fail("CONFLICT");
  let lockedRecoveryRequired = false;
  for (const x of lockedHeld) for (const c of model.resources) for (const old of x.record.resources) {
    if (exactLeaseOverlap(c, old, overlapRegistry) && !(c.mode === "read" && old.mode === "read")) {
      const proof = identityProof(x.record.holder_process);
      if (["pid-absent", "pid-identity-mismatch", "boot-changed"].includes(proof)) lockedRecoveryRequired = true;
      else fail("CONFLICT");
    }
  }
  if (lockedRecoveryRequired) fail("RECOVERY-REQUIRED");
  ensureStore(); const tx = beginTx(lockedStore, ownerProof); const store = tx.store;
  const token = store.counter + 1n; if (token > MAX) { tx.finish(); fail("OVERFLOW"); }
  publish(path.join(STORE, "fencing-counter"), Buffer.from(`${dec(token)}\n`)); const record = {schema_version: "workgraph-lease/v1", namespace_id: store.namespace, goal_id: model.goalId, slice_id: model.sliceId, lease_id: leaseId, graph_sha256: model.graphCap.digest, contract_sha256: model.contractCap.digest, registry_sha256: model.registry.digest, state: "held", revision: "1", holder_id: holderId, holder_process: hp, transaction_generation: dec(tx.generation), holder_fencing_token: dec(token), current_fencing_token: dec(token), resources: model.resources, terminal: {kind: "none", actor_id: "", proof: ""}};
  const bytes = Buffer.from(canonical(record)); publish(recordPath(model.goalId, leaseId, 1), bytes, true); publishEvent("acquire", record); finishResult("acquire", tx, record, holderId); process.exit(0);
}
if (["release", "recover", "fence"].includes(command)) {
  if (argv.length < 2 || !safeId(argv[1])) usage(); const goal = argv[1]; const names = command === "recover" ? ["--lease-id", "--actor-id"] : ["--lease-id", "--holder-id", "--fencing-token"]; const options = valueFlags(argv, 2, names); const leaseId = options["--lease-id"]; if (!safeId(leaseId)) fail("SCHEMA"); const holderId = command === "release" || command === "fence" ? options["--holder-id"] : null; const actor = command === "recover" ? options["--actor-id"] : holderId; const tokenArg = command === "recover" ? null : options["--fencing-token"]; if (!safeId(actor)) fail("SCHEMA"); if (tokenArg !== null) asBig(tokenArg, true);
  const store = loadStore(); if (store.absent) fail("NOT-RECONSTRUCTABLE"); const item = store.records.find((x) => x.record.goal_id === goal && x.record.lease_id === leaseId); if (!item) fail("OWNER"); const current = item.terminal ? item.terminal.record : item.record;
  if (command === "fence") { if (current.holder_id !== holderId) fail("OWNER"); if (tokenArg !== current.current_fencing_token) fail("TOKEN"); if (current.state !== "held") fail("STATE"); process.stdout.write(makeResult("fence", current, holderId)); process.exit(0); }
  if (command === "release" && current.holder_id !== holderId) fail("OWNER");
  if (command === "release" && tokenArg !== current.holder_fencing_token) fail("TOKEN");
  if (command === "release" && current.state !== "held") { if (current.state === "released" && tokenArg === current.holder_fencing_token) { /* exact terminal retry continues through transaction lifecycle */ } else fail("STATE"); }
  if (command === "recover" && current.state !== "held") { if (current.state === "recovered" && current.terminal.actor_id === actor) { /* exact retry */ } else if (current.state === "recovered") fail("OWNER"); else fail("STATE"); }
  let recoveryProof = null;
  if (command === "recover" && current.state === "held") { recoveryProof = identityProof(current.holder_process); if (!recoveryProof || recoveryProof === "live") fail("UNPROVEN-DEATH"); }
  if (current.state === "held" && store.counter >= MAX) fail("OVERFLOW");
  const ownerProof = stableOwnerIdentity(); if (!ownerProof) fail("STORE");
  ensureStore(); const tx = beginTx(store, ownerProof); if (current.state !== "held") { if (!store.events.has(`${current.lease_id}:2`)) publishEvent(current.state === "released" ? "release" : "recover", current); finishResult(command, tx, current, actor); process.exit(0); }
  if (!store.events.has(`${current.lease_id}:1`)) publishEvent("acquire", current);
  const next = store.counter + 1n; if (next > MAX) { tx.finish(); fail("OVERFLOW"); } publish(path.join(STORE, "fencing-counter"), Buffer.from(`${dec(next)}\n`));
  const terminal = command === "release" ? {kind: "release", actor_id: holderId, proof: "holder-release"} : {kind: "recover", actor_id: actor, proof: recoveryProof};
  const record = {...current, state: command === "release" ? "released" : "recovered", revision: "2", transaction_generation: dec(tx.generation), current_fencing_token: dec(next), terminal}; const bytes = Buffer.from(canonical(record)); publish(recordPath(goal, leaseId, 2), bytes, true); publishEvent(command === "release" ? "release" : "recover", record); finishResult(command, tx, record, actor); process.exit(0);
}
if (command === "inspect") {
  if (argv.length < 2 || !safeId(argv[1])) usage(); const goal = argv[1]; let lease = null; let history = false;
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === "--history") { if (history) usage(); history = true; }
    else if (argv[i] === "--lease-id") { if (lease !== null || i + 1 >= argv.length || argv[i + 1].startsWith("--")) usage(); lease = argv[++i]; }
    else usage();
  }
  if (lease !== null && !safeId(lease)) fail("SCHEMA"); const store = loadStore(); if (store.absent) process.exit(0); const out = store.records.filter((x) => x.record.goal_id === goal && (!lease || x.record.lease_id === lease)).flatMap((x) => history && x.terminal ? [x.record, x.terminal.record] : [x.terminal ? x.terminal.record : x.record]).filter((r) => history || r.state === "held").sort(compareRecords); out.forEach((r) => process.stdout.write(canonical(r))); process.exit(0);
}
// NODE_SOURCE_END
NODE
