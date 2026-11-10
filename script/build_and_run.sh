#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product pocket-backend-benchmark
exec .build/release/pocket-backend-benchmark "$@"
