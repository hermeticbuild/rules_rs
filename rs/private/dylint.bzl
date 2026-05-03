"""Rules for running Bazel-native Dylint checks with target-local configs."""

load("@rules_rust//rust/private:common.bzl", "rust_common")
load("@rules_rust//rust/private:providers.bzl", "LintsInfo")
load(
    "@rules_rust//rust/private:rustc.bzl",
    "collect_deps",
    "collect_inputs",
    "construct_arguments",
    "get_error_format",
)
load(
    "@rules_rust//rust/private:utils.bzl",
    "determine_output_hash",
    "find_cc_toolchain",
    "find_toolchain",
)

DylintLibraryInfo = provider(
    doc = "A host-built dynamic library that can be loaded by dylint-driver.",
    fields = {
        "file": "File: The underlying host-built dynamic library.",
        "name": "String: Logical Dylint library name.",
    },
)

DylintConfigInfo = provider(
    doc = "Target-local Dylint selection and configuration.",
    fields = {
        "config_file": "Optional[File]: TOML file exposed to libraries as DYLINT_TOML.",
        "libraries": "List[DylintLibraryInfo]: Libraries to load for this config.",
        "rustc_flags": "List[String]: Extra rustc flags appended to the Dylint invocation.",
    },
)

DylintInfo = provider(
    doc = "Provides information on a Dylint run.",
    fields = {
        "output": "Depset[File]: Captured Dylint stderr output files.",
    },
)

def _dylint_transition_impl(_settings, _attr):
    # Dylint libraries and dylint-driver depend on `rustc_private`, and the
    # checked target graph must be compiled by the same nightly toolchain so
    # its dependency metadata stays compatible with the compiler that runs the
    # lints. Transition only the explicit Dylint subtree; ordinary Rust builds
    # keep using the caller's regular toolchain selection.
    return {
        "@rules_rust//rust/toolchain/channel:channel": "nightly",
        "@rules_rs//rs/toolchains/family:family": _attr.toolchain_family,
    }

_dylint_transition = transition(
    implementation = _dylint_transition_impl,
    inputs = [],
    outputs = [
        "@rules_rust//rust/toolchain/channel:channel",
        "@rules_rs//rs/toolchains/family:family",
    ],
)

def _empty_lints_info():
    return LintsInfo(
        rustc_lint_flags = [],
        rustc_lint_files = [],
        clippy_lint_flags = [],
        clippy_lint_files = [],
        rustdoc_lint_flags = [],
        rustdoc_lint_files = [],
    )

def _single_dynamic_library(files, label):
    files = files.to_list()
    if len(files) != 1:
        fail("Expected {} to provide exactly one dynamic library file, got {}".format(label, files))
    return files[0]

def _dylint_library_impl(ctx):
    return [
        DylintLibraryInfo(
            file = _single_dynamic_library(ctx.attr.library[DefaultInfo].files, ctx.attr.library.label),
            name = ctx.attr.library_name or ctx.label.name,
        ),
    ]

dylint_library = rule(
    implementation = _dylint_library_impl,
    attrs = {
        "library": attr.label(
            doc = "Shared library target containing the custom Dylint lints.",
            cfg = "exec",
            mandatory = True,
        ),
        "library_name": attr.string(
            doc = "Logical Dylint library name. Defaults to this rule's name.",
        ),
    },
    doc = """\
Wraps a host-built shared library so it can be loaded by `rust_dylint`.

The wrapped `library` is built in the exec configuration because Dylint loads it into
the host-side compiler driver while the lint action runs.
""",
)

def _dylint_config_impl(ctx):
    libraries = []
    seen = {}
    for library in ctx.attr.libraries:
        info = library[DylintLibraryInfo]
        if info.name in seen:
            fail("Duplicate Dylint library name `{}` in {}".format(info.name, ctx.label))
        seen[info.name] = True
        libraries.append(info)

    base_lints = ctx.attr.lint_config[LintsInfo] if ctx.attr.lint_config else _empty_lints_info()

    return [
        base_lints,
        DylintConfigInfo(
            config_file = ctx.file.config,
            libraries = libraries,
            rustc_flags = ctx.attr.rustc_flags,
        ),
    ]

dylint_config = rule(
    implementation = _dylint_config_impl,
    attrs = {
        "config": attr.label(
            allow_single_file = True,
            doc = "Optional TOML file made available to configurable libraries via DYLINT_TOML.",
        ),
        "libraries": attr.label_list(
            doc = "Custom Dylint libraries loaded by checks using this config.",
            providers = [DylintLibraryInfo],
        ),
        "lint_config": attr.label(
            doc = "Optional ordinary Rust lint config to forward alongside the Dylint config.",
            providers = [LintsInfo],
        ),
        "rustc_flags": attr.string_list(
            doc = "Extra rustc flags appended after the target's ordinary lint configuration.",
        ),
    },
    doc = """\
Defines one reusable, target-local Dylint configuration bundle.

This rule also forwards an ordinary `LintsInfo` provider, so it can be assigned
directly to a Rust target's existing `lint_config` attribute.
""",
)

