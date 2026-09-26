"""Inventory a Word (.docx) template into a TemplateBinding dict."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from docx import Document
from docx.oxml.ns import qn

_SDT_CONTENT_TAGS = (
    "w:text",
    "w:richText",
    "w:dropDownList",
    "w:comboBox",
    "w:date",
    "w:checkBox",
    "w:picture",
    "w:citation",
    "w:group",
    "w:docPartObj",
)


def _content_controls(document: Any) -> list[dict[str, Any]]:
    """Inventory every structured document tag (content control) in the body."""
    controls: list[dict[str, Any]] = []
    for sdt in document.element.body.iter(qn("w:sdt")):
        sdt_pr = sdt.find(qn("w:sdtPr"))

        tag = alias = None
        control_type = "plainText"
        if sdt_pr is not None:
            tag_el = sdt_pr.find(qn("w:tag"))
            alias_el = sdt_pr.find(qn("w:alias"))
            tag = tag_el.get(qn("w:val")) if tag_el is not None else None
            alias = alias_el.get(qn("w:val")) if alias_el is not None else None
            for candidate in _SDT_CONTENT_TAGS:
                if sdt_pr.find(qn(candidate)) is not None:
                    control_type = candidate.split(":", 1)[1]
                    break

        controls.append({"tag": tag, "alias": alias, "type": control_type})
    return controls


def _control_role(control: dict[str, Any]) -> str:
    return control.get("tag") or control.get("alias") or control["type"]


def _placeholder_roles(controls: list[dict[str, Any]]) -> dict[str, str]:
    roles: dict[str, str] = {}
    for index, control in enumerate(controls):
        key = control.get("tag") or control.get("alias") or f"control_{index}"
        roles[key] = _control_role(control)
    return roles


def _styles_inventory(document: Any) -> dict[str, Any]:
    inventory: dict[str, list[str]] = {}
    for style in document.styles:
        type_name = style.type.name.lower()
        inventory.setdefault(type_name, []).append(style.name)
    return inventory


def _sections_inventory(document: Any) -> list[dict[str, Any]]:
    sections: list[dict[str, Any]] = []
    for section in document.sections:
        sections.append(
            {
                "page_width_emu": int(section.page_width)
                if section.page_width is not None
                else None,
                "page_height_emu": int(section.page_height)
                if section.page_height is not None
                else None,
                "orientation": section.orientation.name,
                "has_header": not section.header.is_linked_to_previous,
                "has_footer": not section.footer.is_linked_to_previous,
            }
        )
    return sections


def inventory_docx_template(path: str | Path) -> dict[str, Any]:
    """Read a .docx template and return a TemplateBinding dict.

    Inventories paragraph/character/table/list styles, structured
    document tags (content controls), and section geometry.
    """
    path = Path(path)
    document = Document(str(path))

    controls = _content_controls(document)
    styles = _styles_inventory(document)
    styles["sections"] = _sections_inventory(document)

    return {
        "format": "docx",
        "template": str(path),
        "name": path.stem,
        "layouts": {"default": _placeholder_roles(controls)},
        "placeholders": {"content_controls": controls},
        "styles": styles,
    }
