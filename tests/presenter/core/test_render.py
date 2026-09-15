"""Unit tests for render dispatch and the engine registry."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Iterator

import pytest

from presenter.core import DocumentBuilder, DocumentSpec, render
from presenter.core.errors import (
    BindingError,
    EngineNotImplementedError,
    PresenterError,
    RenderError,
    SpecError,
    UnknownFormatError,
)
from presenter.core.render import (
    _engines,
    _stubs,
    FORMATS,
    binding_format,
    get_engine,
    is_engine_implemented,
    register_engine,
    registered_formats,
    unregister_engine,
    validate_binding,
)


@pytest.fixture(autouse=True)
def _restore_registry() -> Iterator[None]:
    """Leave the module-level registry exactly as the test found it."""
    saved_engines, saved_stubs = dict(_engines), set(_stubs)
    yield
    _engines.clear()
    _engines.update(saved_engines)
    _stubs.clear()
    _stubs.update(saved_stubs)


def _spec() -> DocumentSpec:
    return DocumentBuilder("T").slide("S").add({"type": "text", "text": "hi"}).build()


def _binding(fmt: str = "docx") -> dict[str, Any]:
    return {
        "format": fmt,
        "template": f"templates/acme.{fmt}",
        "name": "acme",
        "layouts": {},
        "placeholders": {},
        "styles": {},
    }


def test_default_slots_are_stubs() -> None:
    assert set(FORMATS) == {"pptx", "docx"}
    assert registered_formats() == ("docx", "pptx")
    for fmt in FORMATS:
        assert not is_engine_implemented(fmt)
        assert callable(get_engine(fmt))


@pytest.mark.parametrize("fmt", ["pptx", "docx"])
def test_stub_raises_not_implemented_with_clear_message(fmt: str, tmp_path: Path) -> None:
    out = tmp_path / f"out.{fmt}"
    with pytest.raises(EngineNotImplementedError) as info:
        render(_spec(), _binding(fmt), out)
    message = str(info.value)
    assert fmt in message and "register_engine" in message and str(out) in message
    assert isinstance(info.value, NotImplementedError)
    assert isinstance(info.value, RenderError)
    assert isinstance(info.value, PresenterError)
    assert not out.exists()


def test_render_dispatches_to_registered_engine(tmp_path: Path) -> None:
    seen: dict[str, Any] = {}

    def engine(document: dict[str, Any], binding: dict[str, Any], output_path: Path) -> Path:
        seen["document"] = document
        seen["binding"] = binding
        seen["path"] = output_path
        output_path.write_bytes(b"docx")
        return output_path

    register_engine("docx", engine)
    assert is_engine_implemented("docx")
    out = tmp_path / "out.docx"
    written = render(_spec(), _binding("DOCX"), str(out))
    assert written == out and out.read_bytes() == b"docx"
    assert seen["document"] == _spec().to_dict()
    assert seen["binding"]["format"] == "docx"
    assert seen["binding"]["template"] == "templates/acme.DOCX"
    assert isinstance(seen["path"], Path)
    # pptx slot is untouched by registering docx.
    assert not is_engine_implemented("pptx")


def test_render_accepts_plain_dict_spec(tmp_path: Path) -> None:
    captured: list[dict[str, Any]] = []
    register_engine("pptx", lambda d, b, p: captured.append(d) or p)
    render(_spec().to_dict(), _binding("pptx"), tmp_path / "deck.pptx")
    assert captured[0]["slides"][0]["blocks"][0]["text"] == "hi"
    with pytest.raises(SpecError):
        render({"title": ""}, _binding("pptx"), tmp_path / "deck.pptx")


def test_render_returns_path_when_engine_returns_none(tmp_path: Path) -> None:
    register_engine("docx", lambda d, b, p: None)  # type: ignore[arg-type,return-value]
    out = tmp_path / "x.docx"
    assert render(_spec(), _binding(), out) == out


def test_render_rejects_mismatched_extension(tmp_path: Path) -> None:
    register_engine("docx", lambda d, b, p: p)
    with pytest.raises(RenderError, match=r"must end in \.docx"):
        render(_spec(), _binding("docx"), tmp_path / "out.pptx")


def test_register_replace_semantics() -> None:
    first = lambda d, b, p: p  # noqa: E731
    second = lambda d, b, p: p  # noqa: E731
    register_engine("docx", first)
    with pytest.raises(RenderError, match="already registered"):
        register_engine("docx", second)
    assert get_engine("docx") is first
    register_engine("docx", second, replace=True)
    assert get_engine("docx") is second


def test_register_validation() -> None:
    with pytest.raises(TypeError):
        register_engine("docx", "not callable")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        register_engine("", lambda d, b, p: p)


def test_unregister_restores_stub_and_drops_custom_formats() -> None:
    register_engine("docx", lambda d, b, p: p)
    unregister_engine("docx")
    assert not is_engine_implemented("docx")
    with pytest.raises(EngineNotImplementedError):
        get_engine("docx")({}, {}, Path("x.docx"))

    register_engine("pdf", lambda d, b, p: p)
    assert "pdf" in registered_formats() and is_engine_implemented("pdf")
    unregister_engine("pdf")
    assert "pdf" not in registered_formats()
    with pytest.raises(UnknownFormatError):
        get_engine("pdf")


def test_binding_validation() -> None:
    assert binding_format({"format": "PPTX"}) == "pptx"
    checked = validate_binding(_binding("Docx"))
    assert checked["format"] == "docx" and checked["name"] == "acme"
    with pytest.raises(BindingError, match="format"):
        binding_format({})
    with pytest.raises(BindingError, match="mapping"):
        binding_format("docx")  # type: ignore[arg-type]
    with pytest.raises(UnknownFormatError, match="pdf"):
        validate_binding({"format": "pdf", "template": "t"})
    with pytest.raises(BindingError, match="template"):
        validate_binding({"format": "docx"})
    with pytest.raises(BindingError, match="name"):
        validate_binding({"format": "docx", "template": "t", "name": 3})
    with pytest.raises(BindingError, match="layouts"):
        validate_binding({"format": "docx", "template": "t", "layouts": []})


def test_validate_binding_is_minimal_and_non_mutating() -> None:
    binding = {"format": "docx", "template": "t", "extra": {"owned": "by the template lane"}}
    checked = validate_binding(binding)
    assert checked["extra"] == binding["extra"]
    assert binding["format"] == "docx" and checked is not binding


def test_unknown_format_error_lists_registered(tmp_path: Path) -> None:
    with pytest.raises(UnknownFormatError, match="docx, pptx"):
        render(_spec(), {"format": "odt", "template": "t"}, tmp_path / "x.odt")
