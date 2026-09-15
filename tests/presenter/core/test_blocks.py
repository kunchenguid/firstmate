"""Unit tests for the shared block contract validator and typed accessors."""

from __future__ import annotations

import json

import pytest

from presenter.core import blocks
from presenter.core.blocks import (
    BLOCK_TYPES,
    EquationBlock,
    ImageBlock,
    PageBreakBlock,
    PlotBlock,
    TableBlock,
    TextBlock,
    TocBlock,
    block_from_dict,
    validate_block,
    validate_blocks,
)
from presenter.core.errors import BlockValidationError, PresenterError


def test_block_types_match_contract() -> None:
    assert BLOCK_TYPES == {"text", "table", "image", "plot", "equation", "toc", "pagebreak"}


def test_text_block_normalizes_and_defaults_style() -> None:
    out = validate_block({"type": "text", "text": "hello"})
    assert out == {"type": "text", "style": "body", "text": "hello"}
    assert validate_block({"type": "text", "style": "heading1", "text": ""})["style"] == "heading1"


@pytest.mark.parametrize("style", ["body", "heading1", "heading2", "caption"])
def test_text_styles_accepted(style: str) -> None:
    assert validate_block({"type": "text", "style": style, "text": "x"})["style"] == style


def test_text_bad_style_rejected() -> None:
    with pytest.raises(BlockValidationError, match="style"):
        validate_block({"type": "text", "style": "title", "text": "x"})


def test_table_block_full_normalization() -> None:
    out = validate_block(
        {"type": "table", "headers": ["A", "B"], "rows": [["1", 2], [None, True]]}
    )
    assert out == {
        "type": "table",
        "caption": None,
        "headers": ["A", "B"],
        "rows": [["1", 2], [None, True]],
        "style": "grid",
    }
    assert json.loads(json.dumps(out)) == out


@pytest.mark.parametrize("style", ["grid", "plain", "striped"])
def test_table_styles_accepted(style: str) -> None:
    out = validate_block({"type": "table", "headers": ["A"], "rows": [], "style": style})
    assert out["style"] == style


def test_table_row_width_mismatch_rejected() -> None:
    with pytest.raises(BlockValidationError, match=r"rows\[1\] has 1 value"):
        validate_block({"type": "table", "headers": ["A", "B"], "rows": [[1, 2], [3]]})


def test_table_cell_must_be_scalar() -> None:
    with pytest.raises(BlockValidationError, match=r"rows\[0\]\[0\]"):
        validate_block({"type": "table", "headers": ["A"], "rows": [[{"nested": 1}]]})


def test_table_requires_headers() -> None:
    with pytest.raises(BlockValidationError, match="headers"):
        validate_block({"type": "table", "headers": [], "rows": []})


@pytest.mark.parametrize("kind", ["image", "plot"])
def test_image_and_plot_share_shape(kind: str) -> None:
    out = validate_block({"type": kind, "source": "artifact://x", "width_in": 4})
    assert out == {"type": kind, "source": "artifact://x", "width_in": 4.0, "caption": None}
    with pytest.raises(BlockValidationError, match="source"):
        validate_block({"type": kind, "source": ""})
    with pytest.raises(BlockValidationError, match="width_in"):
        validate_block({"type": kind, "source": "p.png", "width_in": -1})
    with pytest.raises(BlockValidationError, match="width_in"):
        validate_block({"type": kind, "source": "p.png", "width_in": "4"})


def test_equation_block() -> None:
    out = validate_block({"type": "equation", "latex": r"E = mc^2"})
    assert out == {"type": "equation", "latex": r"E = mc^2", "font_size_pt": None}
    assert validate_block({"type": "equation", "latex": "x", "font_size_pt": 11})["font_size_pt"] == 11.0
    with pytest.raises(BlockValidationError, match="latex"):
        validate_block({"type": "equation", "latex": ""})


@pytest.mark.parametrize("kind", ["toc", "pagebreak"])
def test_marker_blocks_carry_only_type(kind: str) -> None:
    assert validate_block({"type": kind}) == {"type": kind}
    with pytest.raises(BlockValidationError, match="unexpected field"):
        validate_block({"type": kind, "text": "nope"})


def test_unknown_type_and_missing_type_rejected() -> None:
    with pytest.raises(BlockValidationError, match="unknown block type"):
        validate_block({"type": "chart"})
    with pytest.raises(BlockValidationError, match="'type'"):
        validate_block({"text": "x"})
    with pytest.raises(BlockValidationError, match="mapping"):
        validate_block(["type", "text"])  # type: ignore[arg-type]


def test_unknown_keys_rejected() -> None:
    with pytest.raises(BlockValidationError, match="captoin"):
        validate_block({"type": "image", "source": "a.png", "captoin": "typo"})


def test_validate_block_returns_new_object() -> None:
    src = {"type": "text", "text": "x"}
    out = validate_block(src)
    assert out is not src
    assert "style" not in src


def test_error_location_label_and_hierarchy() -> None:
    with pytest.raises(BlockValidationError) as info:
        validate_blocks([{"type": "toc"}, {"type": "text"}], location="slides[3].blocks")
    assert str(info.value).startswith("slides[3].blocks[1]: ")
    assert info.value.location == "slides[3].blocks[1]"
    assert isinstance(info.value, PresenterError)


def test_validate_blocks_rejects_non_list() -> None:
    with pytest.raises(BlockValidationError, match="list of blocks"):
        validate_blocks({"type": "toc"})  # type: ignore[arg-type]


def test_typed_accessors_round_trip() -> None:
    cases = [
        (TextBlock, {"type": "text", "style": "caption", "text": "c"}),
        (TableBlock, {"type": "table", "caption": "t", "headers": ["h"], "rows": [[1]], "style": "plain"}),
        (ImageBlock, {"type": "image", "source": "i.png", "width_in": 2.5, "caption": None}),
        (PlotBlock, {"type": "plot", "source": "artifact://p", "width_in": None, "caption": "p"}),
        (EquationBlock, {"type": "equation", "latex": "a+b", "font_size_pt": 10.0}),
        (TocBlock, {"type": "toc"}),
        (PageBreakBlock, {"type": "pagebreak"}),
    ]
    for cls, d in cases:
        typed = cls.from_dict(d)
        assert typed.to_dict() == d
        assert isinstance(block_from_dict(d), cls)


def test_typed_accessor_type_mismatch() -> None:
    with pytest.raises(BlockValidationError, match="expected a text block"):
        TextBlock.from_dict({"type": "toc"})


def test_typed_accessor_attributes() -> None:
    tbl = TableBlock.from_dict({"type": "table", "headers": ["A"], "rows": [[1]]})
    assert tbl.headers == ["A"] and tbl.rows == [[1]] and tbl.style == "grid"
    assert TextBlock(text="x").to_dict()["style"] == "body"


def test_builder_helpers_return_validated_dicts() -> None:
    assert blocks.text("x") == {"type": "text", "style": "body", "text": "x"}
    assert blocks.table(("A",), [(1,)], caption="c", style="striped") == {
        "type": "table", "caption": "c", "headers": ["A"], "rows": [[1]], "style": "striped",
    }
    assert blocks.image("a.png", width_in=1)["width_in"] == 1.0
    assert blocks.plot("artifact://p", caption="c")["caption"] == "c"
    assert blocks.equation("x", font_size_pt=9)["font_size_pt"] == 9.0
    assert blocks.toc() == {"type": "toc"}
    assert blocks.pagebreak() == {"type": "pagebreak"}
    with pytest.raises(BlockValidationError):
        blocks.text("x", style="nope")
