# Copyright 2019 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Hermetic bindgen rule and prebuilt toolchains."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@rules_cc//cc:action_names.bzl", "C_COMPILE_ACTION_NAME")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rs/private:bindgen.bzl", "CLANG_PARAMETER_FLAGS", "normalize_msvc_compile_flags")
load("//rs/toolchains:declare_bindgen_toolchains.bzl", "BINDGEN_PREBUILTS", "bindgen_binary_name")

_BINDGEN_TOOLCHAIN_TYPE = Label("//rs:bindgen_toolchain_type")

def _supports_apple_action(ctx, bindgen_toolchain):
    if not hasattr(bindgen_toolchain, "exec_os") or bindgen_toolchain.exec_os != "macos":
        return False

    return apple_support.target_os_from_rule_ctx(
        ctx,
        fail_on_missing_constraint = False,
    ) != None and apple_support.target_environment_from_rule_ctx(
        ctx,
        fail_on_missing_constraint = False,
    ) != None and apple_support.target_arch_from_rule_ctx(
        ctx,
        fail_on_missing_constraint = False,
    ) != None

def _clang_compile_flags(ctx, cc_toolchain, feature_configuration):
    compilation_context = ctx.attr.cc_lib[CcInfo].compilation_context
    clang_flags = normalize_msvc_compile_flags(ctx.attr.clang_flags)
    compile_variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        include_directories = compilation_context.includes,
        quote_include_directories = compilation_context.quote_includes,
        system_include_directories = depset(
            direct = cc_toolchain.built_in_include_directories,
            transitive = [
                compilation_context.system_includes,
                compilation_context.external_includes,
            ],
        ),
        user_compile_flags = ctx.attr.clang_flags,
    )
    compile_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )
    compile_flags = normalize_msvc_compile_flags(compile_flags)

    allowed_flag_prefixes = (
        "-fms-runtime-lib=",
        "-no-canonical-prefixes",
        "-nostdinc",
        "-nostdinc++",
        "-nostdlibinc",
        "-resource-dir=",
        "-std=",
        "--no-standard-includes",
    )
    xclang_flags_to_strip = (
        "-fno-cxx-modules",
        "-fexperimental-optimized-noescape",
        "-fmodule-map-file-home-is-cwd",
    )

    result = []
    copy_next = False
    skip_next = False
    for index, flag in enumerate(compile_flags):
        if skip_next:
            skip_next = False
            continue
        if copy_next:
            result.append(flag)
            copy_next = False
            continue
        if flag in clang_flags:
            result.append(flag)
            copy_next = flag in CLANG_PARAMETER_FLAGS
            continue
        if not flag.startswith(CLANG_PARAMETER_FLAGS + allowed_flag_prefixes):
            continue
        if flag == "-Xclang" and index + 1 < len(compile_flags) and compile_flags[index + 1] in xclang_flags_to_strip:
            skip_next = True
            continue

        result.append(flag)
        copy_next = flag in CLANG_PARAMETER_FLAGS

    for define in compilation_context.defines.to_list():
        result.append("-D" + define)

    return result

