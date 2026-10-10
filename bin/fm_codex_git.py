"""Task-private Git and trusted exact-head import for the app-server adapter."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


class PrivateGitVerificationError(ValueError):
    """The task-private result failed an intentional publication check."""


def _env():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
    return env


def git(directory, *args, data=None):
    return subprocess.check_output(
        ["git", "--no-replace-objects", "-c", "core.hooksPath=" + os.devnull,
         "-C", str(directory), *args], input=data, env=_env())


def git_dir(gitdir, *args, data=None):
    return subprocess.check_output(
        ["git", "--no-replace-objects", "--git-dir=" + str(gitdir),
         "-c", "core.hooksPath=" + os.devnull, *args], input=data, env=_env())


def _git_command(directory, git_dir_mode, *args):
    if git_dir_mode:
        return ["git", "--no-replace-objects", "--git-dir=" + str(directory),
                "-c", "core.hooksPath=" + os.devnull, *args]
    return ["git", "--no-replace-objects", "-c", "core.hooksPath=" + os.devnull,
            "-C", str(directory), *args]


def _transfer_pack(source, source_git_dir, destination, destination_git_dir, oid):
    env = _env()
    env["LC_ALL"] = "C"
    producer = subprocess.Popen(_git_command(
        source, source_git_dir, "pack-objects", "--stdout", "--revs"),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=env)
    try:
        producer.stdin.write((oid + "\n").encode())
        producer.stdin.close()
        consumer = subprocess.Popen(_git_command(
            destination, destination_git_dir, "index-pack", "--stdin"),
            stdin=producer.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            env=env)
        producer.stdout.close()
        _, error = consumer.communicate()
        producer_status = producer.wait()
    except BaseException:
        producer.kill()
        producer.wait()
        raise
    if consumer.returncode:
        if any(message in error.lower() for message in
               (b"no space left", b"disk quota exceeded", b"device is full")):
            raise PrivateGitCapacityError("task-private Git pack import exceeded available storage")
        raise subprocess.CalledProcessError(consumer.returncode, consumer.args, stderr=error)
    if producer_status:
        raise subprocess.CalledProcessError(producer_status, producer.args)


class PrivateGitCapacityError(PrivateGitVerificationError):
    """Pack import failed because the destination has no available capacity."""


class PrivateGit:
    """A per-task Git store. Only validated reachable objects cross into canonical Git."""

    def __init__(self, worktree, root, branch, task, generation):
        self.published = False
        self.worktree = Path(worktree).resolve()
        self.root = Path(root).resolve()
        self.task = task
        self.generation = generation
        self.owner_file = self.root.parent / (self.root.name + ".owner")
        self.pointer = self.worktree / ".git"
        if not self.pointer.is_file() or self.pointer.is_symlink():
            raise ValueError("app-server ship requires a linked worktree")
        self.original = self.pointer.read_bytes()
        if b"\x00" in self.original or not self.original.startswith(b"gitdir: "):
            raise ValueError("invalid linked-worktree Git pointer")
        pointer = self.original.decode("utf-8").strip()
        if not pointer.startswith("gitdir: ") or "\n" in pointer:
            raise ValueError("invalid linked-worktree Git pointer")
        recorded_gitdir = Path(pointer[8:])
        if not recorded_gitdir.is_absolute():
            recorded_gitdir = self.worktree / recorded_gitdir
        if recorded_gitdir.resolve() == self.root:
            self._recover_stale_pointer()
            raise ValueError("recovered stale task-private Git pointer; retry the operation")
        self.canonical = Path(git(self.worktree, "rev-parse",
                                  "--absolute-git-dir").decode().strip()).resolve()
        if recorded_gitdir.resolve() != self.canonical:
            raise ValueError("linked-worktree Git pointer changed during setup")
        if os.stat(self.root.parent).st_dev in {
                os.stat(self.worktree).st_dev, os.stat(self.canonical).st_dev}:
            raise ValueError("task-private Git must be on a separate filesystem")
        self.base = git(self.worktree, "rev-parse", "HEAD").decode().strip()
        git(self.worktree, "check-ref-format", "--branch", branch)
        self.ref = "refs/heads/" + branch
        prior = subprocess.run(["git", "-C", str(self.worktree), "rev-parse",
                                "--verify", self.ref],
                               capture_output=True, text=True, env=_env())
        self.old = prior.stdout.strip() if prior.returncode == 0 else "0" * len(self.base)
        if self.old != "0" * len(self.base) and self.old != self.base:
            raise ValueError("task branch differs from worktree base")
        if git(self.worktree, "status", "--porcelain").strip():
            raise ValueError("private Git setup requires a clean task worktree")
        self.root.mkdir(mode=0o700)
        self.preserve_root_on_failure = False
        try:
            git(self.root, "init", "--bare", "--quiet")
            self.preserve_root_on_failure = True
            _transfer_pack(self.worktree, False, self.root, False, self.base)
            git(self.root, "update-ref", self.ref, self.base)
            git(self.root, "symbolic-ref", "HEAD", self.ref)
            git(self.root, "config", "core.bare", "false")
            git(self.root, "config", "core.worktree", str(self.worktree))
            git(self.root, "config", "core.hooksPath", os.devnull)
            git(self.root, "config", "commit.gpgsign", "false")
            for key in ("user.name", "user.email"):
                value = subprocess.run(["git", "-C", str(self.worktree),
                    "config", "--get", key], capture_output=True, env=_env())
                if value.returncode == 0:
                    git(self.root, "config", key, value.stdout.decode().strip())
            config = self.root / "config"
            self.config_hash = hashlib.sha256(config.read_bytes()).digest()
            self._write_owner_record()
            self.pointer_active = False
            self._write_pointer(("gitdir: " + str(self.root) + "\n").encode())
            self.pointer_active = True
            git(self.worktree, "read-tree", self.base)
        except BaseException:
            self.restore()
            if not self.preserve_root_on_failure:
                shutil.rmtree(self.root, ignore_errors=True)
            raise

    def _owner_record(self):
        return {"task": self.task, "generation": self.generation,
                "worktree": str(self.worktree), "canonical": str(self.canonical),
                "original": base64.b64encode(self.original).decode("ascii")}

    def _write_owner_record(self):
        payload = (json.dumps(self._owner_record(), sort_keys=True) + "\n").encode()
        fd = os.open(self.owner_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)

    def _recover_stale_pointer(self):
        if (self.root.is_symlink() or not self.root.is_dir() or
                self.owner_file.is_symlink() or not self.owner_file.is_file() or
                self.owner_file.stat().st_nlink != 1):
            raise ValueError("stale private Git pointer has no safe owner record")
        record = json.loads(self.owner_file.read_text())
        if (record.get("task") != self.task or record.get("generation") != self.generation or
                record.get("worktree") != str(self.worktree)):
            raise ValueError("stale private Git pointer belongs to another task or generation")
        canonical = Path(record.get("canonical", "/"))
        original = base64.b64decode(record["original"], validate=True)
        try:
            original_pointer = original.decode("utf-8").strip()
            original_gitdir = Path(original_pointer[8:])
            if not original_pointer.startswith("gitdir: "):
                raise ValueError
            if not original_gitdir.is_absolute():
                original_gitdir = self.worktree / original_gitdir
        except (UnicodeDecodeError, ValueError):
            raise ValueError("stale private Git pointer owner record is invalid") from None
        if original_gitdir.resolve() != canonical.resolve():
            raise ValueError("stale private Git pointer owner record is invalid")
        relation = canonical / "gitdir"
        if (relation.is_symlink() or not relation.is_file() or
                Path(relation.read_text().strip()).resolve() != self.pointer.resolve()):
            raise ValueError("stale private Git pointer repository ownership is unverified")
        if self.pointer.read_bytes() != ("gitdir: " + str(self.root) + "\n").encode():
            raise ValueError("stale private Git pointer changed during recovery")
        self._write_pointer(original)

    def _write_pointer(self, value):
        temporary = self.worktree / (".git-pointer-" + str(os.getpid()))
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(value)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, self.pointer)

    def restore(self):
        if not getattr(self, "pointer_active", False):
            return
        self._write_pointer(self.original)
        self.pointer_active = False

    def cleanup(self):
        self.restore()
        if self.published:
            shutil.rmtree(self.root)
            self.owner_file.unlink(missing_ok=True)
            try:
                self.root.parent.rmdir()
            except OSError:
                pass

    def _verified_head(self):
        if self.root.is_symlink() or not self.root.is_dir():
            raise PrivateGitVerificationError("task-private Git root is unsafe")
        for name in ("commondir", "gitdir", "config.worktree", "shallow",
                     "packed-refs", "info/grafts", "objects/info/alternates",
                     "objects/info/http-alternates"):
            path = self.root / name
            if path.is_symlink() or path.exists():
                raise PrivateGitVerificationError("task-private Git metadata redirection is not accepted")
        config = self.root / "config"
        if config.is_symlink() or not config.is_file() or hashlib.sha256(config.read_bytes()).digest() != self.config_hash:
            raise PrivateGitVerificationError("task-private Git configuration changed")
        ref_parts = Path(self.ref).parts
        ref_parent = self.root
        for part in ref_parts[:-1]:
            ref_parent = ref_parent / part
            if ref_parent.is_symlink() or not ref_parent.is_dir():
                raise PrivateGitVerificationError("task-private refs directory is unsafe")
        head_file = self.root / "HEAD"
        ref_file = ref_parent / ref_parts[-1]
        for path in (head_file, ref_file):
            if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
                raise PrivateGitVerificationError("task-private task ref is missing or unsafe")
        if head_file.read_text().strip() != "ref: " + self.ref:
            raise PrivateGitVerificationError("task-private HEAD is not the assigned task branch")
        oid = ref_file.read_text().strip()
        if not re.fullmatch("[0-9a-f]{" + str(len(self.base)) + "}", oid) or oid == self.base:
            raise PrivateGitVerificationError("task-private HEAD is invalid or has no ship commit")
        refs = []
        for directory, dirs, files in os.walk(self.root / "refs", followlinks=False):
            directory = Path(directory)
            if any((directory / name).is_symlink() for name in dirs + files):
                raise PrivateGitVerificationError("task-private refs contain symlinks")
            refs.extend(str((directory / name).relative_to(self.root)) for name in files)
        if refs != [self.ref]:
            raise PrivateGitVerificationError("task-private Git contains unrelated refs")
        return oid

    def publish(self, snapshot_parent):
        oid = self._verified_head()
        with tempfile.TemporaryDirectory(prefix="appserver-import-", dir=snapshot_parent) as tmp:
            snapshot = Path(tmp)
            git(snapshot, "init", "--bare", "--quiet")
            source = self.root / "objects"
            for directory, dirs, files in os.walk(source, followlinks=False):
                directory = Path(directory)
                if directory.is_symlink() or any((directory / name).is_symlink() for name in dirs):
                    raise PrivateGitVerificationError("private object directory contains symlink")
                relative = directory.relative_to(source)
                target = snapshot / "objects" / relative
                target.mkdir(exist_ok=True)
                for name in files:
                    path = directory / name
                    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
                        raise PrivateGitVerificationError("private object is not an isolated regular file")
                    if relative == Path("info"):
                        continue
                    shutil.copyfile(path, target / name)
            index = self.root / "index"
            if index.is_symlink() or not index.is_file() or index.stat().st_nlink != 1:
                raise PrivateGitVerificationError("task-private index is unsafe")
            shutil.copyfile(index, snapshot / "index")
            try:
                flags = git_dir(snapshot, "ls-files", "-v", "-z").split(b"\0")
            except subprocess.CalledProcessError as exc:
                raise PrivateGitVerificationError("task-private index is invalid") from exc
            if any(entry and (entry[:1].islower() or entry[:1].upper() == b"S")
                   for entry in flags):
                raise PrivateGitVerificationError("task-private index contains assume-unchanged or skip-worktree entries")
            git(snapshot, "update-ref", self.ref, oid)
            git(snapshot, "symbolic-ref", "HEAD", self.ref)
            for args in (("diff", "--quiet", "--no-ext-diff", "--no-textconv", oid, "--"),
                         ("diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv", oid, "--")):
                try:
                    git_dir(snapshot, "--work-tree=" + str(self.worktree),
                            "-c", "core.bare=false", "-c", "core.fsmonitor=false", *args)
                except subprocess.CalledProcessError as exc:
                    raise PrivateGitVerificationError(
                        "task-private worktree has uncommitted tracked changes") from exc
            checks = (
                (("cat-file", "-e", oid + "^{commit}"), "task-private HEAD is not a commit"),
                (("merge-base", "--is-ancestor", self.base, oid),
                 "task-private commit does not descend from its base"),
                (("fsck", "--strict", "--no-reflogs", oid),
                 "task-private commit failed integrity verification"),
            )
            for args, reason in checks:
                try:
                    git(snapshot, *args)
                except subprocess.CalledProcessError as exc:
                    raise PrivateGitVerificationError(reason) from exc
            # This process is outside the worker sandbox. CAS refuses a branch
            # moved by another supervisor since task setup.
            _transfer_pack(snapshot, False, self.canonical, True, oid)
            git_dir(self.canonical, "update-ref", self.ref, oid, self.old)
            self.restore()
            git(self.worktree, "symbolic-ref", "HEAD", self.ref)
            git(self.worktree, "read-tree", oid)
        self.published = True
        return oid
