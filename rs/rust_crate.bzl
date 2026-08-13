"""Cargo-style first-party Rust libraries, binaries, and test suites."""

load(":cargo_build_script.bzl", "cargo_build_script")
load(":rust_binary.bzl", "rust_binary")
load(":rust_library.bzl", "rust_library")
load(":rust_proc_macro.bzl", "rust_proc_macro")
load(":rust_test.bzl", "rust_integration_test_suite", "rust_unit_test_suite")

def _discover_binaries(name, binaries):
    """Returns Cargo-conventional binary names and their crate roots."""
    discovered = {}

    if native.glob(["src/main.rs"], allow_empty = True):
        discovered[name] = "src/main.rs"

    for crate_root in native.glob(["src/bin/*.rs"], allow_empty = True):
        binary_name = crate_root.removeprefix("src/bin/").removesuffix(".rs")
        discovered[binary_name] = crate_root

    for crate_root in native.glob(["src/bin/*/main.rs"], allow_empty = True):
        binary_name = crate_root.removeprefix("src/bin/").removesuffix("/main.rs")
        if binary_name in discovered:
            fail("binary '{}' has both '{}' and '{}'".format(
                binary_name,
                discovered[binary_name],
                crate_root,
            ))
        discovered[binary_name] = crate_root

    discovered.update(binaries)
    return discovered

def _build_script_root(build_script):
    """Returns the selected Cargo build script, or None when disabled."""
    if build_script == False:
        return None

    if type(build_script) == "string":
        return build_script

    detected = native.glob(["build.rs"], allow_empty = True)
    if detected:
        return detected[0]

    if build_script == True:
        fail("build_script = True requires build.rs")

    if build_script != None:
        fail("build_script must be None, a boolean, or a build-script filename")

    return None

def _binary_alias(name, binary_labels, visibility, tags, target_compatible_with):
    """Makes a binary-only package addressable through its package target."""
    if name in binary_labels:
        actual = binary_labels[name]
    elif len(binary_labels) == 1:
        actual = binary_labels.values()[0]
    else:
        return

    native.alias(
        name = name,
        actual = actual,
        visibility = visibility,
        tags = tags,
        target_compatible_with = target_compatible_with,
    )

