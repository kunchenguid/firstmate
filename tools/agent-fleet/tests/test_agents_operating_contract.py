from pathlib import Path

import pytest

AGENTS = Path(__file__).parents[3] / "AGENTS.md"


@pytest.mark.parametrize(
    "rule",
    [
        "Add the line when you clone or create a project, keep the description "
        "useful for identifying the project, and drop the line if a project is "
        "ever removed from `projects/`.",
        "If `config/crew-harness` or `config/secondmate-harness` names an "
        "unverified one, tell the captain and fall back to your own harness "
        "until it is verified.",
    ],
)
def test_curated_operating_rule_remains_verbatim(rule: str) -> None:
    assert AGENTS.read_text().splitlines().count(rule) == 1
