"""DOCX rendering for the presenter library.

Public entry point: :func:`render` turns a list of content block dicts,
optionally bound to a corporate .docx template through a TemplateBinding
dict, into a finished .docx document.
"""

from presenter.render_docx.engine import render

__all__ = ["render"]
