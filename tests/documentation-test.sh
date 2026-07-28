#!/bin/sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
sh "$ROOT/tests/eigiib-documentation-test.sh"
sh "$ROOT/tests/feature-matrix-test.sh"
printf 'documentation review passed
'
