"""Small generated Cargo repositories for visibility integration tests."""

load("@rules_rs//rs/private:repository_utils.bzl", "render_rust_crate_call", "rust_crate_attrs")
load("@rules_rs//rs/private:visibility.bzl", "visibility_with_internal_access")

def _repo_impl(rctx):
    crate_name = "dependent" if rctx.attr.deps else rctx.attr.crate_name
    rctx.file("Cargo.toml", "[package]\nname = 'sample'\nversion = '1.0.0'\nedition = '2021'\n")
    rctx.file("cargo_toml_env_vars.env", "")
    rctx.file("lib.rs", "extern crate proc_macro;\n" if rctx.attr.macro else "pub fn value() -> u8 { 1 }\n")
    rctx.file("main.rs", "fn main() {}\n")
    rctx.file("BUILD.bazel", """load("@rules_rs//rs/private:rust_crate.bzl", "rust_crate")
RESOLVED_PLATFORMS = []
""" + render_rust_crate_call(rctx.attr, {
        "name": repr(crate_name),
        "crate_name": repr(crate_name),
        "purl": repr("pkg:cargo/sample@1.0.0"),
        "version": repr("1.0.0"),
        "binaries": repr({} if rctx.attr.macro else {"probe": "main.rs"}),
        "build_script": "None",
        "crate_root": repr("lib.rs"),
        "edition": repr("2021"),
        "has_lib": "True",
        "is_proc_macro": repr(rctx.attr.macro),
        "links": "None",
    }))

_repo = repository_rule(implementation = _repo_impl, attrs = rust_crate_attrs | {"macro": attr.bool(), "crate_name": attr.string(default = "sample")})

def _groups_impl(rctx):
    rctx.file("BUILD.bazel", "package_group(name = 'consumers', includes = %r)" % [str(rctx.attr.consumers)])

_groups = repository_rule(
    implementation = _groups_impl,
    attrs = {"consumers": attr.label()},
)

def _fixtures_impl(_mctx):
    _groups(name = "visibility_groups", consumers = Label("//visibility:consumers"))
    internal = ["@visibility_dependent//:__pkg__"]
    for name, visibility in [
        ("visibility_lib", [Label("//visibility/allowed:__pkg__")]),
        ("visibility_macro", [Label("//visibility/allowed:__subpackages__")]),
        ("visibility_dependent", [Label("//visibility/allowed:__pkg__")]),
        ("visibility_private", [Label("//visibility:private")]),
        ("visibility_empty", []),
    ]:
        _repo(
            name = name,
            macro = name == "visibility_macro",
            crate_name = name if name in ["visibility_private", "visibility_empty"] else "sample",
            crate_visibility = visibility_with_internal_access(visibility, internal),
            deps = ["@visibility_lib//:sample", "@visibility_private//:visibility_private", "@visibility_empty//:visibility_empty"] if name == "visibility_dependent" else [],
        )
    _repo(name = "visibility_public")

fixtures = module_extension(implementation = _fixtures_impl)
