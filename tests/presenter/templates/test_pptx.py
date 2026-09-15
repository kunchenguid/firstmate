"""Tests for presenter.templates.pptx, built against an in-test pptx fixture."""

from __future__ import annotations

import pytest
from pptx import Presentation

from presenter.templates.binding import validate_binding
from presenter.templates.pptx import inventory_pptx_template


@pytest.fixture
def master_template_path(tmp_path):
    """A default python-pptx template, which already ships a full layout set
    (Title Slide, Title and Content, etc.) and a standard Office theme."""
    presentation = Presentation()
    path = tmp_path / "corp_master.pptx"
    presentation.save(str(path))
    return path


def test_inventory_pptx_template_reports_format_and_identity(master_template_path):
    binding = inventory_pptx_template(master_template_path)

    assert binding["format"] == "pptx"
    assert binding["template"] == str(master_template_path)
    assert binding["name"] == "corp_master"


def test_inventory_pptx_template_lists_every_layout(master_template_path):
    binding = inventory_pptx_template(master_template_path)
    presentation = Presentation(str(master_template_path))

    expected_layout_names = {layout.name for layout in presentation.slide_layouts}
    assert set(binding["layouts"]) == expected_layout_names
    assert set(binding["placeholders"]) == expected_layout_names


def test_inventory_pptx_template_maps_title_slide_placeholder_roles(
    master_template_path,
):
    binding = inventory_pptx_template(master_template_path)

    title_slide_roles = binding["layouts"]["Title Slide"]
    assert title_slide_roles["Title 1"] == "title"
    assert title_slide_roles["Subtitle 2"] == "subtitle"


def test_inventory_pptx_template_records_placeholder_type_and_idx(
    master_template_path,
):
    binding = inventory_pptx_template(master_template_path)

    title_slide_inventory = binding["placeholders"]["Title Slide"]
    by_name = {entry["name"]: entry for entry in title_slide_inventory}

    assert by_name["Title 1"]["type"] == "CENTER_TITLE"
    assert by_name["Title 1"]["idx"] == 0
    assert by_name["Subtitle 2"]["type"] == "SUBTITLE"
    assert by_name["Subtitle 2"]["idx"] == 1


def test_inventory_pptx_template_reports_theme_fonts_and_colors(
    master_template_path,
):
    binding = inventory_pptx_template(master_template_path)

    theme = binding["styles"]["theme"]
    assert theme["fonts"]["major"]
    assert theme["fonts"]["minor"]
    # The default python-pptx template uses the stock Office palette.
    assert theme["colors"]["accent1"].upper() == "4F81BD"


def test_inventory_pptx_template_reports_slide_size(master_template_path):
    binding = inventory_pptx_template(master_template_path)

    slide_size = binding["styles"]["slide_size"]
    assert slide_size["width_emu"] > 0
    assert slide_size["height_emu"] > 0


def test_inventory_pptx_template_produces_a_valid_binding(master_template_path):
    binding = inventory_pptx_template(master_template_path)
    validate_binding(binding)
