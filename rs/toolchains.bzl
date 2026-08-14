"""Public macros for declaring custom Rust compiler toolchains."""

load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES")
load("//rs/toolchains:declare_rustc_toolchains.bzl", "declare_rustc_toolchains")

def rust_toolchain(
        name,
        rustc,
        version,
        edition = "2021",
        exec_triples = None,
        target_triples = ALL_TARGET_TRIPLES,
        toolchains_repo = "@default_rust_toolchains",
        rust_doc = None,
        rustc_lib = None,
        cargo = None,
        clippy_driver = None,
        cargo_clippy = None,
        rust_objcopy = None,
        rust_lld = None,
        bpf_linker = None,
        rust_std = None,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        toolchain_attrs = {}):
    """Declares Rust toolchains using a custom compiler and existing components.

    Declare these targets in a dedicated BUILD package and register that package
    before the generated toolchain repository:

    ```starlark
    rust_toolchain(
        name = "custom_rust",
        rustc = "//tools/rust:rustc",
        version = "1.92.0",
        edition = "2024",
        exec_triples = ["x86_64-unknown-linux-gnu"],
    )
    ```

    Args:
      name: Prefix for every generated target and configuration setting.
      rustc: Compiler label or a dictionary mapping execution triples to labels.
      version: Version of the generated toolchain repository to reuse.
      edition: Default Rust edition for the custom toolchains.
      exec_triples: Execution triples to support. Defaults to `rustc` dictionary
        keys when `rustc` is a dictionary, otherwise all supported execution triples.
      target_triples: Target triples supported by the custom toolchains.
      toolchains_repo: Generated repository supplying default toolchain components.
      rust_doc: Optional rustdoc label or labels keyed by execution triple.
      rustc_lib: Optional compiler-library label or labels keyed by execution triple.
      cargo: Optional Cargo label or labels keyed by execution triple.
      clippy_driver: Optional clippy-driver label or labels keyed by execution triple.
      cargo_clippy: Optional cargo-clippy label or labels keyed by execution triple.
      rust_objcopy: Optional rust-objcopy label or labels keyed by execution triple.
      rust_lld: Optional rust-lld label or labels keyed by execution triple.
      bpf_linker: Optional bpf-linker label or labels keyed by execution triple.
      rust_std: Optional standard-library label or labels keyed by target triple.
      extra_rustc_flags: Additional compiler flags keyed by target triple.
      extra_exec_rustc_flags: Additional execution compiler flags keyed by triple.
      toolchain_attrs: Additional attributes passed to every upstream rust_toolchain.
    """
    if not name:
        fail("rust_toolchain requires a nonempty name")
    if rustc == None:
        fail("rust_toolchain requires a rustc label")
    if not version:
        fail("rust_toolchain requires a Rust version")
    if not toolchains_repo.startswith("@") or "//" in toolchains_repo:
        fail("toolchains_repo must be a repository name such as @default_rust_toolchains")

    if exec_triples == None:
        exec_triples = list(rustc.keys()) if type(rustc) == "dict" else SUPPORTED_EXEC_TRIPLES
    if not exec_triples:
        fail("rust_toolchain requires at least one execution triple")
    if not target_triples:
        fail("rust_toolchain requires at least one target triple")

    for exec_triple in exec_triples:
        if exec_triple not in SUPPORTED_EXEC_TRIPLES:
            fail("unsupported Rust execution triple: %s" % exec_triple)
        if type(rustc) == "dict" and exec_triple not in rustc:
            fail("rustc does not contain a compiler for execution triple %s" % exec_triple)

    for target_triple in target_triples:
        if target_triple not in ALL_TARGET_TRIPLES:
            fail("unsupported Rust target triple: %s" % target_triple)

    declare_rustc_toolchains(
        name = name,
        version = version,
        edition = edition,
        execs = exec_triples,
        targets = target_triples,
        toolchains_repo = toolchains_repo,
        rustc = rustc,
        rust_doc = rust_doc,
        rustc_lib = rustc_lib,
        cargo = cargo,
        clippy_driver = clippy_driver,
        cargo_clippy = cargo_clippy,
        rust_objcopy = rust_objcopy,
        rust_lld = rust_lld,
        bpf_linker = bpf_linker,
        rust_std = rust_std,
        extra_rustc_flags = extra_rustc_flags,
        extra_exec_rustc_flags = extra_exec_rustc_flags,
        toolchain_attrs = toolchain_attrs,
    )
