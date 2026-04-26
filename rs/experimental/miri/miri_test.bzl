"""Miri test rule."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//rs/experimental/miri/private:compile.bzl", "alias_for_dep", "miri_compile_aspect", "miri_extern_arg", "miri_process_wrapper_args", "miri_transitive_outputs")
load("//rs/experimental/miri/private:providers.bzl", "MiriCrateInfo")
load("//rs/experimental/miri/private:toolchain.bzl", "MIRI_TOOLCHAIN_TYPE")

def _default_crate_name(label):
    return label.name.replace("-", "_")

def _crate_root(ctx):
    if ctx.file.crate_root:
        return ctx.file.crate_root

    for src in ctx.files.srcs:
        if src.basename in ("main.rs", "lib.rs"):
            return src

    if len(ctx.files.srcs) == 1:
        return ctx.files.srcs[0]

    fail("miri_test requires crate_root when srcs does not contain main.rs or lib.rs")

def _extern_arg(dep):
    return ["--extern", "{}={}".format(dep.name, dep.output.short_path)]

def _dirname(file):
    return file.dirname

def _short_path_dirname(file):
    path = file.short_path
    idx = path.rfind("/")
    return path[:idx] if idx != -1 else "."

def _direct_deps(ctx):
    direct_deps = []
    for dep in ctx.attr.deps:
        if MiriCrateInfo not in dep:
            continue
        miri_dep = dep[MiriCrateInfo]
        compiled_crate = miri_dep.target
        direct_deps.append(struct(
            name = alias_for_dep(ctx.attr.aliases, dep, miri_dep.crate_info),
            output = compiled_crate.output,
            transitive_inputs = compiled_crate.transitive_inputs,
            transitive_outputs = compiled_crate.transitive_outputs,
        ))
    return direct_deps

def _declare_test_executable(ctx):
    name = ctx.label.name
    if ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        name += ".exe"
    return ctx.actions.declare_file(name)

def _miri_compile_args(ctx, toolchain, crate_root, crate_name, direct_deps):
    args = ctx.actions.args()
    args.add(crate_root)
    args.add_all([
        "--crate-name",
        crate_name,
        "--crate-type",
        "bin",
        "--edition",
        ctx.attr.edition,
        "--test",
        "--target",
        toolchain.target_triple,
        "--cfg=miri",
    ])
    args.add_all([toolchain.miri_sysroot], format_each = "--sysroot=%s", expand_directories = False)
    args.add_all(ctx.attr.rustc_flags)
    args.add_all(direct_deps, map_each = miri_extern_arg)
    args.add_all(
        miri_transitive_outputs(direct_deps),
        map_each = _dirname,
        format_each = "-Ldependency=%s",
        uniquify = True,
    )
    return args

def _emit_miri_check_action(ctx, toolchain, crate_root, crate_name, direct_deps):
    output = ctx.actions.declare_file(ctx.label.name + ".miri_check.rmeta")
    args = _miri_compile_args(ctx, toolchain, crate_root, crate_name, direct_deps)
    args.add(output, format = "--emit=metadata=%s")

    ctx.actions.run(
        executable = toolchain.process_wrapper,
        arguments = miri_process_wrapper_args(ctx, toolchain, [], args),
        env = ctx.attr.env | {
            "MIRI_BE_RUSTC": "target",
            "MIRI_SYSROOT": toolchain.miri_sysroot.path,
            "REPOSITORY_NAME": ctx.label.workspace_name,
        },
        inputs = depset(
            direct = ctx.files.srcs + ctx.files.data + [crate_root],
            transitive = [toolchain.all_files] + [dep.transitive_inputs for dep in direct_deps],
        ),
        outputs = [output],
        mnemonic = "MiriTestCheck",
        progress_message = "Compiling Miri test %{label}",
        toolchain = MIRI_TOOLCHAIN_TYPE,
    )
    return output

def _miri_runfiles(ctx, toolchain, crate_root, args_file, check_output, direct_deps):
    runfiles = ctx.runfiles(
        files = ctx.files.srcs + ctx.files.data + [crate_root, args_file, check_output, ctx.executable._runner],
        transitive_files = depset(transitive = [toolchain.all_files] + [dep.transitive_inputs for dep in direct_deps]),
    )
    return runfiles.merge_all(
        [ctx.attr._runner[DefaultInfo].default_runfiles] +
        [data[DefaultInfo].default_runfiles for data in ctx.attr.data if DefaultInfo in data],
    )

def _write_runner_args(ctx, toolchain, crate_root, crate_name, direct_deps):
    args_file = ctx.actions.declare_file(ctx.label.name + ".miri_runner_args")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add_all([
        toolchain.miri.short_path,
        "--sysroot",
        toolchain.miri_sysroot.short_path,
        crate_root.short_path,
        "--crate-name",
        crate_name,
        "--crate-type",
        "bin",
        "--edition",
        ctx.attr.edition,
        "--test",
        "--target",
        toolchain.target_triple,
        "--cfg=miri",
    ])
    args.add_all(direct_deps, map_each = _extern_arg)
    args.add_all(
        miri_transitive_outputs(direct_deps),
        map_each = _short_path_dirname,
        format_each = "-Ldependency=%s",
        uniquify = True,
    )
    args.add_all(ctx.attr.rustc_flags)
    args.add_all(ctx.attr.miri_flags)
    args.add("--")
    args.add_all(ctx.attr.args)
    ctx.actions.write(args_file, args)
    return args_file

def _launcher_args(ctx, args_file):
    embedded_args, transformed_args = launcher.args_from_entrypoint(ctx.executable._runner)
    embedded_args.append("@" + args_file.short_path)
    return embedded_args, transformed_args

def _miri_test_impl(ctx):
    toolchain = ctx.toolchains[MIRI_TOOLCHAIN_TYPE]
    crate_root = _crate_root(ctx)
    crate_name = ctx.attr.crate_name or _default_crate_name(ctx.label)
    direct_deps = _direct_deps(ctx)
    check_output = _emit_miri_check_action(ctx, toolchain, crate_root, crate_name, direct_deps)
    args_file = _write_runner_args(ctx, toolchain, crate_root, crate_name, direct_deps)

    executable = _declare_test_executable(ctx)
    embedded_args, transformed_args = _launcher_args(ctx, args_file)
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = executable,
    )

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable, check_output]),
            runfiles = _miri_runfiles(ctx, toolchain, crate_root, args_file, check_output, direct_deps),
        ),
        RunEnvironmentInfo(environment = ctx.attr.env),
    ]

miri_test = rule(
    implementation = _miri_test_impl,
    attrs = {
        "crate_name": attr.string(doc = "Rust crate name. Defaults to the target name with '-' replaced by '_'."),
        "crate_root": attr.label(allow_single_file = [".rs"]),
        "aliases": attr.label_keyed_string_dict(doc = "Remap direct dependencies to another extern crate name."),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(aspects = [miri_compile_aspect]),
        "edition": attr.string(default = "2021"),
        "env": attr.string_dict(doc = "Environment variables set while running Miri."),
        "miri_flags": attr.string_list(doc = "Extra flags passed to the Miri driver."),
        "rustc_flags": attr.string_list(doc = "Extra rustc-compatible flags passed to Miri."),
        "srcs": attr.label_list(allow_files = [".rs"], mandatory = True),
        "_runner": attr.label(
            default = Label("//rs/experimental/miri/private:miri_test_runner"),
            executable = True,
            cfg = "target",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
    toolchains = [
        MIRI_TOOLCHAIN_TYPE,
        launcher.finalizer_toolchain_type,
        launcher.template_toolchain_type,
    ],
)
