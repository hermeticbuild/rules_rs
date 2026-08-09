"""Aspect recording everything needed to mutation-test a `rust_test` target.

Bazel cannot enumerate mutants during analysis (the count depends on file
contents), so this aspect records two things and leaves the N-mutant loop to
test time:

  1. `<name>.mutants.json` — `cargo-mutants --list --json` over a synthetic,
     dependency-free copy of the crate. Enumeration is all cargo-mutants is
     used for; Bazel keeps doing the building and testing.
  2. The exact `rustc --test` command line rules_rust itself would run, split
     into the same `Args` objects `rustc_compile` passes to `ctx.actions.run`.
     Replaying it verbatim is why the runner mirrors exec paths into runfiles.
"""

load("@bazel_skylib//lib:structs.bzl", "structs")
load("@rules_rust//rust/private:providers.bzl", "CrateInfo", "LintsInfo")
load("@rules_rust//rust/private:rust.bzl", "get_rust_test_flags")
load(
    "@rules_rust//rust/private:rustc.bzl",
    "collect_deps",
    "collect_inputs",
    "construct_arguments",
    "get_cc_toolchain_runtime_libs",
    "resolve_cc_runtime_linkage",
)
load("@rules_rust//rust/private:utils.bzl", "find_cc_toolchain")
load(":providers.bzl", "CargoMutantsInfo")

RUST_TOOLCHAIN_TYPE = "@rules_rust//rust:toolchain_type"
CPP_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"

def _enumerate(ctx, crate, toolchain):
    """Emits the action producing `cargo-mutants --list --json` output."""
    if not toolchain.cargo:
        fail("cargo_mutants needs a Rust toolchain that provides cargo")

    output = ctx.actions.declare_file(ctx.label.name + ".mutants.json")
    args = ctx.actions.args()
    args.add("--cargo-mutants", ctx.executable._cargo_mutants)
    args.add("--cargo", toolchain.cargo)
    args.add("--crate-name", crate.name)
    args.add("--edition", crate.edition)
    args.add("--crate-root", crate.root)
    args.add("--output", output)
    args.add_all(crate.srcs, before_each = "--src")

    ctx.actions.run(
        executable = ctx.executable._lister,
        arguments = [args],
        inputs = depset([toolchain.cargo], transitive = [crate.srcs]),
        tools = [ctx.executable._cargo_mutants],
        outputs = [output],
        mnemonic = "CargoMutantsList",
        progress_message = "Enumerating mutants for %{label}",
    )
    return output

def _replayable_crate_info(crate):
    """Drops the diagnostic side outputs; the replay must only write to scratch."""
    fields = structs.to_dict(crate)
    fields.update({
        "metadata": None,
        "metadata_supports_pipelining": False,
        "rustc_output": None,
        "rustc_rmeta_output": None,
    })
    return CrateInfo(**fields)

def _record_rustc(ctx, crate, toolchain):
    """Rebuilds the rustc invocation rules_rust uses for this test target."""
    attr = ctx.rule.attr
    dep_info, build_info, linkstamps = collect_deps(
        deps = crate.deps.to_list(),
        proc_macro_deps = crate.proc_macro_deps.to_list(),
        aliases = crate.aliases,
    )
    cc_toolchain, feature_configuration = find_cc_toolchain(ctx)
    runtime_libs = get_cc_toolchain_runtime_libs(
        cc_toolchain,
        feature_configuration,
        crate.type,
        resolve_cc_runtime_linkage(ctx),
    )

    # `--test` comes from here, not from crate.is_test.
    rust_flags = get_rust_test_flags(attr)
    lint_files = []
    if getattr(attr, "lint_config", None):
        rust_flags = rust_flags + attr.lint_config[LintsInfo].rustc_lint_flags
        lint_files = attr.lint_config[LintsInfo].rustc_lint_files

    compile_inputs, out_dir, build_env_files, build_flags_files, linkstamp_outs, ambiguous_libs = collect_inputs(
        ctx = ctx,
        file = ctx.rule.file,
        files = ctx.rule.files,
        linkstamps = linkstamps,
        toolchain = toolchain,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        crate_info = crate,
        dep_info = dep_info,
        build_info = build_info,
        lint_files = lint_files,
        runtime_libs = runtime_libs,
    )

    args, env = construct_arguments(
        ctx = ctx,
        attr = attr,
        file = ctx.rule.file,
        toolchain = toolchain,
        tool_file = toolchain.rustc,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        crate_info = crate,
        dep_info = dep_info,
        linkstamp_outs = linkstamp_outs,
        ambiguous_libs = ambiguous_libs,
        output_hash = None,
        rust_flags = rust_flags,
        out_dir = out_dir,
        build_env_files = build_env_files,
        build_flags_files = build_flags_files,
        emit = ["link"],
        add_flags_for_binary = True,
        runtime_libs = runtime_libs,
        # rustc_env is already expanded by the rule; re-expanding chokes on the
        # `${pwd}` placeholders process_wrapper resolves at execution time.
        skip_expanding_rustc_env = True,
    )
    return args, env, compile_inputs

