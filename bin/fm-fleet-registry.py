#!/usr/bin/env python3
"""Schema-v2 registry operations for bin/fm-fleet.sh.

This module owns JSON validation and atomic registry mutation. Process health,
session-lock checks, and endpoint lifecycle remain in the shell control plane.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile
from pathlib import Path


ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def csv(value: str) -> list[str]:
    return sorted({item for item in value.split(",") if item})


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def write_atomic(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def owner_map(reg: dict) -> dict[str, dict]:
    return {row["secondmate"]: row for row in reg.get("owners", [])}


def assignment_map(reg: dict) -> dict[str, dict]:
    return {
        row["secondmate"]: row
        for row in reg.get("assignments", [])
        if row.get("state") == "active"
    }


def validate(reg: dict) -> list[str]:
    errors: list[str] = []
    if reg.get("version") != 2:
        return [f"unsupported registry version: {reg.get('version')!r}"]
    managers = reg.get("managers")
    owners = reg.get("owners")
    assignments = reg.get("assignments")
    unassigned = reg.get("unassigned")
    dependencies = reg.get("dependencies")
    legacy_dependencies = reg.get("legacy_dependencies")
    transfers = reg.get("transfers")
    for key, value in (
        ("managers", managers), ("owners", owners),
        ("assignments", assignments), ("unassigned", unassigned),
        ("dependencies", dependencies),
        ("legacy_dependencies", legacy_dependencies), ("transfers", transfers),
    ):
        if not isinstance(value, list):
            errors.append(f"{key} must be a list")
    if errors:
        return errors

    seen_ids: dict[str, str] = {}
    seen_homes: dict[str, str] = {}
    homes: list[tuple[str, str]] = []
    for manager in managers:
        mid = manager.get("id", "")
        home = manager.get("home", "")
        if mid not in {"manager-1", "manager-2", "manager-3", "manager-4"}:
            errors.append(f"manager id must be manager-1 through manager-4: {mid!r}")
        if mid in seen_ids:
            errors.append(f"duplicate manager id: {mid}")
        seen_ids[mid] = home
        if not os.path.isabs(home):
            errors.append(f"manager {mid} home must be absolute: {home!r}")
            continue
        normalized = os.path.normpath(home)
        if normalized in seen_homes:
            errors.append(
                f"duplicate manager home: {home} "
                f"(used by {seen_homes[normalized]} and {mid})"
            )
        seen_homes[normalized] = mid
        homes.append((mid, normalized))
        extra = sorted(set(manager) - {"id", "home"})
        if extra:
            errors.append(
                f"manager {mid} has semantic fields {', '.join(extra)}; "
                "manager rows are operational only"
            )
    for index, (aid, ahome) in enumerate(homes):
        for bid, bhome in homes[index + 1 :]:
            if ahome.startswith(bhome + os.sep) or bhome.startswith(ahome + os.sep):
                errors.append(
                    f"overlapping manager homes: {aid} ({ahome}) and {bid} ({bhome})"
                )

    seen_sm: set[str] = set()
    seen_projects: dict[str, str] = {}
    seen_domains: dict[str, str] = {}
    for owner in owners:
        secondmate = owner.get("secondmate", "")
        if not ID_RE.fullmatch(secondmate):
            errors.append(f"invalid SecondMate id: {secondmate!r}")
        if secondmate in seen_sm:
            errors.append(f"duplicate SecondMate owner: {secondmate}")
        seen_sm.add(secondmate)
        home = owner.get("home", "")
        if not os.path.isabs(home):
            errors.append(f"SecondMate {secondmate} home must be absolute: {home!r}")
        for key, seen in (("projects", seen_projects), ("domains", seen_domains)):
            values = owner.get(key, [])
            if not isinstance(values, list):
                errors.append(f"SecondMate {secondmate} {key} must be a list")
                continue
            for value in values:
                if value in seen:
                    errors.append(
                        f"duplicate {key[:-1]} owner: {value} "
                        f"({seen[value]} and {secondmate})"
                    )
                seen[value] = secondmate

    active_seen: set[str] = set()
    known_managers = set(seen_ids)
    for assignment in assignments:
        secondmate = assignment.get("secondmate", "")
        manager = assignment.get("manager", "")
        if secondmate not in seen_sm:
            errors.append(f"assignment names unknown SecondMate: {secondmate}")
        if manager not in known_managers:
            errors.append(f"assignment for {secondmate} names unknown manager: {manager}")
        if assignment.get("state") != "active":
            errors.append(f"assignment for {secondmate} has invalid state")
        if secondmate in active_seen:
            errors.append(f"duplicate active SecondMate assignment: {secondmate}")
        active_seen.add(secondmate)
        generation = assignment.get("generation")
        if not isinstance(generation, int) or generation < 1:
            errors.append(f"assignment for {secondmate} has invalid generation")
        forbidden = {"done", "reviewed", "landed", "accepted", "complete"} & set(assignment)
        if forbidden:
            errors.append(
                f"assignment for {secondmate} contains completion fields: "
                f"{', '.join(sorted(forbidden))}"
            )

    seen_triage: set[str] = set()
    for row in unassigned:
        key = row.get("key", "")
        if not key or key in seen_triage:
            errors.append(f"duplicate or empty unassigned key: {key!r}")
        seen_triage.add(key)

    for dependency in dependencies:
        owner = dependency.get("owner_secondmate", "")
        needed = dependency.get("needs_secondmate", "")
        if owner not in seen_sm:
            errors.append(f"dependency names unknown owner SecondMate: {owner}")
        if needed not in seen_sm:
            errors.append(f"dependency names unknown needed SecondMate: {needed}")
        if owner == needed:
            errors.append(f"dependency {dependency.get('from_task')} is not cross-SecondMate")
        if dependency.get("status") not in ("open", "done"):
            errors.append(f"dependency {dependency.get('from_task')} has invalid status")
    return errors


def require_valid(reg: dict) -> None:
    errors = validate(reg)
    if errors:
        raise ValueError("\n".join(errors))


def command_init(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    if path.exists():
        raise ValueError(f"registry already exists at {path}")
    write_atomic(path, {
        "version": 2,
        "managers": [],
        "owners": [],
        "assignments": [],
        "unassigned": [],
        "dependencies": [],
        "legacy_dependencies": [],
        "transfers": [],
    })


def command_validate(args: argparse.Namespace) -> None:
    reg = load(Path(args.registry))
    errors = validate(reg)
    if errors:
        print("fleet validation FAILED:")
        for error in errors:
            print(f"  - {error}")
        raise SystemExit(1)
    print(
        "fleet validation ok: %d manager(s), %d owner(s), %d assignment(s), "
        "%d triage record(s), %d open dependency(s)"
        % (
            len(reg["managers"]), len(reg["owners"]), len(reg["assignments"]),
            len(reg["unassigned"]),
            sum(1 for row in reg["dependencies"] if row.get("status") == "open"),
        )
    )


def secondmate_home_from_registry(parent_home: str, secondmate: str) -> str:
    registry = Path(parent_home) / "data" / "secondmates.md"
    if not registry.is_file() or registry.is_symlink():
        return ""
    pattern = re.compile(
        rf"^- {re.escape(secondmate)} - .* \(home:\s*([^;)]+);.*\)\s*$"
    )
    matches = []
    for line in registry.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            matches.append(match.group(1).strip())
    return matches[0] if len(matches) == 1 else ""


def binding_confirms(secondmate_home: str, parent_home: str) -> bool:
    binding = Path(secondmate_home) / ".fm-secondmate-parent"
    if not binding.is_file() or binding.is_symlink():
        return False
    fields: dict[str, list[str]] = {}
    for line in binding.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields.setdefault(key, []).append(value)
    return (
        fields.get("schema") == ["fm-secondmate-parent.v1"]
        and fields.get("route") == ["local"]
        and len(fields.get("parent_home", [])) == 1
        and os.path.normpath(fields["parent_home"][0]) == os.path.normpath(parent_home)
    )


def command_migrate(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    source = load(path)
    if source.get("version") == 2:
        require_valid(source)
        print("fleet registry already uses version 2")
        return
    if source.get("version") != 1:
        raise ValueError(f"unsupported registry version: {source.get('version')!r}")
    legacy_managers = source.get("managers", [])
    managers = []
    renamed: dict[str, str] = {}
    candidates: list[dict] = []
    triage: list[dict] = []
    stamp = now()
    for index, manager in enumerate(sorted(legacy_managers, key=lambda row: row.get("id", "")), 1):
        legacy_id = manager.get("id", "")
        manager_id = f"manager-{index}"
        renamed[legacy_id] = manager_id
        managers.append({"id": manager_id, "home": manager.get("home", "")})
        secondmates = sorted(set(manager.get("secondmates", [])))
        if len(secondmates) != 1:
            for key, values in (
                ("secondmate", secondmates),
                ("project", manager.get("projects", [])),
                ("domain", manager.get("domains", [])),
            ):
                for value in values:
                    triage.append({
                        "key": f"legacy-{key}:{value}", key: value,
                        "reason": f"ambiguous version-1 manager {legacy_id}",
                        "first_seen_at": stamp, "last_seen_at": stamp, "attempts": 1,
                    })
            continue
        secondmate = secondmates[0]
        secondmate_home = secondmate_home_from_registry(manager.get("home", ""), secondmate)
        if not secondmate_home or not binding_confirms(secondmate_home, manager.get("home", "")):
            for key, values in (
                ("secondmate", [secondmate]),
                ("project", manager.get("projects", [])),
                ("domain", manager.get("domains", [])),
            ):
                for value in values:
                    triage.append({
                        "key": f"legacy-{key}:{value}", key: value,
                        "reason": f"unconfirmed version-1 parent binding for {legacy_id}",
                        "first_seen_at": stamp, "last_seen_at": stamp, "attempts": 1,
                    })
            continue
        candidates.append({
            "secondmate": secondmate, "home": secondmate_home,
            "projects": sorted(set(manager.get("projects", []))),
            "domains": sorted(set(manager.get("domains", []))),
            "manager": manager_id,
        })

    counts: dict[str, int] = {}
    for candidate in candidates:
        counts[candidate["secondmate"]] = counts.get(candidate["secondmate"], 0) + 1
    owners = []
    assignments = []
    unique_candidates: dict[str, dict] = {}
    for candidate in candidates:
        secondmate = candidate["secondmate"]
        if counts[secondmate] != 1:
            triage.append({
                "key": f"legacy-secondmate:{secondmate}", "secondmate": secondmate,
                "reason": "duplicate version-1 SecondMate assignment",
                "first_seen_at": stamp, "last_seen_at": stamp, "attempts": 1,
            })
            continue
        unique_candidates[secondmate] = candidate

    for dimension in ("projects", "domains"):
        claims: dict[str, list[str]] = {}
        for candidate in unique_candidates.values():
            for value in candidate[dimension]:
                claims.setdefault(value, []).append(candidate["secondmate"])
        for value, claimants in claims.items():
            if len(claimants) > 1:
                for secondmate in claimants:
                    unique_candidates[secondmate][dimension].remove(value)
                singular = dimension[:-1]
                triage.append({
                    "key": f"legacy-{singular}:{value}", singular: value,
                    "reason": "ambiguous version-1 semantic ownership",
                    "first_seen_at": stamp, "last_seen_at": stamp, "attempts": 1,
                })
    for secondmate, candidate in sorted(unique_candidates.items()):
        owners.append({key: candidate[key] for key in ("secondmate", "home", "projects", "domains")})
        assignments.append({
            "secondmate": secondmate, "manager": candidate["manager"],
            "generation": 1, "state": "active", "assigned_at": stamp,
            "recovery_reason": "binding-confirmed version-1 migration",
        })

    dependencies = []
    legacy_dependencies = list(source.get("legacy_dependencies", []))
    by_legacy_manager: dict[str, list[str]] = {}
    for secondmate, candidate in unique_candidates.items():
        legacy = next((old for old, new in renamed.items() if new == candidate["manager"]), "")
        by_legacy_manager.setdefault(legacy, []).append(secondmate)
    for dependency in source.get("dependencies", []):
        owner_options = by_legacy_manager.get(dependency.get("owner", ""), [])
        need_options = by_legacy_manager.get(dependency.get("needs_manager", ""), [])
        if len(owner_options) == 1 and len(need_options) == 1 and owner_options[0] != need_options[0]:
            dependencies.append({
                "owner_secondmate": owner_options[0],
                "from_task": dependency.get("from_task", ""),
                "needs_secondmate": need_options[0],
                "needs_task": dependency.get("needs_task", ""),
                "status": dependency.get("status", "open"),
            })
        else:
            legacy_dependencies.append({
                "kind": "legacy-manager-v1",
                "reason": "ambiguous manager-to-SecondMate mapping",
                "record": dependency,
            })
    migrated = {
        "version": 2, "managers": managers, "owners": owners,
        "assignments": assignments,
        "unassigned": sorted({row["key"]: row for row in triage}.values(), key=lambda row: row["key"]),
        "dependencies": dependencies, "legacy_dependencies": legacy_dependencies,
        "transfers": [],
    }
    require_valid(migrated)
    write_atomic(path, migrated)
    print(
        f"migrated registry to version 2: {len(managers)} manager(s), "
        f"{len(owners)} binding-confirmed owner(s), {len(migrated['unassigned'])} triage record(s)"
    )


def command_manager_register(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    row = {"id": args.id, "home": args.home}
    existing = next((m for m in reg["managers"] if m["id"] == args.id), None)
    if existing:
        if existing == row:
            return
        raise ValueError(f"duplicate manager id: {args.id}")
    reg["managers"].append(row)
    reg["managers"].sort(key=lambda value: value["id"])
    require_valid(reg)
    write_atomic(path, reg)


def command_owner_register(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    prior = owner_map(reg).get(args.secondmate, {})
    home = args.home or prior.get("home", "")
    row = {
        "secondmate": args.secondmate,
        "home": home,
        "projects": csv(args.projects),
        "domains": csv(args.domains),
    }
    existing = prior or None
    if existing:
        if existing == row:
            return
        raise ValueError(f"duplicate SecondMate owner: {args.secondmate}")
    reg["owners"].append(row)
    reg["owners"].sort(key=lambda value: value["secondmate"])
    require_valid(reg)
    write_atomic(path, reg)


def command_get(args: argparse.Namespace) -> None:
    reg = load(Path(args.registry))
    require_valid(reg)
    if args.kind == "manager":
        rows = [row for row in reg["managers"] if row["id"] == args.id]
    elif args.kind == "owner":
        rows = [row for row in reg["owners"] if row["secondmate"] == args.id]
    elif args.kind == "assignment":
        rows = [row for row in reg["assignments"] if row["secondmate"] == args.id]
    else:
        rows = reg.get(args.kind, [])
    if not rows:
        raise SystemExit(1)
    print(json.dumps(rows[0] if args.kind in {"manager", "owner", "assignment"} else rows))


def in_flight_transfer(reg: dict, secondmate: str) -> dict | None:
    return next((row for row in reg["transfers"] if row.get("secondmate") == secondmate), None)


def upsert_triage(reg: dict, dimensions: dict[str, str], reason: str) -> dict:
    parts = [f"{key}:{dimensions[key]}" for key in sorted(dimensions) if dimensions[key]]
    key = "|".join(parts)
    stamp = now()
    for row in reg["unassigned"]:
        if row["key"] == key:
            row["last_seen_at"] = stamp
            row["attempts"] = int(row.get("attempts", 1)) + 1
            return row
    row = {
        "key": key,
        **{key: value for key, value in dimensions.items() if value},
        "reason": reason,
        "first_seen_at": stamp,
        "last_seen_at": stamp,
        "attempts": 1,
    }
    reg["unassigned"].append(row)
    reg["unassigned"].sort(key=lambda value: value["key"])
    return row


def command_route(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    dimensions = {
        "secondmate": args.secondmate,
        "project": args.project,
        "domain": args.domain,
        "issue": args.issue,
    }
    claims: dict[str, str] = {}
    for owner in reg["owners"]:
        if args.secondmate and owner["secondmate"] == args.secondmate:
            claims["secondmate"] = owner["secondmate"]
        if args.project and args.project in owner["projects"]:
            claims["project"] = owner["secondmate"]
        if args.domain and args.domain in owner["domains"]:
            claims["domain"] = owner["secondmate"]
    unresolved = [
        key for key in ("secondmate", "project", "domain")
        if dimensions[key] and key not in claims
    ]
    if unresolved:
        row = upsert_triage(
            reg,
            dimensions,
            "unowned semantic routing key: " + ", ".join(unresolved),
        )
        require_valid(reg)
        write_atomic(path, reg)
        print(json.dumps({"state": "unassigned", "claims": claims, "triage": row}, sort_keys=True))
        raise SystemExit(3)
    if not claims:
        row = upsert_triage(reg, dimensions, "no semantic SecondMate owner")
        require_valid(reg)
        write_atomic(path, reg)
        print(json.dumps({"state": "unassigned", "triage": row}, sort_keys=True))
        raise SystemExit(3)
    if len(set(claims.values())) != 1:
        row = upsert_triage(reg, dimensions, "routing dimensions disagree")
        require_valid(reg)
        write_atomic(path, reg)
        print(json.dumps({"state": "unassigned", "claims": claims, "triage": row}, sort_keys=True))
        raise SystemExit(3)
    secondmate = next(iter(claims.values()))
    transfer = in_flight_transfer(reg, secondmate)
    if transfer:
        print(json.dumps({"state": "transfer-in-progress", "secondmate": secondmate,
                          "transaction": transfer.get("transaction"), "by": sorted(claims)}, sort_keys=True))
        raise SystemExit(4)
    assignment = assignment_map(reg).get(secondmate)
    print(json.dumps({
        "state": "assigned" if assignment else "needs-assignment",
        "secondmate": secondmate,
        "manager": assignment.get("manager") if assignment else None,
        "generation": assignment.get("generation") if assignment else None,
        "by": sorted(claims),
    }, sort_keys=True))


def command_assign(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    if args.secondmate not in owner_map(reg):
        raise ValueError(f"unknown SecondMate owner: {args.secondmate}")
    transfer = in_flight_transfer(reg, args.secondmate)
    if transfer:
        raise ValueError(f"transfer {transfer.get('transaction')} is in flight for {args.secondmate}")
    assignments = assignment_map(reg)
    prior = assignments.get(args.secondmate)
    if prior:
        print(json.dumps(prior, sort_keys=True))
        return
    if args.manager not in {row["id"] for row in reg["managers"]}:
        raise ValueError(f"unknown manager: {args.manager}")
    row = {
        "secondmate": args.secondmate,
        "manager": args.manager,
        "generation": 1,
        "state": "active",
        "assigned_at": now(),
        "recovery_reason": args.reason,
    }
    reg["assignments"].append(row)
    reg["assignments"].sort(key=lambda value: value["secondmate"])
    require_valid(reg)
    write_atomic(path, reg)
    print(json.dumps(row, sort_keys=True))


def command_dep(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    if args.action == "list":
        print(json.dumps(reg["dependencies"], indent=2, sort_keys=True))
        return
    if args.action == "add":
        known = set(owner_map(reg))
        if args.owner not in known or args.needs not in known:
            raise ValueError("dependency names an unknown SecondMate")
        reg["dependencies"] = [
            row for row in reg["dependencies"]
            if not (row["owner_secondmate"] == args.owner and row["from_task"] == args.from_task)
        ]
        reg["dependencies"].append({
            "owner_secondmate": args.owner,
            "from_task": args.from_task,
            "needs_secondmate": args.needs,
            "needs_task": args.task,
            "status": "open",
        })
    else:
        found = False
        for row in reg["dependencies"]:
            if row["owner_secondmate"] == args.owner and row["from_task"] == args.from_task:
                row["status"] = "done"
                found = True
        if not found:
            raise ValueError("dependency not found")
    require_valid(reg)
    write_atomic(path, reg)


def require_expected_generation(reg: dict, args: argparse.Namespace) -> None:
    current = assignment_map(reg).get(args.secondmate)
    if args.expected_generation == 0:
        if current:
            raise ValueError("assignment appeared during transfer")
    elif not current or current["generation"] != args.expected_generation:
        raise ValueError("assignment generation changed during transfer")


def current_transfer(reg: dict, secondmate: str, transaction: str, states: tuple[str, ...]) -> dict:
    """Return the SecondMate's in-flight transfer row when it is exactly this transaction in an eligible state."""
    rows = [row for row in reg["transfers"] if row.get("secondmate") == secondmate]
    if len(rows) != 1 or rows[0].get("transaction") != transaction or rows[0].get("state") not in states:
        raise ValueError(f"transfer {transaction} is not the current {'/'.join(states)} transfer for {secondmate}")
    return rows[0]


