#!/usr/bin/env python3
"""Per-run Azure command-class routing for daemon-spawned no-mistakes steps.

WHY THIS EXISTS
---------------
`FM_AZURE_RUNNER_REMOTE_CLASSES` cannot select a class for one no-mistakes run.
The step that reads it is not a child of the operator's shell: it is a child of
the machine-global no-mistakes daemon, whose launchd job pins its environment to
`{HOME, PATH}`. Reading the live environment of a real run's step processes on
2026-08-21 showed the step's own shells carrying ZERO `FM_*` variables, so the
documented `export ... && no-mistakes axi run` recipe selects nothing. The only
environment that reaches such a step is a machine-global `launchctl setenv` plus
a daemon restart, which is an ambient global that outlives the intent AND a
restart of the daemon every other pipeline depends on.

This routing file replaces that with an ordinary per-run act: one file, keyed by
the run it applies to, that expires and carries a dispatch budget.

WHAT IT MUST CARRY, AND WHY EACH FIELD IS EXPLICIT
--------------------------------------------------
`fm_home` is declared, never inferred. `bin/fm-azure-runner.py` requires
`os.environ["FM_HOME"]` and it is where the runner's SPEND LEDGER lives, so a
guessed value does not merely fail: it silently writes cost accounting into a
second ledger and the real one under-reports.

`subscription` is likewise declared. Today the dispatch falls back to the
operator environment's `FM_AZURE_SUBSCRIPTION_ID`, which does not exist inside
the daemon. Requiring it here is not a workaround for that absence: it turns the
billable-compute confirmation from an ambient inheritance into an explicit
written act, which is what a confirmation should have been.

A selected remote command also needs the rest of the runner's landed Azure
configuration. The daemon does not inherit any of it, so resolution reads the
regular operator-owned `$HOME/.fm-azure/fleet.env` once, evaluates those exact
bytes, returns only the required values, and refuses unless its subscription
matches this document's explicit confirmation. An absent routing file never
reads that environment and stays visibly local.

THE LOOKUP PATH IS NEVER DERIVED FROM REPOSITORY CONTENT
---------------------------------------------------------
The routing directory is anchored on `$HOME` alone. It is never derived from the
repository, the checkout, the worktree, or the working directory, so a branch may
carry `.fm-azure/runner-routing/*.json` freely and nothing here will read it.
That invariant is the whole answer to "what stops a checkout carrying one", and
it is asserted by `tests/fm-azure-runner.test.sh` rather than left as a property
of today's code, because it is exactly what a later refactor breaks by accident.

FAIL-CLOSED ASYMMETRY
---------------------
ABSENT is safe and means local execution, exactly today's default; it is the
normal case, and it is what keeps the machine-global empty forever.
PRESENT-BUT-BROKEN is never safe. Unreadable, torn, malformed, wrong schema,
missing field, expired, budget-exhausted, wrong run, or an unusable `fm_home`
all REFUSE BY NAME and the command runs NOWHERE. A present file means the
operator intended remote; running local instead would be a silent fallback, and
a silent local fallback is indistinguishable from a real cell run.

Usage:
  fm-azure-runner-routing.py resolve --run-id <ulid> --class <command-class>

Exit codes:
  0  remote selected; KEY=VALUE bindings on stdout
  1  refusal; exact reason on stderr; the caller must execute NOWHERE
  2  usage error
  3  no routing file for this run; the caller executes LOCALLY
  4  a routing file exists but does not select this class; execute LOCALLY
"""

import argparse
import base64
import contextlib
import datetime as dt
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

