#!/bin/sh
# Mandatory direct-execution door into tests/run.sh.

fm_test_entry_script=$0
case "$fm_test_entry_script" in
  /*) ;;
  *) fm_test_entry_script=$PWD/$fm_test_entry_script ;;
esac
fm_test_entry_dir=$(cd "$(dirname "$fm_test_entry_script")" && pwd -P) || exit 97
fm_test_entry_script=$fm_test_entry_dir/$(basename "$fm_test_entry_script")
fm_test_entry_root=$(cd "$fm_test_entry_dir/.." && pwd -P) || exit 97

if [ "${FM_TEST_RUNNER_ACTIVE:-}" != firstmate-test-runner-v1 ]; then
  exec "$fm_test_entry_root/tests/run.sh" "$fm_test_entry_script" "$@"
fi

python3 "$fm_test_entry_root/tests/test-seal.py" admit "$fm_test_entry_script" || exit $?
unset fm_test_entry_script fm_test_entry_dir fm_test_entry_root
