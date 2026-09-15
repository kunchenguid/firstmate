"""Tests for presenter.artifacts module."""

from __future__ import annotations

import sys
from pathlib import Path
import pytest

# Ensure repository root is on sys.path
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from presenter.artifacts import ArtifactSource, FilesystemArtifactSource


def test_artifact_source_protocol_conformance(tmp_path: Path) -> None:
    """Verify FilesystemArtifactSource implements ArtifactSource protocol."""
    source = FilesystemArtifactSource(tmp_path)
    assert isinstance(source, ArtifactSource)


def test_resolve_path_success(tmp_path: Path) -> None:
    """Verify resolving an existing relative path returns the correct Path."""
    test_file = tmp_path / "plot.png"
    test_file.write_bytes(b"fake_png_data")

    source = FilesystemArtifactSource(tmp_path)
    resolved = source.resolve_path("plot.png")
    assert resolved == test_file.resolve()
    assert resolved.exists()


def test_resolve_path_nonexistent_raises_filenotfound(tmp_path: Path) -> None:
    """Verify resolving a non-existent path raises FileNotFoundError."""
    source = FilesystemArtifactSource(tmp_path)
    with pytest.raises(FileNotFoundError, match="not found"):
        source.resolve_path("missing.png")


def test_resolve_bytes_success(tmp_path: Path) -> None:
    """Verify resolve_bytes returns the exact raw file bytes."""
    data = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    test_file = tmp_path / "sample.png"
    test_file.write_bytes(data)

    source = FilesystemArtifactSource(tmp_path)
    content = source.resolve_bytes("sample.png")
    assert content == data


def test_resolve_method(tmp_path: Path) -> None:
    """Verify resolve() returns a Path."""
    test_file = tmp_path / "data.csv"
    test_file.write_text("x,y\n1,2\n", encoding="utf-8")

    source = FilesystemArtifactSource(tmp_path)
    resolved = source.resolve("data.csv")
    assert isinstance(resolved, Path)
    assert resolved == test_file.resolve()


def test_exists_method(tmp_path: Path) -> None:
    """Verify exists() correctly reports presence/absence of artifacts."""
    test_file = tmp_path / "valid.txt"
    test_file.write_text("hello", encoding="utf-8")

    source = FilesystemArtifactSource(tmp_path)
    assert source.exists("valid.txt") is True
    assert source.exists("nonexistent.txt") is False


def test_path_traversal_prevention(tmp_path: Path) -> None:
    """Verify attempts to escape the root directory raise ValueError."""
    source = FilesystemArtifactSource(tmp_path)

    with pytest.raises(ValueError, match="escapes root directory"):
        source.resolve_path("../outside.txt")

    with pytest.raises(ValueError, match="escapes root directory"):
        source.resolve_path("../../etc/passwd")

    assert source.exists("../outside.txt") is False


def test_absolute_path_handling(tmp_path: Path) -> None:
    """Verify absolute path rules with allow_absolute=False vs True."""
    outside_dir = tmp_path.parent
    outside_file = outside_dir / "outside_test_file.tmp"
    outside_file.write_text("outside", encoding="utf-8")

    try:
        # Default: allow_absolute=False
        source_strict = FilesystemArtifactSource(tmp_path, allow_absolute=False)
        with pytest.raises(ValueError, match="outside root directory"):
            source_strict.resolve_path(str(outside_file))

        # With allow_absolute=True
        source_permissive = FilesystemArtifactSource(tmp_path, allow_absolute=True)
        resolved = source_permissive.resolve_path(str(outside_file))
        assert resolved == outside_file.resolve()
        assert source_permissive.resolve_bytes(str(outside_file)) == b"outside"
    finally:
        if outside_file.exists():
            outside_file.unlink()