def rust_crate(
        name,
        crate_name = None,
        srcs = None,
        crate_root = None,
        binaries = {},
        deps = [],
        dev_deps = [],
        integration_deps = None,
        build_deps = [],
        aliases = {},
        edition = None,
        version = None,
        crate_features = [],
        proc_macro = False,
        build_script = None,
        build_script_data = [],
        compile_data = [],
        data = [],
        test_data = [],
        rustc_env = {},
        rustc_flags = [],
        tags = [],
        test_tags = [],
        visibility = None,
        target_compatible_with = None,
        test_args = None,
        test_timeout = None,
        unit_test_args = None,
        integration_test_args = None):
    """Creates Cargo-conventional library, binary, and Rust test targets.

    A library is generated for ``src/lib.rs`` or an explicit ``crate_root``.
    Binaries are discovered from ``src/main.rs``, ``src/bin/*.rs``, and
    ``src/bin/*/main.rs``. Explicit ``binaries`` supplement discovered binaries
    and replace discovered roots with the same binary name. Integration tests
    are discovered from ``tests/*.rs`` and ``tests/*/main.rs``.

    Args:
        name: Library target name and default Cargo binary name.
        crate_name: Rust library crate name; defaults to ``name`` normalized
            by replacing hyphens with underscores.
        srcs: Optional explicit Rust sources for library and binary targets.
        crate_root: Optional library crate root replacing ``src/lib.rs``.
        binaries: Mapping from additional Cargo binary names to crate roots.
        deps: Normal dependencies of the library and binary targets.
        dev_deps: Additional dependencies of library, binary, and integration
            test targets.
        integration_deps: Optional combined normal and development
            dependencies for integration tests. Use this when dependency
            categories overlap or contain platform-dependent selections.
        build_deps: Dependencies used to compile ``build.rs``.
        aliases: Rust dependency aliases forwarded to generated targets.
        edition: Rust edition forwarded to generated targets.
        version: Optional Cargo package version forwarded to generated targets.
        crate_features: Cargo features forwarded to generated targets.
        proc_macro: Whether the library is a Rust procedural macro.
        build_script: None discovers ``build.rs``; False disables build-script
            generation; True requires ``build.rs``; a string identifies a
            custom build-script filename.
        build_script_data: Runtime data required by the build script.
        compile_data: Compile-time data required by generated Rust targets.
        data: Runtime data required by generated library and binary targets.
        test_data: Additional runtime data required by generated tests.
        rustc_env: Rust compiler environment variables.
        rustc_flags: Rust compiler arguments.
        tags: Tags applied to all generated targets.
        test_tags: Additional tags applied to generated test targets.
        visibility: Visibility applied to generated targets and test suites.
        target_compatible_with: Target compatibility constraints.
        test_args: Default command-line arguments for generated tests.
        test_timeout: Timeout applied to generated tests.
        unit_test_args: Unit-test arguments replacing ``test_args``.
        integration_test_args: Integration-test arguments replacing
            ``test_args``.
    """
    binary_roots = _discover_binaries(name, binaries)
    library_root = crate_root
    if library_root == None:
        detected_library = native.glob(["src/lib.rs"], allow_empty = True)
        if detected_library:
            library_root = detected_library[0]

    if library_root == None and not binary_roots:
        fail("rust_crate '{}' requires a library crate root or at least one binary".format(name))

    discovered_srcs = native.glob(["src/**/*.rs"], allow_empty = True)
    library_srcs = srcs
    if library_srcs == None:
        library_srcs = [src for src in discovered_srcs if src not in binary_roots.values()]
        if library_root != None and library_root not in library_srcs:
            library_srcs.append(library_root)

    binary_srcs = srcs if srcs != None else discovered_srcs
    resolved_crate_name = crate_name if crate_name != None else name.replace("-", "_")
    rustc_env = {"CARGO_PKG_NAME": name} | rustc_env
    build_script_root = _build_script_root(build_script)
    build_script_deps = []

    if build_script_root != None:
        build_script_name = name + "_build_script"
        build_script_srcs = native.glob(["**/*.rs"], allow_empty = True)
        if build_script_root not in build_script_srcs:
            build_script_srcs.append(build_script_root)
        cargo_build_script(
            name = build_script_name,
            crate_name = "build_script_build",
            crate_root = build_script_root,
            srcs = build_script_srcs,
            aliases = aliases,
            crate_features = crate_features,
            compile_data = compile_data,
            data = build_script_data,
            deps = build_deps,
            edition = edition,
            link_deps = deps,
            pkg_name = name,
            rustc_env = rustc_env,
            rustc_flags = rustc_flags,
            tags = tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = visibility,
        )
        build_script_deps = [":" + build_script_name]

    library_deps = deps + build_script_deps
    library_labels = []
    if library_root != None:
        library_rule = rust_proc_macro if proc_macro else rust_library
        library_rule(
            name = name,
            crate_name = resolved_crate_name,
            crate_root = library_root,
            srcs = library_srcs,
            aliases = aliases,
            crate_features = crate_features,
            compile_data = compile_data,
            data = data,
            deps = library_deps,
            edition = edition,
            rustc_env = rustc_env,
            rustc_flags = rustc_flags,
            tags = tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = visibility,
        )
        library_labels = [":" + name]

    binary_labels = {}
    for binary_name, binary_root in binary_roots.items():
        binary_target = binary_name + "__bin"
        binary_labels[binary_name] = ":" + binary_target

        resolved_binary_srcs = binary_srcs
        if srcs == None and binary_root not in resolved_binary_srcs:
            resolved_binary_srcs = resolved_binary_srcs + [binary_root]

        rust_binary(
            name = binary_target,
            binary_name = binary_name,
            crate_name = binary_name.replace("-", "_"),
            crate_root = binary_root,
            srcs = resolved_binary_srcs,
            aliases = aliases,
            crate_features = crate_features,
            compile_data = compile_data,
            data = data,
            deps = library_deps + library_labels,
            edition = edition,
            rustc_env = rustc_env,
            rustc_flags = rustc_flags,
            tags = tags,
            target_compatible_with = target_compatible_with,
            version = version,
            visibility = visibility,
        )

    if library_root == None:
        _binary_alias(name, binary_labels, visibility, tags, target_compatible_with)

    unit_test_kwargs = {
        "aliases": aliases,
        "crate_features": crate_features,
        "compile_data": compile_data,
        "data": data + test_data,
        "rustc_env": rustc_env,
        "rustc_flags": rustc_flags,
        "target_compatible_with": target_compatible_with,
        "version": version,
    }
    if test_timeout != None:
        unit_test_kwargs["timeout"] = test_timeout

    resolved_unit_test_args = unit_test_args if unit_test_args != None else test_args
    if resolved_unit_test_args != None:
        unit_test_kwargs["args"] = resolved_unit_test_args

    rust_unit_test_suite(
        name = name + "_unit_tests",
        crates = library_labels + binary_labels.values(),
        deps = dev_deps,
        tags = tags + test_tags,
        visibility = visibility,
        **unit_test_kwargs
    )

    integration_roots = native.glob(
        ["tests/*.rs", "tests/*/main.rs"],
        allow_empty = True,
    )
    shared_test_srcs = native.glob(
        ["tests/**/*.rs"],
        exclude = integration_roots,
        allow_empty = True,
    )

    integration_test_kwargs = {
        "aliases": aliases,
        "crate_features": crate_features,
        "compile_data": compile_data,
        "edition": edition,
        "rustc_env": rustc_env,
        "rustc_flags": rustc_flags,
        "target_compatible_with": target_compatible_with,
        "version": version,
    }
    if test_timeout != None:
        integration_test_kwargs["timeout"] = test_timeout

    resolved_integration_test_args = integration_test_args if integration_test_args != None else test_args
    if resolved_integration_test_args != None:
        integration_test_kwargs["args"] = resolved_integration_test_args

    if integration_deps == None:
        if type(deps) == "list" and type(dev_deps) == "list":
            integration_deps = list({str(dep): dep for dep in deps + dev_deps}.values())
        else:
            integration_deps = deps + dev_deps

    rust_integration_test_suite(
        name = name + "_integration_tests",
        srcs = integration_roots,
        shared_srcs = shared_test_srcs,
        deps = integration_deps + build_script_deps + library_labels,
        binaries = binary_labels.values(),
        data = data + test_data,
        tags = tags + test_tags,
        visibility = visibility,
        **integration_test_kwargs
    )
