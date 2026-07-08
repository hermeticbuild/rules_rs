"""Declares toolchains for the self-contained bindgen prebuilts."""

BINDGEN_PREBUILTS = [
    struct(
        name = "darwin_amd64",
        cpu = "x86_64",
        os = "macos",
        sha256 = "9effe0323d0441d6f541497e0590b970beb15b9104c7e034ac4557942202f869",
    ),
    struct(
        name = "darwin_arm64",
        cpu = "aarch64",
        os = "macos",
        sha256 = "456ab5235685c498455ddc2fafeba32eb1d93758346e585e8da5e09c19cc680c",
    ),
    struct(
        name = "linux_amd64",
        cpu = "x86_64",
        os = "linux",
        sha256 = "ec2b39a56443142a34dc76ec32a17cb099c6c09137c3fbac893310c623cb10ac",
    ),
    struct(
        name = "linux_arm64",
        cpu = "aarch64",
        os = "linux",
        sha256 = "d4da684d021d1ebf40bb3819c1521c96c3ca51d22d911ee71731a358bd768594",
    ),
    struct(
        name = "windows_amd64",
        cpu = "x86_64",
        os = "windows",
        sha256 = "beede8f802ab96a2cce0de84c560150dcbc89c96db94f7c17519dd164ac983fd",
    ),
    struct(
        name = "windows_arm64",
        cpu = "aarch64",
        os = "windows",
        sha256 = "0885047b40b119e58fcca4491a2bd00331de131f41183de2a9b563ca407f9109",
    ),
]

def bindgen_binary_name(os):
    return "bindgen.exe" if os == "windows" else "bindgen"

def _bindgen_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(bindgen = ctx.executable.bindgen)]

_bindgen_toolchain = rule(
    implementation = _bindgen_toolchain_impl,
    attrs = {
        "bindgen": attr.label(
            allow_single_file = True,
            cfg = "exec",
            executable = True,
            mandatory = True,
        ),
    },
)

def declare_bindgen_toolchains():
    """Declares one toolchain for each bindgen prebuilt."""
    for prebuilt in BINDGEN_PREBUILTS:
        _bindgen_toolchain(
            name = prebuilt.name + "_impl",
            bindgen = "@rules_rust_bindgen_{}//:{}".format(prebuilt.name, bindgen_binary_name(prebuilt.os)),
        )

        native.toolchain(
            name = prebuilt.name,
            exec_compatible_with = [
                "@platforms//cpu:" + prebuilt.cpu,
                "@platforms//os:" + prebuilt.os,
            ],
            toolchain = prebuilt.name + "_impl",
            toolchain_type = "@rules_rs//rs:bindgen_toolchain_type",
            visibility = ["//visibility:public"],
        )
