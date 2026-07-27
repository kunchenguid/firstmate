from __future__ import annotations

import json
import math
import os
import shutil
import socket
import stat
import time
import uuid
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Any

from .paths import ensure_private_dir
from .util import process_identity_state, process_start_token


class DirectoryLock:
    """Portable inter-process lock based on atomic directory creation."""

    def __init__(
        self,
        path: Path,
        *,
        stale_seconds: int,
        timeout: float = 10.0,
        purpose: str = "exclusive",
        test_hook: Callable[[str, Path], None] | None = None,
    ):
        self.path = path
        self.stale_seconds = stale_seconds
        self.timeout = timeout
        self.nonce = uuid.uuid4().hex
        process_start = process_start_token(os.getpid())
        if process_start is None:
            raise RuntimeError("cannot acquire a Fleet lock without a verified process start token")
        self.owner = {
            "schema": 1,
            "pid": os.getpid(),
            "process_start": process_start,
            "hostname": socket.gethostname(),
            "created_unix": time.time(),
            "nonce": self.nonce,
            "purpose": purpose,
        }
        self.acquired = False
        self._directory_fd: int | None = None
        self._directory_identity: tuple[int, int] | None = None
        self._test_hook = test_hook

    @property
    def owner_path(self) -> Path:
        return self.path / "owner.json"

    @staticmethod
    def _directory_flags() -> int:
        return os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)

    def _open_directory(self, path: Path) -> tuple[int, tuple[int, int]]:
        try:
            descriptor = os.open(path, self._directory_flags())
        except FileNotFoundError:
            raise
        except OSError as exc:
            raise ValueError(f"unsafe Fleet lock directory: {path}") from exc
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o700
            ):
                raise ValueError(f"unsafe Fleet lock directory: {path}")
            current = os.stat(path, follow_symlinks=False)
            identity = (opened.st_dev, opened.st_ino)
            if identity != (current.st_dev, current.st_ino):
                raise ValueError(f"Fleet lock directory changed while opening: {path}")
            return descriptor, identity
        except BaseException:
            os.close(descriptor)
            raise

    @staticmethod
    def _read_owner_fd(descriptor: int) -> tuple[bytes | None, dict[str, Any] | None]:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            owner_fd = os.open("owner.json", flags, dir_fd=descriptor)
        except FileNotFoundError:
            return None, None
        except OSError:
            return b"unsafe-owner", None
        try:
            opened = os.fstat(owner_fd)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_nlink != 1
            ):
                return b"unsafe-owner", None
            current = os.stat(
                "owner.json",
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
                return b"changed-owner", None
            chunks: list[bytes] = []
            while True:
                chunk = os.read(owner_fd, 64 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            raw = b"".join(chunks)
        finally:
            os.close(owner_fd)
        try:
            value = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return raw, None
        return raw, value if isinstance(value, dict) else None

    def _owner_snapshot(
        self, path: Path
    ) -> tuple[tuple[int, int], bytes | None, dict[str, Any] | None, float]:
        descriptor, identity = self._open_directory(path)
        try:
            raw, owner = self._read_owner_fd(descriptor)
            opened = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        return identity, raw, owner, self._age(owner, opened.st_mtime)

    def _owner(self) -> dict[str, Any] | None:
        try:
            descriptor, _ = self._open_directory(self.path)
        except (FileNotFoundError, ValueError):
            return None
        try:
            _, owner = self._read_owner_fd(descriptor)
            return owner
        finally:
            os.close(descriptor)

    @staticmethod
    def _age(owner: dict[str, Any] | None, directory_mtime: float) -> float:
        created = owner.get("created_unix") if owner is not None else None
        if (
            isinstance(created, (int, float))
            and not isinstance(created, bool)
            and math.isfinite(float(created))
        ):
            return max(0.0, time.time() - float(created))
        return max(0.0, time.time() - directory_mtime)

    @staticmethod
    def _owner_reclaimable(owner: dict[str, Any] | None) -> bool:
        if owner is None:
            return True
        if owner.get("hostname") != socket.gethostname():
            return False
        pid = owner.get("pid")
        start = owner.get("process_start")
        if not isinstance(pid, int) or isinstance(pid, bool):
            return True
        return process_identity_state(pid, start if isinstance(start, str) else None) == "dead"

    def _quarantines(self) -> list[Path]:
        return sorted(self.path.parent.glob(f".{self.path.name}.stale.*"))

    @staticmethod
    def _path_identity(path: Path) -> tuple[int, int] | None:
        try:
            current = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            return None
        return current.st_dev, current.st_ino

    def _restore_quarantine(self, quarantine: Path, identity: tuple[int, int]) -> bool:
        if (
            self._path_identity(quarantine) != identity
            or self.path.exists()
            or self.path.is_symlink()
        ):
            return False
        try:
            os.replace(quarantine, self.path)
        except OSError:
            return False
        return self._path_identity(self.path) == identity

    def _remove_quarantine(self, quarantine: Path, identity: tuple[int, int]) -> bool:
        if self._path_identity(quarantine) != identity:
            return False
        try:
            shutil.rmtree(quarantine, ignore_errors=False)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return True

    def _recover_quarantines(self) -> bool:
        for quarantine in self._quarantines():
            try:
                identity, raw, owner, age = self._owner_snapshot(quarantine)
            except FileNotFoundError:
                continue
            except ValueError:
                return False
            if age <= self.stale_seconds or not self._owner_reclaimable(owner):
                if not self._restore_quarantine(quarantine, identity):
                    return False
                continue
            try:
                current_identity, current_raw, current_owner, current_age = self._owner_snapshot(
                    quarantine
                )
            except FileNotFoundError:
                continue
            except ValueError:
                return False
            if (
                current_identity != identity
                or current_raw != raw
                or current_age <= self.stale_seconds
                or not self._owner_reclaimable(current_owner)
            ):
                if not self._restore_quarantine(quarantine, identity):
                    return False
                continue
            if not self._remove_quarantine(quarantine, identity):
                return False
        return True

    def _reclaim_if_stale(self) -> bool:
        try:
            identity, raw, owner, age = self._owner_snapshot(self.path)
        except FileNotFoundError:
            return True
        except ValueError:
            return False
        if age <= self.stale_seconds or not self._owner_reclaimable(owner):
            return False
        tombstone = self.path.with_name(f".{self.path.name}.stale.{uuid.uuid4().hex}")
        try:
            os.replace(self.path, tombstone)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        if self._path_identity(tombstone) != identity:
            self._restore_quarantine(tombstone, identity)
            return False
        if self._test_hook is not None:
            self._test_hook("post-reclaim-rename", tombstone)
        try:
            current_identity, current_raw, current_owner, current_age = self._owner_snapshot(
                tombstone
            )
        except (FileNotFoundError, ValueError):
            self._restore_quarantine(tombstone, identity)
            return False
        if (
            current_identity != identity
            or current_raw != raw
            or current_age <= self.stale_seconds
            or not self._owner_reclaimable(current_owner)
        ):
            self._restore_quarantine(tombstone, identity)
            return False
        return self._remove_quarantine(tombstone, identity)

    def held(self) -> bool:
        """Return whether a live owner holds this lock, reclaiming stale state."""

        if not self._recover_quarantines():
            return True
        if not self.path.exists():
            return False
        self._reclaim_if_stale()
        return self.path.exists()

    def _write_owner_fd(self, descriptor: int) -> None:
        payload = (json.dumps(self.owner, indent=2, sort_keys=True) + "\n").encode()
        temporary = f".owner.{self.nonce}.tmp"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        owner_fd = os.open(temporary, flags, 0o600, dir_fd=descriptor)
        try:
            os.fchmod(owner_fd, 0o600)
            view = memoryview(payload)
            while view:
                written = os.write(owner_fd, view)
                view = view[written:]
            os.fsync(owner_fd)
            os.link(
                temporary,
                "owner.json",
                src_dir_fd=descriptor,
                dst_dir_fd=descriptor,
                follow_symlinks=False,
            )
            os.unlink(temporary, dir_fd=descriptor)
            os.fsync(descriptor)
        except BaseException:
            with suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=descriptor)
            raise
        finally:
            os.close(owner_fd)

    def _discard_created_directory(self, identity: tuple[int, int]) -> None:
        if self._path_identity(self.path) == identity:
            tombstone = self.path.with_name(f".{self.path.name}.failed.{self.nonce}")
            try:
                os.replace(self.path, tombstone)
            except OSError:
                return
            if self._path_identity(tombstone) == identity:
                shutil.rmtree(tombstone, ignore_errors=True)
            return

        # A reclaimer can rename the just-created directory after mkdir but
        # before owner installation. If another contender passed quarantine
        # recovery immediately before that rename, it may already have
        # installed the new primary lock by the time this creator detects the
        # identity change. Remove only this creator's exact quarantined inode;
        # never touch the successor at the primary path.
        for quarantine in self._quarantines():
            if self._path_identity(quarantine) != identity:
                continue
            try:
                _, _, owner, _ = self._owner_snapshot(quarantine)
            except (FileNotFoundError, ValueError):
                return
            if owner is not None and owner.get("nonce") != self.nonce:
                return
            self._remove_quarantine(quarantine, identity)
            return

    def acquire(self) -> None:
        ensure_private_dir(self.path.parent)
        deadline = time.monotonic() + self.timeout
        while True:
            if not self._recover_quarantines():
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out recovering state lock: {self.path}") from None
                time.sleep(0.05)
                continue
            if self._test_hook is not None:
                self._test_hook("pre-mkdir", self.path)
            try:
                self.path.mkdir(mode=0o700)
            except FileExistsError:
                self._reclaim_if_stale()
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out acquiring state lock: {self.path}") from None
                time.sleep(0.05)
                continue
            descriptor: int | None = None
            identity: tuple[int, int] | None = None
            try:
                descriptor, identity = self._open_directory(self.path)
                if self._quarantines():
                    os.close(descriptor)
                    descriptor = None
                    self._discard_created_directory(identity)
                    if time.monotonic() >= deadline:
                        raise TimeoutError(f"timed out acquiring state lock: {self.path}")
                    time.sleep(0.05)
                    continue
                if self._test_hook is not None:
                    self._test_hook("post-mkdir", self.path)
                self._write_owner_fd(descriptor)
                raw, owner = self._read_owner_fd(descriptor)
                if (
                    self._path_identity(self.path) != identity
                    or raw is None
                    or owner is None
                    or owner.get("nonce") != self.nonce
                ):
                    raise RuntimeError("Fleet lock directory changed during owner installation")
            except BaseException:
                if descriptor is not None:
                    os.close(descriptor)
                if identity is not None:
                    self._discard_created_directory(identity)
                raise
            self._directory_fd = descriptor
            self._directory_identity = identity
            self.acquired = True
            return

    def release(self) -> None:
        if not self.acquired:
            return
        descriptor = self._directory_fd
        identity = self._directory_identity
        if descriptor is None or identity is None:
            raise RuntimeError(f"state lock descriptor is unavailable: {self.path}")
        _, owner = self._read_owner_fd(descriptor)
        if owner is None or owner.get("nonce") != self.nonce:
            raise RuntimeError(f"state lock ownership changed unexpectedly: {self.path}")
        if self._path_identity(self.path) != identity:
            raise RuntimeError(f"state lock directory changed unexpectedly: {self.path}")
        tombstone = self.path.with_name(f".{self.path.name}.release.{self.nonce}")
        os.replace(self.path, tombstone)
        if self._path_identity(tombstone) != identity:
            self._restore_quarantine(tombstone, identity)
            raise RuntimeError(f"state lock release moved an unexpected directory: {self.path}")
        os.close(descriptor)
        self._directory_fd = None
        shutil.rmtree(tombstone, ignore_errors=False)
        self.acquired = False
        self._directory_identity = None

    def __enter__(self) -> DirectoryLock:
        self.acquire()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.release()


def state_lock(state_dir: Path, stale_seconds: int, *, timeout: float = 10.0) -> DirectoryLock:
    return DirectoryLock(
        state_dir / "locks" / "registry.lock",
        stale_seconds=stale_seconds,
        timeout=timeout,
    )


def provider_enrollment_lock(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
    *,
    timeout: float = 10.0,
) -> DirectoryLock:
    return DirectoryLock(
        state_dir / "locks" / f"provider-enrollment-{provider}.lock",
        stale_seconds=stale_seconds,
        timeout=timeout,
        purpose="maintenance",
    )


def provider_selection_refresh_lock(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
    *,
    timeout: float = 10.0,
) -> DirectoryLock:
    path = state_dir / "locks" / f"provider-enrollment-{provider}.lock"

    class SelectionRefreshLock(DirectoryLock):
        def acquire(self) -> None:
            while True:
                try:
                    super().acquire()
                    return
                except TimeoutError:
                    owner = self._owner()
                    if owner is not None and owner.get("purpose") == "selection-refresh":
                        continue
                    if not self.path.exists():
                        continue
                    raise

    return SelectionRefreshLock(
        path,
        stale_seconds=stale_seconds,
        timeout=timeout,
        purpose="selection-refresh",
    )


def provider_maintenance_active(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
) -> bool:
    lock = provider_enrollment_lock(
        state_dir,
        provider,
        stale_seconds,
        timeout=0,
    )
    if not lock.held():
        return False
    owner = lock._owner()
    # mkdir necessarily precedes the atomic owner.json write. Avoid treating
    # that tiny initialization window as auth maintenance and spuriously
    # rejecting a concurrent selection; an owner that stays absent remains
    # fail-closed.
    for _ in range(10):
        if owner is not None:
            break
        time.sleep(0.005)
        owner = lock._owner()
    # A missing/corrupt owner is fail-closed. Selection refreshes use the same
    # exclusion primitive to serialize quota writes, but they are not auth
    # maintenance and therefore do not block another lease commit.
    return owner is None or owner.get("purpose") != "selection-refresh"