def transfer_authority(reg: dict, secondmate: str, transaction: str) -> str:
    """The in-flight row state for this transaction, 'active' when its published assignment is current, else 'superseded'."""
    rows = [row for row in reg["transfers"] if row.get("secondmate") == secondmate]
    if rows:
        return rows[0]["state"] if rows[0].get("transaction") == transaction else "superseded"
    current = assignment_map(reg).get(secondmate)
    return "active" if current and current.get("transaction") == transaction else "superseded"


def reserved_managers(reg: dict, failover: bool) -> set[str]:
    """Managers held by in-flight transfer rows; a failover shares live managers, so it honors only planned rows."""
    return {
        row["destination_manager"] for row in reg["transfers"]
        if row.get("destination_manager") and (not failover or not row.get("failover"))
    }


def command_transfer_reserve(args: argparse.Namespace) -> None:
    """Admit one in-flight transfer per SecondMate and reserve its destination manager."""
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    if args.manager not in {row["id"] for row in reg["managers"]}:
        raise ValueError(f"unknown destination manager {args.manager}")
    transfer = in_flight_transfer(reg, args.secondmate)
    if transfer:
        raise ValueError(f"transfer {transfer.get('transaction')} is already in flight for {args.secondmate}")
    if args.manager in reserved_managers(reg, bool(args.failover)):
        raise ValueError(f"destination manager {args.manager} is reserved by an unfinished transfer")
    reg["transfers"].append({"secondmate": args.secondmate, "transaction": args.transaction, "state": "preparing",
                             "destination_manager": args.manager, "failover": bool(args.failover)})
    require_valid(reg)
    write_atomic(path, reg)


