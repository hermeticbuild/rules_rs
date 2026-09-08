#!/usr/bin/env bash
set -euo pipefail

deps="$1"
rustix_targets="$(grep -E 'rs_pkg__rustix-1\.1\.4__registry_[^/]+(__class_[0-9]+)?//:rustix$' "${deps}" || true)"
count="$(printf '%s\n' "${rustix_targets}" | grep -c . || true)"

if [[ "${count}" != 1 ]]; then
    echo "expected one coalesced rustix 1.1.4 target, found ${count}:" >&2
    printf '%s\n' "${rustix_targets}" >&2
    exit 1
fi
