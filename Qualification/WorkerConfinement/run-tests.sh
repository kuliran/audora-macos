#!/bin/sh
set -eu

cd "$(dirname "$0")"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
"$PYTHON_BIN" -W error::ResourceWarning -m unittest discover -s tests -v
