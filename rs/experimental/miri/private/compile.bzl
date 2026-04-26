"""Miri compile aspects."""

load("@bazel_skylib//lib:structs.bzl", "structs")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(
    "@rules_rust//rust:rust_common.bzl",
    "BuildInfo",
    "CrateGroupInfo",
    "CrateInfo",
    "DepInfo",
    "DepVariantInfo",
    "TestCrateInfo",
)
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("@rules_rust//rust/private:rustc.bzl", "rustc_compile")
load("@rules_rust//rust/private:utils.bzl", "determine_output_hash")
load("//rs/experimental/miri/private:providers.bzl", "MiriCrateInfo")
load("//rs/experimental/miri/private:toolchain.bzl", "MIRI_SYSROOT_TOOLCHAIN_TYPE", "MIRI_TOOLCHAIN_TYPE")

_CC_TOOLCHAIN_TYPE = "@bazel_tools//tools/cpp:toolchain_type"
_RUST_TOOLCHAIN_TYPE = "@rules_rust//rust:toolchain_type"

def _find_library_dir(rust_srcs):
    for src in rust_srcs:
        if src.path.endswith("/library/Cargo.toml"):
            return src.dirname
    fail("rust_srcs must contain library/Cargo.toml from the Rust source tree")

def _sanitize_for_rustc_metadata(value):
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    result = []
    for char in value.elems():
        result.append(char if char in allowed else "_")
    return "".join(result)

def _crate_provider(target):
    if CrateInfo in target:
        return target[CrateInfo]
    if TestCrateInfo in target:
        return target[TestCrateInfo].crate
    return None

def _rustc_files(target, crate):
    env_files = list(crate.rustc_env_files)
    flag_files = []
    if DepInfo not in target:
        return struct(env_files = env_files, flag_files = flag_files)

    dep_env = target[DepInfo].dep_env
    if dep_env:
        env_files.append(dep_env)

    for build_info in target[DepInfo].transitive_build_infos.to_list():
        if build_info.rustc_env:
            env_files.append(build_info.rustc_env)
        if build_info.flags:
            flag_files.append(build_info.flags)

    return struct(env_files = env_files, flag_files = flag_files)

def alias_for_dep(aliases, dep, dep_crate):
    for candidate in [
        dep,
        dep.label,
        dep_crate.owner,
    ]:
        if candidate in aliases:
            return aliases[candidate]
    return dep_crate.name

def _direct_crate_aliases(target):
    if DepInfo not in target:
        return {}

    aliases = {}
    for dep in target[DepInfo].direct_crates.to_list():
        aliases[dep.dep.owner] = dep.name
    return aliases

def _miri_direct_dep_infos(owner_crate, deps, aliases, direct_crate_aliases, use_host_outputs = False):
    resolved_aliases = dict(owner_crate.aliases)
    resolved_aliases.update(aliases)
    resolved_aliases.update(direct_crate_aliases)

    direct_deps = []
    for dep in deps:
        if MiriCrateInfo not in dep:
            continue
        miri_dep = dep[MiriCrateInfo]
        compiled_crate = miri_dep.host if use_host_outputs else miri_dep.target
        direct_deps.append(struct(
            name = alias_for_dep(resolved_aliases, dep, miri_dep.crate_info),
            output = compiled_crate.output,
            transitive_inputs = compiled_crate.transitive_inputs,
            transitive_outputs = compiled_crate.transitive_outputs,
        ))
    return direct_deps

