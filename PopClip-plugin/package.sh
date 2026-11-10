#!/usr/bin/env bash
#
# Package the extension as atst.popclipextz, the zip format PopClip
# installs by double-click. Output: PopClip-plugin/atst.popclipextz
set -euo pipefail

cd "$(dirname "$0")"

rm -f atst.popclipextz
zip -r -X atst.popclipextz atst.popclipext -x '*.DS_Store' >/dev/null
printf 'Built %s\n' "$PWD/atst.popclipextz"
