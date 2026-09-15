#!/usr/bin/env python3
"""Journaled parent-record movement for one local SecondMate transfer."""

from __future__ import annotations

import argparse
import base64
import json
import os
import tempfile
from pathlib import Path


def read_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def atomic_json(path: Path, value: dict) -> None:
    atomic_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def snapshot(path: Path) -> dict:
    if path.is_symlink():
        raise ValueError(f"refusing symlinked transfer record: {path}")
    if not path.exists():
        return {"exists": False, "data": ""}
    if not path.is_file():
        raise ValueError(f"refusing non-file transfer record: {path}")
    return {"exists": True, "data": base64.b64encode(path.read_bytes()).decode("ascii")}


def restore(path: Path, value: dict) -> None:
    if value["exists"]:
        atomic_bytes(path, base64.b64decode(value["data"]))
    elif path.exists() and not path.is_symlink():
        path.unlink()


def routes(document: bytes, secondmate: str) -> list[bytes]:
    prefix = f"- {secondmate} ".encode()
    return [line for line in document.splitlines(keepends=True) if line.startswith(prefix)]


def registry_line(document: bytes, secondmate: str) -> bytes:
    matches = routes(document, secondmate)
    if len(matches) != 1:
        raise ValueError(f"source registry needs exactly one route for {secondmate}")
    return matches[0]


def remove_registry_line(document: bytes, secondmate: str) -> bytes:
    prefix = f"- {secondmate} ".encode()
    return b"".join(line for line in document.splitlines(keepends=True) if not line.startswith(prefix))


def append_registry_line(document: bytes, line: bytes, secondmate: str) -> bytes:
    if routes(document, secondmate):
        raise ValueError(f"destination registry already routes {secondmate}")
    if document and not document.endswith(b"\n"):
        document += b"\n"
    return document + line


def binding_parent(document: bytes) -> str:
    fields: dict[str, list[str]] = {}
    for raw in document.decode("utf-8").splitlines():
        if "=" in raw:
            key, value = raw.split("=", 1)
            fields.setdefault(key, []).append(value)
    if fields.get("schema") != ["fm-secondmate-parent.v1"] or fields.get("route") != ["local"]:
        raise ValueError("SecondMate parent binding is not a valid local v1 record")
    values = fields.get("parent_home", [])
    if len(values) != 1 or not os.path.isabs(values[0]):
        raise ValueError("SecondMate parent binding has no unique absolute parent home")
    return values[0]


def open_pending(source: Path) -> list[str]:
    directory = source / "state" / "pending-replies"
    if not directory.exists():
        return []
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"unsafe pending-reply directory: {directory}")
    open_records = []
    for record in sorted(directory.iterdir()):
        if not record.is_file() or record.is_symlink():
            raise ValueError(f"unsafe pending-reply record: {record}")
        phase = ""
        for line in record.read_text(encoding="utf-8").splitlines():
            if line.startswith("phase="):
                phase = line.split("=", 1)[1]
                break
        if phase != "resolved":
            open_records.append(record.name)
    return open_records


