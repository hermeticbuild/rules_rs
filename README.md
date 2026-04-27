## Overview

`rules_rs` is a Rust + Bazel ruleset built on top of [rules_rust](https://github.com/bazelbuild/rules_rust).
It provides a redistribution of the core compilation rules from `rules_rust`, augmenting them with optimized toolchains, crates.from_cargo integration, and other codepaths.

## Why `rules_rs`

- Fast incremental dependency resolution via Bazel downloader integration and lockfile facts. It uses your Cargo lockfile directly, with no Cargo workspace splicing and no Bazel-specific Cargo lockfile.
- Hermetic Rust toolchains covering a wide target matrix, including Linux GNU/musl and Windows MSVC/GNU/GNULVM ABI variants.
- Cross builds from any supported host to any supported target through the `@llvm` toolchain, including remote execution use cases.
- A patched `rules_rust` repository with compatibility fixes for Windows linking, rust-analyzer integration, and related workflows.

# Installation And Configuration

Add `rules_rs` to `MODULE.bazel`:

```bzl
bazel_dep(name = "rules_rs", version = "0.0.33")
```

## Paved Path

This is the default setup for new users. It provisions the patched `rules_rust`, registers `rules_rs` Rust toolchains, sets explicit host platforms, and resolves Cargo dependencies against `rules_rs` platforms.

### `MODULE.bazel`

```bzl
bazel_dep(name = "rules_rs", version = "0.0.61")
bazel_dep(name = "llvm", version = "0.7.3")
bazel_dep(name = "platforms", version = "1.0.0")

toolchains = use_extension("@rules_rs//rs/toolchains:module_extension.bzl", "toolchains")
toolchains.toolchain(
    edition = "2024",
    version = "1.92.0",
)
use_repo(toolchains, "default_rust_toolchains")

# This extension is optional but can help keep existing `@rules_rust` references working.
rules_rust = use_extension("@rules_rs//rs:rules_rust.bzl", "rules_rust")
use_repo(rules_rust, "rules_rust")

register_toolchains(
    "@default_rust_toolchains//:all",
    "@llvm//toolchain:all",
)

crate = use_extension("@rules_rs//rs:extensions.bzl", "crate")
crate.from_cargo(
    name = "crates",
    cargo_lock = "//:Cargo.lock",
    cargo_toml = "//:Cargo.toml",
    platform_triples = [
        "aarch64-apple-darwin",
        "aarch64-pc-windows-msvc",
        "aarch64-unknown-linux-gnu",
        "x86_64-apple-darwin",
        "x86_64-pc-windows-msvc",
        "x86_64-unknown-linux-gnu",
    ],
)
use_repo(crate, "crates")
```

`platform_triples` should include every exec and target triple that can participate in the build. For the common case, include the host triples you use locally and in CI plus the target triples you build for.

### `.bazelrc`

Set an explicit host platform for operating systems with ABI choices. Linux and Windows host platforms need an ABI constraint so Rust toolchain resolution can choose the matching exec toolchain.

```bazelrc
common --enable_platform_specific_config
common:linux --host_platform=//platforms:local_gnu
common:windows --host_platform=//platforms:local_windows_msvc
```

### `platforms/BUILD.bazel`

```bzl
platform(
    name = "local_gnu",
    parents = ["@platforms//host"],
    constraint_values = [
        "@llvm//constraints/libc:gnu.2.28",
    ],
)

platform(
    name = "local_windows_msvc",
    parents = ["@platforms//host"],
    constraint_values = [
        "@rules_rs//rs/platforms/constraints:windows_msvc",
    ],
)
```

macOS does not need an additional ABI constraint for the default host case.

### `BUILD.bazel`

Prefer the `rules_rs` wrappers for Rust targets:

```bzl
load("@crates//:defs.bzl", "aliases", "all_crate_deps")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")
load("@rules_rs//rs:rust_library.bzl", "rust_library")

rust_library(
    name = "lib",
    srcs = ["src/lib.rs"],
    aliases = aliases(),
    deps = all_crate_deps(normal = True),
)

rust_binary(
    name = "app",
    srcs = ["src/main.rs"],
    deps = [":lib"],
)
```

## rust-analyzer

The rust-analyzer generator can be invoked like so:

```bash
bazel run @rules_rs//tools/rust_analyzer:gen_rust_project -- --help
```

See the upstream `rules_rust` rust-analyzer docs for editor setup details:
https://bazelbuild.github.io/rules_rust/rust_analyzer.html#vscode

## Advanced Options

<details>
<summary>Use legacy rules_rust toolchains or platforms</summary>

You can keep an existing `rules_rust` toolchain setup during migration. In that mode, configure toolchains from `@rules_rust` and tell `crate.from_cargo(...)` to render selects against legacy `rules_rust` platform labels.

```bzl
rules_rust = use_extension("@rules_rs//rs:rules_rust.bzl", "rules_rust")
use_repo(rules_rust, "rules_rust")

rust = use_extension("@rules_rust//rust:extensions.bzl", "rust")
rust.toolchain(
    edition = "2024",
    versions = ["1.92.0"],
)

use_repo(rust, "rust_toolchains")
register_toolchains("@rust_toolchains//:all")

crate = use_extension("@rules_rs//rs:extensions.bzl", "crate")
crate.from_cargo(
    name = "crates",
    cargo_lock = "//:Cargo.lock",
    cargo_toml = "//:Cargo.toml",
    platform_triples = [
        "x86_64-unknown-linux-gnu",
    ],
    use_legacy_rules_rust_platforms = True,
)
use_repo(crate, "crates")
```

</details>

<details>
<summary>Cross ABI target details</summary>

Proc macros and build scripts run in the exec configuration, while your library or binary may be built for a different target ABI. Include both exec and target triples when they differ.

Windows GNULVM target with MSVC exec:

```bzl
platform_triples = [
    "x86_64-pc-windows-msvc",     # exec
    "x86_64-pc-windows-gnullvm",  # target
]
```

Linux musl target with GNU exec:

```bzl
platform_triples = [
    "x86_64-unknown-linux-gnu",   # exec
    "x86_64-unknown-linux-musl",  # target
]
```

The default Windows exec toolchain is MSVC-flavored. The upstream GNULVM toolchain dynamically links `libunwind`, which may not exist on a stock Windows machine.

The Linux exec toolchains are GNU-flavored. When targeting musl, also include the corresponding GNU triple for build scripts and proc macros.

</details>

<details>
<summary>Remote execution platforms</summary>

Remote execution platforms can inherit from a triple-based platform published by `rules_rs`, then add execution properties:

```bzl
platform(
    name = "rbe_linux_amd64_gnu",
    parents = ["@rules_rs//rs/platforms:x86_64-unknown-linux-gnu"],
    exec_properties = {
        "container-image": "docker://ghcr.io/example/rbe-linux-gnu:latest",
    },
)
```

Keep host ABI constraints aligned with your exec toolchain choice. Model target ABI differences with target platforms and `platform_triples`.

</details>

<details>
<summary>Patch or override rules_rust</summary>

`rules_rs` exports a `rules_rust` module extension that provisions the pinned, patched `rules_rust` repository:

```bzl
rules_rust = use_extension("@rules_rs//rs:rules_rust.bzl", "rules_rust")

rules_rust.patch(
    patches = ["//:my_rules_rust_fix.patch"],
    strip = 1,
)

use_repo(rules_rust, "rules_rust")
```

If you need to replace the pinned repository completely, use `override_repo`:

```bzl
bazel_dep(name = "rules_rs", version = "0.0.33")
bazel_dep(name = "rules_rust", version = "0.68.1")

archive_override(
    module_name = "rules_rust",
    integrity = "sha256-...",
    strip_prefix = "rules_rust-<commit>",
    urls = ["https://github.com/my-org/rules_rust/archive/<commit>.tar.gz"],
)

rules_rust_ext = use_extension("@rules_rs//rs:rules_rust.bzl", "rules_rust")
override_repo(rules_rust_ext, rules_rust = "rules_rust")
```

Overriding with a version that does not include required patches from [hermeticbuild/rules_rust](https://github.com/hermeticbuild/rules_rust) may cause build failures.

</details>

<details>
<summary>Protobuf with rules_rust_prost</summary>

`rules_rs` exports a `rules_rust_prost` module extension for prost integration:

```bzl
bazel_dep(name = "rules_proto", version = "7.1.0")
bazel_dep(name = "protobuf", version = "34.0.bcr.1", repo_name = "com_google_protobuf")

rules_rust_prost = use_extension("@rules_rs//rs:rules_rust_prost.bzl", "rules_rust_prost")
use_repo(rules_rust_prost, "rules_rust_prost")

register_toolchains("@rules_rust_prost//:default_prost_toolchain")
register_toolchains("@//path/to/proto_toolchain")
```

The default prost toolchain and its Cargo dependencies are provided by `rules_rs`. If you need different prost, tonic, or plugin versions, define your own `rust_prost_toolchain` from `@rules_rust_prost//:defs.bzl`.

</details>

<details>
<summary>Dependency resolution caveats</summary>

`rules_rs` currently supports Cargo lockfile based resolution through `crate.from_cargo(...)`.
`crate.spec` and vendoring mode are not currently supported.

Cargo workspaces sometimes use a self-referencing dev-dependency to enable extra features for tests:

```toml
[dev-dependencies]
mycrate = { path = ".", features = ["test-utils"] }
```

`rules_rs` suppresses the generated self-edge in `aliases()` and `all_crate_deps()` so this pattern does not create a Bazel dependency cycle. The requested features are still part of workspace feature resolution, so they may be enabled on the first-party crate more broadly than Cargo would enable them for a single targeted test command.

If you need separate normal and test feature variants, model them as separate Bazel targets, with the test-only variant setting extra `crate_features` and `testonly = True`.

</details>

<details>
<summary>Migration from rules_rust loads</summary>

If you import `rules_rust` through the `rules_rs` extension, existing `load("@rules_rust//...")` statements can be kept during migration.

For long-term hygiene, prefer migrating common Rust rule loads to `@rules_rs//rs:*` wrappers. A helper script is provided:

```bash
./scripts/rewrite_rules_rust_loads.sh
```

The script rewrites common `@rules_rust` Rust loads to `@rules_rs//rs:*` wrappers and then formats with `buildifier`.

</details>

## Public API

See https://registry.bazel.build/docs/rules_rs

## Users

- [OpenAI Codex](https://github.com/openai/codex)
- [Aspect CLI](https://github.com/aspect-build/aspect-cli)
- [Astradot](https://astradot.com)
- [Datadog Agent](https://github.com/DataDog/datadog-agent)
- [ZML](https://github.com/zml/zml/tree/zml/v2)
- [rules_py](https://github.com/aspect-build/rules_py)
- [JetBrains](https://github.com/JetBrains/intellij-community), used in closed sources of [JetBrains Air](https://air.dev/)
- [Perplexity](https://perplexity.ai)
- [formatjs](https://github.com/formatjs/formatjs)

## Telemetry And Privacy Policy

This ruleset collects limited usage data via [`tools_telemetry`](https://github.com/aspect-build/tools_telemetry), which is reported to Aspect Build Inc and governed by their [privacy policy](https://www.aspect.build/privacy-policy).