def command_transfer_reserved(args: argparse.Namespace) -> None:
    print(" ".join(sorted(reserved_managers(load(Path(args.registry)), bool(args.failover)))))


def command_transfer_authority(args: argparse.Namespace) -> None:
    print(transfer_authority(load(Path(args.registry)), args.secondmate, args.transaction))


def command_transfer_release(args: argparse.Namespace) -> None:
    """Remove this transaction's unclaimed reservation; print whether it still owned the SecondMate."""
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    row = next((item for item in reg["transfers"] if item.get("transaction") == args.transaction), None)
    if row and row.get("state") != "preparing":
        raise ValueError(f"transfer {args.transaction} claimed its record move")
    if row:
        reg["transfers"].remove(row)
        require_valid(reg)
        write_atomic(path, reg)
        owned = True
    else:
        owned = args.retry and not any(item.get("secondmate") == args.secondmate for item in reg["transfers"])
    print("owned" if owned else "superseded")


def command_transfer_claim(args: argparse.Namespace) -> None:
    """Claim the record move for one transaction before any owner record changes."""
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    require_expected_generation(reg, args)
    current_transfer(reg, args.secondmate, args.transaction, ("preparing", "records-ready"))["state"] = "records-ready"
    require_valid(reg)
    write_atomic(path, reg)


