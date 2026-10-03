#!/bin/bash
# No proprietary 64 KiB build, no packing-off option.
set -euo pipefail
case "${1:?}-${2:?}" in
    proprietary-4k|open-4k|open-64k) ;;
    *) echo "Unsupported variant: ${1}-${2}" >&2; exit 1 ;;
esac
