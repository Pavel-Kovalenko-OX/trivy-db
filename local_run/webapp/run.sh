#!/usr/bin/env bash

# Add Go bin to PATH for bbolt and other Go tools
export PATH="$HOME/go/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$SCRIPT_DIR" || exit 1
. ./venv/bin/activate
python app.py