def command_transfer_publish(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    require_expected_generation(reg, args)
    transfer = current_transfer(reg, args.secondmate, args.transaction, ("records-ready",))
    row = {
        "secondmate": args.secondmate,
        "manager": args.manager,
        "generation": args.expected_generation + 1,
        "state": "active",
        "assigned_at": now(),
        "recovery_reason": args.reason,
        "transaction": args.transaction,
    }
    reg["assignments"] = [
        item for item in reg["assignments"] if item["secondmate"] != args.secondmate
    ] + [row]
    reg["assignments"].sort(key=lambda value: value["secondmate"])
    transfer.update(state="published", generation=row["generation"])
    require_valid(reg)
    write_atomic(path, reg)
    print(json.dumps(row, sort_keys=True))


def command_transfer_state(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    if args.state != "active":
        raise ValueError("transfer-state only activates a published transfer")
    if transfer_authority(reg, args.secondmate, args.transaction) == "active":
        return
    reg["transfers"].remove(current_transfer(reg, args.secondmate, args.transaction, ("published",)))
    require_valid(reg)
    write_atomic(path, reg)


def transfer_rollback_valid(reg: dict, args: argparse.Namespace) -> dict | None:
    authority = transfer_authority(reg, args.secondmate, args.transaction)
    if authority not in ("records-ready", "published", "active"):
        raise ValueError(f"transfer {args.transaction} is not the current transfer for {args.secondmate}; rollback refused")
    return next((row for row in reg["transfers"] if row.get("transaction") == args.transaction), None)


def command_transfer_rollback_check(args: argparse.Namespace) -> None:
    reg = load(Path(args.registry))
    require_valid(reg)
    transfer_rollback_valid(reg, args)


def command_transfer_rollback(args: argparse.Namespace) -> None:
    path = Path(args.registry)
    reg = load(path)
    require_valid(reg)
    transfer = transfer_rollback_valid(reg, args)
    reg["assignments"] = [
        row for row in reg["assignments"] if row["secondmate"] != args.secondmate
    ]
    if args.prior_assignment:
        prior = json.loads(args.prior_assignment)
        if prior:
            reg["assignments"].append(prior)
            reg["assignments"].sort(key=lambda value: value["secondmate"])
    if transfer:
        reg["transfers"].remove(transfer)
    require_valid(reg)
    write_atomic(path, reg)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("registry")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("init").set_defaults(function=command_init)
    commands.add_parser("validate").set_defaults(function=command_validate)
    commands.add_parser("migrate").set_defaults(function=command_migrate)
    register = commands.add_parser("manager-register")
    register.add_argument("--id", required=True)
    register.add_argument("--home", required=True)
    register.set_defaults(function=command_manager_register)
    owner = commands.add_parser("owner-register")
    owner.add_argument("--secondmate", required=True)
    owner.add_argument("--home", default="")
    owner.add_argument("--projects", default="")
    owner.add_argument("--domains", default="")
    owner.set_defaults(function=command_owner_register)
    get = commands.add_parser("get")
    get.add_argument("kind", choices=("manager", "owner", "assignment", "unassigned", "dependencies", "transfers"))
    get.add_argument("id", nargs="?", default="")
    get.set_defaults(function=command_get)
    route = commands.add_parser("route")
    route.add_argument("--secondmate", default="")
    route.add_argument("--project", default="")
    route.add_argument("--domain", default="")
    route.add_argument("--issue", default="")
    route.set_defaults(function=command_route)
    assign = commands.add_parser("assign")
    assign.add_argument("--secondmate", required=True)
    assign.add_argument("--manager", required=True)
    assign.add_argument("--reason", default="")
    assign.set_defaults(function=command_assign)
    dep = commands.add_parser("dep")
    dep.add_argument("action", choices=("add", "done", "list"))
    dep.add_argument("--owner", default="")
    dep.add_argument("--from", dest="from_task", default="")
    dep.add_argument("--needs", default="")
    dep.add_argument("--task", default="")
    dep.set_defaults(function=command_dep)
    publish = commands.add_parser("transfer-publish")
    publish.add_argument("--secondmate", required=True)
    publish.add_argument("--manager", required=True)
    publish.add_argument("--expected-generation", type=int, required=True)
    publish.add_argument("--transaction", required=True)
    publish.add_argument("--reason", required=True)
    publish.set_defaults(function=command_transfer_publish)
    reserve = commands.add_parser("transfer-reserve")
    reserve.add_argument("--secondmate", required=True)
    reserve.add_argument("--manager", required=True)
    reserve.add_argument("--transaction", required=True)
    reserve.add_argument("--failover", type=int, choices=(0, 1), default=0)
    reserve.set_defaults(function=command_transfer_reserve)
    reserved = commands.add_parser("transfer-reserved")
    reserved.add_argument("--failover", type=int, choices=(0, 1), default=0)
    reserved.set_defaults(function=command_transfer_reserved)
    release = commands.add_parser("transfer-release")
    release.add_argument("--secondmate", required=True)
    release.add_argument("--transaction", required=True)
    release.add_argument("--retry", action="store_true")
    release.set_defaults(function=command_transfer_release)
    authority = commands.add_parser("transfer-authority")
    authority.add_argument("--secondmate", required=True)
    authority.add_argument("--transaction", required=True)
    authority.set_defaults(function=command_transfer_authority)
    claim = commands.add_parser("transfer-claim")
    claim.add_argument("--secondmate", required=True)
    claim.add_argument("--expected-generation", type=int, required=True)
    claim.add_argument("--transaction", required=True)
    claim.set_defaults(function=command_transfer_claim)
    transfer_state = commands.add_parser("transfer-state")
    transfer_state.add_argument("--secondmate", required=True)
    transfer_state.add_argument("--transaction", required=True)
    transfer_state.add_argument("--state", required=True)
    transfer_state.set_defaults(function=command_transfer_state)
    transfer_rollback = commands.add_parser("transfer-rollback")
    transfer_rollback.add_argument("--secondmate", required=True)
    transfer_rollback.add_argument("--transaction", required=True)
    transfer_rollback.add_argument("--prior-assignment", default="")
    transfer_rollback.set_defaults(function=command_transfer_rollback)
    rollback_check = commands.add_parser("transfer-rollback-check")
    rollback_check.add_argument("--secondmate", required=True)
    rollback_check.add_argument("--transaction", required=True)
    rollback_check.set_defaults(function=command_transfer_rollback_check)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.function(args)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"fm-fleet: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
