"""Corporate template ingestion for the presenter package.

Reads .pptx and .docx master templates and produces a TemplateBinding
dict (layouts, placeholders, styles) consumed by the render engines.
"""

from presenter.templates.binding import (
    TemplateBindingError,
    load_binding,
    save_binding,
    validate_binding,
)
from presenter.templates.docx import inventory_docx_template
from presenter.templates.pptx import inventory_pptx_template

__all__ = [
    "TemplateBindingError",
    "inventory_docx_template",
    "inventory_pptx_template",
    "load_binding",
    "save_binding",
    "validate_binding",
]
