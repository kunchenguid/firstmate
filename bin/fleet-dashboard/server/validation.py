"""Structural enforcement of the board's link and needs-attention policy.

The Admiral receives files for review as links he can open on his phone.
Two rules from standing order 17 and his own words are enforced here, not
just documented, so a card cannot silently carry a link that fails them:

  1. Never a GitHub or pull-request link.
  2. Never a link that cannot open on his phone (a bare path, or a host
     that only resolves on this machine).

A third rule enforced here: `needs_attention` is the loudest status on the
board and means the work is blocked on him. A card set to that status with
no reason, or with a reason that only reports progress, spends his
attention for nothing - see `validate_needs_attention_reason`.
"""

from __future__ import annotations

import ipaddress
from urllib.parse import urlparse

LOCAL_HOSTNAMES = {"localhost", "127.0.0.1", "0.0.0.0", "::1"}

# Phrases that mark a needs_attention reason as a progress report rather
# than an ask. Matched as a case-insensitive substring anywhere in the
# reason, not just at the start, because the failure mode this guards
# against is exactly a report clause tacked onto the end of a sentence
# ("You reported flares not changing the lights - being chased now").
#
# This is deliberately a small, fixed list, not a language model: it
# catches only the plainest report-shaped language and says nothing about
# whether a reason that dodges every phrase here is actually a real ask.
# See docs/dashboard.md "The needs-attention reason guard" for the
# reviewed false-negative rate and the fleet auditor's complementary,
# non-mechanical check.
REPORT_SHAPED_PHRASES = (
    "being chased",
    "in progress",
    "investigating",
    "looking into",
    "working on",
    "keeping an eye on",
    "monitoring",
    "no update yet",
    "will update",
    "update to follow",
    "tracking down",
    "digging into",
    "following up on",
    "under investigation",
    "still chasing",
)


class InvalidLinkError(ValueError):
    pass


class InvalidReasonError(ValueError):
    pass


def validate_needs_attention_reason(reason: str | None) -> None:
    """Raise InvalidReasonError if reason cannot back a needs_attention card.

    Empty is always rejected: needs_attention is the loudest status on the
    board, and a card with no stated ask is exactly how it becomes noise.
    A non-empty reason is further rejected if it contains one of
    REPORT_SHAPED_PHRASES, on the theory that a real ask ("pick red or
    blue for the trim") essentially never contains one of these phrases,
    while a status update dropped into the field ("being chased now")
    reliably does.
    """
    text = (reason or "").strip()
    if not text:
        raise InvalidReasonError(
            "needs-attention requires --reason - say what he needs to decide, "
            "approve, or supply, not what happened"
        )
    lowered = text.lower()
    for phrase in REPORT_SHAPED_PHRASES:
        if phrase in lowered:
            raise InvalidReasonError(
                f"that reason reads as a progress report, not something he can act on "
                f"(matched {phrase!r}) - say what he needs to decide, approve, or supply: {text!r}"
            )


def _is_private_literal(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return False


def validate_review_link(url: str) -> None:
    """Raise InvalidLinkError if url cannot be sent to the Admiral as-is."""
    if not url or not url.strip():
        raise InvalidLinkError("a link needs a URL")
    parsed = urlparse(url.strip())
    if parsed.scheme not in ("http", "https"):
        raise InvalidLinkError(
            f"link must be a full http(s) URL that opens on his phone, got: {url!r}"
        )
    host = (parsed.hostname or "").lower()
    if not host:
        raise InvalidLinkError(f"link has no host: {url!r}")
    if "github" in host:
        raise InvalidLinkError(
            "never a GitHub or pull-request link to the Admiral (standing order 17) "
            f"- report the outcome in words instead: {url!r}"
        )
    if host in LOCAL_HOSTNAMES or _is_private_literal(host):
        raise InvalidLinkError(
            f"link host is local-only and will not open on his phone: {url!r}"
        )
