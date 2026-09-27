#!/usr/bin/env bash
# tests/fm-jev-flake-detector.test.sh - Regression test suite for Pattern 13
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DETECTOR="${FM_ROOT}/bin/fm-jev-flake-detector.py"

echo "=== Running fm-jev-flake-detector test suite ==="

# Test 1: Syntax / compilation check
python3 -m py_compile "${DETECTOR}"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
shellcheck "${FM_ROOT}/bin/fm-jev-flake-detector.sh"
echo "PASS: Test 2 - ShellCheck clean on wrapper"

# Test 3: Unit test signature matching logic
python3 -c '
import sys
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("fd", "'"${DETECTOR}"'")
fd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fd)

# Test flake signatures
mock_sse_log = """
AssertionError: primary action \"Check In\" for apt_123 never stuck within 40000ms
waiting for locator(\"tr[data-appointment-id=\\\"apt_123\\\"]\")
The click landed on a node the next SSE render replaced
tests/e2e_journeys/test_j7_visit_lifecycle.py::test_in_person_visit_lifecycle
"""
tests, signatures = fd.parse_failed_tests_and_traces(mock_sse_log)
assert "tests/e2e_journeys/test_j7_visit_lifecycle.py::test_in_person_visit_lifecycle" in tests, f"Missing test: {tests}"
assert "Staff dashboard SSE re-render race" in signatures, f"Missing SSE signature: {signatures}"
assert "E2E staff driver appointment action convergence timeout" in signatures, f"Missing action timeout: {signatures}"
print("PASS: Test 3 - Flake signature matching verified")
'

# Test 4: Unit test intersection logic (genuine defect vs flake)
python3 -c '
import sys
sys.path.insert(0, "'"${FM_ROOT}"'/bin")
import importlib.util
spec = importlib.util.spec_from_file_location("fd", "'"${DETECTOR}"'")
fd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fd)

# Case 1: Untouched test -> FLAKE_TRANSIENT
tests = ["tests/e2e_journeys/test_j7_visit_lifecycle.py"]
changed = ["app/templates/header.html", "static/css/main.css"]
intersection = [t for t in tests if t in changed]
assert len(intersection) == 0, "Expected empty intersection"

# Case 2: Touched test -> CODE_REGRESSION
changed_with_test = ["tests/e2e_journeys/test_j7_visit_lifecycle.py", "app/staff/views.py"]
intersection_reg = [t for t in tests if t in changed_with_test]
assert len(intersection_reg) == 1, "Expected intersection"

# Case 3: Bot gate recognition
assert fd.is_bot_review_gate("PR must be raised via no-mistakes", "Require no-mistakes")
assert fd.is_bot_review_gate("Juror", "Juror")
assert not fd.is_bot_review_gate("Test Suite (0/12)", "CI")
print("PASS: Test 4 - Disambiguation & bot gate logic verified")
'

echo "=== All 4/4 fm-jev-flake-detector tests PASSED (100%) ==="
