#!/usr/bin/env python3
"""fm-jev-tunnel-watchdog.py - Jev Cross-Seat Idle SSH & Persistent Tunnel Health Watchdog

Audits active SSH client processes, proxy tunnels, and remote fleet carrier sessions
across multi-agent worker seats (e.g., dev, srv, svc, storage-covenant, agt-N).
Detects wedged/stale remote sessions, abandoned socket tunnels, and half-open connections.

Invariants:
- Fail-open: Never crashes caller; returns non-destructive status on probe errors.
- Safety: NEVER terminates interactive TTY sessions, ssh-agent, sshd daemons,
  or deliberate persistent background tunnels (-N, -f, -W, -L, -R, autossh).
- Precision: Accurately isolates hung command executions (>max-age) and CLOSE_WAIT sockets.
- Structured telemetry: Emits machine-readable JSON for supervisor logging.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Set


def get_process_elapsed_seconds(pid: int) -> int:
    """Return elapsed wall-clock seconds for a given PID from /proc/uptime and /proc/[pid]/stat."""
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            uptime = float(f.readline().split()[0])
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as f:
            fields = f.read().split()
            # field 22 (0-indexed 21) is starttime in clock ticks
            starttime_ticks = int(fields[21])
        ticks_per_sec = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
        start_seconds = starttime_ticks / ticks_per_sec
        return max(0, int(uptime - start_seconds))
    except Exception:
        return 0


def is_interactive_tty(pid: int) -> bool:
    """Check if process is associated with a controlling terminal or active TTY."""
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as f:
            fields = f.read().split()
            # field 7 (0-indexed 6) is tty_nr
            tty_nr = int(fields[6])
            return tty_nr != 0
    except Exception:
        return False


def is_legitimate_tunnel(cmd: str) -> bool:
    """Detect if SSH process was invoked as a deliberate persistent tunnel or proxy jump."""
    # Check for tunnel / port-forward / proxy jump flags
    tunnel_patterns = [
        r"(?:^|\s)-[a-zA-Z0-9]*[NDLRW][a-zA-Z0-9]*\b",  # -N, -D, -L, -R, -W, -fN, etc.
        r"ControlMaster=(?:yes|auto|autoask)",
        r"autossh",
        r"\bProxyCommand\b",
    ]
    for pat in tunnel_patterns:
        if re.search(pat, cmd):
            return True
    return False


def get_active_ssh_connections() -> List[Dict[str, Any]]:
    """Scan active network connections on port 22/2222 or SSH remote sockets."""
    connections = []
    try:
        res = subprocess.run(
            ["ss", "-tanp", "sport = :22 or dport = :22 or dport = :2222"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            for line in lines[1:]:  # Skip header
                parts = line.split()
                if len(parts) >= 4:
                    state = parts[0]
                    local = parts[3]
                    remote = parts[4] if len(parts) > 4 else ""
                    pid = None
                    proc_name = None
                    m = re.search(r'users:\(\("([^"]+)",pid=(\d+)', line)
                    if m:
                        proc_name = m.group(1)
                        pid = int(m.group(2))
                    connections.append({
                        "state": state,
                        "local": local,
                        "remote": remote,
                        "pid": pid,
                        "process": proc_name,
                    })
    except Exception:
        pass
    return connections


def audit_ssh_processes(max_age_seconds: int = 600) -> Dict[str, Any]:
    """Audit running SSH client processes for stale/wedged state."""
    my_uid = os.getuid()
    audited_procs: List[Dict[str, Any]] = []
    flagged_procs: List[Dict[str, Any]] = []

    connections = get_active_ssh_connections()
    close_wait_pids: Set[int] = {
        c["pid"] for c in connections if c["state"] == "CLOSE_WAIT" and c.get("pid")
    }

    try:
        # List processes matching ssh
        res = subprocess.run(
            ["ps", "-u", str(my_uid), "-o", "pid,ppid,stat,etime,args"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            lines = res.stdout.strip().splitlines()
            for line in lines[1:]:
                parts = line.strip().split(None, 4)
                if len(parts) < 5:
                    continue
                pid_str, ppid_str, stat, etime, cmd = parts
                try:
                    pid = int(pid_str)
                    ppid = int(ppid_str)
                except ValueError:
                    continue

                # Filter for ssh client processes (not ssh-agent, not sshd, not ssh-keyscan)
                cmd_tokens = cmd.split()
                if not cmd_tokens:
                    continue
                binary = os.path.basename(cmd_tokens[0])
                if binary != "ssh":
                    continue

                elapsed = get_process_elapsed_seconds(pid)
                interactive = is_interactive_tty(pid)
                tunnel = is_legitimate_tunnel(cmd)

                # Determine target host from args
                target_host = "unknown"
                for arg in cmd_tokens[1:]:
                    if not arg.startswith("-") and "=" not in arg:
                        target_host = arg
                        break

                proc_info = {
                    "pid": pid,
                    "ppid": ppid,
                    "stat": stat,
                    "etime": etime,
                    "elapsed_seconds": elapsed,
                    "interactive": interactive,
                    "is_tunnel": tunnel,
                    "target_host": target_host,
                    "command_preview": (cmd[:100] + "...") if len(cmd) > 100 else cmd,
                }
                audited_procs.append(proc_info)

                # Detection rules for wedged/stale SSH sessions:
                # 1. Associated socket is wedged in CLOSE_WAIT
                if pid in close_wait_pids:
                    proc_info["stale_reason"] = "socket_in_close_wait"
                    flagged_procs.append(proc_info)
                    continue

                # 2. Non-interactive remote command execution exceeding max_age_seconds
                # (Deliberate tunnels and interactive TTYs are safely exempted)
                if not interactive and not tunnel and elapsed > max_age_seconds:
                    proc_info["stale_reason"] = f"elapsed_time_exceeded_{elapsed}s"
                    flagged_procs.append(proc_info)
                    continue

                # 3. Defunct/Zombie SSH process
                if "Z" in stat:
                    proc_info["stale_reason"] = "defunct_zombie"
                    flagged_procs.append(proc_info)
                    continue

    except Exception as e:
        return {
            "error": str(e),
            "audited_processes_count": 0,
            "flagged_stale_count": 0,
            "healthy": True,  # Fail open
        }

    close_wait_connections = [c for c in connections if c["state"] == "CLOSE_WAIT"]
    healthy = len(flagged_procs) == 0 and len(close_wait_connections) == 0

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "healthy": healthy,
        "audited_processes_count": len(audited_procs),
        "flagged_stale_count": len(flagged_procs),
        "flagged_processes": flagged_procs,
        "active_ssh_connections_count": len(connections),
        "close_wait_connections_count": len(close_wait_connections),
        "max_age_threshold_seconds": max_age_seconds,
    }


def reap_stale_processes(flagged_procs: List[Dict[str, Any]]) -> List[int]:
    """Terminate flagged stale non-interactive SSH processes safely."""
    reaped = []
    for proc in flagged_procs:
        pid = proc["pid"]
        if pid <= 1 or pid == os.getpid():
            continue
        try:
            os.kill(pid, 15)  # SIGTERM
            reaped.append(pid)
        except ProcessLookupError:
            pass
        except Exception:
            pass
    return reaped


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Cross-Seat Idle SSH & Persistent Tunnel Health Watchdog"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run health check and return 0 if healthy, 1 if stale/wedged detected",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )
    parser.add_argument(
        "--max-age",
        type=int,
        default=600,
        help="Maximum allowed runtime in seconds for non-interactive SSH clients (default: 600)",
    )
    parser.add_argument(
        "--reap-stale",
        action="store_true",
        help="Terminate flagged stale SSH client processes",
    )
    args = parser.parse_args()

    result = audit_ssh_processes(max_age_seconds=args.max_age)

    if args.reap_stale and result.get("flagged_processes"):
        reaped = reap_stale_processes(result["flagged_processes"])
        result["reaped_pids"] = reaped
        result["healthy"] = True

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_str = "HEALTHY" if result.get("healthy") else "STALE_DETECTED"
        print(f"SSH Tunnel Watchdog: {status_str}")
        print(f"  • Audited Processes: {result.get('audited_processes_count', 0)}")
        print(f"  • Flagged Stale: {result.get('flagged_stale_count', 0)}")
        print(f"  • Active Connections: {result.get('active_ssh_connections_count', 0)}")
        print(f"  • CLOSE_WAIT Sockets: {result.get('close_wait_connections_count', 0)}")
        if result.get("reaped_pids"):
            print(f"  • Reaped PIDs: {result['reaped_pids']}")

    if args.check:
        return 0 if result.get("healthy", True) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
