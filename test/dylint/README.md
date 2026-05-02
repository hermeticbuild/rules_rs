# Dylint integration example

This package demonstrates two Rust targets in one Bazel workspace selecting different
custom Dylint libraries through their ordinary `lint_config` attribute:

- `:alpha_component` loads only `:alpha_policy`
- `:beta_component` loads only `:beta_policy`

The alpha config uses an explicit `dylint.toml`; the beta config omits one, which
exercises the runner's empty-config fallback instead of allowing Cargo workspace
discovery.

The small patches registered from `test/MODULE.bazel` only adapt upstream Dylint
crates to Bazel's non-`rustup` build-script environment; the lint behavior under test
is unchanged.

Run the example directly; `rust_dylint` moves only the checked lint subtree onto
the registered nightly toolchain:

```bash
bazel test //dylint:verify_target_local_dylint_configs
```
