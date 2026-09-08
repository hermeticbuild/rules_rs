#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "${script_dir}/.."

resolve_crate_dep() {
    local root_target="$1"
    local crate_name="$2"

    bt --ignore_all_rc_files cquery \
        "filter(\"//:${crate_name}$\", deps(${root_target}))" \
        --registry=https://bcr.bazel.build \
        --output=label 2>/dev/null |
        grep -F 'rs_pkg__' |
        sed -E 's/ \([^()]+\)$//' |
        sort -u |
        tail -n 1
}

assert_one_rustc_action_per_configuration() {
    local summary="$1"

    grep -F 'Rustc:' <<<"${summary}"
    awk '
        /^Configurations:$/ { in_configurations = 1; next }
        /^Execution Platforms:$/ { in_configurations = 0 }
        in_configurations && /^  / {
            found = 1
            if ($NF != 1) {
                exit 1
            }
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' <<<"${summary}"
}

readonly bar_http="$(resolve_crate_dep '@crate_coalescing_bar//:library_bar' 'http')"
readonly baz_http="$(resolve_crate_dep '@crate_coalescing_baz//:library_baz' 'http')"
readonly bar_serde="$(resolve_crate_dep '@crate_coalescing_bar//:library_bar' 'serde')"
readonly baz_serde="$(resolve_crate_dep '@crate_coalescing_baz//:library_baz' 'serde')"

[[ -n "${bar_http}" && "${bar_http}" == "${baz_http}" ]]
[[ -n "${bar_serde}" && "${bar_serde}" == "${baz_serde}" ]]

summary="$(
    bt --ignore_all_rc_files aquery \
        "mnemonic(\"Rustc\", ${bar_http})" \
        --registry=https://bcr.bazel.build \
        --output=summary 2>&1
)"

assert_one_rustc_action_per_configuration "${summary}"

serde_summary="$(
    bt --ignore_all_rc_files aquery \
        "mnemonic(\"Rustc\", ${bar_serde})" \
        --registry=https://bcr.bazel.build \
        --output=summary 2>&1
)"
serde_action="$(
    bt --ignore_all_rc_files aquery \
        "mnemonic(\"Rustc\", ${bar_serde})" \
        --registry=https://bcr.bazel.build \
        --output=text 2>&1
)"

assert_one_rustc_action_per_configuration "${serde_summary}"
grep -F "'feature=\"derive\"'" <<<"${serde_action}"
grep -F "'feature=\"std\"'" <<<"${serde_action}"
grep -F -- '--extern=serde_derive=' <<<"${serde_action}"
