# Ordinary-brief baseline

Path-normalized `bin/fm-brief.sh` output captured from commit 8f7b79c7, the
current base before the per-project external-contract mode lands. These files are
the committed anchor for the acceptance criterion "ordinary project brief output
is byte-identical to the old path": `tests/fm-brief.test.sh` regenerates each
brief with the current script, applies the same normalization, and compares bytes.

Normalization (identical in the capture and the test): the temp home's
`state/` and `data/` directories become `{STATE}` and `{DATA}`, and the firstmate
repo root becomes `{FM_ROOT}`. Project name is `baseline-proj`; the task id is the
fixture's basename.

Regenerating these files from the current script would defeat their purpose. They
change only when a deliberate, reviewed change to ordinary brief text is made, and
the diff is then the record of exactly what the crewmate-facing text lost or gained.
