#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly output="$(mktemp)"
trap 'rm -f "${output}"' EXIT

cd "${script_dir}/.."

# The raw native target is intentionally unchecked without the aspect.
bt --ignore_all_rc_files build \
    //cargo_link_validation:cc_mixed_conflict_unchecked \
    >"${output}" 2>&1

# Applying the public aspect at the command line must reject the same target.
if bt --ignore_all_rc_files build \
    //cargo_link_validation:cc_mixed_conflict_unchecked \
    --aspects=@rules_rust//rust:rust_link_validation.bzl%rust_link_validation_aspect \
    >"${output}" 2>&1; then
    echo "command-line Rust link-validation aspect unexpectedly succeeded" >&2
    exit 1
fi
grep -F "would link incompatible instances of the same Rust library" "${output}"

# An action query must fail during analysis and therefore return no C++ link
# action for the invalid configured target.
if bt --ignore_all_rc_files aquery \
    //cargo_link_validation:cc_mixed_conflict_unchecked \
    --aspects=@rules_rust//rust:rust_link_validation.bzl%rust_link_validation_aspect \
    --output=summary \
    >"${output}" 2>&1; then
    echo "command-line aspect action query unexpectedly succeeded" >&2
    exit 1
fi
grep -F "would link incompatible instances of the same Rust library" "${output}"
if grep -F "CppLink" "${output}"; then
    echo "invalid native target exposed a C++ link action" >&2
    exit 1
fi
