"""Document and slide specification model.

A :class:`DocumentSpec` is the renderer-independent description of one
deliverable: document-level fields plus an ordered list of
:class:`SlideSpec` units, each holding an ordered list of content blocks
that satisfy the shared block contract (:mod:`presenter.core.blocks`).

A ``SlideSpec`` is one slide in a ``.pptx`` deck and one section in a
``.docx`` document; the engine registered for the binding's format decides
how the unit is laid out.

Both dataclasses round-trip to plain JSON-serializable dicts through
``to_dict`` / ``from_dict``.  :class:`DocumentBuilder` is the convenience
API for assembling a document from block dicts without touching the
dataclasses directly.
"""

from __future__ import annotations

import copy
import json
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Sequence

from presenter.core.blocks import validate_block, validate_blocks
from presenter.core.errors import SpecError

__all__ = ["SPEC_VERSION", "SlideSpec", "DocumentSpec", "DocumentBuilder"]

SPEC_VERSION = 1

_SLIDE_KEYS = frozenset({"title", "layout", "notes", "blocks"})
_DOCUMENT_KEYS = frozenset(
    {"version", "title", "subtitle", "author", "metadata", "slides"}
)


def _optional_str(data: Mapping[str, Any], key: str, location: str) -> str | None:
    value = data.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise SpecError(f"{location}.{key} must be a string or null, got {type(value).__name__}")
    return value


def _reject_unknown(data: Mapping[str, Any], allowed: frozenset[str], location: str) -> None:
    unknown = sorted(set(data) - allowed)
    if unknown:
        raise SpecError(f"{location}: unexpected field(s): {', '.join(unknown)}")


@dataclass
class SlideSpec:
    """One slide (pptx) or section (docx) holding ordered content blocks."""

    title: str | None = None
    layout: str | None = None
    notes: str | None = None
    blocks: list[dict[str, Any]] = field(default_factory=list)

    def add_block(self, block: Mapping[str, Any]) -> "SlideSpec":
        """Validate ``block`` and append its normalized form; returns ``self``."""
        self.blocks.append(validate_block(block))
        return self

    def validate(self, *, location: str = "slide") -> "SlideSpec":
        """Re-validate every field, normalizing blocks in place."""
        for name in ("title", "layout", "notes"):
            value = getattr(self, name)
            if value is not None and not isinstance(value, str):
                raise SpecError(
                    f"{location}.{name} must be a string or null, got {type(value).__name__}"
                )
        self.blocks = validate_blocks(self.blocks, location=f"{location}.blocks")
        return self

    def to_dict(self) -> dict[str, Any]:
        """Return a plain JSON-serializable dict with normalized blocks."""
        self.validate()
        return {
            "title": self.title,
            "layout": self.layout,
            "notes": self.notes,
            "blocks": [copy.deepcopy(b) for b in self.blocks],
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any], *, location: str = "slide") -> "SlideSpec":
        if not isinstance(data, Mapping):
            raise SpecError(f"{location} must be a mapping, got {type(data).__name__}")
        _reject_unknown(data, _SLIDE_KEYS, location)
        blocks = data.get("blocks", [])
        return cls(
            title=_optional_str(data, "title", location),
            layout=_optional_str(data, "layout", location),
            notes=_optional_str(data, "notes", location),
            blocks=validate_blocks(blocks, location=f"{location}.blocks"),
        )