def _dylint_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            driver = ctx.executable.driver,
            driver_files_to_run = ctx.attr.driver[DefaultInfo].files_to_run,
        ),
    ]

_dylint_toolchain = rule(
    implementation = _dylint_toolchain_impl,
    attrs = {
        "driver": attr.label(
            cfg = "exec",
            doc = "Host-built dylint-driver executable matching the selected nightly Rust toolchain.",
            executable = True,
            mandatory = True,
        ),
    },
    doc = "Defines the host-side dylint-driver executable used by `rust_dylint`.",
)

def dylint_toolchain(
        name,
        *,
        driver,
        toolchain_family,
        exec_compatible_with = [],
        target_compatible_with = [],
        visibility = None,
        tags = []):
    """Declares one Dylint driver toolchain bound to a Rust toolchain family.

    `toolchain_family` must match the `name` of the `toolchains.toolchain(...)`
    tag that provisions the nightly Rust toolchains this driver was built with.
    """

    if not toolchain_family:
        fail("`toolchain_family` must name the nightly rules_rs toolchain family used by this Dylint driver")

    impl_name = name + "_impl"
    family_setting_name = name + "_family"

    _dylint_toolchain(
        name = impl_name,
        driver = driver,
        tags = tags,
        visibility = ["//visibility:private"],
    )

    native.config_setting(
        name = family_setting_name,
        flag_values = {
            "@rules_rs//rs/toolchains/family:family": toolchain_family,
        },
        visibility = ["//visibility:private"],
    )

    toolchain_kwargs = dict(
        name = name,
        exec_compatible_with = exec_compatible_with,
        target_compatible_with = target_compatible_with,
        target_settings = [":" + family_setting_name],
        toolchain = ":" + impl_name,
        toolchain_type = "@rules_rs//rs/dylint:toolchain_type",
        tags = tags,
    )
    if visibility != None:
        toolchain_kwargs["visibility"] = visibility

    native.toolchain(**toolchain_kwargs)

def _crate_info(target):
    if rust_common.crate_info in target:
        return target[rust_common.crate_info]
    if rust_common.test_crate_info in target:
        return target[rust_common.test_crate_info].crate
    return None

def _dylint_config_from_target(ctx):
    if not hasattr(ctx.rule.attr, "lint_config") or not ctx.rule.attr.lint_config:
        return None
    lint_config = ctx.rule.attr.lint_config
    return lint_config[DylintConfigInfo] if DylintConfigInfo in lint_config else None

def _toolchain_id(toolchain):
    return "{}-{}".format(toolchain.version.replace("/", "-"), toolchain.exec_triple.str)

def _library_filename(library_name, toolchain_id, original_file):
    # Rust shared libraries use a `lib` prefix on Unix and no prefix on Windows.
    prefix = "lib" if original_file.basename.startswith("lib") else ""
    extension = "." + original_file.extension if original_file.extension else ""
    return "{}{}@{}{}".format(
        prefix,
        library_name.replace("-", "_"),
        toolchain_id,
        extension,
    )

def _renamed_libraries(ctx, config, toolchain):
    renamed = []
    toolchain_id = _toolchain_id(toolchain)
    for library in sorted(config.libraries, key = lambda lib: lib.name):
        output = ctx.actions.declare_file(
            "{}/{}".format(
                ctx.label.name + "_dylint_libs",
                _library_filename(library.name, toolchain_id, library.file),
            ),
        )
        ctx.actions.symlink(
            output = output,
            target_file = library.file,
        )
        renamed.append(output)
    return renamed

def _rustc_lib_dirs(toolchain):
    dirs = {}
    for file in toolchain.rustc_lib.to_list():
        dirs[file.dirname] = True
    return sorted(dirs.keys())

