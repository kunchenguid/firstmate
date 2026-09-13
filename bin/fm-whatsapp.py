#!/usr/bin/env python3
"""Optional local WhatsApp Agent Platform bridge; see --help and docs/whatsapp.md.

All command text is data on stdin or in JSON files. 'main' never reads the API
token and authenticates against the current FM_HOME session lock. 'run' owns
only its bridge process; it cannot start/stop a harness, watcher or Herdr server.
Service rendering prints a DISABLED launchd plist and lifecycle commands, never
installs it or invokes launchctl. Errors omit raw input, HTTP text and secrets.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import signal
import sqlite3
import subprocess
import sys
import time

from fm_whatsapp_bridge import Bridge, singleton
from fm_whatsapp_main import dispatch
from fm_whatsapp_store import BridgeError, Config, Store, digest, encode
from fm_whatsapp_transport import HTTP, Simulator, configure_token


def service(config, output):
    if platform.system() != "Darwin":
        raise BridgeError("launchd rendering requires Darwin; another OS needs its own service adapter")
    label = "local.firstmate.whatsapp." + digest([str(config.home), config.agent])[:12]
    config.state.mkdir(parents=True, exist_ok=True, mode=0o700)
    arguments = [str(Path(sys.executable).resolve()), str(Path(__file__).resolve()),
                 "--config", str(config.path), "run"]
    value = {"Label": label, "ProgramArguments": arguments, "Disabled": True,
             "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False},
             "ThrottleInterval": 30, "ProcessType": "Background", "Umask": 63,
             "WorkingDirectory": str(config.home),
             "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
             "StandardOutPath": str(config.state / "service.log"),
             "StandardErrorPath": str(config.state / "service-error.log")}
    if config.mode == "simulated":
        fixture = config.raw.get("simulator_file")
        if not fixture:
            raise BridgeError("simulated service requires simulator_file")
        arguments.extend(["--fixture", str(Config.absolute(fixture))])
    with open(output, "wb") as stream:
        plistlib.dump(value, stream)
    target = "gui/" + str(os.getuid())
    installed = Path.home() / "Library" / "LaunchAgents" / (label + ".plist")
    quote = shlex.quote
    return {"label": label, "disabled": True, "configuration_enabled": config.enabled,
            "commands_only_not_executed": {
                "install": f"install -m 600 {quote(str(Path(output).resolve()))} {quote(str(installed))}",
                "enable": f"launchctl enable {target}/{label}",
                "start": f"launchctl bootstrap {target} {quote(str(installed))}",
                "stop": f"launchctl bootout {target}/{label}",
                "restart": f"launchctl kickstart -k {target}/{label}",
                "disable": f"launchctl disable {target}/{label}",
                "logs": f"tail -n 50 {quote(str(config.state / 'service-error.log'))}"}}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=os.environ.get("FM_WA_CONFIG"), required=not os.environ.get("FM_WA_CONFIG"),
                        help="private JSON configuration path; never a bearer value")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="persistent service (or one cycle); no installation")
    run.add_argument("--once", action="store_true")
    run.add_argument("--fixture", type=Path, help="required for simulated mode, forbidden for live")
    commands.add_parser("doctor", help="local configuration/dependency check; no network/token read")
    commands.add_parser("status", help="local transport/typed-event snapshot; never a completion inference")
    commands.add_parser("main", help="authenticated JSON operation from stdin (see fm_whatsapp_main.py)")
    commands.add_parser("configure-token", help="local hidden TTY prompt; never use in agent tools")
    commands.add_parser("resume", help="clear a persistent poll/auth halt after resolving its cause locally")
    render = commands.add_parser("service-render", help="render disabled launchd plist, print lifecycle commands")
    render.add_argument("--output", required=True, type=Path)
    backup = commands.add_parser("backup", help="consistent SQLite backup; also retain inbox keyed receipts")
    backup.add_argument("--output", required=True, type=Path)
    resolve = commands.add_parser("resolve-send", help="explicitly reconcile one blocked send; never blindly retry")
    resolve.add_argument("--seq", type=int, required=True)
    resolve.add_argument("--disposition", choices=("accepted", "abandoned"), required=True)
    resolve.add_argument("--wamid")
    args = parser.parse_args()
    config = Config(args.config)
    if args.command == "configure-token":
        configure_token(config)
        return {"configured": True}
    if args.command == "service-render":
        return service(config, args.output)
    store = Store(config)
    try:
        if args.command == "doctor":
            import shutil
            return {"os": platform.system(), "python": platform.python_version(),
                    "python_path": sys.executable, "sqlite": sqlite3.sqlite_version,
                    "mode": config.mode, "enabled": config.enabled,
                    "outbound_authorized": config.outbound,
                    "token_file_exists": bool(config.token_file and config.token_file.is_file()),
                    "bash": shutil.which("bash"), "python3": shutil.which("python3"),
                    "supervision": Bridge(store, None).availability(),
                    "unattended_wake_verified": False,
                    "api_account_access": "pending live account verification"}
        if args.command == "status":
            return store.snapshot()
        if args.command == "main":
            data = sys.stdin.read(250001)
            if len(data) > 250000:
                raise BridgeError("main operation too large")
            return dispatch(store, json.loads(data))
        if args.command == "backup":
            if args.output.exists():
                raise BridgeError("backup target already exists")
            target = sqlite3.connect(args.output)
            try:
                store.db.backup(target)
            finally:
                target.close()
            return {"backup": str(args.output), "also_preserve": "FM_HOME/state/inbox keyed receipts and pending/handled notes"}
        with singleton(config):
            if args.command == "resume":
                store.put("halt", "")
                return {"resumed": True, "outbox": "uncertain sends still require explicit reconciliation"}
            if args.command == "resolve-send":
                with store.tx():
                    rows = store.rows("SELECT state FROM outbox WHERE seq=?", (args.seq,))
                    if not rows or rows[0]["state"] not in ("permanent", "auth_failed", "delivery_unknown"):
                        raise BridgeError("only a blocked send can be reconciled")
                    if args.disposition == "accepted" and (not args.wamid or not args.wamid.startswith("wamid.")):
                        raise BridgeError("confirmed acceptance requires the verified wamid")
                    store.db.execute("UPDATE outbox SET state=?,wamid=? WHERE seq=?",
                                     (args.disposition, args.wamid, args.seq))
                    store.put("last_manual_resolution", encode({"seq": args.seq, "state": args.disposition,
                                                                "at": store.clock()}))
                return {"resolved": args.seq, "state": args.disposition}
            if not config.enabled:
                raise BridgeError("bridge is disabled in local configuration")
            if config.mode == "simulated":
                if not args.fixture:
                    raise BridgeError("simulated mode requires --fixture")
                transport = Simulator(store, args.fixture)
            else:
                if args.fixture:
                    raise BridgeError("live mode forbids simulation fixtures")
                transport = HTTP(config)
            bridge = Bridge(store, transport)
            bridge.recover()
            stopping = False

            def stop(_signal, _frame):
                nonlocal stopping
                stopping = True

            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            while not stopping:
                bridge.tick()
                if args.once:
                    return store.snapshot()
                # A diagnostic halt does not cause launchd restart contention.
                time.sleep(1)
            return {"stopped": True, "agents": "untouched"}
    finally:
        store.db.close()


if __name__ == "__main__":
    try:
        print(encode(main()))
    except BridgeError as error:
        print(encode({"error": str(error)}), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.TimeoutExpired):
        print(encode({"error": "bridge operation failed; inspect local configuration and durable state (input omitted)"}), file=sys.stderr)
        sys.exit(1)
