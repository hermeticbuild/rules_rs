"""Definitions for declaring Rust compiler toolchains."""

load("@rules_rust//rust:rust_toolchain.bzl", "rust_toolchain")
load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TIER_3_TRIPLES", "triple_to_rust_constraint_set")
load("//rs/private:bpf_linker_repository.bzl", "bpf_linker_binary_name", "bpf_linker_repository_name")
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

def _component(component, triple, default, alias_name = None, custom = False):
    component = component.get(triple) if type(component) == "dict" else component
    if component != None:
        return component
    if alias_name == None:
        return default
    if custom:
        return "@default_rust_toolchains//rustc:" + alias_name

    native.alias(
        name = alias_name,
        actual = default,
        visibility = ["//visibility:public"],
    )
    return default

# buildifier: disable=unnamed-macro
def declare_rustc_toolchains(
        *,
        version,
        edition = "2021",
        name = None,
        rustc = None,
        exec_triples = None,
        target_triples = ALL_TARGET_TRIPLES,
        extra_rustc_flags = {},
        extra_exec_rustc_flags = {},
        rust_doc = None,
        rustc_lib = None,
        cargo = None,
        clippy_driver = None,
        cargo_clippy = None,
        rust_objcopy = None,
        rust_lld = None,
        bpf_linker = None,
        rust_std = None):
    """Declares generated or custom Rust compiler toolchains.

    Args:
      version: Rust compiler version.
      edition: Default Rust edition; defaults to 2021.
      name: Target-name prefix, required when supplying a custom compiler.
      rustc: Custom compiler label or labels keyed by execution triple.
      exec_triples: Supported execution triples; defaults to compiler dictionary
        keys or all supported execution triples.
      target_triples: Supported target triples; defaults to all supported triples.
      extra_rustc_flags: Additional compiler flags keyed by target triple.
      extra_exec_rustc_flags: Additional compiler flags keyed by execution triple.
      rust_doc: Optional rustdoc label or labels keyed by execution triple.
      rustc_lib: Optional compiler-library label or labels keyed by execution triple.
      cargo: Optional Cargo label or labels keyed by execution triple.
      clippy_driver: Optional clippy-driver label or labels keyed by execution triple.
      cargo_clippy: Optional cargo-clippy label or labels keyed by execution triple.
      rust_objcopy: Optional rust-objcopy label or labels keyed by execution triple.
      rust_lld: Optional rust-lld label or labels keyed by execution triple.
      bpf_linker: Optional bpf-linker label or labels keyed by execution triple.
      rust_std: Optional standard-library label or labels keyed by target triple.
    """
    if (name != None or rustc != None) and (not name or rustc == None):
        fail("custom Rust toolchains require a nonempty name and a rustc label")

    if not version:
        fail("declare_rustc_toolchains requires a Rust version")
    if exec_triples == None:
        exec_triples = list(rustc.keys()) if type(rustc) == "dict" else SUPPORTED_EXEC_TRIPLES
    if not exec_triples:
        fail("declare_rustc_toolchains requires at least one execution triple")
    if not target_triples:
        fail("declare_rustc_toolchains requires at least one target triple")

    for exec_triple in exec_triples:
        if exec_triple not in SUPPORTED_EXEC_TRIPLES:
            fail("unsupported Rust execution triple: %s" % exec_triple)
        if type(rustc) == "dict" and exec_triple not in rustc:
            fail("rustc does not contain a compiler for execution triple %s" % exec_triple)

    for target_triple in target_triples:
        if target_triple not in ALL_TARGET_TRIPLES:
            fail("unsupported Rust target triple: %s" % target_triple)

    execs = exec_triples
    targets = target_triples
    version_key = sanitize_version(version)
    channel = _channel(version)
    name_prefix = name + "_" if name else ""

    target_triples_setting = None
    if name and targets != ALL_TARGET_TRIPLES:
        target_triples_setting = name_prefix + "target_triples"
        target_triple_conditions = {
            "@rules_rs//rs/platforms/config:" + target_triple: "@rules_rs//rs/platforms/config:" + target_triple
            for target_triple in targets
        }
        target_triple_conditions["//conditions:default"] = "@rules_rs//rs/platforms/config:" + targets[0]
        native.alias(
            name = target_triples_setting,
            actual = select(target_triple_conditions),
        )

    source_stdlib_building_select = {}
    for target_triple in targets:
        if target_triple not in SUPPORTED_TIER_3_TRIPLES:
            continue

        target_key = sanitize_triple(target_triple)
        config_setting = name_prefix + "source_stdlib_building_" + target_key
        native.config_setting(
            name = config_setting,
            constraint_values = triple_to_rust_constraint_set(target_triple),
            flag_values = {
                "@rules_rs//rs/private:source_stdlib_building": "true",
            },
        )
        source_stdlib_building_select[config_setting] = "@rules_rs//rs/private:empty_stdlib"

    rust_std_override = rust_std
    bpf_linker_override = bpf_linker

    for triple in execs:
        exec_triple = _parse_triple(triple)
        triple_suffix = exec_triple.system + "_" + exec_triple.arch

        rustc_repo_label = "@rustc_{}_{}//:".format(triple_suffix, version_key)
        cargo_repo_label = "@cargo_{}_{}//:".format(triple_suffix, version_key)
        clippy_repo_label = "@clippy_{}_{}//:".format(triple_suffix, version_key)

        default_toolchain_name = triple_suffix + "_" + version_key + "_rust_toolchain"
        rust_toolchain_name = name_prefix + default_toolchain_name
        rust_std = rust_toolchain_name + "_rust_std"

        default_rust_std = "@default_rust_toolchains//rustc:" + default_toolchain_name + "_rust_std" if name else None

        rust_std_select = {}
        target_triple_select = {}
        for target_triple in targets:
            config_label = "@rules_rs//rs/platforms/config:" + target_triple
            target_triple_select[config_label] = target_triple

            if name and rust_std_override == None:
                continue

            if not name:
                target_key = sanitize_triple(target_triple)
                stdlib_repo = "rust_stdlib_%s_%s" % (target_key, version_key)
                if target_triple in SUPPORTED_TIER_3_TRIPLES:
                    default_rust_std = "@rustc_src_" + version_key + "//src:rust_std"
                else:
                    default_rust_std = "@%s//:rust_std-%s" % (stdlib_repo, target_triple)

            rust_std_select[config_label] = _component(
                rust_std_override,
                target_triple,
                default_rust_std,
            )

        if name and rust_std_override == None:
            rust_std = default_rust_std
        else:
            native.alias(
                name = rust_std,
                actual = select(rust_std_select),
                visibility = ["//visibility:public"],
            )
        toolchain_rust_std = select(source_stdlib_building_select | {
            "//conditions:default": rust_std,
        })

        lld_label = _component(
            rust_lld,
            triple,
            rustc_repo_label + "rust-lld",
            default_toolchain_name + "_rust_lld",
            name,
        )

        rust_toolchain_kwargs = dict(
            rust_doc = _component(rust_doc, triple, rustc_repo_label + "rustdoc", default_toolchain_name + "_rust_doc", name),
            rustc = _component(rustc, triple, rustc_repo_label + "rustc"),
            cargo = _component(cargo, triple, cargo_repo_label + "cargo", default_toolchain_name + "_cargo", name),
            clippy_driver = _component(clippy_driver, triple, clippy_repo_label + "clippy_driver_bin", default_toolchain_name + "_clippy_driver", name),
            cargo_clippy = _component(cargo_clippy, triple, clippy_repo_label + "cargo_clippy_bin", default_toolchain_name + "_cargo_clippy", name),
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
            rust_objcopy = _component(rust_objcopy, triple, rustc_repo_label + "rust-objcopy", default_toolchain_name + "_rust_objcopy", name),
            rustc_lib = _component(rustc_lib, triple, rustc_repo_label + "rustc_lib", default_toolchain_name + "_rustc_lib", name),
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
            default_edition = edition,
            extra_exec_rustc_flags = _rustc_flags_to_select(extra_exec_rustc_flags),
            extra_rustc_flags = _rustc_flags_to_select(extra_rustc_flags),
            exec_triple = triple,
            target_triple = select(target_triple_select),
            visibility = ["//visibility:public"],
            tags = ["rust_version=" + version],
        )

        rust_toolchain(
            name = rust_toolchain_name,
            process_wrapper = "@rules_rust//util/process_wrapper",
            rust_std = toolchain_rust_std,
            **rust_toolchain_kwargs
        )

        rust_toolchain(
            name = rust_toolchain_name + "_bootstrap",
            bootstrapping = True,
            process_wrapper = "@rules_rust//util/process_wrapper:bootstrap_process_wrapper",
            rust_std = rust_std,
            **rust_toolchain_kwargs
        )

        bpf_linker = _component(
            bpf_linker_override,
            triple,
            "@%s//:%s" % (bpf_linker_repository_name(triple), bpf_linker_binary_name(triple)),
            default_toolchain_name + "_bpf_linker",
            name,
        )
        rust_toolchain(
            name = rust_toolchain_name + "_bpf",
            linker_preference = "rust",
            process_wrapper = "@rules_rust//util/process_wrapper",
            rust_std = toolchain_rust_std,
            **(rust_toolchain_kwargs | {
                "linker": select({
                    "@platforms//cpu:bpfeb": bpf_linker,
                    "@platforms//cpu:bpfel": bpf_linker,
                }),
            })
        )

        for is_bpf, bootstrapping in [
            (False, False),
            (False, True),
            (True, False),
        ]:
            target_kind = "bpf" if is_bpf else "non_bpf"
            bootstrap_suffix = "_bootstrap" if bootstrapping else ""
            bootstrap_setting = "@rules_rust//rust/private:" + ("bootstrapping" if bootstrapping else "bootstrapped")
            toolchain_suffix = "_bpf" if is_bpf else bootstrap_suffix
            native.toolchain(
                name = name_prefix + "{}_{}_to_{}_targets_{}{}".format(
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
                    "@rules_rust//rust/toolchain/channel:" + channel,
                ] + ([target_triples_setting] if target_triples_setting else []),
                toolchain = rust_toolchain_name + toolchain_suffix,
                toolchain_type = "@rules_rust//rust:toolchain_type",
                visibility = ["//visibility:public"],
            )
