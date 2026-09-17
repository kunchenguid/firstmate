"""Exception hierarchy for the presenter library.

Every error raised by presenter derives from :class:`PresenterError`, so a
caller can catch one base class.  Engine slots that are registered but not
yet implemented raise :class:`EngineNotImplementedError`, which is both a
:class:`RenderError` and a :class:`NotImplementedError`.
"""

from __future__ import annotations

__all__ = [
    "PresenterError",
    "SpecError",
    "BlockValidationError",
    "BindingError",
    "RenderError",
    "UnknownFormatError",
    "EngineNotImplementedError",
]


class PresenterError(Exception):
    """Base class for every error raised by presenter."""


class SpecError(PresenterError):
    """A DocumentSpec or SlideSpec is structurally invalid."""


class BlockValidationError(SpecError):
    """A content block does not satisfy the shared block contract.

    ``location`` names where the block sits (for example ``"slides[2].blocks[0]"``)
    when the validator knows it, so a failure inside a large document can be
    found without re-validating block by block.
    """

    def __init__(self, message: str, *, location: str | None = None) -> None:
        self.location = location
        prefix = f"{location}: " if location else ""
        super().__init__(f"{prefix}{message}")


class BindingError(PresenterError):
    """A TemplateBinding does not carry the keys the renderer dispatches on."""


class RenderError(PresenterError):
    """Rendering could not start or complete."""


class UnknownFormatError(RenderError):
    """The binding names an output format that no engine slot exists for."""


class EngineNotImplementedError(RenderError, NotImplementedError):
    """The engine slot for this format exists but nothing has registered into it."""