def _rust_dylint_action(ctx, crate_info, config, renamed_libraries):
    toolchain = find_toolchain(ctx)
    dylint_toolchain = ctx.toolchains[str(Label("//rs/dylint:toolchain_type"))]
    cc_toolchain, feature_configuration = find_cc_toolchain(ctx)

    dep_info, build_info, _ = collect_deps(
        deps = crate_info.deps.to_list(),
        proc_macro_deps = crate_info.proc_macro_deps.to_list(),
        aliases = crate_info.aliases,
    )

    lint_files = []
    rustc_lint_flags = []
    if hasattr(ctx.rule.attr, "lint_config") and ctx.rule.attr.lint_config:
        lint_config = ctx.rule.attr.lint_config[LintsInfo]
        rustc_lint_flags = lint_config.rustc_lint_flags
        lint_files = lint_config.rustc_lint_files

    compile_inputs, out_dir, build_env_files, build_flags_files, linkstamp_outs, ambiguous_libs = collect_inputs(
        ctx,
        ctx.rule.file,
        ctx.rule.files,
        depset([]),
        toolchain,
        cc_toolchain,
        feature_configuration,
        crate_info,
        dep_info,
        build_info,
        lint_files,
    )

    args, env = construct_arguments(
        ctx = ctx,
        attr = ctx.rule.attr,
        file = ctx.rule.file,
        toolchain = toolchain,
        tool_path = ctx.executable._runner.path,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        crate_info = crate_info,
        dep_info = dep_info,
        linkstamp_outs = linkstamp_outs,
        ambiguous_libs = ambiguous_libs,
        output_hash = determine_output_hash(crate_info.root, ctx.label),
        rust_flags = [],
        out_dir = out_dir,
        build_env_files = build_env_files,
        build_flags_files = build_flags_files,
        emit = ["metadata"],
        skip_expanding_rustc_env = True,
        error_format = get_error_format(ctx.rule.attr, "_error_format"),
    )

    if crate_info.is_test:
        args.rustc_flags.add("--test")

    args.rustc_flags.add_all(rustc_lint_flags)
    args.rustc_flags.add_all(config.rustc_flags)

    output = ctx.actions.declare_file(ctx.label.name + ".dylint.out", sibling = crate_info.output)
    args.process_wrapper_flags.add("--stderr-file", output)

    env["RULES_RS_DYLINT_DRIVER"] = dylint_toolchain.driver.path
    env["RULES_RS_DYLINT_LIBS"] = json.encode([library.path for library in renamed_libraries])
    env["RULES_RS_DYLINT_RUSTC_LIB_DIRS"] = "\n".join(_rustc_lib_dirs(toolchain))
    if config.config_file:
        env["RULES_RS_DYLINT_TOML_PATH"] = config.config_file.path

    direct_inputs = renamed_libraries
    if config.config_file:
        direct_inputs.append(config.config_file)

    ctx.actions.run(
        executable = toolchain.process_wrapper,
        inputs = depset(direct_inputs, transitive = [compile_inputs, toolchain.rustc_lib]),
        outputs = [output],
        env = env,
        tools = [
            dylint_toolchain.driver_files_to_run,
            ctx.attr._runner[DefaultInfo].files_to_run,
        ],
        arguments = args.all,
        mnemonic = "Dylint",
        progress_message = "Dylint %{label}",
        toolchain = "@rules_rust//rust:toolchain_type",
    )

    return output

def _rust_dylint_aspect_impl(target, ctx):
    if OutputGroupInfo in target and hasattr(target[OutputGroupInfo], "dylint_checks"):
        return []

    crate_info = _crate_info(target)
    config = _dylint_config_from_target(ctx)
    if not crate_info or not config:
        return [DylintInfo(output = depset([]))]

    toolchain = find_toolchain(ctx)
    renamed_libraries = _renamed_libraries(ctx, config, toolchain)
    output = _rust_dylint_action(ctx, crate_info, config, renamed_libraries)

    return [
        OutputGroupInfo(dylint_checks = depset([output])),
        DylintInfo(output = depset([output])),
    ]

rust_dylint_aspect = aspect(
    attrs = {
        "_error_format": attr.label(
            doc = "The desired `--error-format` flags for rustc",
            default = Label("@rules_rust//rust/settings:error_format"),
        ),
        "_runner": attr.label(
            cfg = "exec",
            default = Label("//rs/private:dylint_runner"),
            executable = True,
        ),
    },
    fragments = ["cpp"],
    implementation = _rust_dylint_aspect_impl,
    provides = [DylintInfo],
    required_providers = [
        [rust_common.crate_info],
        [rust_common.test_crate_info],
    ],
    toolchains = [
        str(Label("@rules_rust//rust:toolchain_type")),
        str(Label("//rs/dylint:toolchain_type")),
        config_common.toolchain_type("@bazel_tools//tools/cpp:toolchain_type", mandatory = False),
    ],
)

def _rust_dylint_impl(ctx):
    dylint_ready_targets = [
        dep
        for dep in ctx.attr.deps
        if OutputGroupInfo in dep and hasattr(dep[OutputGroupInfo], "dylint_checks")
    ]
    files = depset([], transitive = [dep[OutputGroupInfo].dylint_checks for dep in dylint_ready_targets])
    return [DefaultInfo(files = files)]

rust_dylint = rule(
    implementation = _rust_dylint_impl,
    attrs = {
        "deps": attr.label_list(
            cfg = _dylint_transition,
            doc = "Rust targets to lint.",
            providers = [
                [rust_common.crate_info],
                [rust_common.test_crate_info],
            ],
            aspects = [rust_dylint_aspect],
        ),
        "toolchain_family": attr.string(
            doc = "Name of the nightly rules_rs toolchain family used for this Dylint check.",
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = """\
Runs Dylint against explicitly listed Rust targets.

Each target selects its own Dylint libraries through its ordinary `lint_config`
attribute by pointing at a `dylint_config` target.
""",
)
