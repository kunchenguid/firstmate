"""Render entry point and engine registry.

:func:`render` takes a document (a :class:`DocumentSpec` or its plain-dict
form), a TemplateBinding dict, and an output path, and dispatches on
``binding["format"]`` to the engine registered for that format.

Engines are plain callables so the lanes that provide them (DOCX render,
PPTX render) register into this module without importing anything but the
registration function.  An engine receives the *normalized document dict*
(the output of :meth:`DocumentSpec.to_dict`), the binding dict as given,
and the output path as a :class:`pathlib.Path`, and returns the path it
wrote::

    def my_docx_engine(document: dict, binding: dict, output_path: Path) -> Path: ...
    register_engine("docx", my_docx_engine)

The ``"pptx"`` and ``"docx"`` slots exist from import time with stub engines
that raise :class:`EngineNotImplementedError`, so dispatch can be exercised
before the real engines land, and registering a real engine simply replaces
the stub.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Mapping, Union

from presenter.core.errors import (
    BindingError,
    EngineNotImplementedError,
    RenderError,
    UnknownFormatError,
)
from presenter.core.spec import DocumentSpec

__all__ = [
    "Engine",
    "FORMATS",
    "register_engine",
    "unregister_engine",
    "get_engine",
    "registered_formats",
    "is_engine_implemented",
    "binding_format",
    "validate_binding",
    "render",
]

Engine = Callable[[dict[str, Any], dict[str, Any], Path], Path]
"""Engine callable: ``(document_dict, binding_dict, output_path) -> written_path``."""

FORMATS: tuple[str, ...] = ("pptx", "docx")
"""Output formats that always have an engine slot."""

_BINDING_MAPPING_KEYS: tuple[str, ...] = ("layouts", "placeholders", "styles")

_engines: dict[str, Engine] = {}
_stubs: set[str] = set()


_PROVIDERS: dict[str, str] = {
    "pptx": "PPTX render engine (presenter/render_pptx/)",
    "docx": "DOCX render engine (presenter/render_docx/)",
}


def _make_stub(fmt: str) -> Engine:
    provider = _PROVIDERS.get(fmt, f"{fmt} render engine")

    def _stub(document: dict[str, Any], binding: dict[str, Any], output_path: Path) -> Path:
        raise EngineNotImplementedError(
            f"no {fmt!r} engine is registered: the {provider} has not registered into "
            f"presenter.core.render yet, so {output_path} cannot be written. Register one with "
            f"presenter.core.render.register_engine({fmt!r}, engine)."
        )

    return _stub


def _install_stub(fmt: str) -> None:
    _engines[fmt] = _make_stub(fmt)
    _stubs.add(fmt)


def register_engine(fmt: str, engine: Engine, *, replace: bool = False) -> None:
    """Register ``engine`` for output format ``fmt``.

    Replacing a stub slot never needs ``replace``; replacing a real engine
    does, so two lanes cannot silently overwrite each other.
    """
    if not isinstance(fmt, str) or not fmt:
        raise ValueError("format must be a non-empty string")
    fmt = fmt.lower()
    if not callable(engine):
        raise TypeError(f"engine for {fmt!r} must be callable, got {type(engine).__name__}")
    if fmt in _engines and fmt not in _stubs and not replace:
        raise RenderError(
            f"an engine is already registered for {fmt!r}; pass replace=True to override it"
        )
    _engines[fmt] = engine
    _stubs.discard(fmt)


def unregister_engine(fmt: str) -> None:
    """Remove the engine for ``fmt``, restoring the stub for built-in formats."""
    fmt = fmt.lower()
    if fmt in FORMATS:
        _install_stub(fmt)
        return
    _engines.pop(fmt, None)
    _stubs.discard(fmt)


def get_engine(fmt: str) -> Engine:
    """Return the engine registered for ``fmt`` (a stub counts)."""
    key = fmt.lower() if isinstance(fmt, str) else fmt
    try:
        return _engines[key]
    except (KeyError, TypeError):
        raise UnknownFormatError(
            f"unknown output format {fmt!r}; registered formats: {', '.join(registered_formats())}"
        ) from None


def registered_formats() -> tuple[str, ...]:
    """Every format with an engine slot, stubs included, in sorted order."""
    return tuple(sorted(_engines))


def is_engine_implemented(fmt: str) -> bool:
    """True when a real (non-stub) engine is registered for ``fmt``."""
    key = fmt.lower()
    return key in _engines and key not in _stubs


def binding_format(binding: Mapping[str, Any]) -> str:
    """Return the validated, lower-cased ``binding["format"]``."""
    if not isinstance(binding, Mapping):
        raise BindingError(f"binding must be a mapping, got {type(binding).__name__}")
    fmt = binding.get("format")
    if not isinstance(fmt, str) or not fmt:
        raise BindingError("binding['format'] must be a non-empty string such as 'pptx' or 'docx'")
    return fmt.lower()


def validate_binding(binding: Mapping[str, Any]) -> dict[str, Any]:
    """Check the top-level shape the renderer dispatches on and return a shallow copy.

    Only the keys named by the TemplateBinding contract are checked here, and
    only for type: ``format`` and ``template`` must be strings, ``name`` a
    string when present, and ``layouts``/``placeholders``/``styles`` mappings
    when present.  The template lane owns the meaning of those mappings.
    """
    fmt = binding_format(binding)
    if fmt not in _engines:
        raise UnknownFormatError(
            f"binding['format'] is {fmt!r}; registered formats: {', '.join(registered_formats())}"
        )
    template = binding.get("template")
    if not isinstance(template, str) or not template:
        raise BindingError("binding['template'] must be a non-empty path string")
    name = binding.get("name")
    if name is not None and not isinstance(name, str):
        raise BindingError(f"binding['name'] must be a string, got {type(name).__name__}")
    for key in _BINDING_MAPPING_KEYS:
        value = binding.get(key)
        if value is not None and not isinstance(value, Mapping):
            raise BindingError(f"binding[{key!r}] must be a mapping, got {type(value).__name__}")
    out = dict(binding)
    out["format"] = fmt
    return out


def _document_dict(spec: Union[DocumentSpec, Mapping[str, Any]]) -> dict[str, Any]:
    if isinstance(spec, DocumentSpec):
        return spec.to_dict()
    return DocumentSpec.from_dict(spec).to_dict()


def render(
    spec: Union[DocumentSpec, Mapping[str, Any]],
    binding: Mapping[str, Any],
    output_path: Union[str, Path],
) -> Path:
    """Render ``spec`` through the engine selected by ``binding["format"]``.

    ``output_path`` must end in the binding's format extension so a deck is
    never written to a ``.docx`` name or vice versa.  Returns the path the
    engine reports it wrote.
    """
    checked = validate_binding(binding)
    fmt = checked["format"]
    path = Path(output_path)
    if path.suffix.lower() != f".{fmt}":
        raise RenderError(
            f"output path {path} must end in .{fmt} to match binding['format']={fmt!r}"
        )
    document = _document_dict(spec)
    engine = get_engine(fmt)
    written = engine(document, checked, path)
    if written is None:
        return path
    return Path(written)


for _fmt in FORMATS:
    _install_stub(_fmt)
del _fmt
