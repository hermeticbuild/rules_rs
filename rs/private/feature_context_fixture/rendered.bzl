"""Exercise generated Cargo targets through the compiler's dependency wrappers."""

load("@rules_rust//rust:defs.bzl", "rust_library", "rust_proc_macro")
load("//rs/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES")
load("//rs/private:all_crate_deps.bzl", "all_crate_deps", "crate_aliases", "crate_features")
load("//rs/private:cargo_select.bzl", "cargo_config_settings")
load("//rs/private:cargo_workspace_deps.bzl", "cargo_workspace_deps")
load("//rs/private:rust_crate.bzl", "rust_crate")

_WINDOWS = "x86_64-pc-windows-gnullvm"
_WINDOWS_ARM = "aarch64-pc-windows-gnullvm"

def _repository_impl(ctx):
    ctx.file("BUILD.bazel", 'load("@rules_rs//rs/private/feature_context_fixture:rendered.bzl", "rendered_fixture")\nrendered_fixture()\n')
    ctx.file("lib.rs", "")
    ctx.file("consumer.rs", "renamed_macro::answer!();\n")
    ctx.file("macro.rs", 'extern crate proc_macro;\n#[proc_macro]\npub fn answer(_: proc_macro::TokenStream) -> proc_macro::TokenStream { "pub fn generated() -> u32 { 42 }".parse().unwrap() }\n')
    ctx.file("build.rs", "fn main() {}\n")
    ctx.file("main.rs", "fn main() {}\n")
    ctx.file("cargo_toml_env_vars.env", "")
    ctx.file("shared.rs", '#[cfg(all(feature = "target", feature = "host"))]\ncompile_error!("target and host features must remain separate");\n#[cfg(not(any(feature = "target", feature = "host")))]\ncompile_error!("a resolved compilation context is required");\n')

rendered_repository = repository_rule(implementation = _repository_impl)

def _configuration(features):
    return {
        "crate_features_by_triple": features,
        "deps_by_triple": {triple: {} for triple in features},
        "build_deps_by_triple": {},
        "build_cargo_target_triple_required_on": [],
    }

def rendered_fixture():
    """Define a target-only crate with split build scripts and annotated inputs."""
    native.package(default_visibility = ["//visibility:public"])
    cargo_config_settings(["", _WINDOWS], sorted(set(SUPPORTED_EXEC_TRIPLES + [_WINDOWS, _WINDOWS_ARM, "x86_64-unknown-linux-musl"])))
    rust_library(name = "common_annotation", srcs = ["lib.rs"])
    native.filegroup(name = "common_data", srcs = ["lib.rs"])
    rust_library(
        name = "windows_annotation",
        srcs = ["lib.rs"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    native.filegroup(
        name = "windows_data",
        srcs = ["lib.rs"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    crate_args = dict(
        name = "target_only",
        crate_name = "target_only",
        purl = "pkg:cargo/target_only@1.0.0",
        version = "1.0.0",
        configurations = {"": _configuration({_WINDOWS: ["x86"], _WINDOWS_ARM: ["arm"]})},
        cargo_target_triple_map = {_WINDOWS: ""},
        hub_name = "feature_context_rendered",
        deps = [":common_annotation"],
        link_deps = [":windows_annotation"],
        data = [":windows_data"],
        extra_compile_data = [":common_data"],
        crate_root = "lib.rs",
        edition = "2021",
        rustc_flags = [],
        tags = [],
        links = "",
        build_script = "build.rs",
        build_script_data = [],
        build_script_env = {},
        build_script_env_files = [],
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_toolchains = [],
        build_script_tools = [],
        build_script_tags = [],
        is_proc_macro = False,
        has_lib = True,
        binaries = {"tool": "main.rs"},
        use_legacy_rules_rust_platforms = False,
    )
    rust_crate(**crate_args)
    host_features = {triple: ["unix"] if "windows" not in triple else ["windows"] for triple in SUPPORTED_EXEC_TRIPLES}
    rust_crate(**dict(
        crate_args,
        name = "generated_macro",
        crate_name = "generated_macro",
        configurations = {_WINDOWS: _configuration(host_features)},
        cargo_target_triple_map = {"": _WINDOWS},
        deps = [],
        link_deps = [],
        data = [],
        extra_compile_data = [],
        build_script = None,
        crate_root = "macro.rs",
        is_proc_macro = True,
        binaries = {},
    ))
    macro_data = {"configurations": {_WINDOWS: _configuration(host_features)}}
    rust_proc_macro(
        name = "workspace_macro",
        srcs = ["lib.rs"],
        deps = all_crate_deps(macro_data, hub_name = "feature_context_rendered"),
        aliases = crate_aliases(macro_data, hub_name = "feature_context_rendered"),
        crate_features = crate_features(macro_data, hub_name = "feature_context_rendered"),
    )
    rust_library(
        name = "consumer",
        srcs = ["consumer.rs"],
        aliases = {":generated_macro": "renamed_macro"},
        deps = [":target_only", ":workspace_macro", ":generated_macro"],
    )
    shared_args = dict(
        crate_args,
        name = "shared",
        crate_name = "shared",
        configurations = {
            "": _configuration({_WINDOWS: ["target"]}),
            _WINDOWS: _configuration({host: ["host"] for host in SUPPORTED_EXEC_TRIPLES}),
        },
        cargo_target_triple_map = {},
        crate_root = "shared.rs",
        deps = [],
        link_deps = [],
        data = [],
        extra_compile_data = [],
        build_script = None,
        binaries = {},
    )
    rust_crate(**shared_args)
    rust_crate(**dict(
        shared_args,
        name = "host_only",
        crate_name = "host_only",
        configurations = {_WINDOWS: _configuration({host: ["host"] for host in SUPPORTED_EXEC_TRIPLES})},
        cargo_target_triple_map = {"": _WINDOWS},
    ))
    cargo_workspace_deps(
        name = "workspace_dependencies",
        target_deps = {_WINDOWS: [":shared"]},
        exec_deps = {_WINDOWS: {host: [":shared", ":host_only", ":generated_macro"] for host in SUPPORTED_EXEC_TRIPLES}},
    )
