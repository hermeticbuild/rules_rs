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

load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "CPP_COMPILE_ACTION_NAME")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//rs/toolchains:declare_bindgen_toolchains.bzl", "BINDGEN_PREBUILTS", "bindgen_binary_name")

_BINDGEN_TOOLCHAIN_TYPE = Label("//rs:bindgen_toolchain_type")

def _resource_dir(cc_toolchain):
    files = cc_toolchain.all_files.to_list()

    # Clang toolchains can expose the resource headers as one directory artifact.
    for file in files:
        parts = file.path.split("/")
        if len(parts) >= 4 and parts[-4] == "lib" and parts[-3] == "clang" and parts[-1] == "include":
            return "/".join(parts[:-1])

    # Other Clang toolchains expose the resource headers as individual files.
    # Do not use a C library's stdbool.h: its parent is not a Clang resource dir.
    for file in files:
        if file.basename != "stdbool.h":
            continue

        parts = file.path.split("/")
        if len(parts) >= 5 and parts[-5] == "lib" and parts[-4] == "clang" and parts[-2] == "include":
            return "/".join(parts[:-2])

    return None

def _normalize_msvc_compile_flags(compile_flags):
    """Converts clang-cl preprocessing flags to Clang driver flags."""
    prefixes = (
        ("/external:I", "-isystem"),
        ("/imsvc", "-isystem"),
        ("/FI", "-include"),
        ("/D", "-D"),
        ("/U", "-U"),
        ("/I", "-I"),
    )

    result = []
    for original_flag in compile_flags:
        flag = original_flag
        if flag.startswith("/clang:"):
            flag = flag[len("/clang:"):]

        normalized = False
        for prefix, replacement in prefixes:
            if flag == prefix:
                result.append(replacement)
                normalized = True
                break
            if flag.startswith(prefix):
                result.extend([replacement, flag[len(prefix):]])
                normalized = True
                break

        if not normalized:
            result.append(flag)

    return result

def _clang_compile_flags(ctx, cc_toolchain, feature_configuration):
    compilation_context = ctx.attr.cc_lib[CcInfo].compilation_context
    clang_flags = _normalize_msvc_compile_flags(ctx.attr.clang_flags)
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
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )
    compile_flags = _normalize_msvc_compile_flags(compile_flags)

    parameter_flags = (
        "-D",
        "-F",
        "-I",
        "-U",
        "-Xclang",
        "-idirafter",
        "-iframework",
        "-imacros",
        "-include",
        "-iquote",
        "-isystem",
        "-isysroot",
        "-target",
        "--gcc-toolchain",
        "--no-system-header-prefix",
        "--sysroot",
        "--system-header-prefix",
        "--target",
    )
    parameterless_flags = (
        "-no-canonical-prefixes",
        "-nostdinc",
        "-nostdinc++",
        "-nostdlibinc",
        "--no-standard-includes",
    )
    xclang_flags_to_strip = (
        "-fexperimental-optimized-noescape",
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
            copy_next = flag in parameter_flags
            continue
        if not flag.startswith(parameter_flags) and flag not in parameterless_flags:
            continue
        if flag == "-Xclang" and index + 1 < len(compile_flags) and compile_flags[index + 1] in xclang_flags_to_strip:
            skip_next = True
            continue

        result.append(flag)
        copy_next = flag in parameter_flags

    for define in compilation_context.defines.to_list():
        result.append("-D" + define)

    resource_dir = _resource_dir(cc_toolchain)
    if resource_dir:
        result.append("-resource-dir=" + resource_dir)

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
    doc = "Generates Rust bindings for a C/C++ header with a hermetic bindgen executable.",
    attrs = {
        "bindgen_flags": attr.string_list(
            doc = "Arguments passed to bindgen before the input header.",
        ),
        "cc_lib": attr.label(
            doc = "C/C++ library that provides the header and its transitive includes.",
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
    },
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

def _rules_rust_bindgen_impl(mctx):
    for prebuilt in BINDGEN_PREBUILTS:
        http_archive(
            name = "rules_rust_bindgen_" + prebuilt.name,
            build_file_content = 'exports_files(["%s"])\n' % bindgen_binary_name(prebuilt.os),
            sha256 = prebuilt.sha256,
            url = "https://github.com/hermeticbuild/bindgen/releases/download/v0.0.2/bindgen_{}.tar.zst".format(prebuilt.name),
        )

    _rules_rust_bindgen_repo(name = "rules_rust_bindgen")

    return mctx.extension_metadata(
        root_module_direct_deps = ["rules_rust_bindgen"],
        root_module_direct_dev_deps = [],
        reproducible = True,
    )

rules_rust_bindgen = module_extension(
    implementation = _rules_rust_bindgen_impl,
)
