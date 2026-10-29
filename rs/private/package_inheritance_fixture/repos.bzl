"""Real Git workspace fixtures for package inheritance (issue #273)."""

load("//rs/private:git_cargo_workspace_repository.bzl", "git_cargo_workspace_repository")
load("//rs/private:git_crate_metadata_repository.bzl", "git_crate_metadata_repository")

# name, workspace directory, member directory, README declaration, README file.
_CASES = [
    ("implicit", "a", "a/crates/member", "", "README.txt"),
    ("boolean", "b", "b/member", "readme = true\n", "README.md"),
    ("named", "c", "c/member", 'readme = "docs/README.md"\n', "docs/README.md"),
    ("sibling", "workspace", "sibling", "", "README"),
    ("same", "same", "same", "", "README.md"),
    ("disabled", "disabled", "disabled/member", "readme = true\n", "README.md"),
    ("invalid", "invalid", "invalid/member", "readme = false\n", "README.md"),
]

def _source_impl(rctx):
    for name, workspace, member, readme, readme_file in _CASES:
        member_path = member.removeprefix(workspace + "/") if member.startswith(workspace + "/") else "." if member == workspace else "../" + member
        workspace_manifest = """[workspace]
members = [%r]
resolver = "2"
[workspace.package]
version = "1.2.3"
edition = "2021"
authors = [%r]
rust-version = "1.85"
license-file = "LICENSE"
%s""" % (member_path, name, readme)
        package_manifest = """[package]
name = "%s"
version.workspace = true
edition.workspace = true
authors.workspace = true
rust-version.workspace = true
license-file.workspace = true
%s
# These fields are not consumed by rules_rs and must not cause fetch failures.
categories.workspace = true
documentation.workspace = true
exclude.workspace = true
include.workspace = true
keywords.workspace = true
publish.workspace = true
""" % (name, "readme = false" if name == "disabled" else "readme.workspace = true")
        if name == "sibling":
            package_manifest += 'workspace = "../workspace"\n'
        if member == workspace:
            rctx.file(workspace + "/Cargo.toml", workspace_manifest + package_manifest)
        else:
            rctx.file(workspace + "/Cargo.toml", workspace_manifest)
            rctx.file(member + "/Cargo.toml", package_manifest)
        rctx.file(workspace + "/" + readme_file, name + " readme\n")
        rctx.file(workspace + "/LICENSE", name + " license\n")
        rctx.file(workspace + "/docs/BUILD.bazel", "# A nested Bazel package must not hide inherited files.\n")
        rctx.template(member + "/build.rs", Label("//rs/private/package_inheritance_fixture:build.rs"), executable = False)
        rctx.template(member + "/src/lib.rs", Label("//rs/private/package_inheritance_fixture:lib.rs"), substitutions = {
            "README_CONTENT": '""' if name == "disabled" else 'include_str!(concat!("../", env!("CARGO_PKG_README")))',
        }, executable = False)

    git = rctx.which("git")
    if not git:
        fail("The Git workspace inheritance fixture requires git")
    for arguments in [
        ["-c", "init.templateDir=", "init", "-q"],
        ["-c", "core.autocrlf=false", "add", "."],
        ["-c", "user.name=rules_rs fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
    ]:
        result = rctx.execute([git] + arguments, environment = {
            "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
        })
        if result.return_code:
            fail(result.stderr)
    result = rctx.execute([git, "rev-parse", "HEAD"])
    if result.return_code:
        fail(result.stderr)
    rctx.file("commit", result.stdout)
    rctx.file("BUILD.bazel", 'exports_files(["commit", "a/LICENSE"])\n')

inheritance_source = repository_rule(implementation = _source_impl)

def _hub_impl(rctx):
    rctx.file("defs.bzl", "RESOLVED_PLATFORMS = []\n")
    rctx.file("BUILD.bazel", 'exports_files(["defs.bzl"])\n')

_hub = repository_rule(implementation = _hub_impl)

def _fixtures_impl(mctx):
    commit_file = mctx.path(Label("@inheritance_source//:commit"))
    commit = mctx.read(commit_file).strip()
    _hub(name = "inheritance_hub")
    for name, _workspace, _member, _readme, _readme_file in _CASES:
        git_crate_metadata_repository(
            name = "inheritance_hub__%s-1.2.3" % name,
            hub_name = "inheritance_hub",
            package_name = name,
            package_version = "1.2.3",
            purl = "pkg:cargo/%s@1.2.3" % name,
        )
    for name, invalid in [("inheritance_checkout", False), ("inheritance_invalid", True)]:
        members = {member + "/BUILD.bazel": workspace + "/Cargo.toml" for case, workspace, member, _readme, _file in _CASES if (case == "invalid") == invalid}
        git_cargo_workspace_repository(
            name = name,
            remote = str(commit_file.dirname),
            commit = commit,
            hub_name = "inheritance_hub",
            build_files = {member: "" for member in members},
            workspace_cargo_tomls = members,
        )

fixtures = module_extension(implementation = _fixtures_impl)
