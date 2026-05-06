load("@rules_rust//rust:toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TARGET_TRIPLES", "triple_to_constraint_set")
load("//rs/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

def _channel(version):
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def _rustc_flags_to_select(rustc_flags_by_triple):
    return select(
        {"@rules_rs//rs/platforms/config:" + triple: flags for triple, flags in rustc_flags_by_triple.items()} |
        {"//conditions:default": []},
    )

def declare_rustc_toolchains(
        *,
        version,
        edition,
        include_rustc_dev = False,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        execs = SUPPORTED_EXEC_TRIPLES,
        targets = SUPPORTED_TARGET_TRIPLES):
    """Declare toolchains for all supported target platforms."""

    version_key = sanitize_version(version)
    channel = _channel(version)

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        rustc_with_dev_repo_label = "@rustc_with_dev_{}_{}//:".format(triple_suffix, version_key)
        cargo_repo_label = "@cargo_{}_{}//:".format(triple_suffix, version_key)
        clippy_repo_label = "@clippy_{}_{}//:".format(triple_suffix, version_key)

        rust_toolchain_name = "{}_{}_{}_rust_toolchain".format(
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )
        rust_toolchain_with_dev_name = rust_toolchain_name + "_with_dev"

        rust_std_select = {}
        target_triple_select = {}
        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            config_label = "@rules_rs//rs/platforms/config:{}".format(target_triple)
            rust_std_select[config_label] = "@rust_stdlib_{}_{}//:rust_std-{}".format(target_key, version_key, target_triple)
            target_triple_select[config_label] = target_triple

        rust_toolchain_kwargs = dict(
            rust_doc = "{}rustdoc".format(rustc_repo_label),
            rust_std = select(rust_std_select),
            rustc = "{}rustc".format(rustc_repo_label),
            cargo = "{}cargo".format(cargo_repo_label),
            clippy_driver = "{}clippy_driver_bin".format(clippy_repo_label),
            cargo_clippy = "{}cargo_clippy_bin".format(clippy_repo_label),
            llvm_cov = "@llvm//tools:llvm-cov",
            llvm_profdata = "@llvm//tools:llvm-profdata",
            rust_objcopy = "{}rust-objcopy".format(rustc_repo_label),
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
                "@llvm//constraints/windows/abi:gnu": ".a",
                "@llvm//constraints/windows/abi:gnullvm": ".a",
                "@llvm//constraints/windows/abi:msvc": ".lib",
                "@platforms//os:none": "",
                "@platforms//os:emscripten": ".js",
                "@platforms//os:uefi": ".lib",
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
                "@llvm//constraints/windows/abi:gnu": ["-lws2_32", "-luserenv", "-lbcrypt", "-lntdll", "-lsynchronization"],
                "@llvm//constraints/windows/abi:gnullvm": ["-lws2_32", "-luserenv", "-lbcrypt", "-lntdll", "-lsynchronization"],
                "@llvm//constraints/windows/abi:msvc": [
                    "advapi32.lib",
                    "ws2_32.lib",
                    "userenv.lib",
                    "Bcrypt.lib",
                ],
                "//conditions:default": [],
            }),
            default_edition = edition,
            extra_exec_rustc_flags = _rustc_flags_to_select(extra_exec_rustc_flags),
            extra_rustc_flags = _rustc_flags_to_select(extra_rustc_flags),
            exec_triple = triple,
            target_triple = select(target_triple_select),
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )

        rust_toolchain(
            name = rust_toolchain_name,
            process_wrapper = "@rules_rust//util/process_wrapper",
            **rust_toolchain_kwargs
        )

        rust_toolchain(
            name = rust_toolchain_name + "_bootstrap",
            bootstrapping = True,
            process_wrapper = "@rules_rust//util/process_wrapper:bootstrap_process_wrapper",
            **rust_toolchain_kwargs
        )

        if include_rustc_dev:
            # Keep the ordinary toolchains registered for the default path, and
            # expose parallel dev-enabled variants only to configurations that
            # explicitly request the merged rustc-dev sysroot.
            rust_toolchain_with_dev_kwargs = dict(rust_toolchain_kwargs)
            rust_toolchain_with_dev_kwargs.update(
                rust_doc = "{}rustdoc".format(rustc_with_dev_repo_label),
                rustc = "{}rustc".format(rustc_with_dev_repo_label),
                rust_objcopy = "{}rust-objcopy".format(rustc_with_dev_repo_label),
                rustc_lib = "{}rustc_lib".format(rustc_with_dev_repo_label),
            )

            rust_toolchain(
                name = rust_toolchain_with_dev_name,
                process_wrapper = "@rules_rust//util/process_wrapper",
                **rust_toolchain_with_dev_kwargs
            )

            rust_toolchain(
                name = rust_toolchain_with_dev_name + "_bootstrap",
                bootstrapping = True,
                process_wrapper = "@rules_rust//util/process_wrapper:bootstrap_process_wrapper",
                **rust_toolchain_with_dev_kwargs
            )

        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            bootstrapped_target_settings = [
                "@rules_rust//rust/private:bootstrapped",
                "@rules_rust//rust/toolchain/channel:" + channel,
            ]
            bootstrapping_target_settings = [
                "@rules_rust//rust/private:bootstrapping",
                "@rules_rust//rust/toolchain/channel:" + channel,
            ]
            if include_rustc_dev:
                bootstrapped_target_settings.append("@rules_rs//rs/toolchains/rustc_dev:disabled")
                bootstrapping_target_settings.append("@rules_rs//rs/toolchains/rustc_dev:disabled")

            native.toolchain(
                name = "{}_{}_to_{}_{}".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                exec_compatible_with = [
                    "@platforms//os:" + exec_triple.system,
                    "@platforms//cpu:" + exec_triple.arch,
                ],
                target_compatible_with = triple_to_constraint_set(target_triple),
                target_settings = bootstrapped_target_settings,
                toolchain = rust_toolchain_name,
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )

            native.toolchain(
                name = "{}_{}_to_{}_{}_bootstrap".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                exec_compatible_with = [
                    "@platforms//os:" + exec_triple.system,
                    "@platforms//cpu:" + exec_triple.arch,
                ],
                target_compatible_with = triple_to_constraint_set(target_triple),
                target_settings = bootstrapping_target_settings,
                toolchain = rust_toolchain_name + "_bootstrap",
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )

            if include_rustc_dev:
                native.toolchain(
                    name = "{}_{}_to_{}_{}_with_dev".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                    exec_compatible_with = [
                        "@platforms//os:" + exec_triple.system,
                        "@platforms//cpu:" + exec_triple.arch,
                    ],
                    target_compatible_with = triple_to_constraint_set(target_triple),
                    target_settings = [
                        "@rules_rust//rust/private:bootstrapped",
                        "@rules_rust//rust/toolchain/channel:" + channel,
                        "@rules_rs//rs/toolchains/rustc_dev:enabled_setting",
                    ],
                    toolchain = rust_toolchain_with_dev_name,
                    toolchain_type = "@rules_rust//rust:toolchain_type",
                    visibility = ["//visibility:public"],
                )

                native.toolchain(
                    name = "{}_{}_to_{}_{}_bootstrap_with_dev".format(exec_triple.system, exec_triple.arch, target_key, version_key),
                    exec_compatible_with = [
                        "@platforms//os:" + exec_triple.system,
                        "@platforms//cpu:" + exec_triple.arch,
                    ],
                    target_compatible_with = triple_to_constraint_set(target_triple),
                    target_settings = [
                        "@rules_rust//rust/private:bootstrapping",
                        "@rules_rust//rust/toolchain/channel:" + channel,
                        "@rules_rs//rs/toolchains/rustc_dev:enabled_setting",
                    ],
                    toolchain = rust_toolchain_with_dev_name + "_bootstrap",
                    toolchain_type = "@rules_rust//rust:toolchain_type",
                    visibility = ["//visibility:public"],
                )
