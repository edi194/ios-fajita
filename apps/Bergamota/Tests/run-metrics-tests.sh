#!/bin/sh
# Compiles Core/Metrics.swift with Tests/main.swift and runs the parsing tests on the recorded samples.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/bergamota-metrics-tests
swiftc -O -o "$out" "$here/../Bergamota/Core/Metrics.swift" "$here/main.swift"
exec "$out" "$here/metrics-samples"
