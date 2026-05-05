#!/usr/bin/env bash
set -euo pipefail

alpha_output="$1"
beta_output="$2"

grep -q "alpha-only API should not be used outside project alpha" "${alpha_output}"
! grep -q "beta-only API should not be used outside project beta" "${alpha_output}"

grep -q "beta-only API should not be used outside project beta" "${beta_output}"
! grep -q "alpha-only API should not be used outside project alpha" "${beta_output}"
