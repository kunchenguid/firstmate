"""Validation and typed accessors for the shared block contract.

A block is a plain JSON-serializable dict with a ``"type"`` key.  Other
lanes (template ingestion, DOCX rendering, technical content blocks) build
and consume these dicts directly; this module is the single owner of what
a valid block looks like.  ``presenter/README.md`` carries the canonical
contract text.

Two views of the same data are offered:

- :func:`validate_block` returns a normalized copy of a block dict with
  every optional field present (``None`` where omitted) and rejects any
  block that breaks the contract with :class:`BlockValidationError`.
- The ``*Block`` dataclasses give typed attribute access; ``from_dict``
  validates on the way in and ``to_dict`` returns the normalized dict.

The builder helpers (:func:`text`, :func:`table`, ...) return validated
dicts so callers do not have to spell the contract out by hand.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Mapping, Sequence, Union

from presenter.core.errors import BlockValidationError

__all__ = [
    "BLOCK_TYPES",
    "TEXT_STYLES",
    "TABLE_STYLES",
    "TextBlock",
    "TableBlock",
    "ImageBlock",
    "PlotBlock",
    "EquationBlock",
    "TocBlock",
    "PageBreakBlock",
    "Block",
    "validate_block",
    "validate_blocks",
    "block_from_dict",
    "text",
    "table",
    "image",
    "plot",
    "equation",
    "toc",
    "pagebreak",
]

TEXT_STYLES: tuple[str, ...] = ("body", "heading1", "heading2", "caption")
TABLE_STYLES: tuple[str, ...] = ("grid", "plain", "striped")
BLOCK_TYPES: frozenset[str] = frozenset(
    {"text", "table", "image", "plot", "equation", "toc", "pagebreak"}
)

# Every key a block of each type may carry, beyond "type".  Unknown keys are
# rejected so a typo such as "captoin" fails at validation rather than
# rendering silently without the caption.
_ALLOWED_KEYS: dict[str, frozenset[str]] = {
    "text": frozenset({"style", "text"}),
    "table": frozenset({"caption", "headers", "rows", "style"}),
    "image": frozenset({"source", "width_in", "caption"}),
    "plot": frozenset({"source", "width_in", "caption"}),
    "equation": frozenset({"latex", "font_size_pt"}),
    "toc": frozenset(),
    "pagebreak": frozenset(),
}

_CellValue = Union[str, int, float, bool, None]


def _fail(message: str, location: str | None) -> BlockValidationError:
    return BlockValidationError(message, location=location)


def _require_str(
    block: Mapping[str, Any], key: str, location: str | None, *, allow_empty: bool = False
) -> str:
    if key not in block:
        raise _fail(f"missing required field {key!r}", location)
    value = block[key]
    if not isinstance(value, str):
        raise _fail(f"field {key!r} must be a string, got {type(value).__name__}", location)
    if not allow_empty and not value:
        raise _fail(f"field {key!r} must not be empty", location)
    return value


def _optional_str(block: Mapping[str, Any], key: str, location: str | None) -> str | None:
    value = block.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise _fail(f"field {key!r} must be a string or null, got {type(value).__name__}", location)
    return value


def _optional_positive_number(
    block: Mapping[str, Any], key: str, location: str | None
) -> float | None:
    value = block.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise _fail(f"field {key!r} must be a number or null, got {type(value).__name__}", location)
    if value <= 0:
        raise _fail(f"field {key!r} must be positive, got {value!r}", location)
    return float(value)


def _choice(
    block: Mapping[str, Any],
    key: str,
    choices: Sequence[str],
    default: str,
    location: str | None,
) -> str:
    value = block.get(key, default)
    if not isinstance(value, str) or value not in choices:
        raise _fail(
            f"field {key!r} must be one of {', '.join(choices)}, got {value!r}", location
        )
    return value


def _is_cell_value(value: Any) -> bool:
    return value is None or isinstance(value, (str, int, float, bool))


def validate_block(block: Mapping[str, Any], *, location: str | None = None) -> dict[str, Any]:
    """Validate one block and return its normalized plain-dict form.

    The returned dict is a new object: it carries ``"type"`` first, every
    field the contract defines for that type (optional fields as ``None``
    when omitted), and nothing else.  ``location`` is only used to label
    the error message.
    """
    if not isinstance(block, Mapping):
        raise _fail(f"block must be a mapping, got {type(block).__name__}", location)
    if "type" not in block:
        raise _fail("missing required field 'type'", location)
    block_type = block["type"]
    if not isinstance(block_type, str) or block_type not in BLOCK_TYPES:
        raise _fail(
            f"unknown block type {block_type!r}; expected one of {', '.join(sorted(BLOCK_TYPES))}",
            location,
        )
    unknown = sorted(set(block) - _ALLOWED_KEYS[block_type] - {"type"})
    if unknown:
        raise _fail(
            f"unexpected field(s) for {block_type!r} block: {', '.join(unknown)}", location
        )

    if block_type == "text":
        return {
            "type": "text",
            "style": _choice(block, "style", TEXT_STYLES, "body", location),
            "text": _require_str(block, "text", location, allow_empty=True),
        }
    if block_type == "table":
        return _validate_table(block, location)
    if block_type in ("image", "plot"):
        return {
            "type": block_type,
            "source": _require_str(block, "source", location),
            "width_in": _optional_positive_number(block, "width_in", location),
            "caption": _optional_str(block, "caption", location),
        }
    if block_type == "equation":
        return {
            "type": "equation",
            "latex": _require_str(block, "latex", location),
            "font_size_pt": _optional_positive_number(block, "font_size_pt", location),
        }
    return {"type": block_type}


def _validate_table(block: Mapping[str, Any], location: str | None) -> dict[str, Any]:
    headers = block.get("headers")
    if not isinstance(headers, list) or not headers:
        raise _fail("field 'headers' must be a non-empty list of strings", location)
    for i, header in enumerate(headers):
        if not isinstance(header, str):
            raise _fail(f"headers[{i}] must be a string, got {type(header).__name__}", location)
    rows = block.get("rows")
    if not isinstance(rows, list):
        raise _fail("field 'rows' must be a list of rows", location)
    normalized_rows: list[list[_CellValue]] = []
    for r, row in enumerate(rows):
        if not isinstance(row, list):
            raise _fail(f"rows[{r}] must be a list, got {type(row).__name__}", location)
        if len(row) != len(headers):
            raise _fail(
                f"rows[{r}] has {len(row)} value(s) but there are {len(headers)} header(s)",
                location,
            )
        for c, value in enumerate(row):
            if not _is_cell_value(value):
                raise _fail(
                    f"rows[{r}][{c}] must be a string, number, boolean, or null, "
                    f"got {type(value).__name__}",
                    location,
                )
        normalized_rows.append(list(row))
    return {
        "type": "table",
        "caption": _optional_str(block, "caption", location),
        "headers": list(headers),
        "rows": normalized_rows,
        "style": _choice(block, "style", TABLE_STYLES, "grid", location),
    }


def validate_blocks(
    blocks: Sequence[Mapping[str, Any]], *, location: str = "blocks"
) -> list[dict[str, Any]]:
    """Validate a sequence of blocks, labelling each error with its index."""
    if not isinstance(blocks, Sequence) or isinstance(blocks, (str, bytes)):
        raise BlockValidationError(
            f"must be a list of blocks, got {type(blocks).__name__}", location=location
        )
    return [validate_block(b, location=f"{location}[{i}]") for i, b in enumerate(blocks)]


# --------------------------------------------------------------------------
# Typed accessors
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class TextBlock:
    """``{"type": "text", "style": ..., "text": ...}``."""

    text: str
    style: str = "body"

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "TextBlock":
        d = validate_block(block)
        if d["type"] != "text":
            raise BlockValidationError(f"expected a text block, got {d['type']!r}")
        return cls(text=d["text"], style=d["style"])

    def to_dict(self) -> dict[str, Any]:
        return validate_block({"type": "text", **asdict(self)})


@dataclass(frozen=True)
class TableBlock:
    """``{"type": "table", "caption": ..., "headers": [...], "rows": [[...]], "style": ...}``."""

    headers: list[str]
    rows: list[list[_CellValue]] = field(default_factory=list)
    caption: str | None = None
    style: str = "grid"

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "TableBlock":
        d = validate_block(block)
        if d["type"] != "table":
            raise BlockValidationError(f"expected a table block, got {d['type']!r}")
        return cls(headers=d["headers"], rows=d["rows"], caption=d["caption"], style=d["style"])

    def to_dict(self) -> dict[str, Any]:
        return validate_block({"type": "table", **asdict(self)})


@dataclass(frozen=True)
class ImageBlock:
    """``{"type": "image", "source": ..., "width_in": ..., "caption": ...}``."""

    source: str
    width_in: float | None = None
    caption: str | None = None

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "ImageBlock":
        d = validate_block(block)
        if d["type"] != "image":
            raise BlockValidationError(f"expected an image block, got {d['type']!r}")
        return cls(source=d["source"], width_in=d["width_in"], caption=d["caption"])

    def to_dict(self) -> dict[str, Any]:
        return validate_block({"type": "image", **asdict(self)})


@dataclass(frozen=True)
class PlotBlock:
    """``{"type": "plot", "source": ..., "width_in": ..., "caption": ...}``."""

    source: str
    width_in: float | None = None
    caption: str | None = None

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "PlotBlock":
        d = validate_block(block)
        if d["type"] != "plot":
            raise BlockValidationError(f"expected a plot block, got {d['type']!r}")
        return cls(source=d["source"], width_in=d["width_in"], caption=d["caption"])

    def to_dict(self) -> dict[str, Any]:
        return validate_block({"type": "plot", **asdict(self)})


@dataclass(frozen=True)
class EquationBlock:
    """``{"type": "equation", "latex": ..., "font_size_pt": ...}``."""

    latex: str
    font_size_pt: float | None = None

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "EquationBlock":
        d = validate_block(block)
        if d["type"] != "equation":
            raise BlockValidationError(f"expected an equation block, got {d['type']!r}")
        return cls(latex=d["latex"], font_size_pt=d["font_size_pt"])

    def to_dict(self) -> dict[str, Any]:
        return validate_block({"type": "equation", **asdict(self)})


@dataclass(frozen=True)
class TocBlock:
    """``{"type": "toc"}``."""

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "TocBlock":
        d = validate_block(block)
        if d["type"] != "toc":
            raise BlockValidationError(f"expected a toc block, got {d['type']!r}")
        return cls()

    def to_dict(self) -> dict[str, Any]:
        return {"type": "toc"}


@dataclass(frozen=True)
class PageBreakBlock:
    """``{"type": "pagebreak"}``."""

    @classmethod
    def from_dict(cls, block: Mapping[str, Any]) -> "PageBreakBlock":
        d = validate_block(block)
        if d["type"] != "pagebreak":
            raise BlockValidationError(f"expected a pagebreak block, got {d['type']!r}")
        return cls()

    def to_dict(self) -> dict[str, Any]:
        return {"type": "pagebreak"}


Block = Union[TextBlock, TableBlock, ImageBlock, PlotBlock, EquationBlock, TocBlock, PageBreakBlock]

_TYPED: dict[str, type] = {
    "text": TextBlock,
    "table": TableBlock,
    "image": ImageBlock,
    "plot": PlotBlock,
    "equation": EquationBlock,
    "toc": TocBlock,
    "pagebreak": PageBreakBlock,
}


def block_from_dict(block: Mapping[str, Any], *, location: str | None = None) -> Block:
    """Validate a block dict and return the matching typed accessor."""
    d = validate_block(block, location=location)
    return _TYPED[d["type"]].from_dict(d)


# --------------------------------------------------------------------------
# Builder helpers returning validated dicts
# --------------------------------------------------------------------------


def text(content: str, style: str = "body") -> dict[str, Any]:
    """Build a validated text block."""
    return validate_block({"type": "text", "style": style, "text": content})


def table(
    headers: Sequence[str],
    rows: Sequence[Sequence[_CellValue]],
    *,
    caption: str | None = None,
    style: str = "grid",
) -> dict[str, Any]:
    """Build a validated table block."""
    return validate_block(
        {
            "type": "table",
            "caption": caption,
            "headers": list(headers),
            "rows": [list(r) for r in rows],
            "style": style,
        }
    )


def image(source: str, *, width_in: float | None = None, caption: str | None = None) -> dict[str, Any]:
    """Build a validated image block."""
    return validate_block(
        {"type": "image", "source": source, "width_in": width_in, "caption": caption}
    )


def plot(source: str, *, width_in: float | None = None, caption: str | None = None) -> dict[str, Any]:
    """Build a validated plot block."""
    return validate_block(
        {"type": "plot", "source": source, "width_in": width_in, "caption": caption}
    )


def equation(latex: str, *, font_size_pt: float | None = None) -> dict[str, Any]:
    """Build a validated equation block."""
    return validate_block({"type": "equation", "latex": latex, "font_size_pt": font_size_pt})


def toc() -> dict[str, Any]:
    """Build a table-of-contents block."""
    return {"type": "toc"}


def pagebreak() -> dict[str, Any]:
    """Build a page-break block."""
    return {"type": "pagebreak"}
