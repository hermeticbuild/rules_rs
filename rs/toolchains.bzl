"""Public macros for declaring Rust compiler toolchains."""

load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES")
load("//rs/toolchains:declare_rustc_toolchains.bzl", _declare_rustc_toolchains = "declare_rustc_toolchains")

# buildifier: disable=unnamed-macro
def declare_rustc_toolchains(
        *,
        version,
        edition = "2021",
        name = None,
        rustc = None,
        exec_triples = None,
        target_triples = ALL_TARGET_TRIPLES,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        rust_doc = None,
        rustc_lib = None,
        cargo = None,
        clippy_driver = None,
        cargo_clippy = None,
        rust_objcopy = None,
        rust_lld = None,
        bpf_linker = None,
        rust_std = None):
    """Declares generated or custom Rust compiler toolchains.

    Args:
      version: Rust compiler version.
      edition: Default Rust edition; defaults to 2021.
      name: Target-name prefix, required when supplying a custom compiler.
      rustc: Custom compiler label or labels keyed by execution triple.
      exec_triples: Supported execution triples; defaults to compiler dictionary
        keys or all supported execution triples.
      target_triples: Supported target triples; defaults to all supported triples.
      extra_rustc_flags: Additional compiler flags keyed by target triple.
      extra_exec_rustc_flags: Additional compiler flags keyed by execution triple.
      rust_doc: Optional rustdoc label or labels keyed by execution triple.
      rustc_lib: Optional compiler-library label or labels keyed by execution triple.
      cargo: Optional Cargo label or labels keyed by execution triple.
      clippy_driver: Optional clippy-driver label or labels keyed by execution triple.
      cargo_clippy: Optional cargo-clippy label or labels keyed by execution triple.
      rust_objcopy: Optional rust-objcopy label or labels keyed by execution triple.
      rust_lld: Optional rust-lld label or labels keyed by execution triple.
      bpf_linker: Optional bpf-linker label or labels keyed by execution triple.
      rust_std: Optional standard-library label or labels keyed by target triple.
    """
    if (name != None or rustc != None) and (not name or rustc == None):
        fail("custom Rust toolchains require a nonempty name and a rustc label")

    if not version:
        fail("declare_rustc_toolchains requires a Rust version")
    if exec_triples == None:
        exec_triples = list(rustc.keys()) if type(rustc) == "dict" else SUPPORTED_EXEC_TRIPLES
    if not exec_triples:
        fail("declare_rustc_toolchains requires at least one execution triple")
    if not target_triples:
        fail("declare_rustc_toolchains requires at least one target triple")

    for exec_triple in exec_triples:
        if exec_triple not in SUPPORTED_EXEC_TRIPLES:
            fail("unsupported Rust execution triple: %s" % exec_triple)
        if type(rustc) == "dict" and exec_triple not in rustc:
            fail("rustc does not contain a compiler for execution triple %s" % exec_triple)

    for target_triple in target_triples:
        if target_triple not in ALL_TARGET_TRIPLES:
            fail("unsupported Rust target triple: %s" % target_triple)

    _declare_rustc_toolchains(
        version = version,
        edition = edition,
        extra_rustc_flags = extra_rustc_flags,
        extra_exec_rustc_flags = extra_exec_rustc_flags,
        execs = exec_triples,
        targets = target_triples,
        name = name,
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
    )
