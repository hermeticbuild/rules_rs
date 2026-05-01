load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")
load(":repository_utils.bzl", "common_attrs", "generate_build_file")
load(":symlink_utils.bzl", "relative_symlink")
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

def source_to_vcs_url(source):
    # source is expected to have a field/attribute "repr"
    url = source
    if not url.startswith("git+"):
        fail("expected source.repr to start with 'git+': %r" % url)

    q = url.find("?")  # -1 if not found
    f = url.find("#")  # -1 if not found

    has_q = (q != -1)
    has_f = (f != -1)

    # Has both query params and commit hash: strip query, keep commit as @
    if has_q and has_f:
        base = url[:q]
        commit = url[f + 1:]
        return "%s@%s" % (base, commit)

    # No query params, has commit hash: just replace # with @
    if (not has_q) and has_f:
        return url.replace("#", "@")

    # Has query params but no commit hash: extract the ref value as @
    if has_q and (not has_f):
        base = url[:q]
        query = url[q + 1:]

        ref_value = None
        for param in query.split("&"):
            for prefix in ["branch=", "tag=", "rev="]:
                if param.startswith(prefix):
                    ref_value = param[len(prefix):]
                    break
            if ref_value != None:
                break

        if ref_value == None:
            ref_value = query

        return "%s@%s" % (base, ref_value)

    # No query params, no commit hash: return as-is
    return url

def _crate_git_repository_implementation(rctx):
    strip_prefix = rctx.attr.strip_prefix

    repo_dir = rctx.path(rctx.attr.git_repo_label).dirname

    root = rctx.path(".")
    dest_dir = root.get_child(".tmp_git_root") if strip_prefix else root

    result = rctx.execute([
        "git",
        "--git-dir=" + str(repo_dir.get_child(".git")),
        "worktree",
        "add",
        str(dest_dir),
        "--force",
        "--force",
        "--detach",
        "HEAD",
    ])
    if result.return_code != 0:
        fail(result.stderr)

    # Recursively check out git submodules to match Cargo's git-dependency
    # behavior. Cargo always recurses submodules for git sources, so a crate
    # whose source includes submodules (e.g. khronos_api, which vendors the
    # KhronosGroup/WebGL extensions registry as a submodule) would otherwise
    # build under Cargo but silently produce empty source trees here.
    # No-op when the worktree has no .gitmodules file.
    submodule_paths = []
    if dest_dir.get_child(".gitmodules").exists:
        result = rctx.execute([
            "git",
            "-C",
            str(dest_dir),
            "submodule",
            "update",
            "--init",
            "--recursive",
        ])
        if result.return_code != 0:
            fail("failed to initialize submodules: " + result.stderr)

        # Collect submodule paths so their gitlink files can be removed below
        # for reproducibility. Each submodule's `.git` is a file pointing at
        # the superproject's modules dir, which contains machine-specific
        # absolute paths.
        result = rctx.execute([
            "git",
            "-C",
            str(dest_dir),
            "submodule",
            "foreach",
            "--recursive",
            "--quiet",
            "echo $displaypath",
        ])
        if result.return_code != 0:
            fail("failed to enumerate submodules: " + result.stderr)
        for line in result.stdout.split("\n"):
            line = line.strip()
            if line:
                submodule_paths.append(line)

    if strip_prefix:
        dest_link = dest_dir.get_child(strip_prefix)
        if not dest_link.exists:
            fail("strip_prefix at {} does not exist in repo".format(strip_prefix))
        for item in dest_link.readdir():
            relative_symlink(rctx, item, root.get_child(item.basename))

    patch(rctx)

    cargo_toml = run_toml2json(rctx, "Cargo.toml")

    if strip_prefix:
        workspace_cargo_toml_path = repo_dir.get_child(rctx.attr.workspace_cargo_toml)
    else:
        workspace_cargo_toml_path = rctx.path(rctx.attr.workspace_cargo_toml)
    workspace_cargo_toml = run_toml2json(rctx, workspace_cargo_toml_path)
    workspace_package = workspace_cargo_toml.get("workspace", {}).get("package")
    if workspace_package:
        crate_package = cargo_toml["package"]
        for field in _INHERITABLE_FIELDS:
            value = crate_package.get(field)
            if type(value) == "dict" and value.get("workspace") == True:
                crate_package[field] = workspace_package.get(field)

    vcs_url = source_to_vcs_url(rctx.attr.remote)

    rctx.file("BUILD.bazel", generate_build_file(rctx, cargo_toml, purl_qualifiers = {"vcs_url": vcs_url}))

    # Since we're using `git` to download the repo, remove the `.git` (and any
    # submodule gitlink files) to make sure it's reproducible.
    rctx.delete(dest_dir.get_child(".git"))
    for sub in submodule_paths:
        rctx.delete(dest_dir.get_child(sub).get_child(".git"))
    return rctx.repo_metadata(reproducible = True)

crate_git_repository = repository_rule(
    implementation = _crate_git_repository_implementation,
    attrs = {
        "git_repo_label": attr.label(),
        "workspace_cargo_toml": attr.string(default = "Cargo.toml"),
        "remote": attr.string(),
    } | common_attrs,
)
