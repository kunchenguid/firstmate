from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import base64
import csv
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/bridge-cutover/build_sealed_bridge_runtimes.py"
SPEC = importlib.util.spec_from_file_location("build_sealed_bridge_runtimes", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
builder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = builder
SPEC.loader.exec_module(builder)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def host_system_tool_paths() -> dict[str, Path] | None:
    """Map each pinned system tool to a host path the BUILDER will also accept.

    The fixture must never accept a tool the builder then rejects: every case
    would die on that rejection instead of its own assertion. So usability is the
    builder's own validation - which carries the ancestry rule - plus the
    manifest's separate root-ownership requirement (load_manifest refuses any
    system tool whose st_uid is not 0).

    Returns None when nothing qualifies. That is a real host condition rather
    than a bug: a runner image whose /usr is owned by neither root nor the
    invoking uid leaves no usable root-owned system tool, and a test-created
    fallback cannot stand in because a test process cannot own a file as root.
    Callers skip, so the gap is visible and states its reason. Do NOT substitute
    a relaxed ancestry rule here - that would silently stop exercising the
    ownership property these tests exist to cover.
    """

    def usable(path: Path) -> bool:
        try:
            metadata = path.lstat()
        except OSError:
            return False
        if not (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == 0
            and not stat.S_IMODE(metadata.st_mode) & 0o022
            and Path(os.path.realpath(path)) == path
            and os.access(path, os.X_OK)
        ):
            return False
        try:
            builder._require_regular(
                path, "fixture system tool", executable=True, allow_root_owner=True
            )
        except (OSError, builder.BuildError):
            return False
        return True

    fallback = next(
        (
            path
            for path in map(
                Path,
                ("/usr/bin/true", "/bin/true", "/usr/bin/env", "/bin/echo"),
            )
            if usable(path)
        ),
        None,
    )
    if fallback is None:
        return None
    return {
        name: path if usable(path) else fallback
        for name, path in builder.SYSTEM_TOOL_PATHS.items()
    }


class ManifestFixture:
    def __init__(self, temporary: Path) -> None:
        self.root = temporary
        self.output = temporary / "output"
        self.output.mkdir(mode=0o700)
        for relative in ("agent/releases", "quota/releases"):
            (self.output / relative).mkdir(parents=True, mode=0o700)
        self.front_parent = temporary / "bin"
        self.front_parent.mkdir(mode=0o700)
        self.tool = temporary / "tool"
        self.tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.tool.chmod(0o700)
        self.python = temporary / "python"
        (self.python / "bin").mkdir(parents=True)
        (self.python / "lib").mkdir()
        (self.python / "bin/python3.11").write_bytes(b"python")
        (self.python / "bin/python3.11").chmod(0o700)
        (self.python / "lib/stdlib.py").write_bytes(b"stdlib")
        self.node = temporary / "node"
        self.node.write_bytes(b"node")
        self.node.chmod(0o700)
        self.agent_source = temporary / "agent-source"
        self.agent_source.mkdir()
        self.quota_source = temporary / "quota-source"
        self.quota_source.mkdir()
        self.wheels: dict[str, Path] = {}
        self.packages: dict[str, Path] = {}
        self.locks: dict[str, Path] = {}
        self.build_proofs: dict[str, Path] = {}
        for role in ("candidate", "rollback"):
            wheel = temporary / f"{role}.whl"
            wheel.write_bytes(role.encode())
            self.wheels[role] = wheel
            package = temporary / f"{role}.tgz"
            package.write_bytes(role.encode())
            self.packages[role] = package
            lock = temporary / f"{role}-package-lock.json"
            lock.write_text("{}\n", encoding="utf-8")
            self.locks[role] = lock
            build_proof = temporary / f"{role}-build-proof.json"
            build_proof.write_text("{}\n", encoding="utf-8")
            self.build_proofs[role] = build_proof
        tool_pin = {"path": str(self.tool), "sha256": sha(self.tool)}
        self.value = {
            "schema_version": 2,
            "output_root": str(self.output),
            "proof_manifest": str(self.output / "proof-v2.json"),
            "operator_front_door": str(self.front_parent / "agent-fleet"),
            "transaction_driver": dict(tool_pin),
            "tools": {
                name: {
                    "path": str(builder.SYSTEM_TOOL_PATHS[name]),
                    "sha256": sha(builder.SYSTEM_TOOL_PATHS[name]),
                }
                for name in builder.SYSTEM_TOOL_PATHS
            },
            "python_runtime": {
                "root": str(self.python),
                "version": "3.11.9",
                "binary_sha256": sha(self.python / "bin/python3.11"),
                "tree_sha256": builder._content_tree_sha256(
                    self.python, ("bin/python3.11", "lib"), "fixture"
                ),
            },
            "node_runtime": {
                "binary": str(self.node),
                "version": "20.19.0",
                "sha256": sha(self.node),
            },
            "agent_fleet": {
                "candidate": self.agent_role("candidate", "0.2.0", 2),
                "rollback": self.agent_role("rollback", "0.1.5", 1),
            },
            "quota_axi": {
                "candidate": self.quota_role("candidate", "0.1.7"),
                "rollback": self.quota_role("rollback", "0.1.5"),
            },
        }
        self.path = temporary / "manifest.json"
        self.write()

    def agent_role(self, role: str, version: str, contract: int) -> dict[str, object]:
        return {
            "role": role,
            "release_path": f"agent/releases/{version}-{role}",
            "version": version,
            "contract_version": contract,
            "source_repo": str(self.agent_source),
            "source_commit": ("a" if role == "candidate" else "b") * 40,
            "source_tree_sha256": ("1" if role == "candidate" else "2") * 64,
            "source_subdirectory": ".",
            "wheel": str(self.wheels[role]),
            "wheel_sha256": sha(self.wheels[role]),
        }

    def quota_role(self, role: str, version: str) -> dict[str, object]:
        return {
            "role": role,
            "release_path": f"quota/releases/{version}-{role}",
            "version": version,
            "source_repo": str(self.quota_source),
            "source_commit": ("c" if role == "candidate" else "d") * 40,
            "source_tree_sha256": ("3" if role == "candidate" else "4") * 64,
            "package_tarball": str(self.packages[role]),
            "package_sha256": sha(self.packages[role]),
            "package_lock": str(self.locks[role]),
            "package_lock_sha256": sha(self.locks[role]),
            "build_proof": str(self.build_proofs[role]),
            "build_proof_sha256": sha(self.build_proofs[role]),
            "dependencies": [],
        }

    def write(self) -> None:
        self.path.write_text(
            json.dumps(self.value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )


class SealedRuntimeBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="sealed-builder-test-")
        self.root = Path(os.path.realpath(self.temporary.name))
        system_tools = host_system_tool_paths()
        if system_tools is None:
            raise unittest.SkipTest(
                "no root-owned system tool with builder-safe ancestry on this host"
            )
        self.system_tools_patch = mock.patch.object(
            builder, "SYSTEM_TOOL_PATHS", system_tools
        )
        self.system_tools_patch.start()
        self.fixture = ManifestFixture(self.root)

    def tearDown(self) -> None:
        builder._unseal(self.root)
        self.system_tools_patch.stop()
        self.temporary.cleanup()

    def test_manifest_accepts_exact_four_role_schema(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        self.assertEqual(set(manifest.agent_roles), {"candidate", "rollback"})
        self.assertEqual(set(manifest.quota_roles), {"candidate", "rollback"})
        self.assertEqual(manifest.agent_roles["candidate"].version, "0.2.0")
        self.assertEqual(manifest.operator_front_door.name, "agent-fleet")

    @unittest.skipUnless(
        Path("/usr/bin/file").is_file() and os.lstat("/usr/bin/file").st_uid == 0,
        "requires a root-owned macOS system tool",
    )
    def test_manifest_accepts_pinned_root_owned_system_tool(self) -> None:
        system_tool = Path("/usr/bin/file")
        self.fixture.value["tools"]["file"] = {
            "path": str(system_tool),
            "sha256": sha(system_tool),
        }
        self.fixture.write()
        manifest = builder.load_manifest(self.fixture.path)
        self.assertEqual(manifest.tools["file"].path, system_tool)

    def test_manifest_rejects_user_input_under_writable_parent(self) -> None:
        unsafe = self.root / "unsafe-parent"
        unsafe.mkdir(mode=0o777)
        unsafe.chmod(0o777)
        driver = unsafe / "driver.py"
        driver.write_text("VALUE = 1\n", encoding="utf-8")
        driver.chmod(0o700)
        self.fixture.value["transaction_driver"] = {
            "path": str(driver),
            "sha256": sha(driver),
        }
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "writable user ancestry"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_unknown_top_level_field(self) -> None:
        self.fixture.value["credentials"] = "/tmp/forbidden"
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "fields are not exact"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_missing_role(self) -> None:
        del self.fixture.value["quota_axi"]["rollback"]
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "fields are not exact"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_wrong_candidate_version(self) -> None:
        self.fixture.value["agent_fleet"]["candidate"]["version"] = "0.2.1"
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "exact candidate 0.2.0"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_disqualified_quota_candidate(self) -> None:
        self.fixture.value["quota_axi"]["candidate"]["version"] = "0.1.6"
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "exact candidate 0.1.7"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_wrong_contract(self) -> None:
        self.fixture.value["agent_fleet"]["candidate"]["contract_version"] = 1
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "contract_version must be 2"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_agent_source_subdirectory_escape(self) -> None:
        self.fixture.value["agent_fleet"]["candidate"]["source_subdirectory"] = "../tools"
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "source_subdirectory"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_existing_release(self) -> None:
        path = self.fixture.output / "agent/releases/0.2.0-candidate"
        path.mkdir()
        with self.assertRaisesRegex(builder.BuildError, "refusing overwrite"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_existing_proof(self) -> None:
        (self.fixture.output / "proof-v2.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "proof_manifest already exists"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_non_agent_fleet_front_door_name(self) -> None:
        self.fixture.value["operator_front_door"] = str(self.fixture.front_parent / "wrong")
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "basename"):
            builder.load_manifest(self.fixture.path)

    def test_manifest_rejects_unsorted_dependencies(self) -> None:
        role = self.fixture.value["quota_axi"]["candidate"]
        dependency = self.fixture.packages["candidate"]
        role["dependencies"] = [
            {
                "name": "z",
                "version": "1.0.0",
                "install_path": "node_modules/z",
                "tarball": str(dependency),
                "sha256": sha(dependency),
                "integrity": "sha512-" + base64.b64encode(
                    hashlib.sha512(dependency.read_bytes()).digest()
                ).decode("ascii"),
            },
            {
                "name": "a",
                "version": "1.0.0",
                "install_path": "node_modules/a",
                "tarball": str(dependency),
                "sha256": sha(dependency),
                "integrity": "sha512-" + base64.b64encode(
                    hashlib.sha512(dependency.read_bytes()).digest()
                ).decode("ascii"),
            },
        ]
        self.fixture.write()
        with self.assertRaisesRegex(builder.BuildError, "path-sorted"):
            builder.load_manifest(self.fixture.path)

    def test_duplicate_json_key_is_rejected(self) -> None:
        duplicate = self.root / "duplicate.json"
        duplicate.write_text('{"schema_version":2,"schema_version":2}\n', encoding="utf-8")
        with self.assertRaisesRegex(builder.BuildError, "duplicate"):
            builder._read_strict_json(duplicate, "duplicate")

    def test_verified_file_rejects_named_replacement_during_hash(self) -> None:
        source = self.root / "race-input"
        source.write_bytes(b"pinned-input\n")
        expected = sha(source)
        displaced = self.root / "race-input.displaced"
        original_sha256_fd = builder._sha256_fd
        replaced = False

        def replace_after_hash(fd: int) -> str:
            nonlocal replaced
            digest = original_sha256_fd(fd)
            if not replaced:
                replaced = True
                source.rename(displaced)
                source.write_bytes(b"pinned-input\n")
            return digest

        with mock.patch.object(builder, "_sha256_fd", side_effect=replace_after_hash):
            with self.assertRaisesRegex(builder.BuildError, "changed while it was verified"):
                builder._require_regular(source, "racing input", expected)

    def test_transaction_driver_rejects_self_replacement_during_load(self) -> None:
        driver = self.root / "racing-driver.py"
        driver.write_text(
            "from pathlib import Path\n"
            "_self = Path(__file__)\n"
            "_self.rename(_self.with_suffix('.original'))\n"
            "_self.write_text('replacement = True\\n', encoding='utf-8')\n"
            "_self.chmod(0o700)\n"
            "def compute_release_tree_sha256(root, label): return '0' * 64\n"
            "def compute_release_proof(root, relative): return {}\n",
            encoding="utf-8",
        )
        driver.chmod(0o700)
        pin = builder.ToolPin(driver, sha(driver))
        with self.assertRaisesRegex(builder.BuildError, "changed while it was consumed"):
            builder._load_transaction_driver(pin)

    def test_transaction_driver_rejects_same_content_inode_replacement(self) -> None:
        driver = self.root / "same-content-racing-driver.py"
        driver.write_text(
            "from pathlib import Path\n"
            "import shutil\n"
            "_self = Path(__file__)\n"
            "_original = _self.with_suffix('.original')\n"
            "_self.rename(_original)\n"
            "shutil.copyfile(_original, _self)\n"
            "_self.chmod(0o700)\n"
            "def compute_release_tree_sha256(root, label): return '0' * 64\n"
            "def compute_release_proof(root, relative): return {}\n",
            encoding="utf-8",
        )
        driver.chmod(0o700)
        pin = builder.ToolPin(driver, sha(driver))
        with self.assertRaisesRegex(builder.BuildError, "changed while it was consumed"):
            builder._load_transaction_driver(pin)

    def test_child_process_environment_is_closed_by_default(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "DYLD_INSERT_LIBRARIES": "/tmp/hostile.dylib",
                "HOME": "/tmp/hostile-home",
                "PATH": "/tmp/hostile-bin",
                "PYTHONPATH": "/tmp/hostile-python",
            },
        ):
            completed = builder._run(["/usr/bin/env"])
        observed = dict(
            line.split("=", 1) for line in completed.stdout.splitlines() if "=" in line
        )
        self.assertEqual(
            observed,
            {
                "HOME": "/var/empty",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": "/tmp",
            },
        )

    def test_pinned_tool_rejects_self_replacement_during_execution(self) -> None:
        tool = self.root / "racing-tool"
        tool.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "mv \"$0\" \"$0.original\"\n"
            "printf '#!/bin/sh\\nexit 0\\n' > \"$0\"\n"
            "chmod 700 \"$0\"\n",
            encoding="utf-8",
        )
        tool.chmod(0o700)
        pin = builder.ToolPin(tool, sha(tool))
        with self.assertRaisesRegex(builder.BuildError, "SHA-256"):
            builder._run_pinned(pin, [])

    def test_pinned_tool_rejects_loader_and_path_environment_overrides(self) -> None:
        pin = builder.ToolPin(self.fixture.tool, sha(self.fixture.tool))
        for environment in (
            {"DYLD_INSERT_LIBRARIES": "/tmp/hostile.dylib"},
            {"PATH": "/tmp/hostile-bin"},
        ):
            with self.subTest(environment=environment):
                with self.assertRaises(builder.BuildError):
                    builder._run_pinned(pin, [], env=environment)

    def test_pinned_tool_rejects_same_content_inode_replacement(self) -> None:
        tool = self.root / "same-content-racing-tool"
        tool.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "mv \"$0\" \"$0.original\"\n"
            "cp \"$0.original\" \"$0\"\n"
            "chmod 700 \"$0\"\n",
            encoding="utf-8",
        )
        tool.chmod(0o700)
        pin = builder.ToolPin(tool, sha(tool))
        with self.assertRaisesRegex(builder.BuildError, "identity changed"):
            builder._run_pinned(pin, [])

    def test_relative_path_rejects_escape_absolute_and_unicode(self) -> None:
        for value in ("../escape", "/absolute", "a//b", "a/./b", "café"):
            with self.subTest(value=value), self.assertRaises(builder.BuildError):
                builder._relative(value, "test")

    def test_git_archive_digest_is_order_independent_and_type_bound(self) -> None:
        first = {"b": ("file", b"2"), "a": ("file", b"1")}
        second = {"a": ("file", b"1"), "b": ("file", b"2")}
        linked = {"a": ("symlink", b"1"), "b": ("file", b"2")}
        self.assertEqual(builder._archive_tree_sha256(first), builder._archive_tree_sha256(second))
        self.assertNotEqual(builder._archive_tree_sha256(first), builder._archive_tree_sha256(linked))

    def test_package_reader_rejects_escape_and_symlink(self) -> None:
        for name, member in (
            ("escape", tarfile.TarInfo("package/../outside")),
            ("symlink", tarfile.TarInfo("package/link")),
        ):
            with self.subTest(name=name):
                payload = io.BytesIO()
                with tarfile.open(fileobj=payload, mode="w:gz") as archive:
                    if name == "escape":
                        member.size = 1
                        archive.addfile(member, io.BytesIO(b"x"))
                    else:
                        member.type = tarfile.SYMTYPE
                        member.linkname = "/outside"
                        archive.addfile(member)
                package = self.root / f"{name}.tgz"
                package.write_bytes(payload.getvalue())
                with self.assertRaises(builder.BuildError):
                    builder._safe_package_members(package, name)

    def test_internal_python_symlink_is_bound_and_materialized(self) -> None:
        alias = self.fixture.python / "lib/alias.py"
        os.symlink("stdlib.py", alias)
        digest = builder._content_tree_sha256(
            self.fixture.python,
            ("bin/python3.11", "lib"),
            "symlinked Python fixture",
        )
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        self.assertEqual(
            builder._python_runtime_transformations(self.fixture.python),
            [
                {
                    "path": "lib/alias.py",
                    "target": "stdlib.py",
                    "resolved_path": "lib/stdlib.py",
                    "resolved_sha256": sha(
                        self.fixture.python / "lib/stdlib.py"
                    ),
                    "transformation": "materialize-internal-regular-file",
                }
            ],
        )
        copied = self.root / "copied-lib"
        builder._copy_tree(
            self.fixture.python / "lib",
            copied,
            canonical_runtime_root=self.fixture.python,
        )
        self.assertFalse((copied / "alias.py").is_symlink())
        self.assertEqual(
            (copied / "alias.py").read_bytes(),
            (copied / "stdlib.py").read_bytes(),
        )

    def test_python_symlink_escape_is_rejected(self) -> None:
        outside = self.root / "outside-runtime.py"
        outside.write_bytes(b"outside")
        os.symlink(
            "../../outside-runtime.py",
            self.fixture.python / "lib/escape.py",
        )
        with self.assertRaisesRegex(builder.BuildError, "(escapes|outside)"):
            builder._content_tree_sha256(
                self.fixture.python,
                ("bin/python3.11", "lib"),
                "escaping Python fixture",
            )

    def test_package_identity_rejects_install_scripts(self) -> None:
        members = {
            "package.json": json.dumps(
                {
                    "name": "quota-axi",
                    "version": "0.1.7",
                    "scripts": {"postinstall": "curl example.invalid"},
                }
            ).encode()
        }
        with self.assertRaisesRegex(builder.BuildError, "install-time"):
            builder._package_identity(members, "quota-axi", "0.1.7", "package")

    def test_quota_package_requires_complete_proof_for_generated_extra(self) -> None:
        package_json = (
            json.dumps(
                {
                    "name": "quota-axi",
                    "version": "0.1.7",
                    "bin": {"quota-axi": "./dist/bin/quota-axi.js"},
                },
                separators=(",", ":"),
            )
            + "\n"
        ).encode()
        entrypoint = b"console.log('0.1.7');\n"
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w:gz") as archive:
            for relative, content in {
                "package.json": package_json,
                "dist/bin/quota-axi.js": entrypoint,
                "dist/imported-extra.js": b"globalThis.compromised=true;\n",
            }.items():
                member = tarfile.TarInfo(f"package/{relative}")
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        package_path = self.root / "malicious-quota.tgz"
        package_path.write_bytes(payload.getvalue())
        lock_value = {
            "lockfileVersion": 3,
            "packages": {
                "": {"dependencies": {"quota-axi": "0.1.7"}},
                "node_modules/quota-axi": {"version": "0.1.7"},
            },
        }
        lock_path = self.root / "malicious-lock.json"
        lock_path.write_text(json.dumps(lock_value) + "\n", encoding="utf-8")
        role = builder.QuotaRole(
            "candidate",
            "quota/releases/candidate",
            "0.1.7",
            self.fixture.quota_source,
            "c" * 40,
            "3" * 64,
            package_path,
            sha(package_path),
            lock_path,
            sha(lock_path),
            self.fixture.build_proofs["candidate"],
            sha(self.fixture.build_proofs["candidate"]),
            (),
        )
        source = {
            "package.json": ("file", package_json),
            "dist/bin/quota-axi.js": ("file", entrypoint),
        }
        with self.assertRaisesRegex(builder.BuildError, "proof fields are not exact"):
            builder._validate_quota_inputs(role, source)

    def test_copy_regular_rebinds_the_expected_runtime_digest(self) -> None:
        source = self.root / "runtime-source"
        destination = self.root / "runtime-copy"
        source.write_bytes(b"substituted-same-version-runtime")
        with self.assertRaisesRegex(builder.BuildError, "runtime pin"):
            builder._copy_regular(
                source,
                destination,
                expected_sha256=hashlib.sha256(b"pinned-runtime").hexdigest(),
                label="runtime pin",
            )
        self.assertFalse(destination.exists())

    def test_copy_tree_rebinds_the_expected_runtime_tree(self) -> None:
        source = self.root / "runtime-tree-source"
        source.mkdir()
        (source / "stdlib.py").write_bytes(b"substituted")
        destination = self.root / "runtime-tree-copy"
        with self.assertRaisesRegex(builder.BuildError, "runtime tree pin"):
            builder._copy_tree(
                source,
                destination,
                expected_tree_sha256="0" * 64,
                expected_tree_relatives=(".",),
                label="runtime tree pin",
            )
        self.assertFalse(destination.exists())

    def test_agent_wheel_rejects_recorded_importable_extra(self) -> None:
        package_files = {
            "agent_fleet/__init__.py": b"",
            "agent_fleet/__main__.py": b"",
            "agent_fleet/config.py": b"",
            "agent_fleet/enrollment.py": b"",
            "agent_fleet/models.py": b"",
            "agent_fleet/provision.py": b"",
            "agent_fleet/identity.py": b"",
            "agent_fleet/recovery.py": b"",
        }
        dist = "agent_fleet-0.2.0.dist-info"
        members = {
            **package_files,
            f"{dist}/METADATA": b"Metadata-Version: 2.4\nName: agent-fleet\nVersion: 0.2.0\n",
            f"{dist}/WHEEL": b"Wheel-Version: 1.0\n",
            "sitecustomize.py": b"raise SystemExit('compromised')\n",
        }
        record_path = f"{dist}/RECORD"
        rows: list[list[str]] = []
        for relative, content in members.items():
            digest = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).decode().rstrip("=")
            rows.append([relative, f"sha256={digest}", str(len(content))])
        rows.append([record_path, "", ""])
        record_buffer = io.StringIO()
        writer = csv.writer(record_buffer, lineterminator="\n")
        writer.writerows(rows)
        members[record_path] = record_buffer.getvalue().encode()
        wheel = self.root / "malicious.whl"
        import zipfile

        with zipfile.ZipFile(wheel, "w") as archive:
            for relative, content in members.items():
                archive.writestr(relative, content)
        role = builder.AgentRole(
            "candidate",
            "agent/releases/candidate",
            "0.2.0",
            2,
            self.fixture.agent_source,
            "a" * 40,
            "1" * 64,
            ".",
            wheel,
            sha(wheel),
        )
        source = {
            f"src/{relative}": ("file", content)
            for relative, content in package_files.items()
        }
        source["pyproject.toml"] = ("file", b"[project]\nname='agent-fleet'\n")
        with self.assertRaisesRegex(builder.BuildError, "non-source"):
            builder._wheel_members(role, source)

    def test_closure_digest_is_canonical_and_order_sensitive(self) -> None:
        entries = [
            {"path": "a", "mode": "0444", "sha256": "1" * 64},
            {"path": "b", "mode": "0555", "sha256": "2" * 64},
        ]
        self.assertRegex(builder._closure_digest(entries), r"^[0-9a-f]{64}$")
        self.assertNotEqual(builder._closure_digest(entries), builder._closure_digest(list(reversed(entries))))

    def test_agent_launcher_binds_full_scrub_and_every_entry(self) -> None:
        entries = [
            {"path": "bin/python3.11", "mode": "0555", "sha256": "1" * 64},
            {"path": "launcher.py", "mode": "0444", "sha256": "2" * 64},
        ]
        source = builder.generate_agent_launcher_source(
            entries, ["lib"], ["lib"], "3" * 64
        )
        for value in (*builder.GENERIC_ENV_EXACT, *builder.AGENT_ENV_EXACT):
            self.assertIn(f'"{value}"', source)
        for value in (*builder.GENERIC_ENV_PREFIXES, *builder.AGENT_ENV_PREFIXES):
            self.assertIn(f'"{value}"', source)
        for entry in entries:
            self.assertIn(entry["path"], source)
            self.assertIn(entry["sha256"], source)
        self.assertIn("execv(python", source)
        self.assertIn("verify_walk", source)
        self.assertIn("require_self_identity(self)", source)
        self.assertNotIn("strcmp(argv[0], self)", source)

    def test_quota_launcher_binds_closure_fixed_path_and_direct_exec(self) -> None:
        entries = [
            {"path": "runtime/node", "mode": "0555", "sha256": "1" * 64},
            {
                "path": "node_modules/quota-axi/dist/bin/quota-axi.js",
                "mode": "0444",
                "sha256": "2" * 64,
            },
        ]
        source = builder.generate_quota_launcher_source(
            entries,
            ["runtime", "node_modules", "node_modules/quota-axi"],
            ["runtime", "node_modules"],
            "3" * 64,
        )
        self.assertIn('setenv("PATH", "/usr/bin:/bin", 1)', source)
        self.assertIn("execv(node", source)
        self.assertNotIn("AGENT_FLEET_CONFIG", source)
        for entry in entries:
            self.assertIn(entry["sha256"], source)

    def test_front_door_binds_physical_target_and_launcher_hash(self) -> None:
        source = builder.generate_agent_front_door_source(
            Path("/safe/final/agent-fleet"), "a" * 64
        )
        self.assertIn('TARGET = "/safe/final/agent-fleet"', source)
        self.assertIn("a" * 64, source)
        self.assertIn("O_NOFOLLOW", source)
        self.assertIn("st_nlink != 1", source)
        self.assertIn("opened.st_uid != getuid()", source)
        self.assertIn("(opened.st_mode & 07777) != 0555", source)
        self.assertIn("require_self_identity(self)", source)
        self.assertNotIn("strcmp(argv[0], self)", source)
        self.assertIn("execv(TARGET", source)

    def test_candidate_proof_paths_cover_schema_v2_identity(self) -> None:
        role = builder.AgentRole(
            "candidate",
            "release",
            "0.2.0",
            2,
            self.fixture.agent_source,
            "a" * 40,
            "1" * 64,
            ".",
            self.fixture.wheels["candidate"],
            sha(self.fixture.wheels["candidate"]),
        )
        release = self.root / "release"
        (release / "site-packages/agent_fleet").mkdir(parents=True)
        for name in ("enrollment.py", "identity.py", "provision.py", "recovery.py"):
            (release / f"site-packages/agent_fleet/{name}").write_bytes(b"x")
        paths = builder._agent_proof_paths(release, role)
        self.assertIn("operator/agent-fleet", paths)
        self.assertIn("site-packages/agent_fleet/provision.py", paths)
        self.assertIn("site-packages/agent_fleet/identity.py", paths)
        self.assertIn("site-packages/agent_fleet/enrollment.py", paths)
        self.assertIn("site-packages/agent_fleet/recovery.py", paths)
        self.assertIn("build/runtime-closure.json", paths)

    def test_front_door_plan_binds_destination_and_both_roles(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        candidate = self.root / "candidate"
        rollback = self.root / "rollback"
        for root, byte in ((candidate, b"c"), (rollback, b"r")):
            (root / "operator").mkdir(parents=True)
            (root / "bin").mkdir()
            (root / "operator/agent-fleet").write_bytes(byte)
            (root / "bin/agent-fleet").write_bytes(byte + b"-target")
        plan = builder._front_door_plan(manifest, candidate, rollback)
        self.assertEqual(plan["installed_path"], str(self.fixture.front_parent / "agent-fleet"))
        self.assertNotEqual(plan["candidate"]["source_sha256"], plan["rollback"]["source_sha256"])
        self.assertFalse(plan["symlink_allowed"])

    def test_atomic_no_replace_refuses_racing_destination(self) -> None:
        source = self.root / "source-release"
        destination = self.root / "destination-release"
        source.mkdir()
        (source / "identity").write_bytes(b"ours")
        destination.mkdir()
        (destination / "identity").write_bytes(b"racer")
        with self.assertRaisesRegex(builder.BuildError, "refusing overwrite"):
            builder._rename_no_replace(source, destination)
        self.assertEqual((source / "identity").read_bytes(), b"ours")
        self.assertEqual((destination / "identity").read_bytes(), b"racer")

    def test_atomic_file_writer_refuses_existing_proof(self) -> None:
        proof = self.root / "proof.json"
        proof.write_bytes(b"racer\n")
        with self.assertRaisesRegex(builder.BuildError, "refusing to overwrite"):
            builder._write_json_no_replace(proof, {"ours": True}, 0o444)
        self.assertEqual(proof.read_bytes(), b"racer\n")

    def test_atomic_file_writer_publishes_complete_read_only_proof(self) -> None:
        proof = self.root / "proof.json"
        builder._write_json_no_replace(proof, {"complete": True}, 0o444)
        self.assertEqual(
            json.loads(proof.read_text(encoding="utf-8")), {"complete": True}
        )
        self.assertEqual(stat.S_IMODE(os.lstat(proof).st_mode), 0o444)

    def test_atomic_file_writer_recovers_exact_partial_staging(self) -> None:
        proof = self.root / "proof.json"
        value = {"complete": True}
        payload = (
            json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
        ).encode("utf-8")
        digest = hashlib.sha256(payload).hexdigest()
        staging = proof.with_name(
            f".{proof.name}.bridge-write-{digest[:32]}"
        )
        staging.write_bytes(payload[:9])
        staging.chmod(0o444)
        builder._write_json_no_replace(proof, value, 0o444)
        self.assertEqual(proof.read_bytes(), payload)
        self.assertFalse(staging.exists())

    def test_atomic_file_writer_fsyncs_parent_after_file_is_final(self) -> None:
        proof = self.root / "proof.json"
        observed: list[str] = []

        def verify_parent(path: Path) -> None:
            self.assertEqual(path, proof.parent)
            self.assertEqual(
                proof.read_text(encoding="utf-8"), '{\n  "ready": true\n}\n'
            )
            self.assertEqual(stat.S_IMODE(os.lstat(proof).st_mode), 0o444)
            observed.append("parent-fsync")

        with mock.patch.object(builder, "_fsync_directory", side_effect=verify_parent):
            builder._write_json(proof, {"ready": True}, 0o444)
        self.assertEqual(observed, ["parent-fsync"])

    def test_release_publication_fsyncs_parent_after_no_replace_rename(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        source = self.root / "release-source"
        source.mkdir()
        (source / "payload").write_bytes(b"sealed")
        destination = self.fixture.output / "agent/releases/published"
        events: list[str] = []
        original_fsync = builder._fsync_directory

        def rename(source_path: Path, destination_path: Path) -> None:
            os.rename(source_path, destination_path)
            events.append("rename")

        def fsync(path: Path) -> None:
            if path == destination:
                self.assertTrue(destination.is_dir())
                events.append("release-fsync")
            elif path == destination.parent:
                self.assertTrue(destination.is_dir())
                events.append("parent-fsync")
            else:
                events.append("staging-fsync")
            original_fsync(path)

        with mock.patch.object(builder, "_rename_no_replace", side_effect=rename), mock.patch.object(
            builder, "_fsync_directory", side_effect=fsync
        ):
            publication_id = "f" * 64
            staging = destination.with_name(
                f".{destination.name}.bridge-sealed-{publication_id[:32]}"
            )
            builder._publish_release(
                manifest,
                source,
                destination,
                publication_id,
                staging,
                "1" * 64,
            )
        rename_index = max(index for index, event in enumerate(events) if event == "rename")
        self.assertEqual(
            events[rename_index : rename_index + 3],
            ["rename", "release-fsync", "parent-fsync"],
        )

    def test_interrupted_publication_journal_recovers_without_live_reference(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        publication_id = "e" * 64
        role = manifest.agent_roles["candidate"]
        interrupted = manifest.output_root / role.release_path
        (interrupted / "build").mkdir(parents=True)
        builder._write_json(
            interrupted / "build/bridge-publication.json",
            {"schema_version": 1, "publication_id": publication_id},
            0o444,
        )
        (interrupted / "payload").write_bytes(b"sealed")
        (interrupted / "payload").chmod(0o444)

        class Driver:
            @staticmethod
            def compute_release_tree_sha256(root: Path, _label: str) -> str:
                digest = hashlib.sha256(b"test-publication-tree-v1\0")
                for path in [root, *sorted(root.rglob("*"))]:
                    info = os.lstat(path)
                    digest.update(path.relative_to(root).as_posix().encode() + b"\0")
                    digest.update(stat.S_IMODE(info.st_mode).to_bytes(4, "big"))
                    if path.is_file():
                        digest.update(path.read_bytes())
                return digest.hexdigest()

        interrupted.chmod(0o555)
        expected_tree = Driver.compute_release_tree_sha256(interrupted, "expected")
        interrupted.chmod(0o700)
        trees = {
            "agent_fleet_candidate": expected_tree,
            "agent_fleet_rollback": "1" * 64,
            "quota_axi_candidate": "2" * 64,
            "quota_axi_rollback": "3" * 64,
        }
        journal_path = builder._publication_journal_path(manifest)
        builder._write_json(
            journal_path,
            journal := {
                "schema_version": 1,
                "manifest_sha256": sha(manifest.path),
                "publication_id": publication_id,
                "live_references_changed": False,
                "releases": builder._publication_records(
                    manifest, trees, publication_id
                ),
            },
            0o600,
        )
        staging = Path(journal["releases"][0]["staging_path"])
        staging.mkdir(mode=0o700)
        builder._write_json(
            staging / ".bridge-publication-staging.json",
            {
                "schema_version": 1,
                "publication_id": publication_id,
                "final_path": journal["releases"][0]["path"],
                "tree_sha256": journal["releases"][0]["tree_sha256"],
            },
            0o400,
        )
        (staging / "release").mkdir()
        (staging / "release/partial").write_bytes(b"partial")
        self.assertFalse(builder._recover_interrupted_publication(manifest, Driver))
        self.assertFalse(interrupted.exists())
        self.assertFalse(staging.exists())
        self.assertFalse(journal_path.exists())
        self.assertFalse(manifest.operator_front_door.exists())

    def test_completed_publication_recovery_retires_ownership_journal(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        publication_id = "d" * 64
        trees = {
            "agent_fleet_candidate": "0" * 64,
            "agent_fleet_rollback": "1" * 64,
            "quota_axi_candidate": "2" * 64,
            "quota_axi_rollback": "3" * 64,
        }
        journal_path = builder._publication_journal_path(manifest)
        builder._write_json(
            journal_path,
            {
                "schema_version": 1,
                "manifest_sha256": sha(manifest.path),
                "publication_id": publication_id,
                "live_references_changed": False,
                "releases": builder._publication_records(
                    manifest, trees, publication_id
                ),
            },
            0o600,
        )
        plan_path = builder._front_door_plan_path(manifest)
        expected_plan = {"schema_version": 1, "completed": True}
        builder._write_json(plan_path, expected_plan, 0o444)
        with mock.patch.object(
            builder, "_proof_matches_publication", return_value=True
        ), mock.patch.object(builder, "_front_door_plan", return_value=expected_plan):
            self.assertTrue(builder._recover_interrupted_publication(manifest, object()))
        self.assertFalse(journal_path.exists())

    def test_interrupted_publication_preserves_live_current_release(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        publication_id = "c" * 64
        role = manifest.agent_roles["candidate"]
        interrupted = manifest.output_root / role.release_path
        (interrupted / "build").mkdir(parents=True)
        builder._write_json(
            interrupted / "build/bridge-publication.json",
            {"schema_version": 1, "publication_id": publication_id},
            0o444,
        )
        (interrupted / "payload").write_bytes(b"sealed")
        (interrupted / "payload").chmod(0o444)

        class Driver:
            @staticmethod
            def compute_release_tree_sha256(root: Path, _label: str) -> str:
                digest = hashlib.sha256(b"test-publication-tree-v1\0")
                for path in [root, *sorted(root.rglob("*"))]:
                    info = os.lstat(path)
                    digest.update(path.relative_to(root).as_posix().encode() + b"\0")
                    digest.update(stat.S_IMODE(info.st_mode).to_bytes(4, "big"))
                    if path.is_file():
                        digest.update(path.read_bytes())
                return digest.hexdigest()

        interrupted.chmod(0o555)
        expected_tree = Driver.compute_release_tree_sha256(interrupted, "expected")
        interrupted.chmod(0o700)
        trees = {
            "agent_fleet_candidate": expected_tree,
            "agent_fleet_rollback": "1" * 64,
            "quota_axi_candidate": "2" * 64,
            "quota_axi_rollback": "3" * 64,
        }
        journal_path = builder._publication_journal_path(manifest)
        builder._write_json(
            journal_path,
            {
                "schema_version": 1,
                "manifest_sha256": sha(manifest.path),
                "publication_id": publication_id,
                "live_references_changed": False,
                "releases": builder._publication_records(
                    manifest, trees, publication_id
                ),
            },
            0o600,
        )
        current = interrupted.parent.parent / "current"
        current.symlink_to(interrupted.relative_to(current.parent))
        with self.assertRaisesRegex(builder.BuildError, "referenced by live current"):
            builder._recover_interrupted_publication(manifest, Driver)
        self.assertTrue(interrupted.exists())
        self.assertTrue(journal_path.exists())

    def test_failed_publication_cleanup_preserves_tree_digest_drift(self) -> None:
        published = self.root / "published-drift"
        published.mkdir(mode=0o700)
        payload = published / "payload"
        payload.write_bytes(b"sealed")
        payload.chmod(0o444)
        published.chmod(0o555)

        class Driver:
            @staticmethod
            def compute_release_tree_sha256(root: Path, _label: str) -> str:
                digest = hashlib.sha256()
                for path in [root, *sorted(root.rglob("*"))]:
                    digest.update(path.relative_to(root).as_posix().encode() + b"\0")
                    if path.is_file():
                        digest.update(path.read_bytes())
                return digest.hexdigest()

        identity = (published.stat().st_dev, published.stat().st_ino)
        expected = Driver.compute_release_tree_sha256(published, "expected")
        published.chmod(0o700)
        payload.chmod(0o644)
        payload.write_bytes(b"foreign")
        with self.assertRaisesRegex(builder.BuildError, "release tree changed"):
            builder._remove_tree_if_identity(published, identity, Driver, expected)
        self.assertTrue(published.exists())
        self.assertEqual(payload.read_bytes(), b"foreign")

    def test_interrupted_builder_workspaces_are_recovered_from_journal(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        publication_id = hashlib.sha256(
            b"bridge-sealed-publication-v2\0"
            + manifest.manifest_sha256.encode("ascii")
        ).hexdigest()
        paths = builder._workspace_paths(manifest, publication_id)
        journal_path = builder._workspace_journal_path(manifest)
        builder._write_json(
            journal_path,
            {
                "schema_version": 1,
                "manifest_sha256": manifest.manifest_sha256,
                "publication_id": publication_id,
                "live_references_changed": False,
                "workspaces": [str(path) for path in paths],
            },
            0o600,
        )
        for index, path in enumerate(paths, start=1):
            builder._create_builder_workspace(
                manifest, publication_id, path, index
            )
            (path / "interrupted-payload").write_bytes(b"partial")
        builder._recover_builder_workspaces(manifest, publication_id)
        self.assertFalse(journal_path.exists())
        self.assertTrue(all(not path.exists() for path in paths))

    def test_workspace_recovery_handles_sigkill_before_marker_publication(self) -> None:
        manifest = builder.load_manifest(self.fixture.path)
        publication_id = hashlib.sha256(
            b"bridge-sealed-publication-v2\0"
            + manifest.manifest_sha256.encode("ascii")
        ).hexdigest()
        paths = builder._workspace_paths(manifest, publication_id)
        journal_path = builder._workspace_journal_path(manifest)
        builder._write_json_no_replace(
            journal_path,
            {
                "schema_version": 1,
                "manifest_sha256": manifest.manifest_sha256,
                "publication_id": publication_id,
                "live_references_changed": False,
                "workspaces": [str(path) for path in paths],
            },
            0o600,
        )
        paths[0].mkdir(mode=0o700)
        builder._recover_builder_workspaces(manifest, publication_id)
        self.assertFalse(journal_path.exists())
        self.assertTrue(all(not path.exists() for path in paths))

    def test_exact_build_lock_refuses_concurrent_consumer(self) -> None:
        lock = self.root / "sealed-builder.lock"
        descriptor = builder._open_sealed_build_lock(lock)
        try:
            with self.assertRaisesRegex(builder.BuildError, "already running"):
                builder._open_sealed_build_lock(lock)
        finally:
            builder.fcntl.flock(descriptor, builder.fcntl.LOCK_UN)
            os.close(descriptor)

    def test_bootstrap_is_exact_consumer_contract(self) -> None:
        expected = (
            "from pathlib import Path\n"
            "import runpy\n"
            "import sys\n"
            "ROOT = Path(__file__).resolve().parent\n"
            'sys.path.insert(0, str(ROOT / "site-packages"))\n'
            'runpy.run_module("agent_fleet", run_name="__main__", alter_sys=True)\n'
        ).encode()
        self.assertEqual(
            (ROOT / "tools/bridge-cutover/sealed_agent_fleet_bootstrap.py").read_bytes(),
            expected,
        )

    def test_builder_has_no_personal_path_or_worker_registry_inputs(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("/Users/", source)
        self.assertNotIn("claude-", source)
        self.assertNotIn("codex-", source)
        self.assertNotIn("credentials", source.lower())

    @unittest.skipUnless(sys.platform == "darwin", "native launchers are macOS-only")
    def test_generated_native_sources_pass_strict_clang_syntax(self) -> None:
        entries = [{"path": "runtime/node", "mode": "0555", "sha256": "1" * 64}]
        sources = {
            "agent.c": builder.generate_agent_launcher_source(
                entries, ["runtime"], ["runtime"], "2" * 64
            ),
            "quota.c": builder.generate_quota_launcher_source(
                entries, ["runtime"], ["runtime"], "2" * 64
            ),
            "front.c": builder.generate_agent_front_door_source(
                Path("/safe/agent-fleet"), "3" * 64
            ),
        }
        for name, source in sources.items():
            with self.subTest(name=name):
                path = self.root / name
                path.write_text(source, encoding="utf-8")
                completed = subprocess.run(
                    [
                        "/usr/bin/clang",
                        "-std=c11",
                        "-Wall",
                        "-Wextra",
                        "-Werror",
                        "-Wno-deprecated-declarations",
                        "-Wno-unused-function",
                        "-Wno-unused-const-variable",
                        "-fsyntax-only",
                        str(path),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "native launchers are macOS-only")
    def test_front_door_uses_physical_self_for_path_and_hostile_argv0(self) -> None:
        target_source = self.root / "target.c"
        target = self.root / "target"
        target_source.write_text(
            '#include <string.h>\nint main(int c,char **v){return c==2 && strcmp(v[1],"ok")==0 ? 0 : 77;}\n',
            encoding="utf-8",
        )
        subprocess.run(
            ["/usr/bin/clang", "-std=c11", "-o", str(target), str(target_source)],
            check=True,
            capture_output=True,
            text=True,
        )
        target.chmod(0o555)
        front_source = self.root / "front.c"
        front = self.root / "agent-fleet"
        front_source.write_text(
            builder.generate_agent_front_door_source(target, sha(target)),
            encoding="utf-8",
        )
        subprocess.run(
            ["/usr/bin/clang", *builder.CLANG_FLAGS, "-o", str(front), str(front_source)],
            check=True,
            capture_output=True,
            text=True,
        )
        front.chmod(0o555)
        by_path = subprocess.run(
            ["agent-fleet", "ok"],
            env={"PATH": str(self.root)},
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(by_path.returncode, 0, by_path.stderr)
        hostile_argv0 = subprocess.run(
            ["hostile-argv-zero", "ok"],
            executable=str(front),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(hostile_argv0.returncode, 0, hostile_argv0.stderr)
        hardlink = self.root / "front-hardlink"
        os.link(front, hardlink)
        rejected = subprocess.run(
            [str(front), "ok"], check=False, capture_output=True, text=True
        )
        self.assertEqual(rejected.returncode, 126)

    @unittest.skipUnless(
        sys.platform == "darwin" and Path("/usr/bin/xattr").is_file(),
        "macOS xattr policy",
    )
    def test_normalization_clears_custom_xattrs_and_seals_root(self) -> None:
        root = self.root / "sealed"
        root.mkdir()
        executable = root / "run"
        executable.write_text("payload\n", encoding="utf-8")
        subprocess.run(
            [
                "/usr/bin/xattr",
                "-w",
                "com.relvino.bridge-cutover-test",
                "hostile",
                str(executable),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        pin = builder.ToolPin(Path("/usr/bin/xattr"), sha(Path("/usr/bin/xattr")))
        builder._normalize_modes(root, {"run"}, pin)
        builder._assert_closed_tree(root, pin)
        self.assertEqual(stat.S_IMODE(root.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE(executable.stat().st_mode), 0o555)


if __name__ == "__main__":
    unittest.main()