@dataclass
class DocumentSpec:
    """A complete renderer-independent document description."""

    title: str
    subtitle: str | None = None
    author: str | None = None
    metadata: dict[str, Any] = field(default_factory=dict)
    slides: list[SlideSpec] = field(default_factory=list)

    def add_slide(
        self,
        title: str | None = None,
        *,
        layout: str | None = None,
        notes: str | None = None,
        blocks: Iterable[Mapping[str, Any]] = (),
    ) -> SlideSpec:
        """Append a new slide and return it so blocks can be added to it."""
        slide = SlideSpec(
            title=title,
            layout=layout,
            notes=notes,
            blocks=validate_blocks(list(blocks), location=f"slides[{len(self.slides)}].blocks"),
        )
        self.slides.append(slide)
        return slide

    def iter_blocks(self) -> Iterable[tuple[int, dict[str, Any]]]:
        """Yield ``(slide_index, block)`` for every block in document order."""
        for index, slide in enumerate(self.slides):
            for block in slide.blocks:
                yield index, block

    def validate(self) -> "DocumentSpec":
        """Re-validate every field, normalizing blocks in place."""
        if not isinstance(self.title, str) or not self.title:
            raise SpecError("document.title must be a non-empty string")
        for name in ("subtitle", "author"):
            value = getattr(self, name)
            if value is not None and not isinstance(value, str):
                raise SpecError(
                    f"document.{name} must be a string or null, got {type(value).__name__}"
                )
        if not isinstance(self.metadata, dict):
            raise SpecError(
                f"document.metadata must be a dict, got {type(self.metadata).__name__}"
            )
        for key in self.metadata:
            if not isinstance(key, str):
                raise SpecError(f"document.metadata keys must be strings, got {key!r}")
        try:
            json.dumps(self.metadata)
        except (TypeError, ValueError) as exc:
            raise SpecError(f"document.metadata must be JSON-serializable: {exc}") from exc
        if not isinstance(self.slides, list):
            raise SpecError(f"document.slides must be a list, got {type(self.slides).__name__}")
        for index, slide in enumerate(self.slides):
            if not isinstance(slide, SlideSpec):
                raise SpecError(
                    f"document.slides[{index}] must be a SlideSpec, got {type(slide).__name__}"
                )
            slide.validate(location=f"slides[{index}]")
        return self

    def to_dict(self) -> dict[str, Any]:
        """Return a plain JSON-serializable dict; ``"version"`` is always present."""
        self.validate()
        return {
            "version": SPEC_VERSION,
            "title": self.title,
            "subtitle": self.subtitle,
            "author": self.author,
            "metadata": json.loads(json.dumps(self.metadata)),
            "slides": [s.to_dict() for s in self.slides],
        }

    def to_json(self, **dumps_kwargs: Any) -> str:
        """Serialize :meth:`to_dict` with :func:`json.dumps`."""
        return json.dumps(self.to_dict(), **dumps_kwargs)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "DocumentSpec":
        if not isinstance(data, Mapping):
            raise SpecError(f"document must be a mapping, got {type(data).__name__}")
        _reject_unknown(data, _DOCUMENT_KEYS, "document")
        version = data.get("version", SPEC_VERSION)
        if version != SPEC_VERSION:
            raise SpecError(f"unsupported document version {version!r}; expected {SPEC_VERSION}")
        title = data.get("title")
        if not isinstance(title, str) or not title:
            raise SpecError("document.title must be a non-empty string")
        metadata = data.get("metadata", {})
        if metadata is None:
            metadata = {}
        slides = data.get("slides", [])
        if not isinstance(slides, Sequence) or isinstance(slides, (str, bytes)):
            raise SpecError(f"document.slides must be a list, got {type(slides).__name__}")
        spec = cls(
            title=title,
            subtitle=_optional_str(data, "subtitle", "document"),
            author=_optional_str(data, "author", "document"),
            metadata=dict(metadata) if isinstance(metadata, Mapping) else metadata,  # type: ignore[arg-type]
            slides=[SlideSpec.from_dict(s, location=f"slides[{i}]") for i, s in enumerate(slides)],
        )
        spec.validate()
        spec.metadata = copy.deepcopy(spec.metadata)
        return spec

    @classmethod
    def from_json(cls, text: str) -> "DocumentSpec":
        """Parse JSON text produced by :meth:`to_json`."""
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise SpecError(f"document JSON is not parseable: {exc}") from exc
        return cls.from_dict(data)


class DocumentBuilder:
    """Fluent assembly of a :class:`DocumentSpec` from block dicts.

    Every call validates its input immediately, so an invalid block fails
    where it is added rather than at render time.  Blocks added before the
    first explicit ``slide()`` land on an untitled first slide.

    Example::

        spec = (
            DocumentBuilder("LDO Datasheet", author="Analog team")
            .slide("Overview")
            .add({"type": "text", "style": "body", "text": "A 3.3 V LDO."})
            .add({"type": "toc"})
            .build()
        )
    """

    def __init__(
        self,
        title: str,
        *,
        subtitle: str | None = None,
        author: str | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> None:
        self._spec = DocumentSpec(
            title=title, subtitle=subtitle, author=author, metadata=dict(metadata or {})
        )
        self._spec.validate()

    def meta(self, key: str, value: Any) -> "DocumentBuilder":
        """Set one document metadata entry; an unserializable value is not kept."""
        missing = object()
        previous = self._spec.metadata.get(key, missing)
        self._spec.metadata[key] = value
        try:
            self._spec.validate()
        except SpecError:
            if previous is missing:
                del self._spec.metadata[key]
            else:
                self._spec.metadata[key] = previous
            raise
        return self

    def slide(
        self,
        title: str | None = None,
        *,
        layout: str | None = None,
        notes: str | None = None,
    ) -> "DocumentBuilder":
        """Start a new slide; later ``add`` calls append to it."""
        self._spec.add_slide(title, layout=layout, notes=notes)
        return self

    def add(self, block: Mapping[str, Any]) -> "DocumentBuilder":
        """Validate one block dict and append it to the current slide."""
        self._current().add_block(block)
        return self

    def extend(self, blocks: Iterable[Mapping[str, Any]]) -> "DocumentBuilder":
        """Validate and append several block dicts to the current slide."""
        for block in blocks:
            self.add(block)
        return self

    def build(self) -> DocumentSpec:
        """Return a validated copy of the assembled document."""
        return DocumentSpec.from_dict(self._spec.to_dict())

    def _current(self) -> SlideSpec:
        if not self._spec.slides:
            self._spec.add_slide()
        return self._spec.slides[-1]
