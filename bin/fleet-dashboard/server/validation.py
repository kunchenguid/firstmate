"""Structural enforcement of the board's link and needs-attention policy.

The Admiral receives files for review as links he can open on his phone.
Two rules from standing order 17 and his own words are enforced here, not
just documented, so a card cannot silently carry a link that fails them:

  1. Never a GitHub or pull-request link.
  2. Never a link that cannot open on his phone (a bare path, or a host
     that only resolves on this machine).

A third rule enforced here: `needs_attention` is the loudest status on the
board and means the work is blocked on him. A card set to that status with
no reason, or with a reason that only opens or closes as a progress
report, spends his attention for nothing - see
`validate_needs_attention_reason`.
"""

from __future__ import annotations

import ipaddress
import re
from urllib.parse import urlparse

LOCAL_HOSTNAMES = {"localhost", "127.0.0.1", "0.0.0.0", "::1"}

# Phrases that mark a needs_attention reason as a progress report rather
# than an ask. A phrase only counts when it sits at an *edge* of the
# reason - the start or the end of the leading or trailing clause - not
# when it is buried inside one. That is the shape the failure this guards
# against actually takes: a report clause tacked onto a sentence ("You
# reported flares not changing the lights - being chased now"), or a
# reason that simply opens as a status update ("Still investigating the
# checkout timeout"). Matching anywhere instead refused genuine asks that
# merely contain the words ("approve the $400 monitoring subscription
# renewal", "pick which contractor keeps working on the deck"), which
# leaves the card silently stuck in `working` - the inverse of the failure
# this guard exists to prevent.
#
# This is deliberately a small, fixed list, not a language model: it
# catches only the plainest report-shaped language and says nothing about
# whether a reason that dodges every phrase here is actually a real ask.
# See docs/dashboard.md "The needs-attention reason guard" for the
# reviewed catch and false-positive rates and the fleet auditor's
# complementary, non-mechanical check.
REPORT_SHAPED_PHRASES = (
    "being chased",
    "in progress",
    "investigating",
    "looking into",
    "working on",
    "keeping an eye on",
    "monitoring the",
    "monitoring it",
    "no update yet",
    "will update",
    "update to follow",
    "tracking down",
    "digging into",
    "following up on",
    "under investigation",
    "still chasing",
)

# A clause boundary: sentence punctuation, or a dash used as a separator
# (spaced, so "follow-up" stays one word).
_CLAUSE_SEPARATORS = re.compile(r"\s+[-\u2013\u2014]+\s+|[,;:.!?()\[\]/\n]+")

# Hedges that can sit in front of a report phrase without changing that the
# clause opens as a report ("Still investigating...", "We're looking into...",
# "We are investigating..."). Deliberately a closed grammatical class - the
# first-person subjects plus the English copulas - not an open list of
# subjects: a subject noun in front of a report phrase ("The team is looking
# into it") stays a miss, in the same reworded-phrasing blind spot documented
# in docs/dashboard.md.
_LEADING_FILLER = frozenset(
    {
        "still",
        "currently",
        "now",
        "just",
        "already",
        "we",
        "we're",
        "i",
        "i'm",
        "im",
        "is",
        "are",
        "was",
        "were",
        "'s",
        "'re",
    }
)

# Trailers that can sit behind a report phrase without changing that the
# clause closes as a report ("being chased now", "looking into it").
_TRAILING_FILLER = frozenset(
    {
        "now",
        "today",
        "tonight",
        "yet",
        "again",
        "here",
        "it",
        "this",
        "that",
        "them",
        "these",
        "those",
        "still",
        "currently",
        "already",
        "though",
    }
)


def _tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _edge_clauses(text: str) -> list[str]:
    parts = [part.strip() for part in _CLAUSE_SEPARATORS.split(text)]
    parts = [part for part in parts if part]
    if len(parts) <= 1:
        return parts
    return [parts[0], parts[-1]]


def _sits_at_an_edge(clause: list[str], phrase: list[str]) -> bool:
    """True if phrase opens or closes clause, ignoring hedge words at that edge."""
    size = len(phrase)
    start = 0
    while start + size <= len(clause):
        if clause[start : start + size] == phrase:
            return True
        if clause[start] in _LEADING_FILLER:
            start += 1
            continue
        break
    end = len(clause)
    while end - size >= 0:
        if clause[end - size : end] == phrase:
            return True
        if clause[end - 1] in _TRAILING_FILLER:
            end -= 1
            continue
        break
    return False


def find_report_shaped_phrase(reason: str) -> str | None:
    """Return the report-shaped phrase sitting at an edge of reason, if any."""
    clauses = [_tokens(clause) for clause in _edge_clauses(reason)]
    for phrase in REPORT_SHAPED_PHRASES:
        phrase_tokens = _tokens(phrase)
        if not phrase_tokens:
            continue
        for clause in clauses:
            if _sits_at_an_edge(clause, phrase_tokens):
                return phrase
    return None


class InvalidLinkError(ValueError):
    pass


class InvalidReasonError(ValueError):
    pass


def validate_needs_attention_reason(reason: str | None) -> None:
    """Raise InvalidReasonError if reason cannot back a needs_attention card.

    Empty is always rejected: needs_attention is the loudest status on the
    board, and a card with no stated ask is exactly how it becomes noise.
    A non-empty reason is further rejected if one of REPORT_SHAPED_PHRASES
    opens or closes its leading or trailing clause, on the theory that a
    real ask ("pick red or blue for the trim") essentially never starts or
    ends that way, while a status update dropped into the field ("being
    chased now") reliably does. A phrase buried mid-clause is left alone -
    "approve the $400 monitoring subscription renewal" is a real ask.
    """
    text = (reason or "").strip()
    if not text:
        raise InvalidReasonError(
            "needs-attention requires --reason - say what he needs to decide, "
            "approve, or supply, not what happened"
        )
    phrase = find_report_shaped_phrase(text)
    if phrase is not None:
        raise InvalidReasonError(
            f"that reason reads as a progress report, not something he can act on "
            f"(matched {phrase!r} at the start or end of a clause) - say what he needs "
            f"to decide, approve, or supply: {text!r}"
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
