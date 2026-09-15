"""presenter - template-driven PowerPoint and Word authoring.

The library assembles a document from plain JSON-serializable content
blocks, binds it to a corporate template through a TemplateBinding, and
renders it to ``.pptx`` or ``.docx`` through a registered engine.

``presenter/README.md`` is the documentation of record, including the
canonical block and TemplateBinding contracts.  ``presenter.core`` holds
the specification model, block validation, and the render entry point.
"""

__version__ = "0.1.0"

__all__ = ["__version__"]