def _rust_bindgen_impl(ctx):
    header = ctx.file.header
    compilation_context = ctx.attr.cc_lib[CcInfo].compilation_context
    if header not in compilation_context.headers.to_list():
        fail("{} is not a transitive header of {}".format(ctx.attr.header.label, ctx.attr.cc_lib.label), "header")

    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + [
            "module_maps",
            "use_header_modules",
        ],
    )

    output = ctx.outputs.out
    args = ctx.actions.args()
    args.add("--no-include-path-detection")
    args.add("--formatter=none")
    args.add_all(ctx.attr.bindgen_flags)
    args.add(header)
    args.add("--output", output)
    args.add("--")
    args.add_all(_clang_compile_flags(ctx, cc_toolchain, feature_configuration))

    bindgen_toolchain = ctx.toolchains[_BINDGEN_TOOLCHAIN_TYPE]
    if _supports_apple_action(ctx, bindgen_toolchain):
        wrapper = ctx.actions.declare_file(ctx.label.name + "_apple_bindgen_wrapper.sh")
        ctx.actions.write(
            wrapper,
            """#!/bin/bash
set -euo pipefail

bindgen="$1"
shift

resource_dir="$(xcrun clang -print-resource-dir)"
exec "$bindgen" "$@" -resource-dir "$resource_dir"
""",
            is_executable = True,
        )

        bindgen_arg = ctx.actions.args()
        bindgen_arg.add(bindgen_toolchain.bindgen)

        apple_support.run(
            actions = ctx.actions,
            xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
            apple_platform_info = apple_support.platform_info_from_rule_ctx(ctx),
            xcode_path_resolve_level = apple_support.xcode_path_resolve_level.args_and_files,
            executable = wrapper,
            arguments = [bindgen_arg, args],
            inputs = compilation_context.headers,
            outputs = [output],
            tools = depset(
                [bindgen_toolchain.bindgen],
                transitive = [cc_toolchain.all_files],
            ),
            mnemonic = "RustBindgen",
            progress_message = "Generating Rust bindings for {}".format(header.short_path),
            toolchain = _BINDGEN_TOOLCHAIN_TYPE,
        )
        return

    ctx.actions.run(
        executable = bindgen_toolchain.bindgen,
        arguments = [args],
        inputs = compilation_context.headers,
        outputs = [output],
        tools = cc_toolchain.all_files,
        mnemonic = "RustBindgen",
        progress_message = "Generating Rust bindings for {}".format(header.short_path),
        toolchain = _BINDGEN_TOOLCHAIN_TYPE,
    )

rust_bindgen = rule(
    implementation = _rust_bindgen_impl,
    doc = "Generates Rust bindings for a C header with a hermetic bindgen executable.",
    attrs = ({
        "bindgen_flags": attr.string_list(
            doc = "Arguments passed to bindgen before the input header.",
        ),
        "cc_lib": attr.label(
            doc = "C library that provides the header and its transitive includes.",
            mandatory = True,
            providers = [CcInfo],
        ),
        "clang_flags": attr.string_list(
            doc = "Additional Clang arguments used to parse the header.",
        ),
        "header": attr.label(
            doc = "Header to generate bindings for.",
            allow_single_file = True,
            mandatory = True,
        ),
    } | apple_support.action_required_attrs() | apple_support.platform_constraint_attrs()),
    fragments = ["cpp"],
    outputs = {"out": "%{name}.rs"},
    toolchains = [_BINDGEN_TOOLCHAIN_TYPE] + use_cc_toolchain(),
)

def _rules_rust_bindgen_repo_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//rs/toolchains:declare_bindgen_toolchains.bzl", "declare_bindgen_toolchains")

declare_bindgen_toolchains()
""",
    )
    return rctx.repo_metadata(reproducible = True)

_rules_rust_bindgen_repo = repository_rule(
    implementation = _rules_rust_bindgen_repo_impl,
)

_toolchain = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
    },
)

def _rules_rust_bindgen_impl(mctx):
    for prebuilt in BINDGEN_PREBUILTS:
        http_archive(
            name = "rules_rust_bindgen_" + prebuilt.name,
            build_file_content = 'exports_files(["%s"])\n' % bindgen_binary_name(prebuilt.os),
            sha256 = prebuilt.sha256,
            url = "https://github.com/hermeticbuild/bindgen/releases/download/v0.0.2/bindgen_{}.tar.zst".format(prebuilt.name),
        )

    toolchain_repositories = {"rules_rust_bindgen": True}
    for module in mctx.modules:
        for toolchain in module.tags.toolchain:
            if toolchain.name in toolchain_repositories:
                fail("duplicate bindgen toolchain repository: {}".format(toolchain.name))
            toolchain_repositories[toolchain.name] = True

    for name in sorted(toolchain_repositories):
        _rules_rust_bindgen_repo(name = name)

    return mctx.extension_metadata(
        root_module_direct_deps = sorted(toolchain_repositories),
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_bindgen = module_extension(
    implementation = _rules_rust_bindgen_impl,
    tag_classes = {"toolchain": _toolchain},
)
