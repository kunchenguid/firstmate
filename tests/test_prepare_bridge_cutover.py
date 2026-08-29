from __future__ import annotations

import base64
import contextlib
import dataclasses
import hashlib
import importlib.util
import json
import os
import pwd
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from collections.abc import Iterator
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "tools" / "bridge-cutover"
sys.path.insert(0, str(SCRIPT_DIR))

import prepare_bridge_cutover as prepare  # noqa: E402


DRIVER = SCRIPT_DIR / "bridge_cutover_transaction.py"


MODELS_SOURCE = """\
from dataclasses import dataclass, field
from pathlib import Path

@dataclass(frozen=True)
class ProviderConfig:
    name: str
    binary: Path
    base_home: Path | None = None
    hooks_source: Path | None = None
    shared_entries: tuple[str, ...] = ()
    desktop_identity_file: Path | None = None
    trusted_projects: tuple[Path, ...] = ()

@dataclass(frozen=True)
class Profile:
    id: str
    provider: str
    home: Path
    pools: tuple[str, ...]
    enabled: bool = False
    weight: int = 1
    max_concurrent: int = 2
    reserve_percent: int = 15
    safety_policy: str = "worker"

@dataclass(frozen=True)
class Settings:
    state_dir: Path
    share_dir: Path
    quota_binary: Path
    quota_node_binary: Path
    quota_binary_sha256: str = ""
    quota_node_sha256: str = ""
    quota_release_tree_sha256: str = ""
    quota_stale_seconds: int = 300
    quota_verification_grace_seconds: int = 86400
    lease_grace_seconds: int = 30
    active_lease_penalty: int = 8
    lock_stale_seconds: int = 30

@dataclass(frozen=True)
class Registry:
    version: int
    settings: Settings
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    profiles: dict[str, Profile] = field(default_factory=dict)
    config_path: Path | None = None
"""


CONFIG_SOURCE = """\
from dataclasses import replace
import json
import os
from pathlib import Path
import tomllib
from .models import Profile, ProviderConfig, Registry, Settings

def load_registry(path):
    raw = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    settings_raw = raw["settings"]
    settings = Settings(
        state_dir=Path(settings_raw["state_dir"]),
        share_dir=Path(settings_raw["share_dir"]),
        quota_binary=Path(settings_raw["quota_binary"]),
        quota_node_binary=Path(settings_raw["quota_node_binary"]),
        quota_binary_sha256=settings_raw.get("quota_binary_sha256", ""),
        quota_node_sha256=settings_raw.get("quota_node_sha256", ""),
        quota_release_tree_sha256=settings_raw.get("quota_release_tree_sha256", ""),
        quota_stale_seconds=settings_raw.get("quota_stale_seconds", 300),
        quota_verification_grace_seconds=settings_raw.get(
            "quota_verification_grace_seconds", 86400
        ),
        lease_grace_seconds=settings_raw.get("lease_grace_seconds", 30),
        active_lease_penalty=settings_raw.get("active_lease_penalty", 8),
        lock_stale_seconds=settings_raw.get("lock_stale_seconds", 30),
    )
    providers = {}
    for name, item in raw["providers"].items():
        desktop = item.get("desktop_identity_file")
        providers[name] = ProviderConfig(
            name=name,
            binary=Path(item["binary"]),
            base_home=Path(item["base_home"]) if item.get("base_home") else None,
            hooks_source=Path(item["hooks_source"]) if item.get("hooks_source") else None,
            shared_entries=tuple(item.get("shared_entries", [])),
            desktop_identity_file=Path(desktop) if isinstance(desktop, str) else None,
            trusted_projects=tuple(Path(value) for value in item.get("trusted_projects", [])),
        )
    profiles = {
        profile_id: Profile(
            id=profile_id,
            provider=item["provider"],
            home=Path(item["home"]),
            pools=tuple(item["pools"]),
            enabled=item.get("enabled", False),
            weight=item.get("weight", 1),
            max_concurrent=item.get("max_concurrent", 2),
            reserve_percent=item.get("reserve_percent", 15),
            safety_policy=item.get("safety_policy", "worker"),
        )
        for profile_id, item in raw["profiles"].items()
    }
    return Registry(raw["version"], settings, providers, profiles)

def quote(value):
    return json.dumps(str(value))

def save_registry(registry, path):
    path = Path(path)
    lines = [
        "version = 1",
        "",
        "[settings]",
        f"state_dir = {quote(registry.settings.state_dir)}",
        f"share_dir = {quote(registry.settings.share_dir)}",
        f"quota_binary = {quote(registry.settings.quota_binary)}",
        f"quota_binary_sha256 = {quote(registry.settings.quota_binary_sha256)}",
        f"quota_node_binary = {quote(registry.settings.quota_node_binary)}",
        f"quota_node_sha256 = {quote(registry.settings.quota_node_sha256)}",
        f"quota_release_tree_sha256 = {quote(registry.settings.quota_release_tree_sha256)}",
        f"quota_stale_seconds = {registry.settings.quota_stale_seconds}",
        f"quota_verification_grace_seconds = {registry.settings.quota_verification_grace_seconds}",
        f"lease_grace_seconds = {registry.settings.lease_grace_seconds}",
        f"active_lease_penalty = {registry.settings.active_lease_penalty}",
        f"lock_stale_seconds = {registry.settings.lock_stale_seconds}",
    ]
    for name in ("claude", "codex"):
        provider = registry.providers[name]
        lines += [
            "",
            f"[providers.{name}]",
            f"binary = {quote(provider.binary)}",
        ]
        if provider.base_home:
            lines.append(f"base_home = {quote(provider.base_home)}")
        if provider.hooks_source:
            lines.append(f"hooks_source = {quote(provider.hooks_source)}")
        if provider.desktop_identity_file:
            lines.append(f"desktop_identity_file = {quote(provider.desktop_identity_file)}")
        elif name == "claude":
            lines.append("desktop_identity_file = false")
        lines += [
            "shared_entries = [" + ", ".join(quote(x) for x in provider.shared_entries) + "]",
            "trusted_projects = [" + ", ".join(quote(x) for x in provider.trusted_projects) + "]",
        ]
    for profile_id in sorted(registry.profiles):
        profile = registry.profiles[profile_id]
        lines += [
            "",
            f"[profiles.{quote(profile_id)}]",
            f"provider = {quote(profile.provider)}",
            f"home = {quote(profile.home)}",
            "pools = [" + ", ".join(quote(x) for x in profile.pools) + "]",
            f"enabled = {'true' if profile.enabled else 'false'}",
            f"weight = {profile.weight}",
            f"max_concurrent = {profile.max_concurrent}",
            f"reserve_percent = {profile.reserve_percent}",
            f"safety_policy = {quote(profile.safety_policy)}",
        ]
    path.write_text("\\n".join(lines) + "\\n", encoding="utf-8")
    path.chmod(0o600)
    return path
"""

OLD_MODELS_SOURCE = MODELS_SOURCE.replace(
    '    quota_node_binary: Path\n    quota_binary_sha256: str = ""\n'
    '    quota_node_sha256: str = ""\n'
    '    quota_release_tree_sha256: str = ""\n',
    "",
).replace(
    "    desktop_identity_file: Path | None = None\n",
    "",
).replace(
    '    safety_policy: str = "worker"\n',
    "",
).replace(
    "    config_path: Path | None = None\n",
    "",
)
OLD_CONFIG_SOURCE = CONFIG_SOURCE.replace(
    '        quota_node_binary=Path(settings_raw["quota_node_binary"]),\n'
    '        quota_binary_sha256=settings_raw.get("quota_binary_sha256", ""),\n'
    '        quota_node_sha256=settings_raw.get("quota_node_sha256", ""),\n'
    '        quota_release_tree_sha256=settings_raw.get("quota_release_tree_sha256", ""),\n',
    "",
).replace(
    '        f"quota_binary_sha256 = {quote(registry.settings.quota_binary_sha256)}",\n'
    '        f"quota_node_binary = {quote(registry.settings.quota_node_binary)}",\n'
    '        f"quota_node_sha256 = {quote(registry.settings.quota_node_sha256)}",\n'
    '        f"quota_release_tree_sha256 = {quote(registry.settings.quota_release_tree_sha256)}",\n',
    "",
).replace(
    "            desktop_identity_file=Path(desktop) if isinstance(desktop, str) else None,\n",
    "",
).replace(
    '            safety_policy=item.get("safety_policy", "worker"),\n',
    "",
).replace(
    '        if provider.desktop_identity_file:\n'
    '            lines.append(f"desktop_identity_file = {quote(provider.desktop_identity_file)}")\n'
    '        elif name == "claude":\n'
    '            lines.append("desktop_identity_file = false")\n',
    "",
).replace(
    '            f"safety_policy = {quote(profile.safety_policy)}",\n',
    "",
)

PROVISION_SOURCE = """\
import hashlib
import json
import os
import stat
from pathlib import Path

def _bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\\n").encode("utf-8")

def closed_claude_state_payload(registry):
    roots = sorted(str(path) for path in registry.providers["claude"].trusted_projects)
    return {
        "hasCompletedOnboarding": True,
        "projects": {
            root: {
                "hasCompletedProjectOnboarding": True,
                "hasTrustDialogAccepted": True,
            }
            for root in roots
        },
    }

def provision_plan(registry, profile_id):
    profile = registry.profiles[profile_id]
    if profile.safety_policy != "worker":
        raise ValueError("reserve profiles cannot be provisioned")
    if registry.config_path is None:
        # The real provision API composes managed hook commands from the loaded
        # registry path and refuses a pathless registry; mirror that contract.
        raise ValueError("loaded registry path is unavailable for managed hooks")
    common = [
        ".agent-fleet-hooks.json",
        ".agent-fleet-profile.json",
        ".agent-fleet-provider-binary.json",
    ]
    provider_paths = (
        [".claude.json", "settings.json"]
        if profile.provider == "claude"
        else ["config.toml", "hooks.json"]
    )
    entries = [{"relative_path": ".", "type": "dir", "mode": "0700"}]
    for path in [*common, *provider_paths]:
        payload = (
            _bytes(closed_claude_state_payload(registry))
            if path == ".claude.json"
            else _bytes({"profile": profile_id, "path": path})
        )
        entries.append({
            "relative_path": path,
            "type": "file",
            "mode": "0600",
            "sha256": hashlib.sha256(payload).hexdigest(),
        })
    entries.append({"relative_path": "hooks", "type": "dir", "mode": "0700"})
    provider = registry.providers[profile.provider]
    for path in provider.shared_entries:
        entries.append({
            "relative_path": path,
            "type": "symlink",
            "target": str(provider.base_home / path),
        })
    return {
        "schema": 1,
        "profile": profile_id,
        "provider": profile.provider,
        "home": str(profile.home),
        "safety_policy": profile.safety_policy,
        "entries": sorted(entries, key=lambda value: value["relative_path"]),
    }

def verify_provisioned_profile(registry, profile_id):
    plan = provision_plan(registry, profile_id)
    encoded = _bytes(plan)
    actual = []
    mismatches = []
    home = Path(plan["home"])
    for expected in plan["entries"]:
        path = home if expected["relative_path"] == "." else home / expected["relative_path"]
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            mismatches.append({"relative_path": expected["relative_path"], "reason": "absent"})
            continue
        if stat.S_ISREG(info.st_mode):
            observed = {
                "relative_path": expected["relative_path"],
                "type": "file",
                "mode": f"{stat.S_IMODE(info.st_mode):04o}",
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        elif stat.S_ISDIR(info.st_mode):
            observed = {
                "relative_path": expected["relative_path"],
                "type": "dir",
                "mode": f"{stat.S_IMODE(info.st_mode):04o}",
            }
        elif stat.S_ISLNK(info.st_mode):
            observed = {
                "relative_path": expected["relative_path"],
                "type": "symlink",
                "target": os.readlink(path),
            }
        else:
            mismatches.append({"relative_path": expected["relative_path"], "reason": "type"})
            continue
        actual.append(observed)
        if observed != expected:
            mismatches.append({"relative_path": expected["relative_path"], "reason": "mismatch"})
    return {
        "schema": 1,
        "profile": profile_id,
        "provider": plan["provider"],
        "status": "verified" if not mismatches else "mismatch",
        "plan_sha256": hashlib.sha256(encoded).hexdigest(),
        "actual_entries": actual,
        "mismatches": mismatches,
    }
"""

IDENTITY_SOURCE = """\
import json

def identity_bundle_path(registry, provider):
    return registry.settings.state_dir / "identity-bindings" / (provider + "-bundle.json")

def verify_identity_bundle(registry, provider, *, compare_live_external=False):
    path = identity_bundle_path(registry, provider)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema") != 1 or payload.get("provider") != provider:
        return {"provider": provider, "status": "invalid", "reason": "identity bundle mismatch"}
    return {"provider": provider, "status": "verified", "reason": None}
"""


def wheel_record_line(root: Path, relative: str) -> str:
    payload = (root / relative).read_bytes()
    digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).decode(
        "ascii"
    ).rstrip("=")
    return f"{relative},sha256={digest},{len(payload)}"