def prepare(args: argparse.Namespace) -> None:
    registry = read_json(Path(args.registry))
    owners = {row["secondmate"]: row for row in registry["owners"]}
    managers = {row["id"]: row for row in registry["managers"]}
    assignments = {row["secondmate"]: row for row in registry["assignments"]}
    owner = owners.get(args.secondmate)
    destination_manager = managers.get(args.manager)
    if not owner or not destination_manager:
        raise ValueError("unknown SecondMate or destination manager")
    assignment = assignments.get(args.secondmate)
    source_home = Path(args.source_home or (managers.get((assignment or {}).get("manager"), {}) or {}).get("home", ""))
    if not source_home.is_absolute():
        raise ValueError("source parent home is unknown; pass --source-home")
    destination_home = Path(destination_manager["home"])
    secondmate_home = Path(owner["home"])
    if assignment and args.source_home:
        assigned_home = (managers.get(assignment.get("manager"), {}) or {}).get("home", "")
        if assigned_home and os.path.normpath(assigned_home) != os.path.normpath(source_home):
            raise ValueError("source home disagrees with the active assignment")
    if source_home == destination_home:
        raise ValueError("source and destination parent homes are identical")
    pending = open_pending(source_home)
    if pending:
        raise ValueError("open pending reply blocks transfer: " + ", ".join(pending))

    paths = {
        "source_registry": source_home / "data" / "secondmates.md",
        "destination_registry": destination_home / "data" / "secondmates.md",
        "source_meta": source_home / "state" / f"{args.secondmate}.meta",
        "destination_meta": destination_home / "state" / f"{args.secondmate}.meta",
        "source_status": source_home / "state" / f"{args.secondmate}.status",
        "destination_status": destination_home / "state" / f"{args.secondmate}.status",
        "binding": secondmate_home / ".fm-secondmate-parent",
    }
    snapshots = {key: snapshot(path) for key, path in paths.items()}
    if not snapshots["source_registry"]["exists"] or not snapshots["source_meta"]["exists"]:
        raise ValueError("source parent route and metadata must both exist")
    binding_data = base64.b64decode(snapshots["binding"]["data"])
    if os.path.normpath(binding_parent(binding_data)) != os.path.normpath(source_home):
        raise ValueError("SecondMate parent binding does not name the source home")
    source_registry_data = base64.b64decode(snapshots["source_registry"]["data"])
    line = registry_line(source_registry_data, args.secondmate)
    destination_registry_data = (
        base64.b64decode(snapshots["destination_registry"]["data"])
        if snapshots["destination_registry"]["exists"] else b"# SecondMates\n\n"
    )
    append_registry_line(destination_registry_data, line, args.secondmate)
    if snapshots["destination_meta"]["exists"] or snapshots["destination_status"]["exists"]:
        raise ValueError("destination already has parent metadata or status for the SecondMate")

    assignment_generation = int((assignment or {}).get("generation", 0))
    journal = {
        "schema": "fm-fleet-transfer.v1",
        "transaction": args.transaction,
        "state": "preparing",
        "secondmate": args.secondmate,
        "secondmate_home": str(secondmate_home),
        "source_home": str(source_home),
        "destination_home": str(destination_home),
        "destination_manager": args.manager,
        "failover": bool(args.failover),
        "expected_generation": assignment_generation,
        "prior_assignment": assignment,
        "paths": {key: str(value) for key, value in paths.items()},
        "snapshots": snapshots,
        "resolved_pending_replies_retained": True,
    }
    journal_path = Path(args.journal)
    if journal_path.exists():
        raise ValueError(f"transfer journal already exists: {journal_path}")
    atomic_json(journal_path, journal)

    print(json.dumps({
        "transaction": args.transaction,
        "expected_generation": assignment_generation,
        "source_home": str(source_home),
        "destination_home": str(destination_home),
        "destination_manager": args.manager,
        "secondmate_home": str(secondmate_home),
    }, sort_keys=True))


