"""Module extension that provisions the rules_rust repository."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

_patch = tag_class(
    doc = "Additional patches to apply to the pinned rules_rust archive.",
    attrs = {
        "patches": attr.label_list(
            doc = "Additional patch files to apply to rules_rust.",
        ),
        "strip": attr.int(
            doc = "Equivalent to adding `-pN` when applying `patches`.",
            default = 0,
        ),
    },
)

def _rules_rust_impl(mctx):
    patches = []
    strip_values = set()

    for mod in mctx.modules:
        for tag in mod.tags.patch:
            patches.extend(tag.patches)
            strip_values.add(tag.strip)

    if len(strip_values) > 1:
        fail("Found conflicting strip values in rules_rust.patch tags")

    strip = list(strip_values)[0] if strip_values else 0

    http_archive(
        name = "rules_rust",
        integrity = "sha256-HlMDBHp6cs2qM2B6HiIXUctf4WG/qWKVhm3Kilsmyto=",
        strip_prefix = "rules_rust-d11dcf615d6eddeb48d524d464563ca06c3b2a98",
        url = "https://github.com/hermeticbuild/rules_rust/releases/download/source-d11dcf615d6eddeb48d524d464563ca06c3b2a98/rules_rust-d11dcf615d6eddeb48d524d464563ca06c3b2a98.tar.gz",
        patches = patches,
        patch_strip = strip,
    )

    return mctx.extension_metadata(reproducible = True)

rules_rust = module_extension(
    implementation = _rules_rust_impl,
    tag_classes = {
        "patch": _patch,
    },
)
