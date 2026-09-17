"""Unit tests for DocumentSpec, SlideSpec, and DocumentBuilder."""

from __future__ import annotations

import json

import pytest

from presenter.core import SPEC_VERSION, DocumentBuilder, DocumentSpec, SlideSpec
from presenter.core.errors import BlockValidationError, SpecError


def _sample() -> DocumentSpec:
    spec = DocumentSpec(title="Datasheet", subtitle="Rev A", author="me", metadata={"part": "X1"})
    spec.add_slide("Intro", layout="title", notes="n", blocks=[{"type": "text", "text": "hi"}])
    spec.add_slide().add_block({"type": "toc"}).add_block(
        {"type": "table", "headers": ["A"], "rows": [[1]]}
    )
    return spec


def test_to_dict_is_plain_and_json_serializable() -> None:
    d = _sample().to_dict()
    assert d["version"] == SPEC_VERSION
    assert d["title"] == "Datasheet"
    assert d["slides"][0] == {
        "title": "Intro",
        "layout": "title",
        "notes": "n",
        "blocks": [{"type": "text", "style": "body", "text": "hi"}],
    }
    assert d["slides"][1]["title"] is None
    assert d["slides"][1]["blocks"][1]["style"] == "grid"
    assert json.loads(json.dumps(d)) == d


def test_round_trip_dict_and_json() -> None:
    spec = _sample()
    assert DocumentSpec.from_dict(spec.to_dict()) == spec
    assert DocumentSpec.from_json(spec.to_json()) == spec


def test_to_dict_does_not_alias_internal_state() -> None:
    spec = _sample()
    spec.metadata["tags"] = ["a"]
    d = spec.to_dict()
    d["slides"][0]["blocks"][0]["text"] = "changed"
    d["slides"][1]["blocks"][1]["headers"].append("H2")
    d["slides"][1]["blocks"][1]["rows"].append(["corrupted"])
    d["metadata"]["tags"].append("b")
    assert spec.slides[0].blocks[0]["text"] == "hi"
    assert spec.slides[1].blocks[1]["headers"] == ["A"]
    assert spec.slides[1].blocks[1]["rows"] == [[1]]
    assert spec.metadata == {"part": "X1", "tags": ["a"]}
    assert spec.to_dict()["slides"][1]["blocks"][1]["rows"] == [[1]]
    assert spec.to_dict()["metadata"] == {"part": "X1", "tags": ["a"]}


def test_from_dict_does_not_alias_input_metadata() -> None:
    source = {"title": "T", "metadata": {"tags": ["a"]}}
    spec = DocumentSpec.from_dict(source)
    spec.metadata["tags"].append("b")
    assert source["metadata"] == {"tags": ["a"]}
    source["metadata"]["tags"].append("c")
    assert spec.metadata == {"tags": ["a", "b"]}


def test_from_dict_defaults_and_optional_keys() -> None:
    spec = DocumentSpec.from_dict({"title": "T"})
    assert spec.slides == [] and spec.metadata == {} and spec.author is None
    spec = DocumentSpec.from_dict({"title": "T", "slides": [{}], "metadata": None})
    assert spec.slides == [SlideSpec()]


def test_from_dict_rejects_bad_shapes() -> None:
    with pytest.raises(SpecError, match="title"):
        DocumentSpec.from_dict({"slides": []})
    with pytest.raises(SpecError, match="title"):
        DocumentSpec.from_dict({"title": ""})
    with pytest.raises(SpecError, match="unexpected field"):
        DocumentSpec.from_dict({"title": "T", "pages": []})
    with pytest.raises(SpecError, match="version"):
        DocumentSpec.from_dict({"title": "T", "version": 99})
    with pytest.raises(SpecError, match="slides"):
        DocumentSpec.from_dict({"title": "T", "slides": "no"})
    with pytest.raises(SpecError, match=r"slides\[0\]"):
        DocumentSpec.from_dict({"title": "T", "slides": ["no"]})
    with pytest.raises(SpecError, match=r"slides\[0\].title"):
        DocumentSpec.from_dict({"title": "T", "slides": [{"title": 1}]})
    with pytest.raises(SpecError, match="mapping"):
        DocumentSpec.from_dict("T")  # type: ignore[arg-type]
    with pytest.raises(SpecError, match="not parseable"):
        DocumentSpec.from_json("{")


