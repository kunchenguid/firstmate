"""Inventory a PowerPoint (.pptx) master template into a TemplateBinding dict."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from lxml import etree
from pptx import Presentation

_THEME_REL_TYPE = (
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
)
_DRAWINGML_NS = {"a": "http://schemas.openxmlformats.org/drawingml/2006/main"}

# Maps python-pptx placeholder type names to a shared, render-engine-facing role.
_ROLE_BY_PLACEHOLDER_TYPE = {
    "TITLE": "title",
    "CENTER_TITLE": "title",
    "SUBTITLE": "subtitle",
    "BODY": "body",
    "OBJECT": "body",
    "PICTURE": "picture",
    "TABLE": "table",
    "CHART": "chart",
    "DATE": "date",
    "FOOTER": "footer",
    "SLIDE_NUMBER": "slide_number",
    "HEADER": "header",
}


def _placeholder_role(placeholder_type: Any) -> str:
    return _ROLE_BY_PLACEHOLDER_TYPE.get(
        placeholder_type.name, placeholder_type.name.lower()
    )


def _layout_placeholders(layout: Any) -> tuple[dict[str, str], list[dict[str, Any]]]:
    roles: dict[str, str] = {}
    inventory: list[dict[str, Any]] = []
    for shape in layout.placeholders:
        placeholder_format = shape.placeholder_format
        roles[shape.name] = _placeholder_role(placeholder_format.type)
        inventory.append(
            {
                "name": shape.name,
                "type": placeholder_format.type.name,
                "idx": placeholder_format.idx,
            }
        )
    return roles, inventory


def _theme_styles(master: Any) -> dict[str, Any]:
    try:
        theme_part = master.part.part_related_by(_THEME_REL_TYPE)
    except KeyError:
        return {"fonts": {}, "colors": {}}

    root = etree.fromstring(theme_part.blob)
    font_scheme = root.find(".//a:fontScheme", _DRAWINGML_NS)
    color_scheme = root.find(".//a:clrScheme", _DRAWINGML_NS)

    fonts: dict[str, str] = {}
    if font_scheme is not None:
        for role, tag in (("major", "a:majorFont"), ("minor", "a:minorFont")):
            latin = font_scheme.find(f"{tag}/a:latin", _DRAWINGML_NS)
            if latin is not None and latin.get("typeface"):
                fonts[role] = latin.get("typeface")

    colors: dict[str, str] = {}
    if color_scheme is not None:
        for entry in color_scheme:
            name = etree.QName(entry).localname
            if len(entry) == 0:
                continue
            child = entry[0]
            value = child.get("val") or child.get("lastClr")
            if value:
                colors[name] = value

    return {"fonts": fonts, "colors": colors}


def inventory_pptx_template(path: str | Path) -> dict[str, Any]:
    """Read a .pptx master template and return a TemplateBinding dict.

    Inventories every slide layout's placeholders (name, type, idx) and
    the master's theme fonts and colors.
    """
    path = Path(path)
    presentation = Presentation(str(path))
    master = presentation.slide_masters[0]

    layouts: dict[str, dict[str, str]] = {}
    placeholders: dict[str, list[dict[str, Any]]] = {}
    for layout in presentation.slide_layouts:
        roles, inventory = _layout_placeholders(layout)
        layouts[layout.name] = roles
        placeholders[layout.name] = inventory

    styles: dict[str, Any] = {
        "theme": _theme_styles(master),
        "slide_size": {
            "width_emu": int(presentation.slide_width)
            if presentation.slide_width is not None
            else None,
            "height_emu": int(presentation.slide_height)
            if presentation.slide_height is not None
            else None,
        },
    }

    return {
        "format": "pptx",
        "template": str(path),
        "name": path.stem,
        "layouts": layouts,
        "placeholders": placeholders,
        "styles": styles,
    }