class CutoverPreparationFixture:
    def __init__(self) -> None:
        real_temp_root = Path(os.path.realpath(tempfile.gettempdir()))
        self._temporary = tempfile.TemporaryDirectory(
            prefix="bridge-cutover-prep-test-", dir=real_temp_root
        )
        self.root = Path(self._temporary.name) / "fixture"
        self.root.mkdir(mode=0o700)
        self.agent_root = self.root / "agent-fleet"
        self.quota_root = self.root / "quota-axi"
        self.config_root = self.root / "config"
        self.input_root = self.root / "input"
        self.output_parent = self.root / "output"
        self.project = self.root / "relvino"
        self.scratch = self.root / "scratch"
        for path in (
            self.agent_root,
            self.quota_root,
            self.config_root,
            self.input_root,
            self.output_parent,
            self.project,
            self.scratch,
        ):
            path.mkdir(mode=0o700)
        self.snapshot_parent = self.scratch / "worker-state"
        self.snapshot_parent.mkdir(mode=0o700)
        self.bundle_dir = self.output_parent / "bundle"

        self.agent_old = self.agent_root / "releases" / "0.1.5-old"
        self.agent_initial = self.agent_root / "releases" / "0.1.5-unsealed"
        self.agent_new = self.agent_root / "releases" / "0.2.0-new"
        self.quota_old = self.quota_root / "releases" / "0.1.5-old"
        self.quota_initial = self.quota_root / "releases" / "0.1.5-unsealed"
        self.quota_new = self.quota_root / "releases" / "0.1.7-new"
        for path in (self.agent_old, self.agent_new, self.quota_old, self.quota_new):
            path.mkdir(parents=True, mode=0o755)
        (self.agent_old / "identity.txt").write_text("agent-fleet 0.1.5\n", encoding="utf-8")
        self.agent_old_executable = self._compile_native_launcher(
            self.agent_old, "0.1.5", 1
        )
        self._compile_python_runtime(self.agent_old, "3.11.14")
        self._create_old_agent_package()
        (self.quota_old / "identity.txt").write_text("quota-axi 0.1.5\n", encoding="utf-8")
        self.quota_initial_js = self.quota_initial / "quota.js"
        os.symlink("releases/0.1.5-unsealed", self.agent_root / "current")
        os.symlink("releases/0.1.5-unsealed", self.quota_root / "current")
        self.operator_bin = self.root / "operator-bin"
        self.operator_bin.mkdir(mode=0o700)
        self.operator_front_door = self.operator_bin / "agent-fleet"
        self.operator_front_initial_target = "../agent-fleet/current/bin/agent-fleet"
        os.symlink(self.operator_front_initial_target, self.operator_front_door)

        self.backend = self.config_root / "backend"
        self.backend.write_text("tmux\n", encoding="utf-8")
        self.backend.chmod(0o600)
        self.routing = self.config_root / "account-routing-mode"
        self.quiet_state = self.root / "fleet-state"
        self.quiet_state.mkdir(mode=0o700)
        self.quiet_paths = tuple(
            self.quiet_state / name for name in ("leases", "sessions", "locks")
        )
        for path in self.quiet_paths:
            path.mkdir(mode=0o700)
        self.ps_binary = self.root / "fake-ps"
        self.ps_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.ps_binary.chmod(0o755)

        self._create_agent_release()
        self._create_quota_release(self.quota_old, "0.1.5")
        self._create_quota_release(self.quota_new, "0.1.7")
        self._create_agent_build_manifests()
        self.baseline = self.input_root / "accounts.toml"
        self.live = self.config_root / "accounts.toml"
        self._write_baseline()
        self.live.write_bytes(self.baseline.read_bytes())
        self.live.chmod(0o600)
        self.spec_path = self.root / "prepare.json"
        self.spec = self._spec()
        self.write_spec()

    def cleanup(self) -> None:
        self._temporary.cleanup()

    def _create_agent_release(self) -> None:
        pythonpath = self.agent_new / "site-packages"
        package = pythonpath / "agent_fleet"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text('__version__ = "0.2.0"\n', encoding="utf-8")
        (package / "models.py").write_text(MODELS_SOURCE, encoding="utf-8")
        (package / "config.py").write_text(CONFIG_SOURCE, encoding="utf-8")
        (package / "enrollment.py").write_text("# fixture enrollment\n", encoding="utf-8")
        (package / "provision.py").write_text(PROVISION_SOURCE, encoding="utf-8")
        (package / "identity.py").write_text(IDENTITY_SOURCE, encoding="utf-8")
        (package / "recovery.py").write_text("# fixture recovery\n", encoding="utf-8")
        (package / "__main__.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
        dist_info = pythonpath / "agent_fleet-0.2.0.dist-info"
        dist_info.mkdir()
        (dist_info / "METADATA").write_text(
            "Metadata-Version: 2.3\nName: agent-fleet\nVersion: 0.2.0\n",
            encoding="utf-8",
        )
        (dist_info / "RECORD").write_text(
            "\n".join(
                [
                    wheel_record_line(pythonpath, relative)
                    for relative in (
                        "agent_fleet/__init__.py",
                        "agent_fleet/__main__.py",
                        "agent_fleet/config.py",
                        "agent_fleet/enrollment.py",
                        "agent_fleet/identity.py",
                        "agent_fleet/models.py",
                        "agent_fleet/provision.py",
                        "agent_fleet/recovery.py",
                        "agent_fleet-0.2.0.dist-info/METADATA",
                    )
                ]
                + ["agent_fleet-0.2.0.dist-info/RECORD,,"]
            )
            + "\n",
            encoding="utf-8",
        )
        (self.agent_new / "build").mkdir()
        (self.agent_new / "build" / "source.whl").write_bytes(b"candidate wheel fixture\n")
        (self.agent_new / "build" / "agent-fleet-front-door.c").write_text(
            "/* fixture native dispatcher source */\n", encoding="utf-8"
        )
        self._compile_python_runtime(self.agent_new, "3.11.14")
        launcher_module = self.agent_new / "launcher.py"
        launcher_module.write_bytes(prepare._expected_agent_fleet_module())
        launcher_module.chmod(0o644)
        self._compile_native_launcher(self.agent_new, "0.2.0", 2)

    def _compile_python_runtime(self, release: Path, version: str) -> Path:
        source = release / "build" / "python-runtime.c"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(
            textwrap.dedent(
                f"""\
                #include <stdio.h>
                int main(void) {{
                    puts("Python {version}");
                    return 0;
                }}
                """
            ),
            encoding="utf-8",
        )
        runtime = release / "bin" / "python3.11"
        runtime.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(source), "-o", str(runtime)],
            check=True,
            capture_output=True,
            text=True,
        )
        runtime.chmod(0o755)
        return runtime

    def _compile_native_launcher(
        self, release: Path, version: str, contract: int
    ) -> Path:
        source = release / "build" / "agent-fleet-launcher.c"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(
            textwrap.dedent(
                f"""\
                #include <stdio.h>
                int main(void) {{
                    puts("{{\\\"cli_version\\\":\\\"{version}\\\",\\\"contract_version\\\":{contract}}}");
                    return 0;
                }}
                """
            ),
            encoding="utf-8",
        )
        executable = release / "bin" / "agent-fleet"
        executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(source), "-o", str(executable)],
            check=True,
            capture_output=True,
            text=True,
        )
        executable.chmod(0o755)
        self._sign_hardened(executable)
        operator = release / "operator" / "agent-fleet"
        operator.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(source), "-o", str(operator)],
            check=True,
            capture_output=True,
            text=True,
        )
        self._sign_hardened(operator)
        operator.chmod(0o555)
        return executable

    def _create_old_agent_package(self) -> None:
        package = self.agent_old / "site-packages" / "agent_fleet"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text('__version__ = "0.1.5"\n', encoding="utf-8")
        (package / "models.py").write_text(OLD_MODELS_SOURCE, encoding="utf-8")
        (package / "config.py").write_text(OLD_CONFIG_SOURCE, encoding="utf-8")
        (package / "__main__.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
        (self.agent_old / "launcher.py").write_bytes(prepare._expected_agent_fleet_module())
        dist_info = self.agent_old / "site-packages" / "agent_fleet-0.1.5.dist-info"
        dist_info.mkdir()
        (dist_info / "METADATA").write_text(
            "Metadata-Version: 2.3\nName: agent-fleet\nVersion: 0.1.5\n",
            encoding="utf-8",
        )
        (dist_info / "RECORD").write_text(
            "\n".join(
                [
                    wheel_record_line(self.agent_old / "site-packages", relative)
                    for relative in (
                        "agent_fleet/__init__.py",
                        "agent_fleet/__main__.py",
                        "agent_fleet/config.py",
                        "agent_fleet/models.py",
                        "agent_fleet-0.1.5.dist-info/METADATA",
                    )
                ]
                + ["agent_fleet-0.1.5.dist-info/RECORD,,"]
            )
            + "\n",
            encoding="utf-8",
        )
        (self.agent_old / "build" / "source.whl").write_bytes(b"rollback wheel fixture\n")
        (self.agent_old / "build" / "agent-fleet-front-door.c").write_text(
            "/* fixture native dispatcher source */\n", encoding="utf-8"
        )

    def _sign_hardened(self, path: Path) -> None:
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--options",
                "runtime",
                "--timestamp=none",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def _create_quota_release(self, release: Path, version: str) -> None:
        node_source = release / "build" / "fixture-node.c"
        node_source.parent.mkdir(parents=True, exist_ok=True)
        node_source.write_text(
            textwrap.dedent(
                f"""\
                #include <stdio.h>
                #include <stdlib.h>
                #include <string.h>
                int main(int argc, char **argv) {{
                    if (argc == 2 && strcmp(argv[1], "--version") == 0) {{
                        puts("v20.19.0");
                        return 0;
                    }}
                    const char *blocked[] = {{
                        "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "PYTHONPATH",
                        "BASH_ENV", "MALLOC_CHECK_", "ELECTRON_RUN_AS_NODE",
                        "GCONV_PATH", "LOCPATH", "NLSPATH", "SSLKEYLOGFILE",
                        "PERL5OPT", NULL
                    }};
                    for (int i = 0; blocked[i] != NULL; ++i) {{
                        if (getenv(blocked[i]) != NULL) return 91;
                    }}
                    if (argc == 3 && strcmp(argv[2], "--version") == 0) {{
                        /* One pinned Node runtime serves both sealed releases.
                         * The real Node binary obtains the package version from
                         * the invoked JS; this fixture derives the same answer
                         * from the release-local entrypoint path. */
                        puts(strstr(argv[1], "0.1.5-old") != NULL
                                 ? "quota-axi 0.1.5"
                                 : "quota-axi 0.1.7");
                        return 0;
                    }}
                    return 2;
                }}
                """
            ),
            encoding="utf-8",
        )
        node = release / "runtime" / "node"
        node.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(node_source), "-o", str(node)],
            check=True,
            capture_output=True,
            text=True,
        )
        node.chmod(0o755)

        wrapper_source = release / "build" / "quota-axi-launcher.c"
        wrapper_source.write_text(
            textwrap.dedent(
                f"""{''}\
                #include <limits.h>
                #include <stdio.h>
                #include <stdlib.h>
                #include <string.h>
                #include <unistd.h>
                extern char **environ;
                static int blocked(const char *name) {{
                    const char *exact[] = {{
                        "ENV", "GCONV_PATH", "LOCPATH", "NLSPATH", "PERL5OPT",
                        "RUBYOPT", "SSLKEYLOGFILE", NULL
                    }};
                    const char *prefix[] = {{
                        "BASH_", "DYLD_", "ELECTRON_", "LD_", "MALLOC_",
                        "NODE_", "NPM_CONFIG_", "PERL5", "PYTHON", "RUBY",
                        "npm_config_", NULL
                    }};
                    for (int i = 0; exact[i] != NULL; ++i)
                        if (strcmp(name, exact[i]) == 0) return 1;
                    for (int i = 0; prefix[i] != NULL; ++i)
                        if (strncmp(name, prefix[i], strlen(prefix[i])) == 0) return 1;
                    return 0;
                }}
                int main(int argc, char **argv) {{
                    (void)argc;
                    int removed;
                    do {{
                        removed = 0;
                        for (char **item = environ; *item != NULL; ++item) {{
                            const char *equals = strchr(*item, '=');
                            if (equals == NULL) continue;
                            size_t length = (size_t)(equals - *item);
                            if (length >= 256) return 126;
                            char name[256];
                            memcpy(name, *item, length);
                            name[length] = '\\0';
                            if (blocked(name)) {{ unsetenv(name); removed = 1; break; }}
                        }}
                    }} while (removed);
                    if (setenv("PATH", "/usr/bin:/bin", 1) != 0) return 126;
                    char executable[PATH_MAX];
                    if (realpath(argv[0], executable) == NULL) return 126;
                    char *slash = strrchr(executable, '/');
                    if (slash == NULL) return 126;
                    *slash = '\0';
                    slash = strrchr(executable, '/');
                    if (slash == NULL) return 126;
                    *slash = '\0';
                    char node[PATH_MAX];
                    char script[PATH_MAX];
                    snprintf(node, sizeof(node), "%s/runtime/node", executable);
                    snprintf(script, sizeof(script),
                             "%s/node_modules/quota-axi/dist/bin/quota-axi.js", executable);
                    char *child[] = {{node, script, "--version", NULL}};
                    execv(node, child);
                    return 127;
                }}
                """
            ),
            encoding="utf-8",
        )
        wrapper = release / "bin" / "quota-axi"
        wrapper.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(wrapper_source), "-o", str(wrapper)],
            check=True,
            capture_output=True,
            text=True,
        )
        wrapper.chmod(0o755)
        self._sign_hardened(wrapper)

        package = release / "node_modules" / "quota-axi"
        entrypoint = package / "dist" / "bin" / "quota-axi.js"
        entrypoint.parent.mkdir(parents=True)
        entrypoint.write_text("console.log('quota fixture');\n", encoding="utf-8")
        entrypoint.chmod(0o444)
        (package / "dist" / "runtime.js").write_text(
            "export const runtime = 'bound';\n",
            encoding="utf-8",
        )
        (package / "package.json").write_text(
            json.dumps(
                {
                    "name": "quota-axi",
                    "version": version,
                    "bin": {"quota-axi": "dist/bin/quota-axi.js"},
                }
            ),
            encoding="utf-8",
        )
        (release / "package-lock.json").write_text(
            json.dumps(
                {
                    "lockfileVersion": 3,
                    "packages": {
                        "": {"dependencies": {"quota-axi": version}},
                        "node_modules/quota-axi": {"version": version},
                    },
                }
            ),
            encoding="utf-8",
        )
        closure_entries = []
        for closure_file in sorted(
            (entrypoint, package / "dist" / "runtime.js"),
            key=lambda path: str(path.relative_to(release)).encode("utf-8"),
        ):
            closure_entries.append(
                {
                    "path": str(closure_file.relative_to(release)),
                    "mode": f"{stat.S_IMODE(closure_file.stat().st_mode):04o}",
                    "sha256": prepare._sha256(closure_file),
                }
            )
        runtime_manifest = release / "build" / "runtime-closure.json"
        runtime_manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "format": "bridge-runtime-closure-v1",
                    "entries": closure_entries,
                },
                indent=2,
                sort_keys=True,
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        quota_build_proof = release / "build" / "quota-build-proof.json"
        quota_build_proof.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "kind": "quota-axi-offline-deterministic-build",
                    "role": "candidate" if version == "0.1.7" else "rollback",
                    "version": version,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (release / "build" / "provenance.json").write_text(
            json.dumps(
                {
                    "schema_version": 2,
                    "role": "quota_axi",
                    "version": version,
                    "source_commit": ("c" if version == "0.1.7" else "d") * 40,
                    "source_tree_sha256": ("e" if version == "0.1.7" else "f") * 64,
                    "artifacts": {
                        "launcher": {
                            "path": str(wrapper.relative_to(release)),
                            "sha256": prepare._sha256(wrapper),
                        },
                        "node": {
                            "path": str(node.relative_to(release)),
                            "sha256": prepare._sha256(node),
                        },
                        "entrypoint": {
                            "path": str(entrypoint.relative_to(release)),
                            "sha256": prepare._sha256(entrypoint),
                        },
                        "package_lock": {
                            "path": "package-lock.json",
                            "sha256": prepare._sha256(release / "package-lock.json"),
                        },
                        "runtime_manifest": {
                            "path": str(runtime_manifest.relative_to(release)),
                            "sha256": prepare._sha256(runtime_manifest),
                        },
                        "quota_build_proof": {
                            "path": str(quota_build_proof.relative_to(release)),
                            "sha256": prepare._sha256(quota_build_proof),
                        },
                    },
                },
                indent=2,
                sort_keys=True,
            ),
            encoding="utf-8",
        )

    def _create_agent_build_manifests(self) -> None:
        driver = prepare._load_driver(DRIVER)
        self.agent_build_manifest = self.root / "sealed-runtime-proof-manifest.json"
        builder_path = SCRIPT_DIR / "build_sealed_bridge_runtimes.py"
        bootstrap_path = SCRIPT_DIR / "sealed_agent_fleet_bootstrap.py"
        # The production builder copies one exact pinned runtime into both role
        # releases.  Keep the fixture faithful to that identity contract rather
        # than compiling path-dependent Mach-O binaries independently.
        (self.agent_old / "bin/python3.11").write_bytes(
            (self.agent_new / "bin/python3.11").read_bytes()
        )
        (self.agent_old / "bin/python3.11").chmod(0o755)
        for release in (self.agent_new, self.agent_old):
            (release / "lib").mkdir(exist_ok=True)
            (release / "lib/stdlib.py").write_text(
                "# pinned fixture stdlib\n", encoding="utf-8"
            )
        (self.quota_old / "runtime/node").write_bytes(
            (self.quota_new / "runtime/node").read_bytes()
        )
        (self.quota_old / "runtime/node").chmod(0o755)
        rollback_quota_provenance = self.quota_old / "build/provenance.json"
        rollback_quota_value = json.loads(
            rollback_quota_provenance.read_text(encoding="utf-8")
        )
        rollback_quota_value["artifacts"]["node"]["sha256"] = prepare._sha256(
            self.quota_old / "runtime/node"
        )
        rollback_quota_provenance.write_text(
            json.dumps(rollback_quota_value, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        pinned_python = self.root / "pinned-python"
        (pinned_python / "bin").mkdir(parents=True)
        (pinned_python / "lib").mkdir()
        (pinned_python / "bin/python3.11").write_bytes(
            (self.agent_new / "bin/python3.11").read_bytes()
        )
        (pinned_python / "bin/python3.11").chmod(0o700)
        (pinned_python / "lib/stdlib.py").write_text(
            "# pinned fixture stdlib\n", encoding="utf-8"
        )
        python_tree_sha256 = prepare._runtime_source_tree_sha256(pinned_python)
        python_transformations = prepare._runtime_transformations(pinned_python)
        pinned_node = self.root / "pinned-node"
        pinned_node.write_bytes((self.quota_new / "runtime/node").read_bytes())
        pinned_node.chmod(0o700)
        agent_source = self.root / "retained-agent-source"
        quota_source = self.root / "retained-quota-source"
        agent_source.mkdir(mode=0o700)
        quota_source.mkdir(mode=0o700)
        quota_packages: dict[str, Path] = {}
        for role_name in ("candidate", "rollback"):
            package = self.root / f"quota-{role_name}.tgz"
            package.write_bytes(f"quota-{role_name}\n".encode("utf-8"))
            quota_packages[role_name] = package
        system_tools = {
            name: {
                "path": f"/usr/bin/{name}",
                "sha256": prepare._sha256(
                    Path(f"/usr/bin/{name}"), allow_root_hardlinks=True
                ),
            }
            for name in ("clang", "codesign", "file", "git", "otool", "xattr")
        }
        driver_pin = {"path": str(DRIVER), "sha256": prepare._sha256(DRIVER)}
        builder_input = {
            "schema_version": 2,
            "output_root": str(self.root),
            "proof_manifest": str(self.agent_build_manifest),
            "operator_front_door": str(self.operator_front_door),
            "transaction_driver": driver_pin,
            "tools": system_tools,
            "python_runtime": {
                "root": str(pinned_python),
                "version": "3.11.14",
                "binary_sha256": prepare._sha256(
                    pinned_python / "bin/python3.11"
                ),
                "tree_sha256": python_tree_sha256,
            },
            "node_runtime": {
                "binary": str(pinned_node),
                "version": "20.19.0",
                "sha256": prepare._sha256(pinned_node),
            },
            "agent_fleet": {
                "candidate": {
                    "role": "candidate",
                    "release_path": str(self.agent_new.relative_to(self.root)),
                    "version": "0.2.0",
                    "contract_version": 2,
                    "source_repo": str(agent_source),
                    "source_commit": "a" * 40,
                    "source_tree_sha256": "9" * 64,
                    "source_subdirectory": ".",
                    "wheel": str(self.agent_new / "build/source.whl"),
                    "wheel_sha256": prepare._sha256(
                        self.agent_new / "build/source.whl"
                    ),
                },
                "rollback": {
                    "role": "rollback",
                    "release_path": str(self.agent_old.relative_to(self.root)),
                    "version": "0.1.5",
                    "contract_version": 1,
                    "source_repo": str(agent_source),
                    "source_commit": "b" * 40,
                    "source_tree_sha256": "9" * 64,
                    "source_subdirectory": ".",
                    "wheel": str(self.agent_old / "build/source.whl"),
                    "wheel_sha256": prepare._sha256(
                        self.agent_old / "build/source.whl"
                    ),
                },
            },
            "quota_axi": {},
        }
        for role_name, release, version, commit, tree in (
            ("candidate", self.quota_new, "0.1.7", "c" * 40, "e" * 64),
            ("rollback", self.quota_old, "0.1.5", "d" * 40, "f" * 64),
        ):
            builder_input["quota_axi"][role_name] = {
                "role": role_name,
                "release_path": str(release.relative_to(self.root)),
                "version": version,
                "source_repo": str(quota_source),
                "source_commit": commit,
                "source_tree_sha256": tree,
                "package_tarball": str(quota_packages[role_name]),
                "package_sha256": prepare._sha256(quota_packages[role_name]),
                "package_lock": str(release / "package-lock.json"),
                "package_lock_sha256": prepare._sha256(
                    release / "package-lock.json"
                ),
                "build_proof": str(release / "build/quota-build-proof.json"),
                "build_proof_sha256": prepare._sha256(
                    release / "build/quota-build-proof.json"
                ),
                "dependencies": [],
            }
        self.builder_input_manifest = self.root / "sealed-runtime-builder-input.json"
        self.builder_input_manifest.write_text(
            json.dumps(builder_input, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.builder_input_manifest.chmod(0o600)

        def generic_proof(root: Path, relative: str) -> dict[str, object]:
            value = driver.compute_release_proof(root, relative)
            return {
                "path": value["relative_path"],
                "sha256": value["sha256"],
                "mode": value["mode"],
                "nlink": 1,
            }

        def signature(binary: Path) -> dict[str, object]:
            return {
                "valid": True,
                "hardened_runtime": True,
                "verify_strict": True,
                "details_sha256": prepare._verify_hardened_signature(
                    binary, "fixture launcher"
                ),
            }

        def agent_record(
            root: Path,
            role: str,
            version: str,
            contract: int,
            commit: str,
            proof_paths: list[str],
        ) -> dict[str, object]:
            launcher = root / "bin" / "agent-fleet"
            source = root / "build" / "agent-fleet-launcher.c"
            python = root / "bin" / "python3.11"
            wheel = root / "build" / "source.whl"
            provenance = root / "build" / "provenance.json"
            provenance.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "role": "agent_fleet",
                        "version": version,
                        "source_commit": commit,
                        "source_tree_sha256": "9" * 64,
                        "python_runtime_source_tree_sha256": python_tree_sha256,
                        "python_runtime_transformations": python_transformations,
                        "artifacts": {
                            "launcher": {
                                "path": str(launcher.relative_to(root)),
                                "sha256": prepare._sha256(launcher),
                            },
                            "python": {
                                "path": str(python.relative_to(root)),
                                "sha256": prepare._sha256(python),
                            },
                            "bootstrap": {
                                "path": "launcher.py",
                                "sha256": prepare._sha256(root / "launcher.py"),
                            },
                            "wheel": {
                                "path": str(wheel.relative_to(root)),
                                "sha256": prepare._sha256(wheel),
                            },
                        },
                    },
                    indent=2,
                    sort_keys=True,
                ),
                encoding="utf-8",
            )
            tree = driver.compute_release_tree_sha256(root)
            launcher_proof = generic_proof(root, "bin/agent-fleet")
            front_source = root / "operator" / "agent-fleet"
            return {
                "role": role,
                "release_path": str(root.relative_to(self.root)),
                "version": version,
                "contract_version": contract,
                "source_commit": commit,
                "tree_sha256": tree,
                "rebuild_tree_sha256": tree,
                "relocated_tree_sha256": tree,
                "proofs": [generic_proof(root, relative) for relative in proof_paths],
                "launcher": {
                    **launcher_proof,
                    "binary_format": "Mach-O fixture",
                    "source_path": str(source.relative_to(root)),
                    "source_sha256": prepare._sha256(source),
                    "dependencies": prepare._native_dependencies(launcher),
                    "signature": signature(launcher),
                    "canonical_physical_only": True,
                    "env_scrub": {
                        "exact": [
                            *prepare.REQUIRED_INJECTION_ENVIRONMENT_EXACT_SCRUB,
                            *prepare.REQUIRED_AGENT_FLEET_ENVIRONMENT_SCRUB,
                        ],
                        "prefixes": [
                            *prepare.REQUIRED_INJECTION_ENVIRONMENT_PREFIX_SCRUB,
                            *prepare.REQUIRED_AGENT_FLEET_ENVIRONMENT_PREFIX_SCRUB,
                        ],
                    },
                },
                "python": {
                    "path": str(python.relative_to(root)),
                    "sha256": prepare._sha256(python),
                    "version": "3.11.14",
                },
                "wheel": {
                    "path": str(wheel.relative_to(root)),
                    "sha256": prepare._sha256(wheel),
                },
                "provenance": {
                    "path": str(provenance.relative_to(root)),
                    "sha256": prepare._sha256(provenance),
                },
                "invocation": {
                    "managed_relative_path": "bin/agent-fleet",
                    "config_relative_path": "bin/agent-fleet",
                    "hooks_relative_path": "bin/agent-fleet",
                    "operator_front_door": {
                        "kind": "native_regular_file",
                        "install_scope": "user_local_bin",
                        "installed_name": "agent-fleet",
                        "source_path": str(front_source.relative_to(root)),
                        "source_sha256": prepare._sha256(front_source),
                        "target_binding": prepare._sha256(launcher),
                        "symlink_allowed": False,
                    },
                },
                "probes": {
                    "version": version,
                    "contract": contract,
                    "hostile_environment": True,
                    "relocated": True,
                    "installed_topology": True,
                },
            }

        def quota_record(
            root: Path,
            role: str,
            version: str,
            commit: str,
            proof_paths: list[str],
        ) -> dict[str, object]:
            launcher = root / "bin" / "quota-axi"
            source = root / "build" / "quota-axi-launcher.c"
            lock = root / "package-lock.json"
            provenance = root / "build" / "provenance.json"
            runtime_manifest = root / "build" / "runtime-closure.json"
            runtime_payload = json.loads(runtime_manifest.read_text(encoding="utf-8"))
            closure_bytes = json.dumps(
                runtime_payload["entries"],
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
            closure_sha256 = hashlib.sha256(
                b"bridge-runtime-closure-v1\0" + closure_bytes
            ).hexdigest()
            tree = driver.compute_release_tree_sha256(root)
            launcher_proof = generic_proof(root, "bin/quota-axi")
            node_proof = generic_proof(root, "runtime/node")
            entrypoint_proof = generic_proof(
                root, "node_modules/quota-axi/dist/bin/quota-axi.js"
            )
            return {
                "role": role,
                "release_path": str(root.relative_to(self.root)),
                "version": version,
                "source_commit": commit,
                "tree_sha256": tree,
                "rebuild_tree_sha256": tree,
                "relocated_tree_sha256": tree,
                "proofs": [generic_proof(root, relative) for relative in proof_paths],
                "launcher": {
                    **launcher_proof,
                    "binary_format": "Mach-O fixture",
                    "source_path": str(source.relative_to(root)),
                    "source_sha256": prepare._sha256(source),
                    "dependencies": prepare._native_dependencies(launcher),
                    "signature": signature(launcher),
                    "fixed_path": "/usr/bin:/bin",
                    "env_scrub": {
                        "exact": list(
                            prepare.REQUIRED_INJECTION_ENVIRONMENT_EXACT_SCRUB
                        ),
                        "prefixes": list(
                            prepare.REQUIRED_INJECTION_ENVIRONMENT_PREFIX_SCRUB
                        ),
                    },
                    "runtime_manifest_sha256": prepare._sha256(runtime_manifest),
                },
                "node": {
                    **node_proof,
                    "version": "20.19.0",
                    "signature_state": "contained-internal-unchanged",
                    "operational": False,
                },
                "entrypoint": {**entrypoint_proof, "operational": False},
                "package_lock": {
                    "path": str(lock.relative_to(root)),
                    "sha256": prepare._sha256(lock),
                },
                "runtime_manifest": {
                    "path": str(runtime_manifest.relative_to(root)),
                    "sha256": prepare._sha256(runtime_manifest),
                    "format": "bridge-runtime-closure-v1",
                    "entries_count": len(runtime_payload["entries"]),
                    "closure_tree_sha256": closure_sha256,
                },
                "provenance": {
                    "path": str(provenance.relative_to(root)),
                    "sha256": prepare._sha256(provenance),
                },
                "invocation": {
                    "operational_relative_path": "bin/quota-axi",
                    "raw_node_forbidden": True,
                    "raw_entrypoint_forbidden": True,
                },
                "probes": {
                    "version": f"quota-axi {version}",
                    "help": True,
                    "hostile_environment": True,
                    "relocated": True,
                    "canonical_path": True,
                },
            }

        agent_candidate_proofs = [
            "bin/agent-fleet",
            "bin/python3.11",
            "launcher.py",
            "build/agent-fleet-launcher.c",
            "build/agent-fleet-front-door.c",
            "operator/agent-fleet",
            "build/provenance.json",
            "build/source.whl",
            "site-packages/agent_fleet/__init__.py",
            "site-packages/agent_fleet/__main__.py",
            "site-packages/agent_fleet/config.py",
            "site-packages/agent_fleet/enrollment.py",
            "site-packages/agent_fleet/identity.py",
            "site-packages/agent_fleet/models.py",
            "site-packages/agent_fleet/provision.py",
            "site-packages/agent_fleet/recovery.py",
            "site-packages/agent_fleet-0.2.0.dist-info/METADATA",
            "site-packages/agent_fleet-0.2.0.dist-info/RECORD",
        ]
        agent_rollback_proofs = [
            "identity.txt",
            "bin/agent-fleet",
            "bin/python3.11",
            "launcher.py",
            "build/agent-fleet-launcher.c",
            "build/agent-fleet-front-door.c",
            "operator/agent-fleet",
            "build/provenance.json",
            "build/source.whl",
            "site-packages/agent_fleet/__init__.py",
            "site-packages/agent_fleet/__main__.py",
            "site-packages/agent_fleet/config.py",
            "site-packages/agent_fleet/models.py",
            "site-packages/agent_fleet-0.1.5.dist-info/METADATA",
            "site-packages/agent_fleet-0.1.5.dist-info/RECORD",
        ]
        quota_proofs = [
            "bin/quota-axi",
            "runtime/node",
            "node_modules/quota-axi/dist/bin/quota-axi.js",
            "node_modules/quota-axi/package.json",
            "package-lock.json",
            "build/quota-axi-launcher.c",
            "build/provenance.json",
            "build/quota-build-proof.json",
            "build/runtime-closure.json",
        ]
        canonical_builder_input = (
            json.dumps(
                builder_input, indent=2, sort_keys=True, ensure_ascii=False
            )
            + "\n"
        ).encode("utf-8")
        build_inputs = {
            "schema_version": 1,
            "manifest_path": str(self.builder_input_manifest),
            "manifest": builder_input,
            "manifest_sha256": prepare._sha256(self.builder_input_manifest),
            "manifest_canonical_sha256": hashlib.sha256(
                canonical_builder_input
            ).hexdigest(),
            "builder": {
                "path": str(builder_path),
                "sha256": prepare._sha256(builder_path),
            },
            "bootstrap": {
                "path": str(bootstrap_path),
                "sha256": prepare._sha256(bootstrap_path),
            },
            "transaction_driver": driver_pin,
            "tools": system_tools,
            "python_runtime": {
                "root": str(pinned_python),
                "version": "3.11.14",
                "binary_sha256": prepare._sha256(
                    pinned_python / "bin/python3.11"
                ),
                "source_tree_sha256": python_tree_sha256,
                "transformations": python_transformations,
            },
            "node_runtime": {
                "path": str(pinned_node),
                "version": "20.19.0",
                "sha256": prepare._sha256(pinned_node),
            },
            "agent_fleet": {
                role_name: {
                    key: builder_input["agent_fleet"][role_name][key]
                    for key in (
                        "source_repo",
                        "source_commit",
                        "source_tree_sha256",
                        "source_subdirectory",
                        "wheel",
                        "wheel_sha256",
                    )
                }
                for role_name in ("candidate", "rollback")
            },
            "quota_axi": {
                role_name: {
                    key: builder_input["quota_axi"][role_name][key]
                    for key in (
                        "source_repo",
                        "source_commit",
                        "source_tree_sha256",
                        "package_tarball",
                        "package_sha256",
                        "package_lock",
                        "package_lock_sha256",
                        "build_proof",
                        "build_proof_sha256",
                        "dependencies",
                    )
                }
                for role_name in ("candidate", "rollback")
            },
        }
        self.agent_build_manifest.write_text(
            json.dumps(
                {
                    "schema_version": 2,
                    "build_inputs": build_inputs,
                    "agent_fleet_candidate": agent_record(
                        self.agent_new, "candidate", "0.2.0", 2, "a" * 40,
                        agent_candidate_proofs,
                    ),
                    "agent_fleet_rollback": agent_record(
                        self.agent_old, "rollback", "0.1.5", 1, "b" * 40,
                        agent_rollback_proofs,
                    ),
                    "quota_axi_candidate": quota_record(
                        self.quota_new, "candidate", "0.1.7", "c" * 40,
                        quota_proofs,
                    ),
                    "quota_axi_rollback": quota_record(
                        self.quota_old, "rollback", "0.1.5", "d" * 40,
                        ["identity.txt", *quota_proofs],
                    ),
                    "xattr_policy": {
                        "allowed_system_xattrs": ["com.apple.provenance"],
                        "stripped_source_xattrs": True,
                        "enforcement": "closed_tree",
                    },
                    "nondeterminism": {
                        "builds": 2,
                        "tree_hashes_match": True,
                        "relocated_hashes_match": True,
                        "known_exclusions": [],
                    },
                    "runtime_versions": {
                        "schema_version": 1,
                        "closed_environment": True,
                        "observed": {
                            "agent_fleet_candidate": "Python 3.11.14",
                            "agent_fleet_rollback": "Python 3.11.14",
                            "quota_axi_candidate": "v20.19.0",
                            "quota_axi_rollback": "v20.19.0",
                        },
                    },
                }
            ),
            encoding="utf-8",
        )
        self.agent_build_manifest.chmod(0o600)

    def _write_baseline(self) -> None:
        state = self.root / "fleet-state"
        share = self.root / "fleet-share"
        lines = [
            "version = 1",
            "",
            "[settings]",
            f"state_dir = {json.dumps(str(state))}",
            f"share_dir = {json.dumps(str(share))}",
            f"quota_binary = {json.dumps(str(self.quota_initial_js))}",
            "quota_stale_seconds = 300",
            "quota_verification_grace_seconds = 86400",
            "lease_grace_seconds = 30",
            "active_lease_penalty = 8",
            "lock_stale_seconds = 30",
        ]
        for name in ("claude", "codex"):
            lines += [
                "",
                f"[providers.{name}]",
                f"binary = {json.dumps(str(self.root / 'provider-bin' / name))}",
                f"base_home = {json.dumps(str(self.root / 'desktop-home' / name))}",
                f"hooks_source = {json.dumps(str(self.root / 'hooks' / name))}",
                (
                    "desktop_identity_file = false"
                    if name == "claude"
                    else 'shared_entries = ["plugins"]'
                ),
            ]
            if name == "claude":
                lines.append('shared_entries = ["CLAUDE.md", "plugins"]')
            lines.append("trusted_projects = []")
        for ordinal, profile_id in enumerate(prepare.EXPECTED_TOPOLOGY, start=1):
            provider = "claude" if profile_id.startswith("claude") else "codex"
            pools = list(prepare.EXPECTED_TOPOLOGY[profile_id][1])
            policy = (
                "desktop_shared"
                if profile_id in {"claude-3", "codex-5"}
                else "worker"
            )
            lines += [
                "",
                f"[profiles.{json.dumps(profile_id)}]",
                f"provider = {json.dumps(provider)}",
                f"home = {json.dumps(str(share / 'accounts' / provider / profile_id))}",
                "pools = [" + ", ".join(json.dumps(pool) for pool in pools) + "]",
                "enabled = false",
                f"weight = {ordinal}",
                f"max_concurrent = {ordinal + 1}",
                f"reserve_percent = {ordinal}",
                f"safety_policy = {json.dumps(policy)}",
            ]
        self.baseline.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.baseline.chmod(0o600)

    def _spec(self) -> dict[str, object]:
        agent_proofs = [
            "bin/agent-fleet",
            "bin/python3.11",
            "launcher.py",
            "build/agent-fleet-launcher.c",
            "build/agent-fleet-front-door.c",
            "operator/agent-fleet",
            "build/provenance.json",
            "build/source.whl",
            "site-packages/agent_fleet/__init__.py",
            "site-packages/agent_fleet/__main__.py",
            "site-packages/agent_fleet/config.py",
            "site-packages/agent_fleet/enrollment.py",
            "site-packages/agent_fleet/identity.py",
            "site-packages/agent_fleet/models.py",
            "site-packages/agent_fleet/provision.py",
            "site-packages/agent_fleet/recovery.py",
            "site-packages/agent_fleet-0.2.0.dist-info/METADATA",
            "site-packages/agent_fleet-0.2.0.dist-info/RECORD",
        ]
        quota_proofs = [
            "bin/quota-axi",
            "runtime/node",
            "node_modules/quota-axi/dist/bin/quota-axi.js",
            "node_modules/quota-axi/package.json",
            "package-lock.json",
            "build/quota-axi-launcher.c",
            "build/provenance.json",
            "build/quota-build-proof.json",
            "build/runtime-closure.json",
        ]
        return {
            "schema_version": prepare.SCHEMA_VERSION,
            "transaction_id": "bridge-cutover-fixture",
            "apply_opt_in": True,
            "output_dir": str(self.bundle_dir),
            "baseline_registry": str(self.baseline),
            "baseline_registry_sha256": prepare._sha256(self.baseline),
            "live_registry": str(self.live),
            "trusted_project": str(self.project),
            "agent_fleet": {
                "current_link": str(self.agent_root / "current"),
                "old_release": str(self.agent_old),
                "old_target": "releases/0.1.5-old",
                "new_release": str(self.agent_new),
                "new_target": "releases/0.2.0-new",
                "old_proof_paths": [
                    "identity.txt",
                    "bin/agent-fleet",
                    "bin/python3.11",
                    "launcher.py",
                    "build/agent-fleet-launcher.c",
                    "build/agent-fleet-front-door.c",
                    "operator/agent-fleet",
                    "build/provenance.json",
                    "build/source.whl",
                    "site-packages/agent_fleet/__init__.py",
                    "site-packages/agent_fleet/__main__.py",
                    "site-packages/agent_fleet/config.py",
                    "site-packages/agent_fleet/models.py",
                    "site-packages/agent_fleet-0.1.5.dist-info/METADATA",
                    "site-packages/agent_fleet-0.1.5.dist-info/RECORD",
                ],
                "new_proof_paths": agent_proofs,
                "pythonpath": str(self.agent_new / "site-packages"),
                "executable": str(self.agent_new / "bin" / "agent-fleet"),
                "python_binary": str(self.agent_new / "bin" / "python3.11"),
                "expected_python_version": "3.11.14",
                "launcher_module": str(self.agent_new / "launcher.py"),
                "launcher_source": str(
                    self.agent_new / "build" / "agent-fleet-launcher.c"
                ),
                "wheel_metadata": str(
                    self.agent_new
                    / "site-packages"
                    / "agent_fleet-0.2.0.dist-info"
                    / "METADATA"
                ),
                "wheel_record": str(
                    self.agent_new
                    / "site-packages"
                    / "agent_fleet-0.2.0.dist-info"
                    / "RECORD"
                ),
                "build_provenance": str(self.agent_new / "build" / "provenance.json"),
                "build_manifest": str(self.agent_build_manifest),
                "source_commit": "a" * 40,
                "expected_version": "0.2.0",
                "expected_contract_version": 2,
                "rollback_executable": str(self.agent_old_executable),
                "rollback_pythonpath": str(self.agent_old / "site-packages"),
                "rollback_python_version": "3.11.14",
                "rollback_source_commit": "b" * 40,
                "rollback_version": "0.1.5",
                "rollback_contract_version": 1,
                "operator_front_door": str(self.operator_front_door),
                "candidate_front_door": str(
                    self.agent_new / "operator/agent-fleet"
                ),
                "rollback_front_door": str(
                    self.agent_old / "operator/agent-fleet"
                ),
            },
            "quota": {
                "current_link": str(self.quota_root / "current"),
                "old_release": str(self.quota_old),
                "old_target": "releases/0.1.5-old",
                "new_release": str(self.quota_new),
                "new_target": "releases/0.1.7-new",
                "old_proof_paths": ["identity.txt", *quota_proofs],
                "new_proof_paths": quota_proofs,
                "node_binary": str(self.quota_new / "runtime" / "node"),
                "entrypoint": str(
                    self.quota_new
                    / "node_modules"
                    / "quota-axi"
                    / "dist"
                    / "bin"
                    / "quota-axi.js"
                ),
                "launcher_source": str(
                    self.quota_new / "build" / "quota-axi-launcher.c"
                ),
                "build_provenance": str(
                    self.quota_new / "build" / "provenance.json"
                ),
                "runtime_manifest": str(
                    self.quota_new / "build" / "runtime-closure.json"
                ),
                "node_version": "20.19.0",
                "binary": str(self.quota_new / "bin" / "quota-axi"),
                "package_json": str(
                    self.quota_new / "node_modules" / "quota-axi" / "package.json"
                ),
                "package_lock": str(self.quota_new / "package-lock.json"),
                "expected_package_name": "quota-axi",
                "expected_version": "0.1.7",
                "source_commit": "c" * 40,
                "rollback_binary": str(self.quota_old / "bin" / "quota-axi"),
                "rollback_node_binary": str(self.quota_old / "runtime" / "node"),
                "rollback_entrypoint": str(
                    self.quota_old
                    / "node_modules"
                    / "quota-axi"
                    / "dist"
                    / "bin"
                    / "quota-axi.js"
                ),
                "rollback_launcher_source": str(
                    self.quota_old / "build" / "quota-axi-launcher.c"
                ),
                "rollback_build_provenance": str(
                    self.quota_old / "build" / "provenance.json"
                ),
                "rollback_runtime_manifest": str(
                    self.quota_old / "build" / "runtime-closure.json"
                ),
                "rollback_package_json": str(
                    self.quota_old / "node_modules" / "quota-axi" / "package.json"
                ),
                "rollback_package_lock": str(self.quota_old / "package-lock.json"),
                "rollback_node_version": "20.19.0",
                "rollback_version": "0.1.5",
                "rollback_source_commit": "d" * 40,
                "legacy_registry_binary": str(self.quota_initial_js),
                "release_tree_sha256": prepare._load_driver(
                    DRIVER
                ).compute_release_tree_sha256(self.quota_new),
            },
            "sealed_adoption": {
                "agent_fleet_initial_target": "releases/0.1.5-unsealed",
                "agent_fleet_front_door_initial_target": (
                    self.operator_front_initial_target
                ),
                "quota_initial_target": "releases/0.1.5-unsealed",
                "routing_absent_paths": [str(self.routing)],
                "backend_path": str(self.backend),
                "backend_sha256": prepare._sha256(self.backend),
                "state_quiet_paths": [str(path) for path in self.quiet_paths],
                "forbidden_process_tokens": [
                    str(self.agent_root / "bin" / "agent-fleet"),
                    str(self.agent_root / "releases") + "/",
                    str(self.quota_root) + "/",
                ],
                "ps_binary": str(self.ps_binary),
                "ps_binary_sha256": prepare._sha256(self.ps_binary),
            },
            "worker_state": {
                "snapshot_parent": str(self.snapshot_parent),
            },
        }

    def write_spec(self) -> None:
        self.spec_path.write_text(json.dumps(self.spec), encoding="utf-8")
        self.spec_path.chmod(0o600)

    def prepare(self) -> dict[str, object]:
        return prepare.prepare(self.spec_path, DRIVER)

    def reseal_candidate_tamper(self) -> None:
        candidate = self.bundle_dir / "registry.new.toml"
        manifest_path = self.bundle_dir / "cutover.manifest.json"
        bundle_path = self.bundle_dir / "bundle.json"
        digest = prepare._sha256(candidate)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["operations"][-1]["new_sha256"] = digest
        manifest_path.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        manifest_path.chmod(0o600)
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["registry_new"]["sha256"] = digest
        bundle["manifest_sha256"] = prepare._sha256(manifest_path)
        bundle_path.write_text(
            json.dumps(bundle, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        bundle_path.chmod(0o600)


REAL_MODELS_PATH = (
    Path(__file__).resolve().parents[1]
    / "tools"
    / "agent-fleet"
    / "src"
    / "agent_fleet"
    / "models.py"
)


class SyntheticAgentFleetSchemaDriftTest(unittest.TestCase):
    """Regression gate for review finding synthetic-agent-fleet-schema-drift.

    MODELS_SOURCE is a deliberate hand-copy of the real agent_fleet.models
    dataclasses so the synthetic pipeline under test never imports the real
    package.  That copy silently drifting from the real schema (a missing
    Registry.config_path) caused the 2026-07-19 Bridge preparer NO-GO, so this
    gate compares every synthetic dataclass field against the real module and
    fails on any mismatch.  Only this comparison loads the real module, under a
    private module name in this process; the synthetic pipeline paths stay
    synthetic.
    """

    # A drift report must always name the drifted field, never truncate.
    maxDiff = None

    @staticmethod
    @contextlib.contextmanager
    def _registered(module: types.ModuleType) -> Iterator[None]:
        # dataclasses resolves string annotations through
        # sys.modules[cls.__module__] while the classes are created, so the
        # module must be registered for the exec; unregister right after so
        # neither the real nor the synthetic copy leaks into import state.
        sys.modules[module.__name__] = module
        try:
            yield
        finally:
            del sys.modules[module.__name__]

    @classmethod
    def _real_models(cls) -> types.ModuleType:
        spec = importlib.util.spec_from_file_location(
            "agent_fleet_models_drift_reference", REAL_MODELS_PATH
        )
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        with cls._registered(module):
            spec.loader.exec_module(module)
        return module

    @classmethod
    def _synthetic_models(cls) -> types.ModuleType:
        module = types.ModuleType("agent_fleet_models_drift_synthetic")
        # The future import matches the real module so both sides report every
        # dataclass annotation as the literal source string.
        source = "from __future__ import annotations\n" + MODELS_SOURCE
        code = compile(source, "<synthetic agent_fleet.models>", "exec")
        with cls._registered(module):
            exec(code, module.__dict__)
        return module

    @staticmethod
    def _model_names(module: types.ModuleType) -> set[str]:
        return {
            name
            for name, value in vars(module).items()
            if dataclasses.is_dataclass(value) and value.__module__ == module.__name__
        }

    @staticmethod
    def _schema(module: types.ModuleType, class_name: str) -> dict[str, object]:
        model = getattr(module, class_name)
        return {
            "frozen": model.__dataclass_params__.frozen,
            "fields": [
                {
                    "name": item.name,
                    "type": " ".join(str(item.type).split()),
                    "default": (
                        "<required>"
                        if item.default is dataclasses.MISSING
                        else repr(item.default)
                    ),
                    "default_factory": (
                        None
                        if item.default_factory is dataclasses.MISSING
                        else item.default_factory.__name__
                    ),
                    "kw_only": item.kw_only,
                }
                for item in dataclasses.fields(model)
            ],
        }

    def test_synthetic_models_match_real_agent_fleet_schema(self) -> None:
        real = self._real_models()
        synthetic = self._synthetic_models()
        real_names = self._model_names(real)
        self.assertEqual(
            self._model_names(synthetic),
            real_names,
            f"MODELS_SOURCE no longer covers the dataclasses in {REAL_MODELS_PATH}; "
            "add, rename, or drop the hand-copied model to match the real module",
        )
        for class_name in sorted(real_names):
            with self.subTest(model=class_name):
                self.assertEqual(
                    self._schema(synthetic, class_name),
                    self._schema(real, class_name),
                    f"MODELS_SOURCE {class_name} drifted from {REAL_MODELS_PATH}; "
                    "update the hand-copy to match the real schema exactly",
                )


@unittest.skipUnless(sys.platform == "darwin", "cutover preparation is macOS-only")
class PrepareBridgeCutoverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = CutoverPreparationFixture()

    def tearDown(self) -> None:
        self.fixture.cleanup()

    def test_prepare_emits_exact_disabled_candidate_and_relative_link_manifest(self) -> None:
        result = self.fixture.prepare()
        self.assertTrue(result["valid"])
        self.assertEqual(result["cutover_phase"], "sealed-adoption-pending")
        self.assertFalse(result["cutover_ready"])
        self.assertEqual(result["profiles"], 8)
        self.assertEqual(result["fleet_managed_workers"], 6)
        self.assertEqual(result["external_reserves"], 2)
        self.assertEqual(result["enabled"], 0)
        manifest = json.loads(
            (self.fixture.bundle_dir / "cutover.manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["operations"][0]["old_target"], "releases/0.1.5-old")
        self.assertEqual(manifest["operations"][1]["new_target"], "releases/0.2.0-new")
        for operation in manifest["operations"][:2]:
            self.assertRegex(operation["old_tree_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(operation["new_tree_sha256"], r"^[0-9a-f]{64}$")
            self.assertGreaterEqual(len(operation["old_proofs"]), 1)
            self.assertGreaterEqual(len(operation["new_proofs"]), 1)
        candidate = (self.fixture.bundle_dir / "registry.new.toml").read_text(
            encoding="utf-8"
        )
        self.assertIn('safety_policy = "desktop_shared"', candidate)
        self.assertIn('pools = ["codex-manual"]', candidate)
        self.assertNotIn("current/bin/quota-axi", candidate)
        self.assertNotIn("hooks_source", candidate)
        self.assertNotIn('"plugins"', candidate)
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        self.assertTrue(bundle["topology"]["claude-3"]["never_enroll"])
        self.assertTrue(bundle["topology"]["codex-5"]["never_enroll"])
        self.assertEqual(
            bundle["activation_plan"]["provision"]["profiles"],
            ["claude-1", "claude-2", "codex-1", "codex-2", "codex-3", "codex-4"],
        )
        contract = bundle["activation_plan"]["provision"]["sealed_contract"]
        self.assertEqual(contract["schema_version"], 1)
        self.assertEqual(list(contract["plans"]), list(prepare.WORKER_PROFILES))
        self.assertNotIn("claude-3", contract["plans"])
        self.assertNotIn("codex-5", contract["plans"])
        for profile_id, sealed in contract["plans"].items():
            encoded = (
                json.dumps(sealed["plan"], indent=2, sort_keys=True) + "\n"
            ).encode("utf-8")
            self.assertEqual(sealed["plan_sha256"], hashlib.sha256(encoded).hexdigest())
            self.assertEqual(sealed["plan"]["entries"][0]["relative_path"], ".")
            self.assertEqual(sealed["plan"]["profile"], profile_id)
        closed = contract["closed_claude_state"]
        closed_bytes = (
            json.dumps(closed["payload"], indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        self.assertEqual(closed["sha256"], hashlib.sha256(closed_bytes).hexdigest())
        identity = contract["identity_bundles"]
        self.assertEqual(
            identity["worker_profiles"],
            {
                "claude": ["claude-1", "claude-2"],
                "codex": ["codex-1", "codex-2", "codex-3", "codex-4"],
            },
        )
        self.assertNotIn("claude-3", json.dumps(identity, sort_keys=True))
        self.assertNotIn("codex-5", json.dumps(identity, sort_keys=True))
        self.assertEqual(bundle["activation_plan"]["commands"], [])
        activation = bundle["activation_plan"]
        self.assertEqual(activation["schema_version"], 2)
        self.assertFalse(activation["verify_existing_auth"]["browser_allowed"])
        self.assertFalse(
            activation["batch_identity_adoption"]["provider_login_allowed"]
        )
        manual = activation["manual_profile_login"]
        self.assertTrue(manual["enabled"])
        self.assertEqual(manual["profiles"], list(prepare.WORKER_PROFILES))
        self.assertEqual(manual["commands"], [])
        self.assertFalse(manual["generated_commands"])
        self.assertFalse(manual["automatic_execution"])
        self.assertFalse(manual["automatic_browser_open"])
        self.assertFalse(manual["automatic_profile_enable"])
        self.assertTrue(manual["credential_mutation_allowed"])
        self.assertTrue(manual["all_same_provider_workers_disabled"])
        self.assertTrue(manual["zero_same_provider_worker_leases"])
        self.assertEqual(
            manual["initialize_login"]["provider_identity_bundle_required_state"],
            "absent",
        )
        self.assertEqual(
            manual["recover_login"]["provider_identity_bundle_required_state"],
            "present-complete",
        )
        self.assertTrue(
            manual["initialize_login"]["durable_provider_scoped_provisional_batch"]
        )
        self.assertTrue(
            manual["initialize_login"][
                "complete_valid_distinct_set_adopts_bundle_atomically"
            ]
        )
        self.assertTrue(
            manual["recover_login"]["staged_identity_must_equal_existing_pin"]
        )
        self.assertFalse(
            manual["provider_side_revocation"]["locally_reversible"]
        )
        serialized_manual = json.dumps(manual, sort_keys=True)
        self.assertNotIn("claude-3", serialized_manual)
        self.assertNotIn("codex-5", serialized_manual)
        worker_manifest = json.loads(
            (self.fixture.bundle_dir / "worker-state.manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            [value["profile"] for value in worker_manifest["workers"]],
            sorted(prepare.WORKER_PROFILES),
        )
        self.assertNotIn("claude-3", json.dumps(worker_manifest, sort_keys=True))
        self.assertNotIn("codex-5", json.dumps(worker_manifest, sort_keys=True))
        self.assertEqual(result["worker_state_phase"], "not-started")

    def test_prepare_recovers_attributed_deterministic_staging(self) -> None:
        spec = prepare.load_spec(self.fixture.spec_path)
        staging = spec.output_dir.parent / (
            f".{spec.output_dir.name}.prepare-"
            f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
        )
        marker = prepare._preparation_staging_marker(
            staging, spec, self.fixture.spec_path, DRIVER
        )
        journal_path, _ = prepare._preparation_control_paths(staging)
        prepare._write_preparation_journal(
            journal_path,
            prepare._preparation_journal_value(
                staging, spec.output_dir, marker, "building", None
            ),
            None,
        )
        staging.mkdir(mode=0o700)
        prepare._write_json(
            staging / ".bridge-preparation-staging.json", marker, 0o600
        )
        (staging / "partial").write_bytes(b"interrupted")
        result = self.fixture.prepare()
        self.assertTrue(result["valid"])
        self.assertFalse(staging.exists())

    def test_prepare_recovers_sigkill_at_every_journal_phase(self) -> None:
        for phase in ("building", "ready", "complete"):
            with self.subTest(phase=phase):
                fixture = CutoverPreparationFixture()
                self.addCleanup(fixture.cleanup)
                injector = textwrap.dedent(
                    f"""\
                    import os, signal, sys
                    from pathlib import Path
                    sys.path.insert(0, {str(SCRIPT_DIR)!r})
                    import prepare_bridge_cutover as module
                    original = module._write_preparation_journal
                    fired = False
                    def write(path, value, previous):
                        global fired
                        digest = original(path, value, previous)
                        if not fired and value.get("phase") == {phase!r}:
                            fired = True
                            os.kill(os.getpid(), signal.SIGKILL)
                        return digest
                    module._write_preparation_journal = write
                    module.prepare(Path({str(fixture.spec_path)!r}), Path({str(DRIVER)!r}))
                    """
                )
                killed = subprocess.run(
                    [sys.executable, "-c", injector],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                self.assertEqual(killed.returncode, -signal.SIGKILL)
                recovered = fixture.prepare()
                self.assertTrue(recovered["valid"])
                self.assertTrue(fixture.prepare()["valid"])
                spec = prepare.load_spec(fixture.spec_path)
                staging = spec.output_dir.parent / (
                    f".{spec.output_dir.name}.prepare-"
                    f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
                )
                self.assertFalse(staging.exists())

    def test_prepare_refuses_foreign_deterministic_staging(self) -> None:
        spec = prepare.load_spec(self.fixture.spec_path)
        staging = spec.output_dir.parent / (
            f".{spec.output_dir.name}.prepare-"
            f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
        )
        staging.mkdir(mode=0o700)
        prepare._write_json(
            staging / ".bridge-preparation-staging.json",
            {"schema_version": 1, "foreign": True},
            0o600,
        )
        sentinel = staging / "foreign-sentinel"
        sentinel.write_bytes(b"preserve")
        with self.assertRaisesRegex(
            prepare.PreparationError, "belongs to another operation"
        ):
            self.fixture.prepare()
        self.assertEqual(sentinel.read_bytes(), b"preserve")

    def test_prepare_refuses_disqualified_quota_candidate(self) -> None:
        self.fixture.spec["quota"]["expected_version"] = "0.1.6"
        self.fixture.write_spec()
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "quota.expected_version must be exactly 0.1.7",
        ):
            self.fixture.prepare()

    def test_prepare_uses_passwd_home_and_never_ambient_home(self) -> None:
        text = self.fixture.baseline.read_text(encoding="utf-8")
        text = text.replace(
            f'state_dir = {json.dumps(str(self.fixture.root / "fleet-state"))}',
            'state_dir = "~/fleet-state"',
        )
        self.fixture.baseline.write_text(text, encoding="utf-8")
        self.fixture.baseline.chmod(0o600)
        self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
        self.fixture.live.chmod(0o600)
        self.fixture.spec["baseline_registry_sha256"] = prepare._sha256(
            self.fixture.baseline
        )
        self.fixture.write_spec()
        hostile_home = str(self.fixture.root / "hostile-home")
        with mock.patch.dict(os.environ, {"HOME": hostile_home}):
            result = self.fixture.prepare()
        self.assertTrue(result["valid"])
        candidate = (self.fixture.bundle_dir / "registry.new.toml").read_text(
            encoding="utf-8"
        )
        passwd_home = pwd.getpwuid(os.getuid()).pw_dir
        self.assertIn(f'state_dir = "{passwd_home}/fleet-state"', candidate)
        self.assertNotIn(hostile_home, candidate)

    def test_prepare_never_lstats_or_opens_reserve_homes(self) -> None:
        share = self.fixture.root / "fleet-share" / "accounts"
        reserve_roots = (
            share / "claude" / "claude-3",
            share / "codex" / "codex-5",
        )
        original_lstat = os.lstat
        original_open = open

        def guarded_lstat(path: object, *args: object, **kwargs: object) -> os.stat_result:
            observed = Path(os.fspath(path))
            if any(observed == root or root in observed.parents for root in reserve_roots):
                raise AssertionError(f"reserve home was lstat'd: {observed}")
            return original_lstat(path, *args, **kwargs)

        def guarded_open(path: object, *args: object, **kwargs: object) -> object:
            if isinstance(path, (str, os.PathLike)):
                observed = Path(os.fspath(path))
                if any(observed == root or root in observed.parents for root in reserve_roots):
                    raise AssertionError(f"reserve home was opened: {observed}")
            return original_open(path, *args, **kwargs)

        with mock.patch("os.lstat", side_effect=guarded_lstat), mock.patch(
            "builtins.open", side_effect=guarded_open
        ):
            result = self.fixture.prepare()
        self.assertTrue(result["valid"])

    def test_prepare_lexically_isolates_reserve_homes_from_worker_state(self) -> None:
        original = self.fixture.baseline.read_text(encoding="utf-8")
        worker_home = self.fixture.root / "fleet-share/accounts/claude/claude-1"
        state_dir = self.fixture.root / "fleet-state"
        cases = (
            ("claude-3", worker_home, "claude-1"),
            ("codex-5", state_dir / "reserve", "identity-state"),
            (
                "claude-3",
                self.fixture.snapshot_parent / "reserve",
                "worker-snapshot-parent",
            ),
        )
        for profile_id, hostile_home, protected_id in cases:
            with self.subTest(profile=profile_id, protected=protected_id):
                marker = f'[profiles."{profile_id}"]'
                before, section = original.split(marker, 1)
                next_marker = section.find("\n[profiles.")
                profile_section = section if next_marker < 0 else section[:next_marker]
                remainder = "" if next_marker < 0 else section[next_marker:]
                home_line = next(
                    line
                    for line in profile_section.splitlines()
                    if line.startswith("home =")
                )
                profile_section = profile_section.replace(
                    home_line,
                    f"home = {json.dumps(str(hostile_home))}",
                    1,
                )
                tampered = before + marker + profile_section + remainder
                self.fixture.baseline.write_text(tampered, encoding="utf-8")
                self.fixture.baseline.chmod(0o600)
                self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
                self.fixture.live.chmod(0o600)
                self.fixture.spec["baseline_registry_sha256"] = prepare._sha256(
                    self.fixture.baseline
                )
                self.fixture.write_spec()
                with self.assertRaisesRegex(
                    prepare.PreparationError,
                    f"reserve profile {profile_id} home overlaps {protected_id}",
                ):
                    self.fixture.prepare()

    def test_prepare_refuses_shell_variable_in_shared_entry(self) -> None:
        text = self.fixture.baseline.read_text(encoding="utf-8").replace(
            'shared_entries = ["CLAUDE.md", "plugins"]',
            'shared_entries = ["$HOME", "plugins"]',
        )
        self.fixture.baseline.write_text(text, encoding="utf-8")
        self.fixture.baseline.chmod(0o600)
        self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
        self.fixture.live.chmod(0o600)
        self.fixture.spec["baseline_registry_sha256"] = prepare._sha256(
            self.fixture.baseline
        )
        self.fixture.write_spec()
        with self.assertRaisesRegex(prepare.PreparationError, "shell-variable"):
            self.fixture.prepare()

    def test_validate_refuses_unallowlisted_profile_change(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        candidate.write_text(text.replace("weight = 1", "weight = 99", 1), encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "unallowlisted profile field"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_bundle_becomes_runtime_switch_ready_only_after_sealed_adoption(self) -> None:
        self.fixture.prepare()
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        adoption_driver = prepare._load_adoption_driver()
        adoption_manifest = adoption_driver.load_manifest(
            Path(bundle["adoption_manifest_path"])
        )

        adoption_driver.apply(adoption_manifest)
        result = prepare.validate_bundle(
            self.fixture.bundle_dir / "bundle.json", DRIVER
        )

        self.assertEqual(result["cutover_phase"], "runtime-switch-ready")
        self.assertTrue(result["runtime_switch_ready"])
        self.assertFalse(result["cutover_ready"])

    def _apply_runtime_switch(
        self, mark_boundary: bool = True
    ) -> tuple[types.ModuleType, Path]:
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        adoption_driver = prepare._load_adoption_driver()
        adoption_driver.apply(
            adoption_driver.load_manifest(Path(bundle["adoption_manifest_path"]))
        )
        driver = prepare._load_driver(DRIVER)
        manifest_path = Path(bundle["manifest_path"])
        driver.execute(driver.load_manifest(manifest_path), "forward")
        if mark_boundary:
            driver.mark_post_install_irreversible_boundary(
                driver.load_manifest(manifest_path)
            )
        return driver, manifest_path

    def test_validate_accepts_post_cutover_state_only_with_boundary_marked(self) -> None:
        self.fixture.prepare()
        driver, manifest_path = self._apply_runtime_switch(mark_boundary=False)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "sealed-adoption state is invalid: .*"
            r"\(post-cutover probe: main cutover is not fully applied past the "
            "marked post-install irreversible boundary\\)",
        ):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

        driver.mark_post_install_irreversible_boundary(
            driver.load_manifest(manifest_path)
        )
        result = prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

        self.assertEqual(result["cutover_phase"], "runtime-switched")
        self.assertFalse(result["runtime_switch_ready"])
        self.assertFalse(result["cutover_ready"])
        # The accepted live-registry set stays pinned to exactly the three
        # bundle-recorded identities; post-cutover the live file is the new one.
        self.assertEqual(
            prepare._sha256(self.fixture.live), result["new_registry_sha256"]
        )

    def test_validate_refuses_tampered_live_registry_after_runtime_switch(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        payload = self.fixture.live.read_bytes()
        self.fixture.live.write_bytes(payload + b"# drift\n")
        self.fixture.live.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "unknown SHA-256"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_candidate_registry_before_adoption(self) -> None:
        self.fixture.prepare()
        self.fixture.live.write_bytes(
            (self.fixture.bundle_dir / "registry.new.toml").read_bytes()
        )
        self.fixture.live.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "unknown SHA-256"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_partially_reverted_state_after_runtime_switch(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        current = self.fixture.agent_root / "current"
        os.unlink(current)
        os.symlink("releases/0.1.5-old", current)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "sealed-adoption state is invalid: .*"
            r"\(post-cutover probe: observed old/new states are not a valid "
            "transaction prefix",
        ):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_post_cutover_plan_refuses_registry_pin_without_sha256(self) -> None:
        self.fixture.prepare()
        driver, manifest_path = self._apply_runtime_switch()
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        adoption_driver = prepare._load_adoption_driver()
        loaded_adoption = adoption_driver.load_manifest(
            Path(bundle["adoption_manifest_path"])
        )
        pins = prepare._post_cutover_pins(driver, driver.load_manifest(manifest_path))
        pins[str(loaded_adoption.registry_operation.path)] = {"kind": "file"}
        with self.assertRaisesRegex(
            adoption_driver.AdoptionError, "requires a registry file pin"
        ):
            adoption_driver.post_cutover_plan(loaded_adoption, pins)

    def _read_json_file(self, path: Path) -> dict:
        return json.loads(Path(path).read_text(encoding="utf-8"))

    def _write_json_file(self, path: Path, value: dict) -> None:
        Path(path).write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        Path(path).chmod(0o600)

    def _transaction_journal_bytes(self) -> dict[str, bytes]:
        transaction = self.fixture.bundle_dir / "transaction"
        return {
            name: (transaction / name).read_bytes()
            for name in ("cutover.journal.json", "sealed-adoption.journal.json")
        }

    def _restale_recorded_identity(self) -> None:
        """Re-stale the recorded identity artifacts the way a byte-exact provider
        reinstall does live: the sealed cutover and adoption journals stay
        intact, but the recorded activation plan and worker-state manifest drift
        off the current provider-binary identity.  The synthetic provision model
        is registry-pure (it does not pin the live binary inode/mtime the real
        provision API does), so the faithful analog of that drift is to move the
        recorded per-worker plan identity off what a fresh contract reconstructs.
        """
        profile = prepare.WORKER_PROFILES[0]
        stale = "a" * 64
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        bundle = self._read_json_file(bundle_path)
        plans = bundle["activation_plan"]["provision"]["sealed_contract"]["plans"]
        plans[profile]["plan_sha256"] = stale
        self._write_json_file(bundle_path, bundle)
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        worker_state = self._read_json_file(worker_state_path)
        worker_state["sealed_plans"][profile]["plan_sha256"] = stale
        for worker in worker_state["workers"]:
            if worker["profile"] == profile:
                worker["plan_sha256"] = stale
        self._write_json_file(worker_state_path, worker_state)

    def test_refresh_updates_identity_and_revalidates_runtime_switched(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"

        # The applied runtime-switched bundle validates strictly before drift.
        self.assertEqual(
            prepare.validate_bundle(bundle_path, DRIVER)["cutover_phase"],
            "runtime-switched",
        )
        original_bundle_bytes = bundle_path.read_bytes()
        original_worker_state_bytes = worker_state_path.read_bytes()
        journal_before = self._transaction_journal_bytes()

        # A byte-exact provider reinstall re-stales the two identity artifacts.
        self._restale_recorded_identity()
        with self.assertRaisesRegex(
            prepare.PreparationError, "activation plan is not exact"
        ):
            prepare.validate_bundle(bundle_path, DRIVER)

        # The in-place refresh realigns both artifacts to the live identity and
        # gates completion on the journal-bound runtime-switched proof.
        refreshed = prepare.refresh_bundle(bundle_path, DRIVER)
        self.assertTrue(refreshed["refreshed"])
        self.assertTrue(refreshed["valid"])
        self.assertEqual(refreshed["cutover_phase"], "runtime-switched")

        # A fresh strict validation now passes with no gate loosening.
        revalidated = prepare.validate_bundle(bundle_path, DRIVER)
        self.assertEqual(revalidated["cutover_phase"], "runtime-switched")
        self.assertFalse(revalidated["runtime_switch_ready"])
        self.assertFalse(revalidated["cutover_ready"])

        # Both artifacts now equal the exact live reconstruction; the sealed
        # cutover and adoption journals were preserved byte-for-byte.
        self.assertEqual(bundle_path.read_bytes(), original_bundle_bytes)
        self.assertEqual(
            worker_state_path.read_bytes(), original_worker_state_bytes
        )
        self.assertEqual(self._transaction_journal_bytes(), journal_before)

    def test_refresh_does_not_loosen_the_strict_identity_gate(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        self._restale_recorded_identity()
        prepare.refresh_bundle(bundle_path, DRIVER)

        # Re-staling after a refresh still refuses exactly as before: the strict
        # gate is unchanged; the refresh only realigned the recorded identity to
        # the live binary rather than weakening the check.
        self._restale_recorded_identity()
        with self.assertRaisesRegex(
            prepare.PreparationError, "activation plan is not exact"
        ):
            prepare.validate_bundle(bundle_path, DRIVER)

    def test_refresh_refuses_bundle_that_is_not_runtime_switched(self) -> None:
        # Prepared but never adopted or switched: sealed-adoption-pending, not
        # the applied runtime-switched bundle, so refresh must refuse and leave
        # both identity artifacts untouched.
        self.fixture.prepare()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        before = (bundle_path.read_bytes(), worker_state_path.read_bytes())
        self.assertEqual(
            prepare.validate_bundle(bundle_path, DRIVER)["cutover_phase"],
            "sealed-adoption-pending",
        )
        with self.assertRaisesRegex(
            prepare.PreparationError, "only to an applied runtime-switched bundle"
        ):
            prepare.refresh_bundle(bundle_path, DRIVER)
        self.assertEqual(
            (bundle_path.read_bytes(), worker_state_path.read_bytes()), before
        )

    def test_refresh_refuses_runtime_switch_ready_bundle(self) -> None:
        # Sealed adoption applied but the main cutover still at the sealed
        # baseline: runtime-switch-ready, not yet applied.  Refresh must refuse.
        self.fixture.prepare()
        bundle = json.loads(
            (self.fixture.bundle_dir / "bundle.json").read_text(encoding="utf-8")
        )
        adoption_driver = prepare._load_adoption_driver()
        adoption_driver.apply(
            adoption_driver.load_manifest(Path(bundle["adoption_manifest_path"]))
        )
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        self.assertEqual(
            prepare.validate_bundle(bundle_path, DRIVER)["cutover_phase"],
            "runtime-switch-ready",
        )
        with self.assertRaisesRegex(
            prepare.PreparationError, "only to an applied runtime-switched bundle"
        ):
            prepare.refresh_bundle(bundle_path, DRIVER)

    def test_refresh_refuses_when_boundary_not_marked(self) -> None:
        # Cutover applied but the post-install irreversible boundary not marked:
        # the journal-bound runtime-switched proof cannot be established, so the
        # shared reconstruction refuses and refresh never mutates the bundle.
        self.fixture.prepare()
        self._apply_runtime_switch(mark_boundary=False)
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        before = (bundle_path.read_bytes(), worker_state_path.read_bytes())
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "post-cutover probe: main cutover is not fully applied",
        ):
            prepare.refresh_bundle(bundle_path, DRIVER)
        self.assertEqual(
            (bundle_path.read_bytes(), worker_state_path.read_bytes()), before
        )

    def test_refresh_refuses_active_worker_state_transaction(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        before = (bundle_path.read_bytes(), worker_state_path.read_bytes())
        worker_state_journal = (
            self.fixture.snapshot_parent
            / "bridge-cutover-fixture-workers.journal.json"
        )
        worker_state_journal.write_text("{}\n", encoding="utf-8")
        worker_state_journal.chmod(0o600)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "before the worker-state 6a snapshot.*strand any bound transaction",
        ):
            prepare.refresh_bundle(bundle_path, DRIVER)
        self.assertEqual(
            (bundle_path.read_bytes(), worker_state_path.read_bytes()), before
        )

    def test_refresh_repairs_partial_artifact_replacement(self) -> None:
        self.fixture.prepare()
        self._apply_runtime_switch()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        worker_state_path = self.fixture.bundle_dir / "worker-state.manifest.json"
        worker_state = self._read_json_file(worker_state_path)
        worker_state["bundle_sha256"] = "a" * 64
        self._write_json_file(worker_state_path, worker_state)
        with self.assertRaises(prepare.PreparationError):
            prepare.validate_bundle(bundle_path, DRIVER)
        refreshed = prepare.refresh_bundle(bundle_path, DRIVER)
        self.assertTrue(refreshed["valid"])
        self.assertEqual(refreshed["cutover_phase"], "runtime-switched")
        repaired_worker_state = self._read_json_file(worker_state_path)
        self.assertEqual(
            repaired_worker_state["bundle_sha256"],
            hashlib.sha256(bundle_path.read_bytes()).hexdigest(),
        )

    def test_validate_refuses_extra_trusted_project(self) -> None:
        self.fixture.prepare()
        extra = self.fixture.root / "other-project"
        extra.mkdir()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        needle = f'trusted_projects = [{json.dumps(str(self.fixture.project))}]'
        replacement = (
            f'trusted_projects = [{json.dumps(str(self.fixture.project))}, '
            f'{json.dumps(str(extra))}]'
        )
        candidate.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "trust exactly"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_prepare_refuses_symlinked_baseline(self) -> None:
        real = self.fixture.baseline.with_name("accounts.real.toml")
        os.replace(self.fixture.baseline, real)
        os.symlink(real.name, self.fixture.baseline)
        with self.assertRaisesRegex(
            prepare.PreparationError, "symlink|tree_sha256|sealed runtime proof"
        ):
            self.fixture.prepare()

    def test_prepare_refuses_release_file_with_external_hardlink(self) -> None:
        runtime_file = self.fixture.quota_new / "unlisted-runtime-state"
        runtime_file.write_text("immutable\n", encoding="utf-8")
        external = self.fixture.root / "external-hardlink"
        os.link(runtime_file, external)
        with self.assertRaisesRegex(prepare.PreparationError, "hard link"):
            self.fixture.prepare()

    def test_prepare_refuses_moving_or_symlinked_quota_binary(self) -> None:
        moving = self.fixture.quota_new / "bin" / "quota-moving"
        moving.parent.mkdir(exist_ok=True)
        os.symlink("quota-axi", moving)
        self.fixture.spec["quota"]["binary"] = str(moving)  # type: ignore[index]
        self.fixture.write_spec()
        with self.assertRaisesRegex(
            prepare.PreparationError, "symlink|tree_sha256|sealed runtime proof"
        ):
            self.fixture.prepare()

    def test_prepare_refuses_extra_profile(self) -> None:
        text = self.fixture.baseline.read_text(encoding="utf-8")
        text += textwrap.dedent(
            f"""

            [profiles."codex-6"]
            provider = "codex"
            home = {json.dumps(str(self.fixture.root / "codex-6"))}
            pools = ["codex-manual"]
            enabled = false
            weight = 1
            max_concurrent = 1
            reserve_percent = 1
            safety_policy = "worker"
            """
        )
        self.fixture.baseline.write_text(text, encoding="utf-8")
        self.fixture.baseline.chmod(0o600)
        self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
        self.fixture.live.chmod(0o600)
        self.fixture.spec["baseline_registry_sha256"] = prepare._sha256(self.fixture.baseline)
        self.fixture.write_spec()
        with self.assertRaisesRegex(prepare.PreparationError, "exactly the eight"):
            self.fixture.prepare()

    def test_prepare_refuses_stale_baseline_generation(self) -> None:
        self.fixture.baseline.write_text(
            self.fixture.baseline.read_text(encoding="utf-8") + "# drift\n",
            encoding="utf-8",
        )
        self.fixture.baseline.chmod(0o600)
        self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
        self.fixture.live.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "generation is stale"):
            self.fixture.prepare()

    def test_validate_refuses_enabled_desktop_shared_reserve(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        marker = '[profiles."claude-3"]'
        before, section = text.split(marker, 1)
        section = section.replace("enabled = false", "enabled = true", 1)
        candidate.write_text(before + marker + section, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "claude-3 is not disabled"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_codex_5_in_worker_pool(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        marker = '[profiles."codex-5"]'
        before, section = text.split(marker, 1)
        section = section.replace(
            'pools = ["codex-manual"]',
            'pools = ["codex-crew", "codex-manual"]',
            1,
        )
        candidate.write_text(before + marker + section, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "codex-5 pools are not exact"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_claude_3_in_worker_pool(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        marker = '[profiles."claude-3"]'
        before, section = text.split(marker, 1)
        section = section.replace(
            'pools = ["claude-manual"]',
            'pools = ["claude-crew", "claude-manual"]',
            1,
        )
        candidate.write_text(before + marker + section, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "claude-3 pools are not exact"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_enabled_codex_5_reserve(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        text = candidate.read_text(encoding="utf-8")
        marker = '[profiles."codex-5"]'
        before, section = text.split(marker, 1)
        section = section.replace("enabled = false", "enabled = true", 1)
        candidate.write_text(before + marker + section, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "codex-5 is not disabled"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_prepare_refuses_quota_path_with_current_component(self) -> None:
        moving_dir = self.fixture.quota_new / "current"
        moving_dir.mkdir()
        moving = moving_dir / "quota-axi.js"
        moving.write_bytes(
            (self.fixture.quota_new / "node_modules/quota-axi/dist/bin/quota-axi.js").read_bytes()
        )
        moving.chmod(0o755)
        self.fixture.spec["quota"]["binary"] = str(moving)  # type: ignore[index]
        self.fixture.write_spec()
        with self.assertRaisesRegex(
            prepare.PreparationError, "tree_sha256|moving 'current'"
        ):
            self.fixture.prepare()

    def test_prepare_refuses_missing_worker_profile(self) -> None:
        text = self.fixture.baseline.read_text(encoding="utf-8")
        start = text.index('[profiles."codex-4"]')
        end = text.index('[profiles."codex-5"]')
        self.fixture.baseline.write_text(text[:start] + text[end:], encoding="utf-8")
        self.fixture.baseline.chmod(0o600)
        self.fixture.live.write_bytes(self.fixture.baseline.read_bytes())
        self.fixture.live.chmod(0o600)
        self.fixture.spec["baseline_registry_sha256"] = prepare._sha256(self.fixture.baseline)
        self.fixture.write_spec()
        with self.assertRaisesRegex(prepare.PreparationError, "exactly the eight"):
            self.fixture.prepare()

    def test_validate_refuses_live_registry_compare_and_swap_drift(self) -> None:
        self.fixture.prepare()
        self.fixture.live.write_text(
            self.fixture.live.read_text(encoding="utf-8") + "# post-prepare drift\n",
            encoding="utf-8",
        )
        self.fixture.live.chmod(0o600)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "drifted|do not equal|unknown SHA-256",
        ):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_release_tree_drift_outside_named_proofs(self) -> None:
        self.fixture.prepare()
        drift = self.fixture.quota_new / "unlisted-runtime.js"
        drift.write_text("changed after bundle\n", encoding="utf-8")
        with self.assertRaisesRegex(prepare.PreparationError, "tree_sha256|release tree"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_prepare_refuses_quota_import_closure_drift_with_same_entry_hash(self) -> None:
        imported = (
            self.fixture.quota_new
            / "node_modules"
            / "quota-axi"
            / "dist"
            / "runtime.js"
        )
        imported.write_text("export const runtime = 'drifted';\n", encoding="utf-8")
        with self.assertRaisesRegex(prepare.PreparationError, "tree_sha256|release tree"):
            self.fixture.prepare()

    def test_prepare_refuses_unpinned_quota_lock(self) -> None:
        lock = self.fixture.quota_new / "package-lock.json"
        payload = json.loads(lock.read_text(encoding="utf-8"))
        payload["packages"][""]["dependencies"]["quota-axi"] = "^0.1.7"
        lock.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "retained quota_axi candidate package_lock digest changed|tree_sha256|exact version pin",
        ):
            self.fixture.prepare()

    def test_prepare_refuses_nonexact_agent_fleet_launcher(self) -> None:
        launcher = self.fixture.agent_new / "bin" / "agent-fleet"
        launcher.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        launcher.chmod(0o755)
        with self.assertRaisesRegex(prepare.PreparationError, "tree_sha256|native Mach-O"):
            self.fixture.prepare()

    def test_prepare_refuses_launcher_build_proof_mismatch(self) -> None:
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        proof["agent_fleet_candidate"]["rebuild_tree_sha256"] = "0" * 64
        self.fixture.agent_build_manifest.write_text(json.dumps(proof), encoding="utf-8")
        self.fixture.agent_build_manifest.chmod(0o600)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            r"agent_fleet_candidate\.rebuild_tree_sha256",
        ):
            self.fixture.prepare()

    def test_runtime_closure_validator_detects_imported_module_drift_directly(self) -> None:
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        record = proof["quota_axi_candidate"]["runtime_manifest"]
        runtime = (
            self.fixture.quota_new
            / "node_modules"
            / "quota-axi"
            / "dist"
            / "runtime.js"
        )
        runtime.write_text("export const runtime = 'tampered';\n", encoding="utf-8")
        with self.assertRaisesRegex(prepare.PreparationError, "sha256"):
            prepare._validate_runtime_closure_manifest(
                self.fixture.quota_new,
                self.fixture.quota_new / "build" / "runtime-closure.json",
                record,
                self.fixture.quota_new
                / "node_modules"
                / "quota-axi"
                / "dist"
                / "bin"
                / "quota-axi.js",
                "quota fixture",
            )

    def test_prepare_refuses_actual_forbidden_release_xattr(self) -> None:
        target = self.fixture.quota_new / "node_modules" / "quota-axi" / "dist" / "runtime.js"
        completed = subprocess.run(
            ["/usr/bin/xattr", "-w", "com.relvino.bridge-test", "forbidden", str(target)],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            self.skipTest(f"xattrs unavailable: {completed.stderr.strip()}")
        with self.assertRaisesRegex(prepare.PreparationError, "forbidden xattrs"):
            self.fixture.prepare()

    def test_invalid_proof_stops_before_candidate_package_import(self) -> None:
        sentinel = self.fixture.root / "candidate-imported"
        initializer = self.fixture.agent_new / "site-packages" / "agent_fleet" / "__init__.py"
        initializer.write_text(
            f"from pathlib import Path\nPath({str(sentinel)!r}).write_text('bad')\n"
            '__version__ = "0.2.0"\n',
            encoding="utf-8",
        )
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        proof["schema_version"] = 1
        self.fixture.agent_build_manifest.write_text(json.dumps(proof), encoding="utf-8")
        self.fixture.agent_build_manifest.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "schema must be 2"):
            self.fixture.prepare()
        self.assertFalse(sentinel.exists())

    def test_prepare_refuses_legacy_runtime_proof_schema(self) -> None:
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        proof["schema_version"] = 1
        self.fixture.agent_build_manifest.write_text(json.dumps(proof), encoding="utf-8")
        self.fixture.agent_build_manifest.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "schema must be 2"):
            self.fixture.prepare()

    def test_prepare_refuses_runtime_proof_without_candidate(self) -> None:
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        del proof["agent_fleet_candidate"]
        self.fixture.agent_build_manifest.write_text(json.dumps(proof), encoding="utf-8")
        self.fixture.agent_build_manifest.chmod(0o600)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "missing keys: agent_fleet_candidate",
        ):
            self.fixture.prepare()

    def test_prepare_refuses_symlinked_operator_front_door_contract(self) -> None:
        proof = json.loads(self.fixture.agent_build_manifest.read_text(encoding="utf-8"))
        proof["agent_fleet_candidate"]["invocation"]["operator_front_door"][
            "symlink_allowed"
        ] = True
        self.fixture.agent_build_manifest.write_text(json.dumps(proof), encoding="utf-8")
        self.fixture.agent_build_manifest.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "permits a symlink"):
            self.fixture.prepare()

    def test_prepare_refuses_operational_raw_quota_entrypoint(self) -> None:
        entrypoint = Path(self.fixture.spec["quota"]["entrypoint"])
        entrypoint.chmod(0o755)
        with self.assertRaisesRegex(
            prepare.PreparationError, "tree_sha256|must be non-operational"
        ):
            self.fixture.prepare()

    def test_prepare_refuses_agent_fleet_wheel_metadata_mismatch(self) -> None:
        metadata = Path(self.fixture.spec["agent_fleet"]["wheel_metadata"])
        text = metadata.read_text(encoding="utf-8")
        metadata.write_text(
            text.replace("Version: 0.2.0", "Version: 0.2.1"),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            prepare.PreparationError, "tree_sha256|METADATA Version"
        ):
            self.fixture.prepare()

    def test_prepare_refuses_agent_fleet_wheel_record_omission(self) -> None:
        record = Path(self.fixture.spec["agent_fleet"]["wheel_record"])
        text = record.read_text(encoding="utf-8")
        record.write_text(
            "\n".join(
                line
                for line in text.splitlines()
                if not line.startswith("agent_fleet/recovery.py,")
            )
            + "\n",
            encoding="utf-8",
        )

        with self.assertRaisesRegex(prepare.PreparationError, "tree_sha256|RECORD omits"):
            self.fixture.prepare()

    def test_prepare_refuses_mixed_old_contract_in_candidate_runtime(self) -> None:
        launcher = self.fixture.agent_new / "bin" / "agent-fleet"
        launcher.write_bytes(self.fixture.agent_old_executable.read_bytes())
        launcher.chmod(0o755)
        with self.assertRaisesRegex(
            prepare.PreparationError,
            "tree_sha256|Agent Fleet candidate version contract mismatch",
        ):
            self.fixture.prepare()

    def test_prepare_refuses_native_launcher_that_sources_hostile_environment(self) -> None:
        source = self.fixture.agent_new / "build" / "agent-fleet-launcher.c"
        source.write_text(
            textwrap.dedent(
                """\
                #include <unistd.h>
                int main(void) {
                    execl("/bin/bash", "bash", "-c",
                          "printf '%s\\n' '{\\\"cli_version\\\":\\\"0.2.0\\\",\\\"contract_version\\\":2}'",
                          (char *)0);
                    return 127;
                }
                """
            ),
            encoding="utf-8",
        )
        launcher = self.fixture.agent_new / "bin" / "agent-fleet"
        subprocess.run(
            ["/usr/bin/cc", "-Os", str(source), "-o", str(launcher)],
            check=True,
            capture_output=True,
            text=True,
        )
        launcher.chmod(0o755)
        with self.assertRaisesRegex(
            prepare.PreparationError, "tree_sha256|hostile shell environment"
        ):
            self.fixture.prepare()

    def test_validate_refuses_automatic_or_reserve_activation(self) -> None:
        self.fixture.prepare()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        bundle["activation_plan"]["automatic_enrollment"] = True
        bundle["activation_plan"]["commands"] = ["agent-fleet profile enroll claude-3"]
        bundle_path.write_text(
            json.dumps(bundle, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bundle_path.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "activation plan"):
            prepare.validate_bundle(bundle_path, DRIVER)

    def test_validate_refuses_manual_login_gate_weakening(self) -> None:
        self.fixture.prepare()
        bundle_path = self.fixture.bundle_dir / "bundle.json"
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        manual = bundle["activation_plan"]["manual_profile_login"]
        manual["profiles"].append("claude-3")
        manual["automatic_browser_open"] = True
        manual["automatic_profile_enable"] = True
        manual["recover_login"]["staged_identity_must_equal_existing_pin"] = False
        bundle_path.write_text(
            json.dumps(bundle, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        bundle_path.chmod(0o600)
        with self.assertRaisesRegex(prepare.PreparationError, "activation plan"):
            prepare.validate_bundle(bundle_path, DRIVER)

    def test_validate_refuses_reintroduced_mutable_hooks(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        payload = candidate.read_text(encoding="utf-8").replace(
            "[providers.claude]\n",
            "[providers.claude]\n"
            f"hooks_source = {json.dumps(str(self.fixture.root / 'mutable-hooks'))}\n",
            1,
        )
        candidate.write_text(payload, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "must not inherit mutable hooks"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_validate_refuses_reintroduced_plugin_sharing(self) -> None:
        self.fixture.prepare()
        candidate = self.fixture.bundle_dir / "registry.new.toml"
        payload = candidate.read_text(encoding="utf-8").replace(
            'shared_entries = ["CLAUDE.md"]',
            'shared_entries = ["CLAUDE.md", "plugins"]',
            1,
        )
        candidate.write_text(payload, encoding="utf-8")
        candidate.chmod(0o600)
        self.fixture.reseal_candidate_tamper()
        with self.assertRaisesRegex(prepare.PreparationError, "plugin sharing"):
            prepare.validate_bundle(self.fixture.bundle_dir / "bundle.json", DRIVER)

    def test_exhaustive_disposable_rehearsal_recovers_both_directions(self) -> None:
        self.fixture.prepare()
        result = prepare.rehearse_bundle(
            self.fixture.bundle_dir / "bundle.json", DRIVER, self.fixture.scratch
        )
        self.assertTrue(result["rehearsed"])
        self.assertEqual(result["adoption_forward_boundaries"], 52)
        self.assertTrue(result["adoption_recovery_refused_after_seal"])
        self.assertGreaterEqual(result["forward_boundaries"], 90)
        self.assertGreaterEqual(result["rollback_boundaries"], 90)
        self.assertTrue(result["rollback_refused_after_irreversible_boundary"])
        self.assertEqual(list(self.fixture.scratch.iterdir()), [self.fixture.snapshot_parent])
        self.assertEqual(list(self.fixture.snapshot_parent.iterdir()), [])


class RealAgentFleetPurePlanningTest(unittest.TestCase):
    """Regression gate for the 2026-07-19 live-cutover preparer NO-GO.

    The synthetic agent_fleet modules elsewhere in this suite never resolve trusted
    projects through git, so the sealed provision API's project canonicalization was
    first exercised live, where the pure-planning guard refused its subprocess call.
    This gate loads the REAL agent_fleet package exactly the way ``prepare`` does and
    invokes the sealed planning APIs under the REAL guard against a REAL git-backed
    trusted project.
    """

    @staticmethod
    def _stage_sealed_quota_release(root: Path) -> tuple[Path, Path]:
        """Stage a self-contained sealed quota-axi release layout under ``root``.

        ``initial_registry`` otherwise pins the operator machine's installed release,
        which no continuous-integration runner has; the release only has to satisfy the
        sealed-layout and identity checks for this gate, never to execute.
        """

        entrypoint = root / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
        entrypoint.parent.mkdir(parents=True)
        entrypoint.write_text("export const fixture = true;\n", encoding="utf-8")
        entrypoint.chmod(0o444)
        node_binary = root / "runtime" / "node"
        node_binary.parent.mkdir(parents=True)
        node_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        node_binary.chmod(0o755)
        quota_binary = root / "bin" / "quota-axi"
        quota_binary.parent.mkdir(parents=True)
        quota_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        quota_binary.chmod(0o755)
        return quota_binary, node_binary

    def test_real_provision_planning_is_pure_for_git_backed_project(self) -> None:
        pythonpath = SCRIPT_DIR.parents[0] / "agent-fleet" / "src"
        init_text = (pythonpath / "agent_fleet" / "__init__.py").read_text("utf-8")
        version = next(
            line.split('"')[1]
            for line in init_text.splitlines()
            if line.startswith("__version__")
        )
        api = prepare.load_agent_fleet_api(
            pythonpath,
            pythonpath.parent,
            version,
            "real source planning gate",
            require_provision_api=True,
        )
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = Path(raw_temp).resolve()
            project = temp / "trusted-project"
            project.mkdir(mode=0o700)
            subprocess.run(["git", "init", "-q", str(project)], check=True)
            quota_binary, quota_node_binary = self._stage_sealed_quota_release(
                temp / "quota-release"
            )
            environment = {
                "AGENT_FLEET_CONFIG": str(temp / "config" / "accounts.toml"),
                "AGENT_FLEET_STATE_DIR": str(temp / "state"),
                "AGENT_FLEET_SHARE_DIR": str(temp / "share"),
                "AGENT_FLEET_QUOTA_BIN": str(quota_binary),
                "AGENT_FLEET_QUOTA_NODE_BIN": str(quota_node_binary),
            }
            with mock.patch.dict(os.environ, environment):
                registry = api.config.initial_registry(1, 1)
            self.assertEqual(registry.settings.quota_binary, quota_binary)
            providers = dict(registry.providers)
            providers["claude"] = dataclasses.replace(
                providers["claude"], trusted_projects=(project,)
            )
            registry = dataclasses.replace(registry, providers=providers)

            payload = prepare._invoke_pure_provision_api(
                api.provision.closed_claude_state_payload, registry
            )

            self.assertEqual(sorted(payload["projects"]), [str(project)])
            bundle_path = prepare._invoke_pure_provision_api(
                api.identity.identity_bundle_path, registry, "claude"
            )
            self.assertTrue(str(bundle_path).endswith("claude-bundle.json"))


if __name__ == "__main__":
    unittest.main()
