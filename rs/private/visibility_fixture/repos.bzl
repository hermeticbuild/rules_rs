"""Small generated Cargo repositories for visibility integration tests."""

load("//rs/private:repository_utils.bzl", "render_rust_crate_call", "rust_crate_attrs")
load("//rs/private:visibility.bzl", "visibility_for")

def _repo_impl(rctx):
    crate_name = "dependent" if rctx.attr.deps else "sample"
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

_repo = repository_rule(implementation = _repo_impl, attrs = rust_crate_attrs | {"macro": attr.bool()})

def _fixtures_impl(_mctx):
    internal = ["@visibility_dependent//:__pkg__"]
    settings = [struct(crates = ["*"], repositories = [], visibility = ["@rules_rs//rs/private/visibility_fixture/allowed:__pkg__"])]
    for name, macro in [("visibility_lib", False), ("visibility_macro", True), ("visibility_dependent", False)]:
        _repo(
            name = name,
            macro = macro,
            crate_visibility = visibility_for(settings, "fixtures", name, internal),
            deps = ["@visibility_lib//:sample"] if name == "visibility_dependent" else [],
        )

fixtures = module_extension(implementation = _fixtures_impl)
