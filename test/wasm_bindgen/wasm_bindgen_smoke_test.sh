#!/usr/bin/env bash

# --- begin runfiles.bash initialization v3 ---
# Copy-pasted from the Bazel Bash runfiles library v3.
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

set -euo pipefail

js_found=0
wasm_found=0

for arg in "$@"; do
    for path in ${arg}; do
        full_path="$(rlocation "${path}")"
        case "${path}" in
            *.js)
                test -s "${full_path}"
                grep -q "add_one" "${full_path}"
                js_found=1
                ;;
            *_bg.wasm)
                test -s "${full_path}"
                wasm_found=1
                ;;
        esac
    done
done

if [[ "${js_found}" -ne 1 ]]; then
    echo "wasm-bindgen JS output was not found" >&2
    exit 1
fi

if [[ "${wasm_found}" -ne 1 ]]; then
    echo "wasm-bindgen wasm output was not found" >&2
    exit 1
fi
