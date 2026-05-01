load(":repository_utils.bzl", "render_rust_crate_call", "rust_crate_attrs")

def _git_crate_metadata_repository_implementation(rctx):
    rctx.file("crate.bzl", """\
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
load("@{hub_name}//:defs.bzl", "RESOLVED_PLATFORMS")

def crate(
        crate_name,
        crate_root,
        edition,
        links,
        build_script,
        is_proc_macro,
        binaries,
        package_metadata_bazel_deps):
{rust_crate_call}""".format(
        hub_name = rctx.attr.hub_name,
        rust_crate_call = render_rust_crate_call(
            rctx.attr,
            # These values are emitted as Starlark source. The bare names refer
            # to this wrapper macro's parameters; repr(...) values are constants
            # known from resolution.
            dict(
                binaries = "binaries",
                build_script = "None" if rctx.attr.gen_build_script == "off" else "build_script",
                crate_name = "crate_name",
                crate_root = "crate_root",
                edition = "edition",
                is_proc_macro = "is_proc_macro",
                links = "links",
                name = repr(rctx.attr.package_name),
                purl = repr(rctx.attr.purl),
                version = repr(rctx.attr.package_version),
            ),
            extra_deps = "package_metadata_bazel_deps",
            indent = "    ",
        ),
    ))

    rctx.file("BUILD.bazel", 'exports_files(["crate.bzl"])')
    return rctx.repo_metadata(reproducible = True)

git_crate_metadata_repository = repository_rule(
    implementation = _git_crate_metadata_repository_implementation,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "package_version": attr.string(mandatory = True),
        "purl": attr.string(mandatory = True),
    } | rust_crate_attrs,
)