SCHEMA = "fm.azure-runner-routing/v1"
RUN_ID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
COMMAND_CLASS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
SUBSCRIPTION = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
REQUIRED = ("schema", "run_id", "classes", "fm_home", "subscription", "expires_at", "max_dispatches")
ALLOWED = frozenset(REQUIRED) | {"dispatched"}
EXACT_UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
OPERATOR_ENVIRONMENT_NAMES = (
    "FM_AZURE_TENANT_ID",
    "FM_AZURE_SUBSCRIPTION_ID",
    "FM_AZURE_NAMING_PREFIX",
    "FM_AZURE_STORAGE_NAME",
    "FM_AZURE_OWNER_TAG",
    "FM_AZURE_DEPLOYMENT_GENERATION",
    "FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID",
)
ALLOWED_OPERATOR_ENVIRONMENT_NAMES = frozenset(OPERATOR_ENVIRONMENT_NAMES) | {
    "FM_AZURE_OPERATOR_DATA_PLANE_IP",
    "FM_AZURE_RESOURCE_GROUP",
    "FM_AZURE_RUNNER_BUDGET_LIMIT_USD",
    "FM_AZURE_RUNNER_CELL_ORDINAL",
    "FM_AZURE_RUNNER_COST_ADMISSION_MODE",
    "FM_AZURE_RUNNER_MAX_CONCURRENCY",
    "FM_AZURE_RUNNER_SKU",
    "FM_AZURE_VM_IMAGE_ID",
    "FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST",
}
FORBIDDEN_OPERATOR_ENVIRONMENT_NAMES = frozenset(
    {
        "FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION",
        "FM_AZURE_RUNNER_GENERATION",
        "FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES",
        "FM_AZURE_RUNNER_REMOTE_CLASSES",
        "FM_AZURE_RUNNER_ROUTING_ROOT",
        "FM_AZURE_RUNNER_TASK",
    }
)
OPERATOR_ENVIRONMENT_NAME = re.compile(r"^FM_AZURE_[A-Z0-9_]+$")
MAX_OPERATOR_ENVIRONMENT_BYTES = 64 * 1024
MAX_ROUTING_DOCUMENT_BYTES = 64 * 1024

EXIT_SELECTED = 0
EXIT_REFUSED = 1
EXIT_USAGE = 2
EXIT_ABSENT = 3
EXIT_NOT_SELECTED = 4


def refuse(message):
    """Every refusal names what is wrong. The caller then runs NOWHERE."""
    print("azure-runner routing: " + message, file=sys.stderr)
    raise SystemExit(EXIT_REFUSED)


def routing_location():
    """Return the routing directory and its lexical authority anchor.

    The production path is anchored at the invoking user's absolute HOME, so
    every lexical path component from HOME through the routing file can be
    checked without resolving through a checkout-carried symlink. The explicit
    root override exists for hermetic tests and is its own authority anchor.

    Returns (None, None) when no routing file can exist at all, which is an
    ABSENCE (execute locally), not a corruption.
    """
    override = os.environ.get("FM_AZURE_RUNNER_ROUTING_ROOT")
    if override:
        root = Path(override)
        if not root.is_absolute():
            refuse("FM_AZURE_RUNNER_ROUTING_ROOT is not an absolute path")
        return root, root
    home = os.environ.get("HOME")
    if not home:
        return None, None
    anchor = Path(home)
    if not anchor.is_absolute():
        refuse("HOME is not an absolute path, so routing cannot be anchored outside the checkout")
    return anchor / ".fm-azure" / "runner-routing", anchor


def check_provenance(path, anchor):
    """The file and every lexical directory through the anchor must be ours.

    A routing file authorizes billable compute, so it is held to the same
    standard as credential material: no symlink anywhere on the path, owned by
    the invoking user, and never group- or world-writable.
    """
    if not path.is_absolute() or not anchor.is_absolute():
        refuse("routing provenance paths must be absolute")
    if ".." in path.parts or ".." in anchor.parts:
        refuse("routing provenance paths may not contain parent traversal")
    try:
        path.relative_to(anchor)
    except ValueError:
        refuse("routing path {} escapes its authority anchor {}".format(path, anchor))
    checked = [path]
    current = path
    while current != anchor:
        current = current.parent
        checked.append(current)
        if current.parent == current and current != anchor:
            refuse("routing path {} never reaches its authority anchor {}".format(path, anchor))
        if len(checked) > 64:
            refuse("routing path is implausibly deep: {}".format(path))
        if current == anchor:
            break
    for item in checked:
        try:
            info = item.lstat()
        except OSError as exc:
            refuse("routing path component {} is unreadable: {}".format(item, exc.strerror))
        if stat.S_ISLNK(info.st_mode):
            refuse("routing path component {} is a symlink".format(item))
        if info.st_uid != os.geteuid():
            refuse(
                "routing path component {} is owned by uid {}, not the invoking uid {}".format(
                    item, info.st_uid, os.geteuid()
                )
            )
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            refuse("routing path component {} is group- or world-writable".format(item))


