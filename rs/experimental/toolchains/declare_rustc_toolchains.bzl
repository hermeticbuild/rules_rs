load("@rules_rust//rust:toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/experimental/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES", "triple_to_constraint_set")
load("//rs/experimental/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def _rustc_flags_to_select(rustc_flags_by_triple):
    return select(
        {"@rules_rs//rs/experimental/platforms/config:" + triple: flags for triple, flags in rustc_flags_by_triple.items()} |
        {"//conditions:default": []},
    )

def _declare_rust_toolchain(
        *,
        name,
        version,
        edition,
        exec_triple,
        rust_std_label,
        cargo_repo_label,
        clippy_repo_label,
        rustc_repo_label,
        target_triple_select,
        extra_rustc_flags,
        extra_exec_rustc_flags):
    rust_toolchain(
        name = name,
        rust_doc = "{}rustdoc".format(rustc_repo_label),
        rust_std = rust_std_label,
        rustc = "{}rustc".format(rustc_repo_label),
        cargo = "{}cargo".format(cargo_repo_label),
        clippy_driver = "{}clippy_driver_bin".format(clippy_repo_label),
        cargo_clippy = "{}cargo_clippy_bin".format(clippy_repo_label),
        llvm_cov = "@llvm//tools:llvm-cov",
        llvm_profdata = "@llvm//tools:llvm-profdata",
        rustc_lib = "{}rustc_lib".format(rustc_repo_label),
        allocator_library = None,
        global_allocator_library = None,
        binary_ext = select({
            "@platforms//cpu:wasm32": ".wasm",
            "@platforms//cpu:wasm64": ".wasm",
            "@platforms//os:emscripten": ".js",
            "@platforms//os:uefi": ".efi",
            "@platforms//os:windows": ".exe",
            "//conditions:default": "",
        }),
        staticlib_ext = select({
            "@platforms//os:none": "",
            "@platforms//os:emscripten": ".js",
            "@platforms//os:uefi": ".lib",
            "@platforms//os:windows": ".lib",
            "//conditions:default": ".a",
        }),
        dylib_ext = select({
            "@platforms//cpu:wasm32": ".wasm",
            "@platforms//cpu:wasm64": ".wasm",
            "@platforms//os:android": ".so",
            "@platforms//os:emscripten": ".js",
            "@platforms//os:fuchsia": ".so",
            "@platforms//os:ios": ".dylib",
            "@platforms//os:macos": ".dylib",
            "@platforms//os:nixos": ".so",
            "@platforms//os:uefi": "",  # UEFI doesn't have dynamic linking
            "@platforms//os:windows": ".dll",
            "//conditions:default": ".so",
        }),
        stdlib_linkflags = select({
            "@platforms//os:android": ["-ldl", "-llog"],
            "@platforms//os:freebsd": ["-lexecinfo", "-lpthread"],
            "@platforms//os:macos": ["-lSystem", "-lresolv"],
            "@platforms//os:netbsd": ["-lpthread", "-lrt"],
            "@platforms//os:nixos": ["-ldl", "-lpthread"],
            "@platforms//os:openbsd": ["-lpthread"],
            "@platforms//os:ios": ["-lSystem", "-lobjc", "-Wl,-framework,Security", "-Wl,-framework,Foundation", "-lresolv"],
            # TODO: windows
            "//conditions:default": [],
        }),
        default_edition = edition,
        extra_exec_rustc_flags = _rustc_flags_to_select(extra_exec_rustc_flags),
        extra_rustc_flags = _rustc_flags_to_select(extra_rustc_flags),
        exec_triple = exec_triple,
        target_triple = select(target_triple_select),
        visibility = ["//visibility:public"],
        tags = ["rust_version={}".format(version)],
    )

def declare_rustc_toolchains(
        *,
        version,
        edition,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        source_rust_std = "",
        execs = SUPPORTED_EXEC_TRIPLES,
        targets = SUPPORTED_TARGET_TRIPLES):
    """Declare toolchains for all supported target platforms."""

    version_key = sanitize_version(version)
    channel = _channel(version)

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        cargo_repo_label = "@cargo_{}_{}//:".format(triple_suffix, version_key)
        clippy_repo_label = "@clippy_{}_{}//:".format(triple_suffix, version_key)

        rust_toolchain_name = "{}_{}_{}_rust_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )

        rust_std_select = {}
        target_triple_select = {}
        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            config_label = "@rules_rs//rs/experimental/platforms/config:{}".format(target_triple)
            rust_std_select[config_label] = "@rust_stdlib_{}_{}//:rust_std-{}".format(target_key, version_key, target_triple)
            target_triple_select[config_label] = target_triple

        _declare_rust_toolchain(
            name = rust_toolchain_name,
            version = version,
            edition = edition,
            exec_triple = triple,
            rust_std_label = select(rust_std_select),
            cargo_repo_label = cargo_repo_label,
            clippy_repo_label = clippy_repo_label,
            rustc_repo_label = rustc_repo_label,
            target_triple_select = target_triple_select,
            extra_rustc_flags = extra_rustc_flags,
            extra_exec_rustc_flags = extra_exec_rustc_flags,
        )

        source_rust_toolchain_name = None
        if source_rust_std:
            source_rust_toolchain_name = "{}_{}_{}_source_rust_toolchain".format(
                exec_triple.system,
                exec_triple.arch,
                version_key,
            )

            _declare_rust_toolchain(
                name = source_rust_toolchain_name,
                version = version,
                edition = edition,
                exec_triple = triple,
                rust_std_label = source_rust_std,
                cargo_repo_label = cargo_repo_label,
                clippy_repo_label = clippy_repo_label,
                rustc_repo_label = rustc_repo_label,
                target_triple_select = target_triple_select,
                extra_rustc_flags = extra_rustc_flags,
                extra_exec_rustc_flags = extra_exec_rustc_flags,
            )

        for target_triple in targets:
            target_key = sanitize_triple(target_triple)

            native.toolchain(
                name = "{}_{}_to_{}_{}".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                exec_compatible_with = [
                    "@platforms//os:" + exec_triple.system,
                    "@platforms//cpu:" + exec_triple.arch,
                ],
                target_compatible_with = triple_to_constraint_set(target_triple),
                target_settings = ["@rules_rust//rust/toolchain/channel:" + channel],
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )

            if source_rust_toolchain_name:
                native.toolchain(
                    name = "{}_{}_to_{}_{}_source".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                    exec_compatible_with = [
                        "@platforms//os:" + exec_triple.system,
                        "@platforms//cpu:" + exec_triple.arch,
                    ],
                    target_compatible_with = triple_to_constraint_set(target_triple, source_stdlib = True),
                    target_settings = ["@rules_rust//rust/toolchain/channel:" + channel],
                    toolchain = source_rust_toolchain_name,
                    toolchain_type = "@rules_rust//rust:toolchain_type",
                    visibility = ["//visibility:public"],
                )