def test_from_dict_labels_block_errors_with_location() -> None:
    with pytest.raises(BlockValidationError, match=r"^slides\[1\].blocks\[0\]: unknown block type"):
        DocumentSpec.from_dict({"title": "T", "slides": [{}, {"blocks": [{"type": "nope"}]}]})


def test_validate_rejects_bad_metadata_and_slides() -> None:
    spec = DocumentSpec(title="T", metadata={"k": object()})
    with pytest.raises(SpecError, match="JSON-serializable"):
        spec.validate()
    spec = DocumentSpec(title="T", metadata={1: "x"})  # type: ignore[dict-item]
    with pytest.raises(SpecError, match="metadata keys"):
        spec.validate()
    spec = DocumentSpec(title="T", slides=[{"title": "x"}])  # type: ignore[list-item]
    with pytest.raises(SpecError, match="SlideSpec"):
        spec.validate()
    spec = DocumentSpec(title="T", slides=[SlideSpec(blocks=[{"type": "text"}])])
    with pytest.raises(BlockValidationError, match=r"slides\[0\].blocks\[0\]"):
        spec.validate()


def test_slide_add_block_validates_and_normalizes() -> None:
    slide = SlideSpec()
    slide.add_block({"type": "text", "text": "x"})
    assert slide.blocks == [{"type": "text", "style": "body", "text": "x"}]
    with pytest.raises(BlockValidationError):
        slide.add_block({"type": "text"})
    assert len(slide.blocks) == 1


def test_iter_blocks_in_document_order() -> None:
    kinds = [(i, b["type"]) for i, b in _sample().iter_blocks()]
    assert kinds == [(0, "text"), (1, "toc"), (1, "table")]


def test_builder_assembles_document() -> None:
    spec = (
        DocumentBuilder("T", subtitle="s", author="a", metadata={"rev": 1})
        .meta("part", "X")
        .slide("One", layout="title", notes="n")
        .add({"type": "text", "text": "hi"})
        .extend([{"type": "toc"}, {"type": "pagebreak"}])
        .slide("Two")
        .add({"type": "equation", "latex": "x"})
        .build()
    )
    assert isinstance(spec, DocumentSpec)
    assert spec.metadata == {"rev": 1, "part": "X"}
    assert [s.title for s in spec.slides] == ["One", "Two"]
    assert [b["type"] for s in spec.slides for b in s.blocks] == ["text", "toc", "pagebreak", "equation"]
    assert spec.slides[0].layout == "title" and spec.slides[0].notes == "n"


def test_builder_creates_implicit_first_slide() -> None:
    spec = DocumentBuilder("T").add({"type": "toc"}).build()
    assert len(spec.slides) == 1 and spec.slides[0].title is None
    assert spec.slides[0].blocks == [{"type": "toc"}]


def test_builder_fails_fast_on_invalid_input() -> None:
    builder = DocumentBuilder("T").slide("S")
    with pytest.raises(BlockValidationError):
        builder.add({"type": "image"})
    with pytest.raises(SpecError):
        builder.meta("bad", object())
    with pytest.raises(SpecError):
        DocumentBuilder("")
    assert builder.build().slides[0].blocks == []


def test_builder_build_returns_independent_copies() -> None:
    builder = DocumentBuilder("T").slide("S").add({"type": "toc"})
    first = builder.build()
    builder.add({"type": "pagebreak"})
    second = builder.build()
    assert len(first.slides[0].blocks) == 1
    assert len(second.slides[0].blocks) == 2
