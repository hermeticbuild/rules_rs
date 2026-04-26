load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/miri/private:sysroot.bzl", "miri_sysroot")
load("//rs/experimental/miri/private:toolchain.bzl", "miri_sysroot_toolchain", "miri_toolchain")
load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES", "triple_to_constraint_set")
load("//rs/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

def declare_miri_toolchains(
        *,
        version,
        execs = SUPPORTED_EXEC_TRIPLES):
    version_key = sanitize_version(version)
    selected_target_triple = select({
        "@rules_rs//rs/platforms/config:" + target_triple: target_triple
        for target_triple in ALL_TARGET_TRIPLES
    })
    source_sysroot_name = "miri_sysroot_" + version_key
    generated_stdlib_root = "@rustc_src_%s//src:sysroot" % version_key
    rust_src_repo_label = "@rustc_src_%s//src:rustc_srcs" % version_key

    miri_sysroot(
        name = source_sysroot_name,
        roots = [generated_stdlib_root],
    )

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch
        exec_compatible_with = [
            "@platforms//os:" + exec_triple.system,
            "@platforms//cpu:" + exec_triple.arch,
        ]

        miri_repo_label = "@miri_%s_%s//:" % (triple_suffix, version_key)
        toolchain_kwargs = dict(
            exec_triple = triple,
            miri = miri_repo_label + "miri",
            rustc_lib = miri_repo_label + "rustc_lib",
            target_triple = selected_target_triple,
        )

        sysroot_toolchain_name = "%s_%s_miri_sysroot_toolchain" % (triple_suffix, version_key)
        miri_sysroot_toolchain(
            name = sysroot_toolchain_name,
            rustc_srcs = rust_src_repo_label,
            **toolchain_kwargs
        )

        host_source_sysroot_name = "%s_%s_miri_host_sysroot" % (triple_suffix, version_key)
        miri_sysroot(
            name = host_source_sysroot_name,
            srcs = ["@rust_stdlib_%s_%s//:rust_std-%s" % (sanitize_triple(triple), version_key, triple)],
        )

        toolchain_name = "%s_%s_miri_toolchain" % (triple_suffix, version_key)
        miri_toolchain(
            name = toolchain_name,
            host_source_sysroot = host_source_sysroot_name,
            source_sysroot = source_sysroot_name,
            **toolchain_kwargs
        )

        for target_triple in ALL_TARGET_TRIPLES:
            target_key = sanitize_triple(target_triple)
            target_compatible_with = triple_to_constraint_set(target_triple)

            native.toolchain(
                name = "%s_to_%s_%s_miri_sysroot" % (triple_suffix, target_key, version_key),
                exec_compatible_with = exec_compatible_with,
                target_compatible_with = target_compatible_with,
                toolchain = sysroot_toolchain_name,
                toolchain_type = "@rules_rs//rs/experimental/miri:sysroot_toolchain_type",
                visibility = ["//visibility:public"],
            )

            native.toolchain(
                name = "%s_to_%s_%s_miri" % (triple_suffix, target_key, version_key),
                exec_compatible_with = exec_compatible_with,
                target_compatible_with = target_compatible_with,
                toolchain = toolchain_name,
                toolchain_type = "@rules_rs//rs/experimental/miri:toolchain_type",
                visibility = ["//visibility:public"],
            )