def _miri_dep_variants(deps, use_host_outputs = False, proc_macro_only = False):
    variants = []
    for dep in deps:
        crate_info = None
        dep_info = None
        if MiriCrateInfo in dep:
            if proc_macro_only and dep[MiriCrateInfo].crate_info.type != "proc-macro":
                continue
            compiled_crate = dep[MiriCrateInfo].host if use_host_outputs else dep[MiriCrateInfo].target
            crate_info = compiled_crate.crate_info
            dep_info = compiled_crate.dep_info
        elif CrateInfo in dep:
            if proc_macro_only and dep[CrateInfo].type != "proc-macro":
                continue
            fail("{} does not provide MiriCrateInfo".format(dep.label))

        if crate_info or BuildInfo in dep or CcInfo in dep or CrateGroupInfo in dep:
            variants.append(DepVariantInfo(
                build_info = dep[BuildInfo] if BuildInfo in dep else None,
                cc_info = dep[CcInfo] if CcInfo in dep else None,
                crate_group_info = dep[CrateGroupInfo] if CrateGroupInfo in dep else None,
                crate_info = crate_info,
                dep_info = dep_info,
            ))
    return variants

def miri_transitive_outputs(direct_deps):
    return depset(transitive = [dep.transitive_outputs for dep in direct_deps])

def miri_extern_arg(dep):
    return ["--extern", "{}={}".format(dep.name, dep.output.path)]

def _dirname(file):
    return file.dirname

def miri_process_wrapper_args(ctx, toolchain, rustc_env_files, miri_args):
    process_wrapper_args = ctx.actions.args()
    process_wrapper_args.add_all(rustc_env_files, before_each = "--env-file")
    process_wrapper_args.add("--subst", "pwd=${pwd}")
    process_wrapper_args.add("--subst", "exec_root=${exec_root}")
    process_wrapper_args.add("--subst", "output_base=${output_base}")

    miri_path = ctx.actions.args()
    miri_path.add("--")
    miri_path.add(toolchain.miri)

    return [process_wrapper_args, miri_path, miri_args]

def _target_rlib_output(ctx, crate, prefix):
    metadata = _sanitize_for_rustc_metadata(str(ctx.label))
    return ctx.actions.declare_file("{}/{}/lib{}-{}.rlib".format(
        prefix,
        ctx.label.name,
        crate.name,
        metadata,
    ))

def _host_output(ctx, crate):
    if crate.type == "proc-macro":
        return ctx.actions.declare_file("miri_host/{}/{}".format(
            ctx.label.name,
            crate.output.basename,
        ))
    return _target_rlib_output(ctx, crate, "miri_host")

def _host_output_hash(ctx, crate):
    if crate.type == "proc-macro":
        return determine_output_hash(crate.root, ctx.label)
    return _sanitize_for_rustc_metadata(str(ctx.label))

def _emit_miri_rustc_action(
        *,
        ctx,
        crate,
        toolchain,
        direct_deps,
        output,
        rustc_env_files,
        rustc_flag_files,
        target_triple,
        sysroot,
        env,
        mnemonic,
        progress_message,
        cfg_miri = False):
    metadata = _sanitize_for_rustc_metadata(str(ctx.label))

    args = ctx.actions.args()
    args.add(crate.root)
    args.add(crate.name, format = "--crate-name=%s")
    args.add(crate.type, format = "--crate-type=%s")
    args.add(crate.edition, format = "--edition=%s")
    args.add(target_triple, format = "--target=%s")
    args.add_all([sysroot], format_each = "--sysroot=%s", expand_directories = False)
    if cfg_miri:
        args.add("--cfg=miri")
    args.add(metadata, format = "-Cmetadata=%s")
    args.add(metadata, format = "-Cextra-filename=-%s")
    args.add(output, format = "--emit=link=%s")
    args.add_all(ctx.rule.attr.crate_features, before_each = "--cfg", format_each = 'feature="%s"')
    args.add_all(ctx.rule.attr.rustc_flags)
    args.add_all(rustc_flag_files, format_each = "@%s")

    args.add_all(direct_deps, map_each = miri_extern_arg)
    args.add_all(
        miri_transitive_outputs(direct_deps),
        map_each = _dirname,
        format_each = "-Ldependency=%s",
        uniquify = True,
    )

    transitive_inputs = [dep.transitive_inputs for dep in direct_deps]
    transitive_outputs = [dep.transitive_outputs for dep in direct_deps]
    direct_inputs = [crate.root, sysroot] + rustc_env_files + rustc_flag_files
    compile_inputs = depset(
        direct = direct_inputs,
        transitive = [
            crate.srcs,
            crate.compile_data,
            toolchain.all_files,
        ] + transitive_inputs,
    )

    ctx.actions.run(
        executable = toolchain.process_wrapper,
        arguments = miri_process_wrapper_args(ctx, toolchain, rustc_env_files, args),
        env = env,
        inputs = compile_inputs,
        outputs = [output],
        mnemonic = mnemonic,
        progress_message = progress_message,
        toolchain = MIRI_TOOLCHAIN_TYPE,
    )

    return struct(
        transitive_inputs = transitive_inputs,
        transitive_outputs = transitive_outputs,
    )