def apply_records(args: argparse.Namespace) -> None:
    journal_path = Path(args.journal)
    journal = read_json(journal_path)
    if journal.get("schema") != "fm-fleet-transfer.v1":
        raise ValueError("unsupported transfer journal")
    if journal.get("state") == "records-ready":
        return
    if journal.get("state") != "preparing":
        raise ValueError(f"cannot apply transfer in state {journal.get('state')}")
    paths = {key: Path(value) for key, value in journal["paths"].items()}
    snapshots = journal["snapshots"]
    secondmate = journal["secondmate"]
    parent = os.path.normpath(binding_parent(paths["binding"].read_bytes()))
    if parent not in {os.path.normpath(journal["source_home"]), os.path.normpath(journal["destination_home"])}:
        raise ValueError("SecondMate parent binding moved outside this transfer")
    line = registry_line(base64.b64decode(snapshots["source_registry"]["data"]), secondmate)
    destination = paths["destination_registry"]
    destination_data = destination.read_bytes() if destination.exists() else b"# SecondMates\n\n"
    if line not in destination_data.splitlines(keepends=True):
        atomic_bytes(destination, append_registry_line(destination_data, line, secondmate))
    atomic_bytes(paths["destination_meta"], base64.b64decode(snapshots["source_meta"]["data"]))
    if snapshots["source_status"]["exists"]:
        atomic_bytes(paths["destination_status"], base64.b64decode(snapshots["source_status"]["data"]))
    atomic_bytes(paths["binding"], (
        "schema=fm-secondmate-parent.v1\nroute=local\n"
        f"parent_home={journal['destination_home']}\n"
    ).encode())
    if paths["source_registry"].exists():
        atomic_bytes(paths["source_registry"], remove_registry_line(paths["source_registry"].read_bytes(), secondmate))
    paths["source_meta"].unlink(missing_ok=True)
    if paths["source_status"].exists():
        paths["source_status"].unlink()
    journal["state"] = "records-ready"
    atomic_json(journal_path, journal)


def rollback(args: argparse.Namespace) -> None:
    journal_path = Path(args.journal)
    journal = read_json(journal_path)
    if journal.get("schema") != "fm-fleet-transfer.v1":
        raise ValueError("unsupported transfer journal")
    paths = {key: Path(value) for key, value in journal["paths"].items()}
    snapshots = journal["snapshots"]
    secondmate = journal["secondmate"]
    line = registry_line(base64.b64decode(snapshots["source_registry"]["data"]), secondmate)
    if paths["destination_registry"].exists():
        atomic_bytes(paths["destination_registry"], remove_registry_line(paths["destination_registry"].read_bytes(), secondmate))
    source_data = paths["source_registry"].read_bytes() if paths["source_registry"].exists() else b""
    if not routes(source_data, secondmate):
        atomic_bytes(paths["source_registry"], append_registry_line(source_data, line, secondmate))
    for kind in ("meta", "status"):
        moved = paths[f"destination_{kind}"]
        if moved.exists():
            atomic_bytes(paths[f"source_{kind}"], moved.read_bytes())
            moved.unlink()
    restore(paths["binding"], snapshots["binding"])
    journal["state"] = "rolled-back"
    atomic_json(journal_path, journal)


def state(args: argparse.Namespace) -> None:
    journal = read_json(Path(args.journal))
    if args.set or args.destination_stopped is not None or args.secondmate_stopped is not None:
        if args.set:
            journal["state"] = args.set
        if args.destination_stopped is not None:
            journal["destination_stopped"] = bool(args.destination_stopped)
        if args.secondmate_stopped is not None:
            journal["secondmate_stopped"] = bool(args.secondmate_stopped)
        atomic_json(Path(args.journal), journal)
    print(json.dumps(journal, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("registry")
    prep.add_argument("--secondmate", required=True)
    prep.add_argument("--manager", required=True)
    prep.add_argument("--source-home", default="")
    prep.add_argument("--transaction", required=True)
    prep.add_argument("--journal", required=True)
    prep.add_argument("--failover", type=int, choices=(0, 1), default=0)
    prep.set_defaults(function=prepare)
    apply_command = commands.add_parser("apply")
    apply_command.add_argument("--journal", required=True)
    apply_command.set_defaults(function=apply_records)
    rb = commands.add_parser("rollback")
    rb.add_argument("--journal", required=True)
    rb.set_defaults(function=rollback)
    st = commands.add_parser("state")
    st.add_argument("--journal", required=True)
    st.add_argument("--set", default="")
    st.add_argument("--destination-stopped", type=int, choices=(0, 1))
    st.add_argument("--secondmate-stopped", type=int, choices=(0, 1))
    st.set_defaults(function=state)
    args = parser.parse_args()
    try:
        args.function(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"fm-fleet-transfer: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
