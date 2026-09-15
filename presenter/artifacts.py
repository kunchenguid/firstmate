"""Artifact source abstraction and filesystem implementation.

Adapter Seam for Polymath SessionArtifactRepository:
---------------------------------------------------
In the polymath platform, simulation artifacts, generated waveforms,
schematic netlists, and data plots are tracked and persisted by
`SessionArtifactRepository`.

While `SessionArtifactRepository` is external to this repository and writing
its concrete adapter is out of scope for this lane, `ArtifactSource` defines the
required protocol seam. An adapter can easily wrap a `SessionArtifactRepository`
instance, for example:

    class SessionArtifactSource(ArtifactSource):
        def __init__(self, repo: SessionArtifactRepository) -> None:
            self._repo = repo

        def resolve_path(self, ref: str) -> Path:
            # Resolves artifact ref/UUID to locally cached file path
            return self._repo.get_cached_path(ref)

        def resolve_bytes(self, ref: str) -> bytes:
            return self._repo.read_bytes(ref)

        def resolve(self, ref: str) -> Path:
            return self.resolve_path(ref)

        def exists(self, ref: str) -> bool:
            return self._repo.has_artifact(ref)

This decouples presentation and document generation from the storage backend.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Protocol, runtime_checkable


@runtime_checkable
class ArtifactSource(Protocol):
    """Protocol for resolving artifact references to local filesystem paths or bytes."""

    def resolve_path(self, ref: str) -> Path:
        """Resolve an artifact reference to a local filesystem path.

        Raises:
            FileNotFoundError: If the artifact does not exist.
            ValueError: If the reference is invalid or insecure.
        """
        ...

    def resolve_bytes(self, ref: str) -> bytes:
        """Resolve an artifact reference to its raw binary content.

        Raises:
            FileNotFoundError: If the artifact does not exist.
            ValueError: If the reference is invalid or insecure.
        """
        ...

    def resolve(self, ref: str) -> Path | bytes:
        """Resolve an artifact reference to either a local Path or raw bytes."""
        ...

    def exists(self, ref: str) -> bool:
        """Check whether an artifact reference exists."""
        ...


class FilesystemArtifactSource:
    """Artifact source backed by a local directory on the filesystem."""

    def __init__(self, root_dir: str | Path, allow_absolute: bool = False) -> None:
        """Initialize with a root directory.

        Args:
            root_dir: Base directory from which relative artifact references are resolved.
            allow_absolute: If True, allow absolute paths outside root_dir. Defaults to False.
        """
        self.root_dir = Path(root_dir).resolve()
        self.allow_absolute = allow_absolute

    def _safe_resolve(self, ref: str) -> Path:
        """Resolve reference and guard against directory traversal attacks."""
        raw_path = Path(ref)
        if raw_path.is_absolute():
            if self.allow_absolute:
                return raw_path.resolve()
            # If absolute, verify it sits inside root_dir
            resolved = raw_path.resolve()
            try:
                resolved.relative_to(self.root_dir)
                return resolved
            except ValueError:
                raise ValueError(
                    f"Absolute artifact path '{ref}' is outside root directory '{self.root_dir}'"
                )

        resolved = (self.root_dir / raw_path).resolve()
        try:
            resolved.relative_to(self.root_dir)
        except ValueError:
            raise ValueError(
                f"Artifact reference '{ref}' escapes root directory '{self.root_dir}'"
            )
        return resolved

    def resolve_path(self, ref: str) -> Path:
        """Resolve an artifact reference to an existing local filesystem Path."""
        resolved = self._safe_resolve(ref)
        if not resolved.exists():
            raise FileNotFoundError(
                f"Artifact '{ref}' not found at resolved path '{resolved}'"
            )
        return resolved

    def resolve_bytes(self, ref: str) -> bytes:
        """Resolve an artifact reference and read its binary content."""
        return self.resolve_path(ref).read_bytes()

    def resolve(self, ref: str) -> Path:
        """Resolve an artifact reference to a local filesystem Path."""
        return self.resolve_path(ref)

    def exists(self, ref: str) -> bool:
        """Check if an artifact reference resolves and exists."""
        try:
            resolved = self._safe_resolve(ref)
            return resolved.exists()
        except (ValueError, FileNotFoundError):
            return False


__all__ = ["ArtifactSource", "FilesystemArtifactSource"]
