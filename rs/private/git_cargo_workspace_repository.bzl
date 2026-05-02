load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":repository_utils.bzl", "cargo_build_file_values")
load(":toml2json.bzl", "run_toml2json")

_INHERITABLE_FIELDS = [
    "version",
    "edition",
    "description",
    "homepage",
    "repository",
    "license",
    # TODO(zbarsky): Do we need to fixup the path for readme and license_file?
    "license_file",
    "rust_version",
    "readme",
]

def _inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml):
    workspace_package = workspace_cargo_toml.get("workspace", {}).get("package")
    if not workspace_package:
        return cargo_toml

    crate_package = cargo_toml["package"]
    for field in _INHERITABLE_FIELDS:
        value = crate_package.get(field)
        if type(value) == "dict" and value.get("workspace") == True:
            crate_package[field] = workspace_package.get(field)

    return cargo_toml

def _render_label_list(labels):
    return ",\n        ".join(['"%s"' % label for label in sorted(labels)])

def _spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def _render_build_file(rctx, dest, additive_build_file_content, gen_binaries, workspace_cargo_toml):
    package_path = rctx.path(dest).dirname
    cargo_toml_path = package_path.get_child("Cargo.toml")
    cargo_toml = run_toml2json(rctx, cargo_toml_path)
    cargo_toml = _inherit_workspace_package_fields(cargo_toml, workspace_cargo_toml)
    package = cargo_toml["package"]

    cargo = cargo_build_file_values(
        rctx,
        cargo_toml,
        gen_binaries,
        gen_build_script = "on",
        package_path = package_path,
    )

    rctx.file(dest, """\
load("@rules_rs//rs:rust_crate.bzl", "rust_crate")
load("@rules_rs//rs:rust_binary.bzl", "rust_binary")
load("{crate_bzl}", "crate")

crate(
    crate_name = {crate_name},
    crate_root = {crate_root},
    edition = {edition},
    links = {links},
    build_script = {build_script},
    is_proc_macro = {is_proc_macro},
    binaries = {binaries},
    package_metadata_bazel_deps = [
        {package_metadata_bazel_deps}
    ],
)
{additive_build_file_content}{package_metadata_bazel_additive_build_file_content}""".format(
        crate_bzl = "@%s//:crate.bzl" % _spoke_repo(rctx.attr.hub_name, package["name"], package["version"]),
        crate_name = cargo.values["crate_name"],
        crate_root = cargo.values["crate_root"],
        edition = cargo.values["edition"],
        links = cargo.values["links"],
        build_script = cargo.values["build_script"],
        is_proc_macro = cargo.values["is_proc_macro"],
        binaries = cargo.values["binaries"],
        package_metadata_bazel_deps = _render_label_list(cargo.bazel_metadata.get("deps", [])),
        additive_build_file_content = additive_build_file_content,
        package_metadata_bazel_additive_build_file_content = cargo.bazel_metadata.get("additive_build_file_content", ""),
    ))

def _git_cargo_workspace_repository_impl(rctx):
    git_repo(rctx, rctx.path("."))

    patch(rctx)
    rctx.delete(rctx.path(".git"))

    workspace_cargo_toml = run_toml2json(rctx, rctx.attr.workspace_cargo_toml)
    for dest, additive_build_file_content in rctx.attr.build_files.items():
        _render_build_file(rctx, dest, additive_build_file_content, rctx.attr.gen_binaries.get(dest, []), workspace_cargo_toml)

    return rctx.repo_metadata(reproducible = True)

git_cargo_workspace_repository = repository_rule(
    implementation = _git_cargo_workspace_repository_impl,
    attrs = {
        "remote": attr.string(mandatory = True),
        "commit": attr.string(mandatory = True),
        "hub_name": attr.string(mandatory = True),
        "shallow_since": attr.string(),
        "init_submodules": attr.bool(default = True),
        "build_files": attr.string_dict(mandatory = True),
        "gen_binaries": attr.string_list_dict(default = {}),
        "workspace_cargo_toml": attr.string(default = "Cargo.toml"),
        "patch_args": attr.string_list(default = []),
        "patches": attr.label_list(default = []),
        "patch_strip": attr.int(default = 0),
        "patch_tool": attr.string(default = ""),
        "recursive_init_submodules": attr.bool(default = True),
        "verbose": attr.bool(default = False),
    },
)
