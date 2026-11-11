load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load(":cargo_credentials.bzl", "registry_auth_headers")
load(":registry_utils.bzl", "sharded_path")
load(":toml2json.bzl", "run_toml2json")

def parse_git_url(url):
    parts = url.split("#")
    if len(parts) < 2:
        fail("No commit SHA (#...) fragment found in URL: " + url)
    return parts[0].partition("?")[0].removeprefix("git+"), parts[1]

def _sanitize_path_fragment(path):
    return path.replace("/", "_").replace(":", "_").replace("?", "_")

def new_downloader_state():
    return struct(
        in_flight_registry_fetches_by_crate = {},
        in_flight_git_crate_fetches_by_url = {},
        pending_git_clones_by_source = {},
    )

def start_github_download(mctx, state, package):
    remote, commit = package["git_source"]
    repo = remote.removeprefix("https://github.com/").removesuffix(".git")
    url = "https://raw.githubusercontent.com/%s/%s/%s" % (repo, commit, package["annotation"].workspace_cargo_toml)
    fetch = state.in_flight_git_crate_fetches_by_url.get(url)
    if not fetch:
        fetch = struct(
            download_token = mctx.download(url, _sanitize_path_fragment(url), allow_fail = True, block = False),
            packages = [],
        )
        state.in_flight_git_crate_fetches_by_url[url] = fetch
    fetch.packages.append(package)

def start_crate_downloads(mctx, state, packages, cargo_credentials):
    for package in packages:
        source = package["source"]
        name = package["name"]
        if source.startswith("sparse+"):
            token = state.in_flight_registry_fetches_by_crate.get(name)
            if not token:
                token = mctx.download(
                    source.removeprefix("sparse+") + sharded_path(name.lower()),
                    name + ".jsonl",
                    headers = registry_auth_headers(cargo_credentials, source),
                    block = False,
                )
                state.in_flight_registry_fetches_by_crate[name] = token
            package["download_token"] = token
        else:
            state.pending_git_clones_by_source.setdefault(source, []).append(package)

def _ensure_cargo_toml_exists(cargo_toml_path, name):
    if not cargo_toml_path.exists:
        fail("""

ERROR: Could not download root Cargo.toml for {name} from git repository, perhaps the repo root is not the Cargo workspace root?
Please indicate the path to the workspace Cargo.toml (or the crate itself, if not part of a workspace) in MODULE.bazel, like so:

crate.annotation(
     crate = "{name}",
     workspace_cargo_toml = "path/to/Cargo.toml",
)

""".format(name = name))
        # TODO(zbarsky): ^^ this currently needs to be configured for all packages, should we make it nicer?

def _find_path_dependency(dependencies, name):
    for dep_name, dep in (dependencies or {}).items():
        if type(dep) != "dict":
            continue

        dep_package = dep.get("package", dep_name)
        if dep_package != name:
            continue

        path = dep.get("path")
        if path:
            return path

    return None

def _member_manifest(mctx, manifest, member, github_url, allow_fail = False):
    if github_url:
        url = github_url.rsplit("/", 1)[0] + "/" + member + "/Cargo.toml"
        path = _sanitize_path_fragment(url)
        return struct(path = path, token = mctx.download(url, path, allow_fail = allow_fail, block = False))
    return struct(path = manifest.dirname.get_child(member + "/Cargo.toml"), token = None)

def read_member_manifest(mctx, member):
    if member.token:
        member.token.wait()
    return run_toml2json(mctx, member.path)

def _workspace_members_by_name(mctx, manifest, github_url, cargo_toml):
    members = {
        member: _member_manifest(mctx, manifest, member, github_url, allow_fail = True)
        for member in (cargo_toml.get("workspace") or {}).get("members", [])
        if "*" not in member and "{" not in member and "}" not in member
    }
    by_name = {}
    for member, info in members.items():
        data = read_member_manifest(mctx, info)
        name = data.get("package", {}).get("name")
        if name:
            by_name[name] = (member, data)
    return by_name

def _compute_strip_prefix(annotation, cargo_toml_json, name):
    strip_prefix = annotation.strip_prefix

    workspace = cargo_toml_json.get("workspace") or {}

    if not strip_prefix and name in workspace.get("members", []):
        strip_prefix = name

    if not strip_prefix:
        # Handle `uv-python = { path = "crates/uv-python" }` when `members` includes wildcard.
        strip_prefix = _find_path_dependency(workspace.get("dependencies"), name)

    if not strip_prefix:
        # Handle `wirefilter = { path = "engine", package = "wirefilter-engine" }` when crate is aliased internally.
        strip_prefix = _find_path_dependency(cargo_toml_json.get("dependencies"), name)

    if not strip_prefix:
        strip_prefix = _find_path_dependency(cargo_toml_json.get("build-dependencies"), name)

    if not strip_prefix:
        for target in (cargo_toml_json.get("target") or {}).values():
            strip_prefix = _find_path_dependency(target.get("dependencies"), name)
            if strip_prefix:
                break

    # TODO(zbarsky): any more cases to handle here?
    return strip_prefix

def _read_git_cargo_tomls(mctx, packages, manifest, github_url = None):
    _ensure_cargo_toml_exists(manifest, packages[0]["name"])
    cargo_toml = run_toml2json(mctx, manifest)
    workspace_members = None
    for package in packages:
        name = package["name"]
        if cargo_toml.get("package", {}).get("name") == name:
            package["cargo_toml_json"] = cargo_toml
            if cargo_toml.get("workspace"):
                package["workspace_cargo_toml_json"] = cargo_toml
            continue

        strip_prefix = _compute_strip_prefix(package["annotation"], cargo_toml, name)
        if not strip_prefix:
            if workspace_members == None:
                workspace_members = _workspace_members_by_name(mctx, manifest, github_url, cargo_toml)
            if name not in workspace_members:
                fail("Could not compute strip_prefix for crate '%s'" % name)
            strip_prefix, member_toml = workspace_members[name]
            package["cargo_toml_json"] = member_toml
        else:
            package["member_crate_cargo_toml_info"] = _member_manifest(mctx, manifest, strip_prefix, github_url)
        package["strip_prefix"] = strip_prefix
        package["workspace_cargo_toml_json"] = cargo_toml

def download_metadata_for_git_crates(mctx, state):
    for url, fetch in state.in_flight_git_crate_fetches_by_url.items():
        fetch.download_token.wait()
        _read_git_cargo_tomls(mctx, fetch.packages, mctx.path(_sanitize_path_fragment(url)), github_url = url)

    for source, packages in state.pending_git_clones_by_source.items():
        remote, commit = packages[0]["git_source"]
        clone_dir = mctx.path(_sanitize_path_fragment(source))
        git_repo(struct(
            delete = lambda _: 0,
            execute = mctx.execute,
            os = mctx.os,
            name = packages[0]["name"],
            path = mctx.path,
            report_progress = mctx.report_progress,
            attr = struct(
                shallow_since = "",
                commit = commit,
                remote = remote,
                init_submodules = True,
                recursive_init_submodules = True,
                verbose = False,
            ),
        ), clone_dir)
        manifest = clone_dir.get_child(packages[0]["annotation"].workspace_cargo_toml)
        _read_git_cargo_tomls(mctx, packages, manifest)
