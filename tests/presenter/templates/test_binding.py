"""Tests for presenter.templates.binding."""

from __future__ import annotations

import json

import pytest

from presenter.templates.binding import (
    TemplateBindingError,
    load_binding,
    save_binding,
    validate_binding,
)


def _minimal_binding(**overrides):
    binding = {
        "format": "pptx",
        "template": "corp_master.pptx",
        "name": "corp_master",
        "layouts": {"Title Slide": {"Title 1": "title"}},
        "placeholders": {},
        "styles": {},
    }
    binding.update(overrides)
    return binding


def test_validate_binding_accepts_minimal_valid_dict():
    validate_binding(_minimal_binding())


def test_validate_binding_accepts_docx_format():
    validate_binding(_minimal_binding(format="docx"))


def test_validate_binding_rejects_non_dict():
    with pytest.raises(TemplateBindingError, match="must be a dict"):
        validate_binding(["not", "a", "dict"])


@pytest.mark.parametrize(
    "key", ["format", "template", "name", "layouts", "placeholders", "styles"]
)
def test_validate_binding_rejects_missing_required_key(key):
    binding = _minimal_binding()
    del binding[key]
    with pytest.raises(TemplateBindingError, match="missing required keys"):
        validate_binding(binding)


def test_validate_binding_rejects_unknown_format():
    with pytest.raises(TemplateBindingError, match="format"):
        validate_binding(_minimal_binding(format="xlsx"))


def test_validate_binding_rejects_empty_template():
    with pytest.raises(TemplateBindingError, match="template"):
        validate_binding(_minimal_binding(template=""))


def test_validate_binding_rejects_empty_name():
    with pytest.raises(TemplateBindingError, match="name"):
        validate_binding(_minimal_binding(name=""))


@pytest.mark.parametrize("key", ["layouts", "placeholders", "styles"])
def test_validate_binding_rejects_non_dict_section(key):
    with pytest.raises(TemplateBindingError, match=key):
        validate_binding(_minimal_binding(**{key: ["nope"]}))


def test_validate_binding_rejects_non_dict_layout_entry():
    with pytest.raises(TemplateBindingError, match="Title Slide"):
        validate_binding(_minimal_binding(layouts={"Title Slide": ["not-a-dict"]}))


def test_validate_binding_rejects_non_string_role():
    with pytest.raises(TemplateBindingError, match="str -> str"):
        validate_binding(_minimal_binding(layouts={"Title Slide": {"Title 1": 123}}))


def test_save_binding_validates_before_writing(tmp_path):
    invalid = _minimal_binding(format="bogus")
    target = tmp_path / "binding.json"
    with pytest.raises(TemplateBindingError):
        save_binding(invalid, target)
    assert not target.exists()


def test_save_and_load_binding_round_trip(tmp_path):
    binding = _minimal_binding(
        layouts={"Title Slide": {"Title 1": "title", "Subtitle 2": "subtitle"}}
    )
    target = tmp_path / "binding.json"

    save_binding(binding, target)
    loaded = load_binding(target)

    assert loaded == binding
    # The file must be readable plain JSON per the shared contract.
    assert json.loads(target.read_text(encoding="utf-8")) == binding


def test_load_binding_rejects_invalid_contents(tmp_path):
    target = tmp_path / "binding.json"
    target.write_text(json.dumps(_minimal_binding(name="")), encoding="utf-8")

    with pytest.raises(TemplateBindingError, match="name"):
        load_binding(target)
