#!/usr/bin/env bash
set -euo pipefail

lib="$1"
llvm_nm="$2"
llvm_readelf="$3"

undefined="$("$llvm_nm" -m -u "$lib")"
echo "$undefined" | grep '_Unwind_GetIP$'
echo "$undefined" | grep '_Unwind_GetIPInfo$'

dynamic="$("$llvm_readelf" --dynamic "$lib")"
echo "$dynamic" | grep 'Shared library: \[libunwind\.so'
echo "$dynamic" | grep 'RUNPATH'
