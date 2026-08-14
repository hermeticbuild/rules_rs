"""Definitions for declaring Rust compiler toolchains."""

load("@rules_rust//rust:rust_toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TIER_3_TRIPLES", "triple_to_rust_constraint_set")
load("//rs/private:bpf_linker_repository.bzl", "bpf_linker_binary_name", "bpf_linker_repository_name")
load("//rs/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

_RUST_PROCESS_WRAPPER = Label("@rules_rust//util/process_wrapper")
_BOOTSTRAP_PROCESS_WRAPPER = Label("@rules_rust//util/process_wrapper:bootstrap_process_wrapper")
_RUST_TOOLCHAIN_TYPE = Label("@rules_rust//rust:toolchain_type")

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

def _component_for_exec(component, exec_triple, default):
    if type(component) == "dict":
        return component.get(exec_triple, default)
    return default if component == None else component

def _component_alias_name(exec_triple, version_key, component):
    return "%s_%s_%s_%s" % (
        exec_triple.system,
        exec_triple.arch,
        version_key,
        component,
    )

def _component_label(toolchains_repo, exec_triple, version_key, component):
    return "%s//:%s" % (
        toolchains_repo,
        _component_alias_name(exec_triple, version_key, component),
    )

# buildifier: disable=unnamed-macro
def declare_rustc_toolchains(
        *,
        version,
        edition,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        execs = SUPPORTED_EXEC_TRIPLES,
        targets = ALL_TARGET_TRIPLES,
        name = None,
        toolchains_repo = None,
        rustc = None,
        rust_doc = None,
        rustc_lib = None,
        cargo = None,
        clippy_driver = None,
        cargo_clippy = None,
        rust_objcopy = None,
        rust_lld = None,
        bpf_linker = None,
        rust_std = None,
        toolchain_attrs = {}):
    """Declares Rust compiler toolchains for all supported target platforms.

    Args:
      version: The Rust compiler version.
      edition: The default Rust edition.
      extra_rustc_flags: Additional target Rust compiler flags keyed by triple.
      extra_exec_rustc_flags: Additional execution Rust compiler flags keyed by triple.
      execs: Execution platform triples for which to declare toolchains.
      targets: Target platform triples supported by the declared toolchains.
      name: Optional target-name prefix for independently declared toolchains.
      toolchains_repo: Existing toolchain repository providing default components.
      rustc: Optional compiler label or compiler labels keyed by execution triple.
      rust_doc: Optional rustdoc label or labels keyed by execution triple.
      rustc_lib: Optional compiler-library label or labels keyed by execution triple.
      cargo: Optional Cargo label or labels keyed by execution triple.
      clippy_driver: Optional clippy-driver label or labels keyed by execution triple.
      cargo_clippy: Optional cargo-clippy label or labels keyed by execution triple.
      rust_objcopy: Optional rust-objcopy label or labels keyed by execution triple.
      rust_lld: Optional rust-lld label or labels keyed by execution triple.
      bpf_linker: Optional bpf-linker label or labels keyed by execution triple.
      rust_std: Optional standard-library label or labels keyed by target triple.
      toolchain_attrs: Additional attributes passed to every rust_toolchain target.
    """

    version_key = sanitize_version(version)
    channel = _channel(version)
    name_prefix = "%s_" % name if name else ""

    target_triples_setting = None
    if name:
        target_triples_setting = "%starget_triples" % name_prefix
        target_triple_conditions = {
            "@rules_rs//rs/platforms/config:" + target_triple: "@rules_rs//rs/platforms/config:" + target_triple
            for target_triple in targets
        }
        target_triple_conditions["//conditions:default"] = "@rules_rs//rs/platforms/config:" + targets[0]
        native.alias(
            name = target_triples_setting,
            actual = select(target_triple_conditions),
        )

    for attr_name in ["bootstrapping", "name", "process_wrapper", "rust_std"]:
        if attr_name in toolchain_attrs:
            fail("toolchain_attrs cannot override %s" % attr_name)

    source_stdlib_building_select = {}
    for target_triple in targets:
        if target_triple not in SUPPORTED_TIER_3_TRIPLES:
            continue

        target_key = sanitize_triple(target_triple)
        config_setting = "%ssource_stdlib_building_%s" % (name_prefix, target_key)
        native.config_setting(
            name = config_setting,
            constraint_values = triple_to_rust_constraint_set(target_triple),
            flag_values = {
                "@rules_rs//rs/private:source_stdlib_building": "true",
            },
        )
        source_stdlib_building_select[config_setting] = "@rules_rs//rs/private:empty_stdlib"

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        cargo_repo_label = "@cargo_{}_{}//:".format(triple_suffix, version_key)
        clippy_repo_label = "@clippy_{}_{}//:".format(triple_suffix, version_key)

        rust_toolchain_name = "%s%s_%s_%s_rust_toolchain" % (
            name_prefix,
            exec_triple.system,
            exec_triple.arch,
            version_key,
        )
        rust_std_name = rust_toolchain_name + "_rust_std"

        rust_std_select = {}
        target_triple_select = {}
        for target_triple in targets:
            target_key = sanitize_triple(target_triple)
            config_label = "@rules_rs//rs/platforms/config:" + target_triple

            if toolchains_repo:
                default_rust_std = _component_label(
                    toolchains_repo,
                    exec_triple,
                    version_key,
                    "rust_std",
                )
            else:
                stdlib_repo = "rust_stdlib_%s_%s" % (target_key, version_key)
                if target_triple in SUPPORTED_TIER_3_TRIPLES:
                    default_rust_std = "@rustc_src_%s//src:rust_std" % version_key
                else:
                    default_rust_std = "@%s//:rust_std-%s" % (stdlib_repo, target_triple)

            if type(rust_std) == "dict":
                rust_std_select[config_label] = rust_std.get(target_triple, default_rust_std)
            elif rust_std == None:
                rust_std_select[config_label] = default_rust_std
            else:
                rust_std_select[config_label] = rust_std

            target_triple_select[config_label] = target_triple

        native.alias(
            name = rust_std_name,
            actual = select(rust_std_select),
            visibility = ["//visibility:public"],
        )
        toolchain_rust_std = select(source_stdlib_building_select | {
            "//conditions:default": rust_std_name,
        })

        default_bpf_linker = "@%s//:%s" % (
            bpf_linker_repository_name(triple),
            bpf_linker_binary_name(triple),
        )
        default_components = {
            "rustc": "%srustc" % rustc_repo_label,
            "rust_doc": "%srustdoc" % rustc_repo_label,
            "rustc_lib": "%srustc_lib" % rustc_repo_label,
            "cargo": "%scargo" % cargo_repo_label,
            "clippy_driver": "%sclippy_driver_bin" % clippy_repo_label,
            "cargo_clippy": "%scargo_clippy_bin" % clippy_repo_label,
            "rust_objcopy": "%srust-objcopy" % rustc_repo_label,
            "rust_lld": "%srust-lld" % rustc_repo_label,
            "bpf_linker": default_bpf_linker,
        }

        if toolchains_repo:
            default_components = {
                component: _component_label(
                    toolchains_repo,
                    exec_triple,
                    version_key,
                    component,
                )
                for component in default_components
            }
        else:
            for component, component_target in default_components.items():
                native.alias(
                    name = _component_alias_name(exec_triple, version_key, component),
                    actual = component_target,
                    visibility = ["//visibility:public"],
                )

            native.alias(
                name = _component_alias_name(exec_triple, version_key, "rust_std"),
                actual = rust_std_name,
                visibility = ["//visibility:public"],
            )

        lld_label = _component_for_exec(rust_lld, triple, default_components["rust_lld"])

        rust_toolchain_kwargs = dict(
            rust_doc = _component_for_exec(rust_doc, triple, default_components["rust_doc"]),
            rustc = _component_for_exec(rustc, triple, default_components["rustc"]),
            cargo = _component_for_exec(cargo, triple, default_components["cargo"]),
            clippy_driver = _component_for_exec(clippy_driver, triple, default_components["clippy_driver"]),
            cargo_clippy = _component_for_exec(cargo_clippy, triple, default_components["cargo_clippy"]),
            llvm_cov = "@llvm//tools:llvm-cov",
            llvm_profdata = "@llvm//tools:llvm-profdata",
            linker = select({
                "@rules_rs//rs/platforms/config:riscv32imac-unknown-none-elf": lld_label,
                "@rules_rs//rs/platforms/config:riscv32imc-unknown-none-elf": lld_label,
                "@platforms//cpu:wasm32": lld_label,
                "@platforms//cpu:wasm64": lld_label,
                "//conditions:default": None,
            }),
            linker_type = "direct",
            rust_objcopy = _component_for_exec(rust_objcopy, triple, default_components["rust_objcopy"]),
            rustc_lib = _component_for_exec(rustc_lib, triple, default_components["rustc_lib"]),
            allocator_library = None,
            global_allocator_library = None,
            binary_ext = select({
                "@rules_rs//rs/platforms/config:wasm32-unknown-emscripten": ".js",
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
                "@platforms//os:emscripten": ".js",
                "@platforms//os:uefi": ".lib",
                "//conditions:default": ".a",
            }),
            dylib_ext = select({
                "@rules_rs//rs/platforms/config:wasm32-unknown-emscripten": ".js",
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
            channel = channel,
            default_edition = edition,
            extra_exec_rustc_flags = _rustc_flags_to_select(extra_exec_rustc_flags),
            extra_rustc_flags = _rustc_flags_to_select(extra_rustc_flags),
            exec_triple = triple,
            target_triple = select(target_triple_select),
            version = version,
            visibility = ["//visibility:public"],
            tags = ["rust_version={}".format(version)],
        )
        rust_toolchain_kwargs.update(toolchain_attrs)

        rust_toolchain(
            name = rust_toolchain_name,
            process_wrapper = _RUST_PROCESS_WRAPPER,
            rust_std = toolchain_rust_std,
            **rust_toolchain_kwargs
        )

        rust_toolchain(
            name = rust_toolchain_name + "_bootstrap",
            bootstrapping = True,
            process_wrapper = _BOOTSTRAP_PROCESS_WRAPPER,
            rust_std = rust_std_name,
            **rust_toolchain_kwargs
        )

        bpf_linker_label = _component_for_exec(
            bpf_linker,
            triple,
            default_components["bpf_linker"],
        )
        rust_toolchain(
            name = rust_toolchain_name + "_bpf",
            process_wrapper = _RUST_PROCESS_WRAPPER,
            rust_std = toolchain_rust_std,
            **(rust_toolchain_kwargs | {
                "linker": select({
                    "@platforms//cpu:bpfeb": bpf_linker_label,
                    "@platforms//cpu:bpfel": bpf_linker_label,
                }),
                "linker_preference": "rust",
            })
        )

        for is_bpf, bootstrapping in [
            (False, False),
            (False, True),
            (True, False),
        ]:
            target_kind = "bpf" if is_bpf else "non_bpf"
            bootstrap_suffix = "_bootstrap" if bootstrapping else ""
            bootstrap_setting = Label("@rules_rust//rust/private:%s" % (
                "bootstrapping" if bootstrapping else "bootstrapped"
            ))
            toolchain_suffix = "_bpf" if is_bpf else bootstrap_suffix
            native.toolchain(
                name = "%s%s_%s_to_%s_targets_%s%s" % (
                    name_prefix,
                    exec_triple.system,
                    exec_triple.arch,
                    target_kind,
                    version_key,
                    bootstrap_suffix,
                ),
                exec_compatible_with = [
                    "@platforms//os:" + exec_triple.system,
                    "@platforms//cpu:" + exec_triple.arch,
                ],
                target_settings = [
                    "@rules_rs//rs/toolchains:bpf_targets" if is_bpf else "@rules_rs//rs/toolchains:non_bpf_targets",
                    bootstrap_setting,
                    Label("@rules_rust//rust/toolchain/channel:%s" % channel),
                ] + ([target_triples_setting] if target_triples_setting else []),
                toolchain = rust_toolchain_name + toolchain_suffix,
                toolchain_type = _RUST_TOOLCHAIN_TYPE,
                visibility = ["//visibility:public"],
            )