def _write_args(ctx, index, arg, needs_format):
    out = ctx.actions.declare_file("{}.mutants.rustc{}.args".format(ctx.label.name, index))
    if needs_format:
        arg.set_param_file_format("multiline")
    ctx.actions.write(out, arg)
    return out

def _write_env(ctx, env):
    out = ctx.actions.declare_file(ctx.label.name + ".mutants.env")
    ctx.actions.write(out, "".join(["{}={}\n".format(key, env[key]) for key in sorted(env)]))
    return out

def _write_manifest(ctx, crate, toolchain, mutants_json, args_files, env_file):
    out = ctx.actions.declare_file(ctx.label.name + ".mutants.manifest")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add("--process-wrapper", toolchain.process_wrapper)
    args.add("--mutants", mutants_json)
    args.add_all(args_files, before_each = "--rustc-args")
    args.add("--env", env_file)
    args.add("--crate-root", crate.root)
    args.add("--output", crate.output)
    args.add_all(crate.srcs, before_each = "--src")
    args.add_all(crate.compile_data, before_each = "--compile-data")
    args.add_all(
        [ctx.expand_location(arg, targets = getattr(ctx.rule.attr, "data", [])) for arg in getattr(ctx.rule.attr, "args", [])],
        before_each = "--test-arg",
    )
    ctx.actions.write(out, args)
    return out

def _cargo_mutants_aspect_impl(target, ctx):
    if CrateInfo not in target:
        return []
    crate = target[CrateInfo]
    if not crate.is_test:
        return []

    toolchain = ctx.toolchains[RUST_TOOLCHAIN_TYPE]
    mutants_json = _enumerate(ctx, crate, toolchain)
    args, env, compile_inputs = _record_rustc(ctx, _replayable_crate_info(crate), toolchain)

    # construct_arguments already formats rustc_flags; setting it twice fails.
    args_files = [
        _write_args(ctx, index, arg, arg != args.rustc_flags)
        for index, arg in enumerate(args.all)
    ]
    env_file = _write_env(ctx, env)
    manifest = _write_manifest(ctx, crate, toolchain, mutants_json, args_files, env_file)

    return [
        CargoMutantsInfo(
            mutants_json = mutants_json,
            manifest = manifest,
            inputs = depset(
                [mutants_json, manifest, env_file, toolchain.process_wrapper] + args_files,
                transitive = [compile_inputs, crate.srcs, crate.compile_data],
            ),
        ),
        OutputGroupInfo(cargo_mutants = depset([mutants_json])),
    ]

cargo_mutants_aspect = aspect(
    implementation = _cargo_mutants_aspect_impl,
    doc = "Records mutation-testing inputs for every `rust_test` target it visits.",
    attr_aspects = [],
    fragments = ["cpp"],
    attrs = {
        "_cargo_mutants": attr.label(
            default = Label("//rs/experimental/mutants:cargo_mutants_binary"),
            executable = True,
            cfg = "exec",
        ),
        "_lister": attr.label(
            default = Label("//rs/experimental/mutants/private:mutants_list"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [RUST_TOOLCHAIN_TYPE, CPP_TOOLCHAIN_TYPE],
)
