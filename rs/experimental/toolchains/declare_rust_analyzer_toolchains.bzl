load("@rules_rust//rust:toolchain.bzl", "rust_analyzer_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "includes_rust_analyzer_proc_macro_srv",
)
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def _parse_version(version):
    if "/" in version:
        return version.split("/", 1)
    return version, None

def declare_rust_analyzer_toolchains(
        *,
        version,
        rust_analyzer_version,
        execs = SUPPORTED_EXEC_TRIPLES):
    version_key = sanitize_version(version)
    rust_analyzer_version_key = sanitize_version(rust_analyzer_version)
    channel = _channel(version)
    rust_analyzer_base_version, rust_analyzer_iso_date = _parse_version(rust_analyzer_version)

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, rust_analyzer_version_key)
        rust_analyzer_repo_label = "@rust_analyzer_{}_{}//:".format(triple_suffix, rust_analyzer_version_key)
        rust_src_repo_label = "@rust_src_{}//lib/rustlib/src:rustc_srcs".format(rust_analyzer_version_key)

        rust_analyzer_toolchain_name = "{}_{}_{}_rust_analyzer_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )

        rust_analyzer_toolchain_kwargs = dict(
            name = rust_analyzer_toolchain_name,
            rust_analyzer = "{}rust_analyzer".format(rust_analyzer_repo_label),
            rustc = "{}rustc".format(rustc_repo_label),
            rustc_srcs = rust_src_repo_label,
            visibility = ["//visibility:public"],
        )

        if includes_rust_analyzer_proc_macro_srv(rust_analyzer_base_version, rust_analyzer_iso_date):
            rust_analyzer_toolchain_kwargs["proc_macro_srv"] = "{}rust_analyzer_proc_macro_srv".format(rustc_repo_label)

        rust_analyzer_toolchain(**rust_analyzer_toolchain_kwargs)

        native.toolchain(
            name = "{}_{}_rust_analyzer_{}".format(exec_triple.system, exec_triple.arch, version_key),
            exec_compatible_with = [
                "@platforms//os:" + exec_triple.system,
                "@platforms//cpu:" + exec_triple.arch,
            ],
            target_compatible_with = [],
            target_settings = [
                "@rules_rust//rust/toolchain/channel:" + channel,
            ],
            toolchain = rust_analyzer_toolchain_name,
            toolchain_type = "@rules_rust//rust/rust_analyzer:toolchain_type",
            visibility = ["//visibility:public"],
        )
