#!/bin/bash
# Checks the modules in ROOT/lib/modules/$KERNEL_RELEASE:
#   - depmod resolves every symbol against SYSTEM_MAP and the other modules
#   - every module carries a SHA-512 signature and vermagic for $KERNEL_RELEASE
#
# Usage: check-modules.sh SYSTEM_MAP ROOT
# Environment: KERNEL_RELEASE
set -euo pipefail

system_map=$1
root=$2

# depmod reports unresolved symbols as warnings, so any output is a failure.
output=$(depmod -b "${root}" -F "${system_map}" --errsyms -w "${KERNEL_RELEASE}" 2>&1)
if [[ -n ${output} ]]; then
    echo "${output}" >&2
    exit 1
fi

count=0
while IFS= read -r -d '' module; do
    read -r release _ < <(modinfo -F vermagic "${module}")
    hash=$(modinfo -F sig_hashalgo "${module}")
    if [[ ${release} != "${KERNEL_RELEASE}" || ${hash} != sha512 ]]; then
        echo "${module}: vermagic '${release}', signature hash '${hash}'" >&2
        exit 1
    fi
    count=$((count + 1))
done < <(find "${root}/lib/modules/${KERNEL_RELEASE}" -name '*.ko' -print0)

echo "${count} modules: SHA-512 signed, vermagic ${KERNEL_RELEASE}, symbols resolved"
