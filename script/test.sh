#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run TokenStatCoreChecks
./script/build_and_run.sh --build-only
python3 script/integration.py