def _compiled_crate(output, transitive_inputs, transitive_outputs):
    return struct(
        output = output,
        transitive_inputs = depset(
            [output],
            transitive = transitive_inputs,
        ),
        transitive_outputs = depset([output], transitive = transitive_outputs),
    )

def _miri_compile_action(
        *,
        ctx,
        crate,
        toolchain,
        direct_deps,
        output,
        rustc_files,
        target_triple,
        sysroot,
        env,
        mnemonic,
        progress_message,
        cfg_miri = False):
    action = _emit_miri_rustc_action(
        ctx = ctx,
        crate = crate,
        toolchain = toolchain,
        direct_deps = direct_deps,
        output = output,
        rustc_env_files = rustc_files.env_files,
        rustc_flag_files = rustc_files.flag_files,
        target_triple = target_triple,
        sysroot = sysroot,
        env = env,
        mnemonic = mnemonic,
        progress_message = progress_message,
        cfg_miri = cfg_miri,
    )
    return _compiled_crate(output, action.transitive_inputs, action.transitive_outputs)

def _miri_rustc_compile_toolchain(toolchain, rust_toolchain, sysroot, target_triple):
    parsed_target = _parse_triple(target_triple)
    fields = structs.to_dict(rust_toolchain)
    fields.update({
        "all_files": depset([sysroot], transitive = [toolchain.all_files]),
        "channel": "nightly",
        "process_wrapper": toolchain.process_wrapper,
        "rust_std": [],
        "rustc": toolchain.miri,
        "target_abi": parsed_target.abi,
        "target_arch": parsed_target.arch,
        "target_flag_value": target_triple,
        "target_json": None,
        "target_os": parsed_target.system,
        "target_triple": parsed_target,
        "_bootstrapping": False,
        "_toolchain_generated_sysroot": False,
    })
    return struct(**fields)

def _miri_host_crate_info_dict(crate, output, deps, proc_macro_deps):
    crate_info = structs.to_dict(crate)
    crate_info.update({
        "deps": deps,
        "metadata": None,
        "metadata_supports_pipelining": False,
        "output": output,
        "proc_macro_deps": proc_macro_deps,
        "rustc_output": None,
        "rustc_rmeta_output": None,
        "srcs": crate.srcs.to_list(),
    })
    return crate_info

