"""TemplateBinding load, save, and contract validation.

A TemplateBinding is a plain JSON-serializable dict shared by the
template-ingestion and render-engine lanes::

    {
        "format": "pptx" | "docx",
        "template": "<path to the template file>",
        "name": str,
        "layouts": {"<layout name>": {"<placeholder name>": "<role>"}},
        "placeholders": {...},
        "styles": {...},
    }

PPTX bindings additionally carry a ``masters`` array with one entry per
slide master in the template (corporate templates may contain several)::

    {
        "masters": [
            {
                "name": str,
                "layouts": {"<layout name>": {"<placeholder name>": "<role>"}},
                "theme": {"fonts": {...}, "colors": {...}},
            },
            ...
        ],
    }

The top-level ``layouts``, ``placeholders``, and ``styles`` keys of a PPTX
binding retain the first master's view for backward compatibility with
consumers written before the ``masters`` array existed; consumers needing
multi-master coverage should read ``masters`` directly.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

VALID_FORMATS = frozenset({"pptx", "docx"})
REQUIRED_KEYS = frozenset(
    {"format", "template", "name", "layouts", "placeholders", "styles"}
)
_DICT_KEYS = frozenset({"layouts", "placeholders", "styles"})


class TemplateBindingError(ValueError):
    """Raised when a TemplateBinding dict fails contract validation."""


def validate_binding(binding: dict[str, Any]) -> None:
    """Validate ``binding`` against the shared TemplateBinding contract.

    Raises TemplateBindingError with a descriptive message on the first
    violation found; returns None when the binding is valid.
    """
    if not isinstance(binding, dict):
        raise TemplateBindingError(
            f"binding must be a dict, got {type(binding).__name__}"
        )

    missing = REQUIRED_KEYS - binding.keys()
    if missing:
        raise TemplateBindingError(f"binding missing required keys: {sorted(missing)}")

    fmt = binding["format"]
    if fmt not in VALID_FORMATS:
        raise TemplateBindingError(
            f"binding['format'] must be one of {sorted(VALID_FORMATS)}, got {fmt!r}"
        )

    if not isinstance(binding["template"], str) or not binding["template"]:
        raise TemplateBindingError("binding['template'] must be a non-empty string")

    if not isinstance(binding["name"], str) or not binding["name"]:
        raise TemplateBindingError("binding['name'] must be a non-empty string")

    for key in _DICT_KEYS:
        if not isinstance(binding[key], dict):
            raise TemplateBindingError(
                f"binding[{key!r}] must be a dict, got {type(binding[key]).__name__}"
            )

    layouts = binding["layouts"]
    for layout_name, layout_roles in layouts.items():
        if not isinstance(layout_name, str):
            raise TemplateBindingError(
                f"layout names must be strings, got {layout_name!r}"
            )
        if not isinstance(layout_roles, dict):
            raise TemplateBindingError(
                f"binding['layouts'][{layout_name!r}] must be a dict, "
                f"got {type(layout_roles).__name__}"
            )
        for placeholder_name, role in layout_roles.items():
            if not isinstance(placeholder_name, str) or not isinstance(role, str):
                raise TemplateBindingError(
                    f"binding['layouts'][{layout_name!r}] entries must map "
                    f"str -> str, got {placeholder_name!r}: {role!r}"
                )


def load_binding(path: str | Path) -> dict[str, Any]:
    """Load and validate a TemplateBinding dict from a JSON file."""
    binding = json.loads(Path(path).read_text(encoding="utf-8"))
    validate_binding(binding)
    return binding


def save_binding(binding: dict[str, Any], path: str | Path) -> None:
    """Validate ``binding`` and write it as JSON to ``path``."""
    validate_binding(binding)
    Path(path).write_text(
        json.dumps(binding, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
