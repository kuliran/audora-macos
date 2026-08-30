#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON_BIN=${PYTHON_BIN:-python3}

exec "$PYTHON_BIN" -m unittest discover -s "$SCRIPT_DIR/tests" -p 'test_*.py' -v