def _miri_host_compile_action(ctx, crate, toolchain, rust_toolchain, deps, proc_macro_deps):
    output = _host_output(ctx, crate)
    rust_flags = ctx.actions.args()
    rust_flags.add_all([toolchain.host_miri_sysroot], format_each = "--sysroot=%s", expand_directories = False)

    result = rustc_compile(
        ctx = ctx,
        attr = ctx.rule.attr,
        rust_toolchain = _miri_rustc_compile_toolchain(
            toolchain,
            rust_toolchain,
            toolchain.host_miri_sysroot,
            toolchain.exec_triple,
        ),
        tool_file = toolchain.miri,
        toolchain = MIRI_TOOLCHAIN_TYPE,
        crate_info_dict = _miri_host_crate_info_dict(crate, output, deps, proc_macro_deps),
        env = {
            "MIRI_BE_RUSTC": "host",
            "MIRI_SYSROOT": toolchain.host_miri_sysroot.path,
            "REPOSITORY_NAME": ctx.label.workspace_name,
        },
        file = ctx.rule.file,
        files = ctx.rule.files,
        include_coverage = False,
        mnemonic = "MiriHostRustc",
        output_hash = _host_output_hash(ctx, crate),
        progress_message = "Compiling Rust host dependency for Miri %{label}",
        rust_flags = rust_flags,
        skip_expanding_rustc_env = True,
    )

    return struct(
        crate_info = result.crate_info,
        dep_info = result.dep_info,
        output = result.crate_info.output,
        transitive_inputs = depset([result.crate_info.output], transitive = [result.compile_inputs]),
        transitive_outputs = depset([result.crate_info.output], transitive = [result.dep_info.transitive_crate_outputs]),
    )

def _miri_compile_aspect_impl(target, ctx):
    crate = _crate_provider(target)
    if not crate:
        return []

    if crate.type not in ("lib", "rlib", "proc-macro"):
        return []

    toolchain = ctx.toolchains[MIRI_TOOLCHAIN_TYPE]
    rust_toolchain = ctx.toolchains[_RUST_TOOLCHAIN_TYPE]
    rustc_files = _rustc_files(target, crate)
    deps = ctx.rule.attr.deps
    proc_macro_deps = ctx.rule.attr.proc_macro_deps
    aliases = ctx.rule.attr.aliases
    direct_crate_aliases = _direct_crate_aliases(target)
    direct_deps = _miri_direct_dep_infos(
        crate,
        deps,
        aliases,
        direct_crate_aliases,
    )
    host = _miri_host_compile_action(
        ctx = ctx,
        crate = crate,
        toolchain = toolchain,
        rust_toolchain = rust_toolchain,
        deps = _miri_dep_variants(deps, use_host_outputs = True),
        proc_macro_deps = _miri_dep_variants(proc_macro_deps, use_host_outputs = True, proc_macro_only = True),
    )

    if crate.type == "proc-macro":
        host = struct(
            output = host.output,
            transitive_inputs = depset(transitive = [host.transitive_inputs, crate.data]),
            transitive_outputs = host.transitive_outputs,
        )
        return [MiriCrateInfo(
            crate_info = crate,
            host = host,
            target = host,
        )]

    # Miri uses MIRI_BE_RUSTC=target to compile dependency rlibs with
    # MIR-preserving defaults, then runs normally for the root crate.
    target = _miri_compile_action(
        ctx = ctx,
        crate = crate,
        toolchain = toolchain,
        direct_deps = direct_deps,
        output = _target_rlib_output(ctx, crate, "miri"),
        rustc_files = rustc_files,
        target_triple = toolchain.target_triple,
        sysroot = toolchain.miri_sysroot,
        cfg_miri = True,
        env = crate.rustc_env | {
            "MIRI_BE_RUSTC": "target",
            "MIRI_SYSROOT": toolchain.miri_sysroot.path,
            "REPOSITORY_NAME": ctx.label.workspace_name,
        },
        mnemonic = "MiriRustc",
        progress_message = "Compiling Rust dependency for Miri %{label}",
    )

    return [MiriCrateInfo(
        crate_info = crate,
        host = host,
        target = target,
    )]

miri_compile_aspect = aspect(
    implementation = _miri_compile_aspect_impl,
    attr_aspects = ["deps", "proc_macro_deps"],
    fragments = ["cpp"],
    toolchains = [
        MIRI_TOOLCHAIN_TYPE,
        _RUST_TOOLCHAIN_TYPE,
        _CC_TOOLCHAIN_TYPE,
    ],
)