@contextlib.contextmanager
def routing_lock(path):
    """Serialize consumers on a stable sibling inode.

    The routing document is atomically replaced after every dispatch. Locking
    that replaceable inode lets a parallel resolver open either the old or new
    inode and spend the same final slot. The sibling lock is never replaced, so
    every resolver rereads and consumes under one durable authority.
    """
    lock_path = path.with_name(path.name + ".lock")
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        handle = os.open(str(lock_path), flags, 0o600)
    except OSError as exc:
        refuse("routing lock {} could not be opened: {}".format(lock_path, exc.strerror))
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode):
            refuse("routing lock {} is not a regular file".format(lock_path))
        if info.st_uid != os.geteuid():
            refuse(
                "routing lock {} is owned by uid {}, not the invoking uid {}".format(
                    lock_path, info.st_uid, os.geteuid()
                )
            )
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            refuse("routing lock {} is group- or world-writable".format(lock_path))
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
        except OSError as exc:
            refuse("routing lock {} could not be acquired: {}".format(lock_path, exc.strerror))
        yield
    finally:
        os.close(handle)


def operator_environment_values(expected_subscription=None):
    """Return exact values from one validated read of the operator environment.

    The daemon step inherits only HOME and PATH. A routing selection therefore
    cannot reach even the runner's read-only preparation gates unless it
    explicitly rehydrates the landed Azure configuration from this HOME-owned
    file. Reading its bytes here and evaluating those exact bytes removes the
    check-then-source pathname race; the caller receives values, never a path.
    """
    home = os.environ.get("HOME")
    if not home:
        refuse("HOME is absent, so the operator Azure environment cannot be located")
    anchor = Path(home)
    if not anchor.is_absolute():
        refuse("HOME is not absolute, so the operator Azure environment cannot be trusted")
    path = anchor / ".fm-azure" / "fleet.env"
    try:
        before = path.lstat()
    except OSError as exc:
        refuse("operator Azure environment file {} is unreadable: {}".format(path, exc.strerror))
    check_provenance(path, anchor)
    if not stat.S_ISREG(before.st_mode):
        refuse("operator Azure environment file {} is not a regular file".format(path))
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        handle = os.open(str(path), flags)
    except OSError as exc:
        refuse("operator Azure environment file {} could not be opened: {}".format(path, exc.strerror))
    try:
        opened = os.fstat(handle)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            refuse("operator Azure environment file {} changed while it was opened".format(path))
        if not stat.S_ISREG(opened.st_mode):
            refuse("operator Azure environment file {} is not a regular file".format(path))
        if opened.st_uid != os.geteuid():
            refuse("operator Azure environment file {} is not owned by the invoking uid".format(path))
        if opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            refuse("operator Azure environment file {} is group- or world-writable".format(path))
        chunks = []
        remaining = MAX_OPERATOR_ENVIRONMENT_BYTES + 1
        while remaining:
            chunk = os.read(handle, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
    except OSError as exc:
        refuse("operator Azure environment file {} could not be read: {}".format(path, exc.strerror))
    finally:
        os.close(handle)
    if len(raw) > MAX_OPERATOR_ENVIRONMENT_BYTES:
        refuse(
            "operator Azure environment file {} exceeds the {}-byte bound".format(
                path, MAX_OPERATOR_ENVIRONMENT_BYTES
            )
        )
    if b"\0" in raw:
        refuse("operator Azure environment file {} contains a NUL byte".format(path))

    script = r"""
set -e
for name in "$@"; do unset "$name"; done
set -a
. /dev/stdin >/dev/null
set +a
/usr/bin/env -0
"""
    try:
        evaluated = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script, "fleet.env"]
            + list(OPERATOR_ENVIRONMENT_NAMES),
            input=raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
            env={
                "HOME": home,
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "LC_ALL": "C",
            },
        )
    except (OSError, subprocess.TimeoutExpired):
        refuse("operator Azure environment file {} could not be evaluated exactly".format(path))
    if evaluated.returncode != 0:
        refuse("operator Azure environment file {} could not be evaluated exactly".format(path))
    values = {}
    try:
        for field in evaluated.stdout.split(b"\0"):
            if not field:
                continue
            encoded_name, separator, encoded_value = field.partition(b"=")
            if not separator:
                refuse("operator Azure environment file {} returned a malformed value".format(path))
            name = encoded_name.decode("ascii")
            if not OPERATOR_ENVIRONMENT_NAME.match(name):
                continue
            value = encoded_value.decode("utf-8")
            if len(value) > 512 or any(ord(character) < 32 or ord(character) == 127 for character in value):
                refuse("operator Azure environment {} declares an unsafe value for {}".format(path, name))
            if name in FORBIDDEN_OPERATOR_ENVIRONMENT_NAMES or name.endswith("_STATE_DIR"):
                refuse(
                    "operator Azure environment {} may not declare per-run control {}".format(
                        path, name
                    )
                )
            if name in ALLOWED_OPERATOR_ENVIRONMENT_NAMES:
                values[name] = value
    except UnicodeDecodeError:
        refuse("operator Azure environment file {} returned non-UTF-8 values".format(path))
    missing = [name for name in OPERATOR_ENVIRONMENT_NAMES if not values.get(name)]
    if missing:
        refuse(
            "operator Azure environment {} is missing required value(s): {}".format(
                path, ", ".join(missing)
            )
        )
    if (
        expected_subscription is not None
        and values["FM_AZURE_SUBSCRIPTION_ID"] != expected_subscription
    ):
        refuse(
            "routing file subscription {} does not match the operator Azure environment subscription".format(
                expected_subscription
            )
        )
    return values


