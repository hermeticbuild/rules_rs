"""Module extension that provisions the rules_rust repository."""

load("@bazel_tools//tools/build_defs/repo:cache.bzl", "get_default_canonical_id")

_RULES_RUST_INTEGRITY = "sha256-9/b8Uw9qlq0bVR4d9aRz2bWNj8seU3pf3fJBSAPmMMM="
_RULES_RUST_STRIP_PREFIX = "rules_rust-2c5990eb8381bc4a9f9c764d97cb541974c480ff"
_RULES_RUST_URL = "https://github.com/hermeticbuild/rules_rust/archive/2c5990eb8381bc4a9f9c764d97cb541974c480ff.tar.gz"

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

def _rules_rust_repository_impl(rctx):
    rctx.download_and_extract(
        url = _RULES_RUST_URL,
        canonical_id = get_default_canonical_id(rctx, [_RULES_RUST_URL]),
        integrity = _RULES_RUST_INTEGRITY,
        strip_prefix = _RULES_RUST_STRIP_PREFIX,
    )

    for patch in rctx.attr.bundled_patches:
        rctx.patch(patch, strip = rctx.attr.bundled_patch_strip)
    for patch in rctx.attr.patches:
        rctx.patch(patch, strip = rctx.attr.patch_strip)

    return rctx.repo_metadata(reproducible = True)

_rules_rust_repository = repository_rule(
    implementation = _rules_rust_repository_impl,
    attrs = {
        "bundled_patches": attr.label_list(),
        "bundled_patch_strip": attr.int(),
        "patches": attr.label_list(),
        "patch_strip": attr.int(),
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

    _rules_rust_repository(
        name = "rules_rust",
        # Remove this patch once the pinned revision contains
        # https://github.com/hermeticbuild/rules_rust/pull/33.
        bundled_patches = [Label("//rs:rustc_srcs_provider.patch")],
        bundled_patch_strip = 1,
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