def _miri_sysroot_compile_aspect_impl(target, ctx):
    crate = _crate_provider(target)
    if not crate:
        return []

    if crate.type == "proc-macro":
        fail("Miri sysroot build does not support proc-macro crate targets: {}".format(ctx.label))

    if crate.type not in ("lib", "rlib"):
        return []

    toolchain = ctx.toolchains[MIRI_SYSROOT_TOOLCHAIN_TYPE]
    direct_deps = _miri_direct_dep_infos(
        crate,
        ctx.rule.attr.deps,
        ctx.rule.attr.aliases,
        _direct_crate_aliases(target),
    )
    transitive_outputs = [dep.transitive_outputs for dep in direct_deps]
    transitive_inputs = [dep.transitive_inputs for dep in direct_deps]

    metadata = _sanitize_for_rustc_metadata(str(ctx.label))
    output = ctx.actions.declare_file("miri_sysroot/{}/lib{}-{}.rlib".format(ctx.label.name, crate.name, metadata))
    rustc_files = _rustc_files(target, crate)

    args = ctx.actions.args()
    args.add(crate.root)
    args.add(crate.name, format = "--crate-name=%s")
    args.add(crate.type, format = "--crate-type=%s")
    args.add(crate.edition, format = "--edition=%s")
    args.add(toolchain.target_triple, format = "--target=%s")
    args.add("--cfg=miri")
    args.add("-Zforce-unstable-if-unmarked")
    args.add("-Aunexpected_cfgs")
    args.add("-Cdebug-assertions=off")
    args.add("-Coverflow-checks=on")
    args.add("-Cpanic=abort" if crate.name == "panic_abort" else "-Cpanic=unwind")
    args.add(metadata, format = "-Cmetadata=%s")
    args.add(metadata, format = "-Cextra-filename=-%s")
    args.add(output, format = "--emit=link=%s")
    args.add_all(ctx.rule.attr.crate_features, before_each = "--cfg", format_each = 'feature="%s"')
    args.add_all(ctx.rule.attr.rustc_flags)
    args.add_all(rustc_files.flag_files, format_each = "@%s")

    args.add_all(direct_deps, map_each = miri_extern_arg)
    args.add_all(
        miri_transitive_outputs(direct_deps),
        map_each = _dirname,
        format_each = "-Ldependency=%s",
        uniquify = True,
    )

    library_dir = _find_library_dir(toolchain.rustc_srcs)
    env = crate.rustc_env | {
        "MIRI_BE_RUSTC": "target",
        "MIRI_CALLED_FROM_SETUP": "1",
        "MIRI_LIB_SRC": library_dir,
        "MIRI_SYSROOT": output.dirname,
        "REPOSITORY_NAME": ctx.label.workspace_name,
    }

    compile_inputs = depset(
        direct = [crate.root] + rustc_files.env_files + rustc_files.flag_files,
        transitive = [
            crate.srcs,
            crate.compile_data,
            toolchain.all_files,
        ] + transitive_inputs,
    )

    ctx.actions.run(
        executable = toolchain.process_wrapper,
        arguments = miri_process_wrapper_args(ctx, toolchain, rustc_files.env_files, args),
        env = env,
        inputs = compile_inputs,
        outputs = [output],
        mnemonic = "MiriSysrootRustc",
        progress_message = "Compiling Rust sysroot crate for Miri %{label}",
        toolchain = MIRI_SYSROOT_TOOLCHAIN_TYPE,
    )

    compiled = _compiled_crate(output, transitive_inputs, transitive_outputs)
    return [MiriCrateInfo(
        crate_info = crate,
        host = compiled,
        target = compiled,
    )]

miri_sysroot_compile_aspect = aspect(
    implementation = _miri_sysroot_compile_aspect_impl,
    attr_aspects = ["deps"],
    toolchains = [MIRI_SYSROOT_TOOLCHAIN_TYPE],
)
