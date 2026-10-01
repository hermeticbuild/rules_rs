"""AWS-LC FIPS 3.1.0 integration for aws-lc-fips-sys 0.13.11.

Uses the crate's shipped bindings and prefix headers. Only the native sys build
script is replaced; aws-lc-rs keeps its upstream checks and metadata forwarding.
"""

load("@bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_rust//rust/private:providers.bzl", "BuildInfo")

# Matches builder/main.rs and the configuration of FIPS 3.1.0.
_CONF = [
    "OPENSSL_NO_ASYNC",
    "OPENSSL_NO_BF",
    "OPENSSL_NO_BLAKE2",
    "OPENSSL_NO_BUF_FREELISTS",
    "OPENSSL_NO_CAMELLIA",
    "OPENSSL_NO_CAPIENG",
    "OPENSSL_NO_CAST",
    "OPENSSL_NO_CMS",
    "OPENSSL_NO_COMP",
    "OPENSSL_NO_CT",
    "OPENSSL_NO_DANE",
    "OPENSSL_NO_DEPRECATED",
    "OPENSSL_NO_DGRAM",
    "OPENSSL_NO_DYNAMIC_ENGINE",
    "OPENSSL_NO_EC_NISTP_64_GCC_128",
    "OPENSSL_NO_EC2M",
    "OPENSSL_NO_EGD",
    "OPENSSL_NO_ENGINE",
    "OPENSSL_NO_GMP",
    "OPENSSL_NO_GOST",
    "OPENSSL_NO_HEARTBEATS",
    "OPENSSL_NO_HW",
    "OPENSSL_NO_IDEA",
    "OPENSSL_NO_JPAKE",
    "OPENSSL_NO_KRB5",
    "OPENSSL_NO_MD2",
    "OPENSSL_NO_MDC2",
    "OPENSSL_NO_OCB",
    "OPENSSL_NO_OCSP",
    "OPENSSL_NO_RC2",
    "OPENSSL_NO_RC5",
    "OPENSSL_NO_RFC3779",
    "OPENSSL_NO_RIPEMD",
    "OPENSSL_NO_RMD160",
    "OPENSSL_NO_SCTP",
    "OPENSSL_NO_SEED",
    "OPENSSL_NO_SM2",
    "OPENSSL_NO_SM3",
    "OPENSSL_NO_SM4",
    "OPENSSL_NO_SRP",
    "OPENSSL_NO_SSL_TRACE",
    "OPENSSL_NO_SSL2",
    "OPENSSL_NO_SSL3",
    "OPENSSL_NO_SSL3_METHOD",
    "OPENSSL_NO_STATIC_ENGINE",
    "OPENSSL_NO_STORE",
    "OPENSSL_NO_WHIRLPOOL",
]

_PLATFORMS = {
    "@rules_rs//rs/platforms/config:x86_64-unknown-linux-gnu": "x86_64_unknown_linux_gnu",
    "@rules_rs//rs/platforms/config:aarch64-unknown-linux-gnu": "aarch64_unknown_linux_gnu",
}

def _build_info_impl(ctx):
    headers = ctx.file.headers
    flags = ctx.actions.declare_file(ctx.label.name + ".flags")
    ctx.actions.write(flags, "--cfg=" + ctx.attr.platform + "\n")
    dep_env = ctx.actions.declare_file(ctx.label.name + ".depenv")
    prefix = "DEP_" + ctx.attr.links.upper() + "_"
    ctx.actions.write(dep_env, "\n".join([
        prefix + "INCLUDE=${pwd}/" + headers.path,
        prefix + "LIBCRYPTO=" + ctx.attr.crypto_name,
        prefix + "CONF=" + ",".join(_CONF),
    ]) + "\n")
    return [
        BuildInfo(
            compile_data = depset([headers]),
            dep_env = dep_env,
            flags = flags,
            linker_flags = None,
            link_search_paths = None,
            out_dir = headers,
            rustc_env = None,
        ),
        ctx.attr.wrapper[CcInfo],
    ]

_build_info = rule(
    implementation = _build_info_impl,
    attrs = {
        "headers": attr.label(allow_single_file = True, mandatory = True),
        "wrapper": attr.label(providers = [CcInfo], mandatory = True),
        "platform": attr.string(mandatory = True),
        "links": attr.string(mandatory = True),
        "crypto_name": attr.string(mandatory = True),
    },
)

def aws_lc_fips_sys(name, version, crypto, headers):
    """Supplies native dependencies, platform cfg, and Cargo metadata.

    Args:
      name: BuildInfo target added to the sys crate dependencies.
      version: Rust sys crate version; determines its symbol namespace.
      crypto: Matching prefixed native crypto library.
      headers: Matching prefixed public header target.
    """
    if version != "0.13.11":
        fail("This adapter is verified for aws-lc-fips-sys 0.13.11 with AWS-LC FIPS 3.1.0")
    prefix = "aws_lc_fips_" + version.replace(".", "_")
    cc_library(
        name = name + "_wrapper",
        srcs = ["rust_wrapper.c"],
        hdrs = ["include/rust_wrapper.h"],
        includes = ["include"],
        deps = [crypto],
    )
    copy_to_directory(
        name = name + "_headers",
        srcs = [headers],
        root_paths = ["**/include"],
    )
    _build_info(
        name = name,
        headers = ":" + name + "_headers",
        wrapper = ":" + name + "_wrapper",
        platform = select({label: platform for label, platform in _PLATFORMS.items()}),
        links = prefix,
        crypto_name = crypto.split(":")[-1],
        visibility = ["//visibility:public"],
    )
