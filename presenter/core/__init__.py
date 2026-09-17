"""Core of the presenter library: spec model, block contract, render dispatch.

Public surface (re-exported here for convenience; each submodule is the
owner of its part):

- :mod:`presenter.core.spec` - ``DocumentSpec``, ``SlideSpec``, ``DocumentBuilder``.
- :mod:`presenter.core.blocks` - ``validate_block`` and the typed block accessors.
- :mod:`presenter.core.render` - ``render``, ``register_engine``, and the registry.
- :mod:`presenter.core.errors` - ``PresenterError`` and its subclasses.
"""

from presenter.core.blocks import (
    BLOCK_TYPES,
    TABLE_STYLES,
    TEXT_STYLES,
    Block,
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
from presenter.core.errors import (
    BindingError,
    BlockValidationError,
    EngineNotImplementedError,
    PresenterError,
    RenderError,
    SpecError,
    UnknownFormatError,
)
from presenter.core.render import (
    FORMATS,
    Engine,
    binding_format,
    get_engine,
    is_engine_implemented,
    register_engine,
    registered_formats,
    render,
    unregister_engine,
    validate_binding,
)
from presenter.core.spec import SPEC_VERSION, DocumentBuilder, DocumentSpec, SlideSpec

__all__ = [
    "BLOCK_TYPES",
    "TABLE_STYLES",
    "TEXT_STYLES",
    "Block",
    "EquationBlock",
    "ImageBlock",
    "PageBreakBlock",
    "PlotBlock",
    "TableBlock",
    "TextBlock",
    "TocBlock",
    "block_from_dict",
    "validate_block",
    "validate_blocks",
    "BindingError",
    "BlockValidationError",
    "EngineNotImplementedError",
    "PresenterError",
    "RenderError",
    "SpecError",
    "UnknownFormatError",
    "FORMATS",
    "Engine",
    "binding_format",
    "get_engine",
    "is_engine_implemented",
    "register_engine",
    "registered_formats",
    "render",
    "unregister_engine",
    "validate_binding",
    "SPEC_VERSION",
    "DocumentBuilder",
    "DocumentSpec",
    "SlideSpec",
]
