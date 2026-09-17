#!/usr/bin/env bash
# test_plugin — run every plugin-side test and lint. No network, no API keys.
#
#   bash scripts/test_plugin.sh
#
# Python tests: unittest under Tests/plugin (jev_shadow state builder, rubric, row).
# Shell tests:  Tests/plugin/test_*.sh (hook behaviour under a throwaway HOME).
# Lint:         shellcheck -S error on all plugin scripts; ruff on the Python.
#               (Default-severity shellcheck already fails on files this branch
#               does not touch: SC2010/SC2034 in stop.sh, session_paths.sh, statusline.sh.)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
rc=0

echo "== python unit tests"
python3 -m unittest discover -s Tests/plugin -p 'test_*.py' || rc=1

for t in Tests/plugin/test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done

echo "== node --test Tests/plugin/test_jev_grader.mjs"
if command -v node >/dev/null 2>&1; then
  node --test Tests/plugin/test_jev_grader.mjs || rc=1
else
  echo "node not installed; skipped"
fi

echo "== shellcheck -S error"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error plugin/hooks/*.sh plugin/lib/*.sh plugin/grader/*.sh plugin/statusline.sh scripts/*.sh Tests/plugin/*.sh || rc=1
else
  echo "shellcheck not installed; skipped"
fi

echo "== ruff"
if command -v ruff >/dev/null 2>&1; then
  ruff check --line-length 120 plugin/grader/jev_shadow.py Tests/plugin/*.py || rc=1
else
  echo "ruff not installed; skipped"
fi

exit $rc
