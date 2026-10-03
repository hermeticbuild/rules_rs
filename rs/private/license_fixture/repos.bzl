"""Exercise registry rendering and post-checkout Git workspace rendering."""

load("//rs/private:git_cargo_workspace_repository.bzl", "render_crate_build_file")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")
load("//rs/private:repository_utils.bzl", "cargo_build_file_values", "common_attrs", "render_build_file_content")

_EXPRESSION = "(MIT OR Apache-2.0) AND BSD-3-Clause"

def _registry_impl(rctx):
    for name, fields in {
        "expression": {"license": _EXPRESSION},
        "file": {"license-file": "legal/LICENSE"},
        "both": {"license": _EXPRESSION, "license-file": "legal/LICENSE"},
        "absent": {},
    }.items():
        rctx.file(name + "/Cargo.toml", "[package]\nname = %r\nversion = '0.1.0'\n" % name)
        rctx.file(name + "/legal/LICENSE", "Example license text.\n")
        cargo = cargo_build_file_values(rctx, {"package": dict(fields, name = name, version = "0.1.0")}, [], package_path = name)
        values = dict(cargo.values, name = repr(name), purl = repr("pkg:cargo/%s@0.1.0" % name), version = repr("0.1.0"))
        content = render_build_file_content(rctx, rctx.attr, values)

        # Public fixture targets allow tests to inspect the license attribute.
        rctx.file(name + "/BUILD.bazel", content + '\npackage(default_visibility = ["//visibility:public"])\nexports_files(glob(["*", "legal/*"]))\n')
    rctx.file("BUILD.bazel", "")

_registry = repository_rule(implementation = _registry_impl, attrs = common_attrs)

def _checkout_impl(rctx):
    rctx.file("Cargo.toml", '[workspace]\nmembers = ["crates/member"]\n[workspace.package]\nlicense = "MIT OR Apache-2.0"\nlicense-file = "LICENSE"\n')
    rctx.file("LICENSE", "Workspace license text.\n")
    rctx.file("BUILD.bazel", 'exports_files(["LICENSE"])\n')
    rctx.file("crates/member/Cargo.toml", '[package]\nname = "member"\nversion = "0.1.0"\nlicense.workspace = true\nlicense-file.workspace = true\n')
    render_crate_build_file(
        rctx,
        "crates/member/BUILD.bazel",
        '\npackage(default_visibility = ["//visibility:public"])\nexports_files(["__rules_rs_cargo_license.txt"])\n',
        [],
        {"workspace": {"package": {"license": "MIT OR Apache-2.0", "license-file": "LICENSE"}}},
    )

_checkout = repository_rule(implementation = _checkout_impl, attrs = {"hub_name": attr.string(), "workspace_cargo_toml": attr.string(default = "Cargo.toml")})

def _hub_impl(rctx):
    rctx.file("defs.bzl", "RESOLVED_PLATFORMS = []\n")
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])\n')

_hub = repository_rule(implementation = _hub_impl)

def _fixtures_impl(_mctx):
    _hub(name = "license_hub")
    _registry(name = "license_registry", hub_name = "license_hub")
    git_crate_metadata_repository(name = "license_hub__member-0.1.0", hub_name = "license_hub", package_name = "member", package_version = "0.1.0", purl = "pkg:cargo/member@0.1.0")
    _checkout(name = "license_checkout", hub_name = "license_hub")

fixtures = module_extension(implementation = _fixtures_impl)
