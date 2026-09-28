"""Repository fixtures for the post-checkout Git workspace generation path."""

load("//rs/private:git_cargo_workspace_repository.bzl", "render_crate_build_file")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")
load("//rs/private:git_workspace_resources.bzl", "declare_workspace_resources", "workspace_resource_build_files")

def _checkout_impl(rctx):
    rctx.file("Cargo.toml", '[workspace]\nmembers = ["member"]\n')
    rctx.file("BUILD", 'filegroup(name = "authored_root", srcs = ["root.txt"], visibility = ["//visibility:public"])\n')
    rctx.file("root.txt", "root")
    rctx.file("shared/BUILD.bazel", 'filegroup(name = "authored_shared", visibility = ["//visibility:public"])\n')
    rctx.file("shared/schema.txt", "schema")
    rctx.file("shared/nested/BUILD", 'filegroup(name = "authored_nested", visibility = ["//visibility:public"])\n')
    rctx.file("shared/nested/data.txt", "nested")
    rctx.symlink(rctx.path("shared"), "alias")
    rctx.file("member/Cargo.toml", '[package]\nname = "member"\nversion = "0.1.0"\nedition = "2021"\n')
    rctx.file("member/BUILD", 'filegroup(name = "authored_member", visibility = ["//visibility:public"])\n')
    rctx.file("member/src/lib.rs", """pub const ROOT: &str = include_str!("../../root.txt");
pub const SHARED: &str = include_str!("../../shared/schema.txt");
pub const NESTED: &str = include_str!("../../shared/nested/data.txt");
pub const LINK: &str = include_str!("../../alias/schema.txt");
""")
    files = workspace_resource_build_files(rctx.path("."), ["member/BUILD.bazel"])
    render_crate_build_file(rctx, "member/BUILD.bazel", "", [], {"workspace": {}})
    declare_workspace_resources(rctx, files)

_checkout = repository_rule(implementation = _checkout_impl, attrs = {"hub_name": attr.string()})

def _hub_impl(rctx):
    rctx.file("defs.bzl", "RESOLVED_PLATFORMS = []\n")
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])\n')

_hub = repository_rule(implementation = _hub_impl)

def _fixtures_impl(_mctx):
    _hub(name = "resource_hub")
    git_crate_metadata_repository(name = "resource_hub__member-0.1.0", hub_name = "resource_hub", package_name = "member", package_version = "0.1.0", purl = "pkg:cargo/member@0.1.0")
    _checkout(name = "resource_checkout", hub_name = "resource_hub")

fixtures = module_extension(implementation = _fixtures_impl)
