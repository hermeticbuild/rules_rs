# Dylint support design

`rules_rs` supports [Dylint](https://github.com/trailofbits/dylint) by treating a Dylint
configuration as an explicit Bazel dependency instead of as ambient workspace state.
That choice is deliberate: Dylint itself can discover libraries from workspace metadata,
but a single repository-wide metadata block would make every Rust target inherit the
same lint set. In Bazel, the more precise abstraction is:

```text
custom Rust lint library  ->  dylint_library
one reusable lint bundle  ->  dylint_config
one Rust target config    ->  lint_config = ":my_dylint_config"
one explicit check target ->  rust_dylint
```

The resulting graph keeps custom lints local to the checks that ask for them. Two
targets in the same repository can use entirely different Dylint libraries, flags, and
`dylint.toml` content without consulting or mutating a global repository configuration.

## Why the implementation is shaped this way

Dylint's native execution model has three details that matter for a Bazel integration:

1. Dylint libraries are dynamic libraries loaded into a compiler driver.
2. The driver accepts the selected libraries through `DYLINT_LIBS`.
3. Configurable libraries can consume inline `dylint.toml` content through
   `DYLINT_TOML`.

`rules_rs` uses those lower-level interfaces directly instead of shelling out to
`cargo dylint`. Doing so keeps dependency resolution, compilation, and target
selection inside Bazel while still preserving Dylint's library semantics.

The implementation therefore has four moving pieces:

```text
rust_shared_library --exec--> dylint_library ----+
                                                  |
                                                  v
                                             dylint_config
                                                  |
rust_library / rust_binary / rust_test ----------+----> rust_dylint
                 lint_config = ":..."            |
dylint_driver toolchain -------------------------+
```

- `dylint_library` wraps a host-built shared library and gives it a stable logical
  library name.
- `dylint_config` collects one or more wrapped libraries plus optional extra rustc
  flags and optional `dylint.toml` input. It also forwards an ordinary `LintsInfo`
  provider, so it can be assigned directly to a Rust target's existing
  `lint_config` attribute.
- `rust_dylint` runs a Dylint driver against explicitly listed Rust targets. The
  aspect reads each target's own `lint_config`, so custom lint selection is local by
  construction.
- `rust_dylint` uses a small runner binary to pass `DYLINT_LIBS`, read a TOML file into
  `DYLINT_TOML`, and expose the Rust compiler dynamic libraries to the driver at
  runtime on Linux, macOS, and Windows.
- If no TOML file is supplied, the runner sets `DYLINT_TOML` to an empty string.
  That keeps checks hermetic: Dylint does not fall back to `cargo metadata` or
  discover a workspace-global config behind Bazel's back.

## Implementation plan

1. Extend `rules_rs` toolchains with an opt-in `include_rustc_dev` switch that is
   accepted only for nightly Rust releases. Download `rustc-dev` beside `rustc`,
   expose the compiler-private `rlib`s through the Rust toolchain, and keep the
   stable/default toolchain path unchanged.
2. Model Dylint data explicitly:
   - `dylint_library` identifies one host-built dynamic library and its logical
     Dylint name.
   - `dylint_config` bundles libraries, optional TOML, optional extra rustc flags,
     and any ordinary Rust lint configuration it should forward.
   - `dylint_toolchain` supplies the driver executable independently of the lint
     libraries selected by any one target.
3. Reuse the existing Rust target `lint_config` edge instead of inventing a second
   per-target attribute. A `dylint_config` also forwards `LintsInfo`, so a target
   can keep one lint configuration reference while the Dylint aspect reads the
   richer provider from that same dependency.
4. Implement `rust_dylint` as an aspect-backed explicit check rule. The aspect is
   responsible for reconstructing the checked Rust action from the original target,
   preserving the target's ordinary deps, aliases, flags, and source shape while
   loading only that target's selected Dylint libraries.
5. Add a tiny runner binary between the Bazel action and the Dylint driver. It
   converts structured Bazel inputs into Dylint's environment-based protocol,
   supplies an empty TOML config when none is requested, and makes the Rust
   compiler dynamic libraries visible to the driver at runtime.
6. Verify the model with an integration example containing two Rust targets built
   from the same source file but assigned different `dylint_config` targets. The
   test must prove positive and negative selection: alpha sees only the alpha lint,
   beta sees only the beta lint.

## Alternatives considered

- **Repository-global Dylint metadata:** rejected because it collapses every target
  into one lint universe and directly conflicts with per-project custom policies.
- **Shelling out to `cargo dylint`:** rejected because it would hand source
  discovery, dependency resolution, and configuration lookup back to Cargo instead
  of the Bazel graph.
- **A direct lint rule that takes a target label and a config label:** rejected
  because it cannot faithfully reconstruct all of a Rust target's compile inputs
  from outside that target. An aspect can observe the original rule attributes and
  files, which is the same reason `rules_rust` uses aspects for comparable checks.

## Toolchain requirements

Custom Dylint libraries use `#![feature(rustc_private)]`, so they require a nightly
Rust toolchain with the `rustc-dev` component available. `rules_rs` toolchains expose
that opt-in as `include_rustc_dev = True`:

```bzl
toolchains.toolchain(
    name = "nightly_rust_toolchains",
    edition = "2024",
    include_rustc_dev = True,
    version = "nightly/2026-03-05",
)
```

`rust_dylint` transitions only the checked lint subtree onto the nightly
channel automatically. Callers do not need to pass a nightly flag when invoking
the check target, and ordinary Rust targets can keep using the repository's
default toolchain selection.

Projects must also register a Dylint driver toolchain. The driver should be built with
the same nightly Rust toolchain family as the custom lint libraries it loads:

```bzl
load("@rules_rs//rs:dylint.bzl", "dylint_toolchain")

dylint_toolchain(
    name = "dylint_toolchain_impl",
    driver = ":dylint_driver",
)

toolchain(
    name = "dylint_toolchain",
    toolchain = ":dylint_toolchain_impl",
    toolchain_type = "@rules_rs//rs/dylint:toolchain_type",
)
```

Then register that toolchain from `MODULE.bazel`:

```bzl
register_toolchains(
    "@nightly_rust_toolchains//:all",
    "//path/to:dylint_toolchain",
)
```

If the repository already has a stable rustfmt / rust-analyzer toolchain, the
nightly Dylint toolchain can reuse those versions; Dylint needs nightly `rustc`
plus `rustc-dev`, not a second copy of unrelated editor tools.

## Example

```bzl
load("@rules_rs//rs:dylint.bzl", "dylint_config", "dylint_library", "rust_dylint")
load("@rules_rs//rs:rust_library.bzl", "rust_library")
load("@rules_rs//rs:rust_shared_library.bzl", "rust_shared_library")

rust_shared_library(
    name = "project_policy_impl",
    srcs = ["project_policy.rs"],
    crate_name = "project_policy",
    edition = "2024",
    deps = ["@crates//:dylint_linting"],
)

dylint_library(
    name = "project_policy",
    library = ":project_policy_impl",
)

dylint_config(
    name = "project_lints",
    libraries = [":project_policy"],
)

rust_library(
    name = "api",
    srcs = ["api.rs"],
    lint_config = ":project_lints",
)

rust_dylint(
    name = "api_dylint",
    deps = [":api"],
)
```

If another target should use a different lint bundle, define another `dylint_config`
and assign that config to the other target's `lint_config` attribute. No
workspace-global Dylint metadata is required. Add `config = "dylint.toml"` to a
`dylint_config` when a library needs target-local settings; if it is omitted, the
runner supplies an empty config rather than discovering one from Cargo metadata.

## Design decisions and future extension points

- The API uses an aspect, but the aspect reads each target's own
  `lint_config`; there is no repository-global Dylint selection.
- Lint libraries are compiled in the exec configuration because the driver loads them
  on the host where the action runs, even when the checked crate itself targets another
  platform.
- The driver is supplied by a dedicated Dylint toolchain. That keeps the Dylint
  version an intentional project choice while keeping library selection local to each
  Rust target.

## Verification strategy

- Unit-level confidence comes from preserving the existing `LintsInfo` pathway and
  exercising the normal `rs/private` test suite.
- Integration-level confidence comes from `test/dylint`, where:
  - `:alpha_component` and `:beta_component` compile the same source,
  - each target selects a different Dylint library through `lint_config`,
  - the shell test asserts that each captured output contains its own warning and
    omits the other target's warning,
  - one config uses an explicit TOML file and the other relies on the empty-config
    fallback, covering both configuration paths without global workspace state.

## References

- Dylint README: <https://github.com/trailofbits/dylint>
- Dylint execution model: <https://github.com/trailofbits/dylint/blob/master/docs/how_dylint_works.md>
