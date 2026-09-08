#!/usr/bin/env bash
set -euo pipefail

shared_deps="$1"
shared_log="$2"

grep 'rs_pkg__http-1.3.1' "${shared_deps}"
grep 'rs_pkg__bytes-1.10.1' "${shared_deps}"
grep 'rs_pkg__itoa-1.0.15' "${shared_deps}"
grep 'rs_pkg__log-0.4.29' "${shared_log}"
grep 'rs_pkg__serde-1.0.228' "${shared_deps}"
grep 'rs_pkg__serde_underscore_derive-1.0.228' "${shared_deps}"

if grep -E '(bar_crates|zz_baz_crates)__http-1.3.1' "${shared_deps}"; then
    echo "http unexpectedly remained hub-local" >&2
    exit 1
fi

if grep -E '(crate_coalescing_a|crate_coalescing_b|bar_crates|zz_baz_crates)__log-0.4.29' "${shared_log}"; then
    echo "log unexpectedly remained hub-local" >&2
    exit 1
fi

if grep -E '(bar_crates|zz_baz_crates)__serde-1.0.228' "${shared_deps}"; then
    echo "serde unexpectedly remained hub-local" >&2
    exit 1
fi

if grep 'local-helper' "${shared_deps}"; then
    echo "separate path packages unexpectedly shared a target" >&2
    exit 1
fi