def known_resource_classes():
    """The runner's own class table, imported rather than mirrored.

    A hardcoded copy would drift; importing means a class this file accepts is
    exactly a class the runner can run. An unimportable runner REFUSES, because
    a routing file is present and its selection cannot be validated.
    """
    module_path = Path(__file__).resolve().parent / "fm-azure-runner.py"
    try:
        spec = importlib.util.spec_from_file_location("fm_azure_runner", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        classes = set(module.RESOURCE_CLASSES)
    except Exception as exc:  # noqa: BLE001 - any import failure must fail closed
        refuse("the runner's resource-class table is unreadable ({}): {}".format(module_path, exc))
    if not classes:
        refuse("the runner declares no resource classes")
    return classes


def parse_utc(value, label):
    if not isinstance(value, str) or not EXACT_UTC.match(value):
        refuse("{} is not a literal UTC Z timestamp: {!r}".format(label, value))
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        refuse("{} is not a literal UTC Z timestamp: {!r}".format(label, value))


class DuplicateKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise DuplicateKeyError(key)
        value[key] = item
    return value


def load_document(path, expected):
    """Read one bounded, identity-pinned regular inode, then validate it."""
    if not stat.S_ISREG(expected.st_mode):
        refuse("routing file {} is not a regular file".format(path))
    if expected.st_size > MAX_ROUTING_DOCUMENT_BYTES:
        refuse(
            "routing file {} exceeds the {}-byte bound".format(
                path, MAX_ROUTING_DOCUMENT_BYTES
            )
        )
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        handle = os.open(str(path), flags)
    except OSError as exc:
        refuse("routing file {} is unreadable: {}".format(path, exc.strerror))
    try:
        opened = os.fstat(handle)
        if (expected.st_dev, expected.st_ino) != (opened.st_dev, opened.st_ino):
            refuse("routing file {} changed while it was opened".format(path))
        if not stat.S_ISREG(opened.st_mode):
            refuse("routing file {} is not a regular file".format(path))
        if opened.st_uid != os.geteuid():
            refuse("routing file {} is not owned by the invoking uid".format(path))
        if opened.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            refuse("routing file {} is group- or world-writable".format(path))
        if opened.st_size > MAX_ROUTING_DOCUMENT_BYTES:
            refuse(
                "routing file {} exceeds the {}-byte bound".format(
                    path, MAX_ROUTING_DOCUMENT_BYTES
                )
            )
        chunks = []
        remaining = MAX_ROUTING_DOCUMENT_BYTES + 1
        while remaining:
            chunk = os.read(handle, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
    except OSError as exc:
        refuse("routing file {} could not be read: {}".format(path, exc.strerror))
    finally:
        os.close(handle)
    if len(raw) > MAX_ROUTING_DOCUMENT_BYTES:
        refuse(
            "routing file {} exceeds the {}-byte bound".format(
                path, MAX_ROUTING_DOCUMENT_BYTES
            )
        )
    if not raw.strip():
        refuse("routing file {} is empty, which is what a torn write looks like".format(path))
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except DuplicateKeyError as exc:
        refuse("routing file {} declares duplicate JSON key {!r}".format(path, str(exc)))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        refuse(
            "routing file {} is not valid JSON ({}); a partially written file is refused "
            "rather than half-applied".format(path, exc)
        )
    if not isinstance(value, dict):
        refuse("routing file {} is not a JSON object".format(path))
    missing = [name for name in REQUIRED if name not in value]
    if missing:
        refuse("routing file {} is missing required field(s): {}".format(path, ", ".join(missing)))
    unknown = sorted(set(value) - ALLOWED)
    if unknown:
        refuse("routing file {} declares unknown top-level field(s): {}".format(path, ", ".join(unknown)))
    if value.get("schema") != SCHEMA:
        refuse(
            "routing file {} declares schema {!r}, not {!r}".format(path, value.get("schema"), SCHEMA)
        )
    return value


def validate(value, path, run_id, command_class):
    if value.get("run_id") != run_id:
        refuse(
            "routing file {} is bound to run {!r}, not the run being executed ({!r})".format(
                path, value.get("run_id"), run_id
            )
        )
    classes = value.get("classes")
    if not isinstance(classes, dict) or not classes:
        refuse("routing file {} declares no class selections".format(path))
    for name, resource in classes.items():
        if not isinstance(name, str) or not COMMAND_CLASS.match(name):
            refuse("routing file {} declares an invalid command class {!r}".format(path, name))
        if not isinstance(resource, str):
            refuse("routing file {} maps class {!r} to a non-string resource class".format(path, name))
    if not SUBSCRIPTION.match(str(value.get("subscription", ""))):
        refuse("routing file {} declares no exact subscription id".format(path))
    max_dispatches = value.get("max_dispatches")
    if not isinstance(max_dispatches, int) or isinstance(max_dispatches, bool) or max_dispatches < 1:
        refuse("routing file {} declares a max_dispatches that is not a positive whole number".format(path))
    dispatched = value.get("dispatched", 0)
    if not isinstance(dispatched, int) or isinstance(dispatched, bool) or dispatched < 0:
        refuse("routing file {} declares a dispatched count that is not a whole number".format(path))
    expires = parse_utc(value.get("expires_at"), "expires_at")
    now = dt.datetime.now(dt.timezone.utc)
    if expires <= now:
        refuse(
            "routing file {} expired at {}; a selection that outlives its window is refused "
            "rather than reused".format(path, value.get("expires_at"))
        )
    if dispatched >= max_dispatches:
        refuse(
            "routing file {} has spent its dispatch budget ({} of {})".format(
                path, dispatched, max_dispatches
            )
        )
    resource_classes = known_resource_classes()
    for name, resource_class in classes.items():
        if resource_class not in resource_classes:
            refuse(
                "routing file {} selects class {!r} onto unknown resource class {!r}".format(
                    path, name, resource_class
                )
            )
    fm_home = value.get("fm_home")
    if not isinstance(fm_home, str) or not fm_home.startswith("/"):
        refuse("routing file {} declares no absolute fm_home".format(path))
    if any(ord(character) < 32 or ord(character) == 127 for character in fm_home):
        refuse("routing file {} declares control characters in fm_home".format(path))
    home_path = Path(fm_home)
    if home_path.is_symlink():
        refuse("routing file {} declares an fm_home that is a symlink".format(path))
    if not home_path.is_dir():
        refuse(
            "routing file {} declares fm_home {!r}, which is not an existing directory; it is "
            "never defaulted because it selects which spend ledger the run writes to".format(
                path, fm_home
            )
        )
    user_home = os.environ.get("HOME")
    if user_home:
        user_home_path = Path(user_home)
        try:
            home_path.relative_to(user_home_path)
        except ValueError:
            refuse(
                "routing file {} declares fm_home {!r} outside {}".format(path, fm_home, user_home)
            )
        check_provenance(home_path, user_home_path)
    # Only now, once the complete file is known good, does an unselected class
    # mean local. Malformation in a different selection still makes the present
    # authority unusable and therefore runs this command nowhere.
    if command_class not in classes:
        return None
    return classes[command_class]


def consume(path, value):
    """Spend one dispatch durably while the caller owns the stable lock."""
    updated = dict(value)
    updated["dispatched"] = int(value.get("dispatched", 0)) + 1
    temporary = path.with_name(path.name + ".tmp-{}".format(os.getpid()))
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        handle = os.open(str(temporary), flags, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(updated, sort_keys=True, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as exc:
        refuse("routing file {} could not record its spent dispatch: {}".format(path, exc.strerror))
    finally:
        try:
            temporary.unlink()
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
    return updated


def selection_binding(value, command_class, resource_class):
    """Bind inspection to the same immutable selection at real dispatch.

    `dispatched` is intentionally excluded because another valid consumer may
    advance the shared budget without changing which authority was inspected.
    The real resolver still rechecks and spends the current count under lock.
    """
    authority = {name: item for name, item in value.items() if name != "dispatched"}
    bound = {
        "authority": authority,
        "command_class": command_class,
        "resource_class": resource_class,
        "source": "routing",
    }
    canonical = json.dumps(bound, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


def resolve(args):
    if not RUN_ID.match(args.run_id):
        print("azure-runner routing: run id is malformed", file=sys.stderr)
        return EXIT_USAGE
    if not COMMAND_CLASS.match(args.command_class):
        print("azure-runner routing: command class is malformed", file=sys.stderr)
        return EXIT_USAGE
    root, anchor = routing_location()
    if root is None:
        return EXIT_ABSENT
    path = root / (args.run_id + ".json")
    try:
        path.lstat()
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return EXIT_ABSENT
        refuse("routing file {} is unreadable: {}".format(path, exc.strerror))
    check_provenance(path, anchor)
    with routing_lock(path):
        # The operator may atomically replace a routing document between the
        # initial existence check and lock acquisition. Recheck every property
        # and read the current budget while holding the stable lock.
        try:
            observed = path.lstat()
        except OSError as exc:
            refuse("routing file {} changed while acquiring its lock: {}".format(path, exc.strerror))
        check_provenance(path, anchor)
        value = load_document(path, observed)
        resource_class = validate(value, path, args.run_id, args.command_class)
        if resource_class is None:
            return EXIT_NOT_SELECTED
        binding = selection_binding(value, args.command_class, resource_class)
        if args.expected_binding and args.expected_binding != binding:
            refuse(
                "selection binding changed between inspection and dispatch for class {}".format(
                    args.command_class
                )
            )
        environment = (
            None if args.inspect_only else operator_environment_values(value["subscription"])
        )
        updated = value if args.inspect_only else consume(path, value)
    remaining = int(updated["max_dispatches"]) - int(updated.get("dispatched", 0))
    print("resource_class={}".format(resource_class))
    print("fm_home={}".format(value["fm_home"]))
    print("subscription={}".format(value["subscription"]))
    print("selection_binding={}".format(binding))
    if environment is not None:
        for name in sorted(environment):
            encoded = base64.b64encode(environment[name].encode("utf-8")).decode("ascii")
            print("environment_{}_b64={}".format(name, encoded))
    print("dispatches_remaining={}".format(remaining))
    return EXIT_SELECTED


def main():
    parser = argparse.ArgumentParser(add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve_parser = commands.add_parser("resolve")
    resolve_parser.add_argument("--run-id", required=True)
    resolve_parser.add_argument("--class", dest="command_class", required=True)
    resolve_parser.add_argument("--inspect-only", action="store_true")
    resolve_parser.add_argument("--expected-binding")
    args = parser.parse_args()
    if args.command == "resolve":
        return resolve(args)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
