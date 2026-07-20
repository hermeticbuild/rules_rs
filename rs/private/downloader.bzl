load("@bazel_tools//tools/build_defs/repo:git_worker.bzl", "git_repo")
load(":annotations.bzl", "annotation_for")
load(":cargo_credentials.bzl", "registry_auth_headers")
load(":registry_utils.bzl", "CRATES_IO_REGISTRY", "sharded_path")
load(":toml2json.bzl", "run_toml2json")

def parse_git_url(url):
    # Drop query params (?rev=...) and keep only before '#'
    parts = url.split("#")
    base = parts[0]
    sha = parts[1] if len(parts) > 1 else None

    if sha == None:
        fail("No commit SHA (#...) fragment found in URL: " + url)

    # Example base: https://github.com/dovahcrow/tldextract-rs?rev=63d75b0
    # Strip query parameters
    base = base.split("?")[0]

    remote = base.removeprefix("git+")

    return remote, sha

def _parse_github_url(url):
    remote, sha = parse_git_url(url)
    repo_path = remote.removeprefix("https://github.com/").removesuffix(".git")
    return repo_path, sha

def _github_source_to_raw_content_base_url(url):
    return "https://raw.githubusercontent.com/%s/%s/" % _parse_github_url(url)

def _sanitize_path_fragment(path):
    return path.replace("/", "_").replace(":", "_").replace("?", "_")

def _fact_cache_key(namespace, parts):
    normalized_parts = [part or "" for part in parts]
    return namespace + "".join([
        "_%s_%s" % (len(part), part)
        for part in normalized_parts
    ])

def git_cargo_toml_fact_key(source, name, selected_manifest, effective_strip_prefix):
    """Returns the cache key for a Git crate's selected manifest view."""
    return _fact_cache_key("git", [source, name, selected_manifest, effective_strip_prefix])

def git_cargo_toml_fact_keys(
        source,
        name,
        selected_manifest,
        configured_strip_prefix,
        effective_strip_prefix):
    """Returns the effective fact key followed by its pre-discovery lookup key."""
    effective_key = git_cargo_toml_fact_key(source, name, selected_manifest, effective_strip_prefix)
    lookup_key = git_cargo_toml_fact_key(source, name, selected_manifest, configured_strip_prefix)
    if lookup_key == effective_key:
        return [effective_key]
    return [effective_key, lookup_key]

def registry_cargo_toml_fact_key(source, name, version):
    """Returns the cache key for a registry crate from a specific source."""
    return _fact_cache_key("registry", [source, name, version])

def registry_metadata_key(source, name):
    """Returns the in-flight metadata key for a crate from a specific registry."""
    return _fact_cache_key("registry_metadata", [source, name])

def _decode_current_cargo_toml_fact(serialized_fact):
    if not serialized_fact:
        return None

    fact = json.decode(serialized_fact)
    return fact if "is_proc_macro" in fact else None

def current_cargo_toml_fact(state, key, serialized_fact):
    """Returns and memoizes a current manifest-derived fact, if available."""
    if key not in state.cargo_toml_facts_by_key:
        state.cargo_toml_facts_by_key[key] = _decode_current_cargo_toml_fact(serialized_fact)
    return state.cargo_toml_facts_by_key[key]

def new_downloader_state():
    return struct(
        cargo_toml_facts_by_key = {},
        in_flight_git_crate_fetches_by_url = {},
        in_flight_git_member_fetches_by_url = {},
        in_flight_registry_fetches_by_source_and_crate = {},
        pending_git_clones_by_source = {},
    )

def start_github_downloads(
        mctx,
        state,
        annotations,
        packages):
    existing_facts = getattr(mctx, "facts", {}) or {}

    for package in packages:
        source = package.get("source", "")
        if not source.startswith("git+https://github.com/"):
            continue

        name = package["name"]
        annotation = annotation_for(annotations, name, package["version"], package["hub_name"])
        lookup_key = git_cargo_toml_fact_key(
            source,
            name,
            annotation.workspace_cargo_toml,
            annotation.strip_prefix,
        )
        fact = current_cargo_toml_fact(state, lookup_key, existing_facts.get(lookup_key))
        if fact != None:
            package["strip_prefix"] = fact["strip_prefix"]
            continue

        url = _github_source_to_raw_content_base_url(source) + annotation.workspace_cargo_toml
        in_flight_fetch = state.in_flight_git_crate_fetches_by_url.get(url)
        if in_flight_fetch:
            in_flight_fetch.packages.append(package)
        else:
            in_flight_fetch = struct(
                download_token = mctx.download(
                    url,
                    _sanitize_path_fragment(url),
                    allow_fail = True,
                    block = False,
                ),
                packages = [package],
            )
            state.in_flight_git_crate_fetches_by_url[url] = in_flight_fetch

        package["download_token"] = in_flight_fetch

def start_crate_registry_downloads(
        mctx,
        state,
        annotations,
        packages,
        cargo_credentials,
        debug):
    existing_facts = getattr(mctx, "facts", {}) or {}

    for package in packages:
        source = package.get("source")
        if not source:
            continue

        if source == "registry+https://github.com/rust-lang/crates.io-index":
            source = CRATES_IO_REGISTRY
            package["source"] = source
        name = package["name"]
        version = package["version"]

        if source.startswith("sparse+"):
            key = registry_cargo_toml_fact_key(source, name, version)
            if key in existing_facts:
                continue

            metadata_key = registry_metadata_key(source, name)
            in_flight_fetch = state.in_flight_registry_fetches_by_source_and_crate.get(metadata_key)
            if not in_flight_fetch:
                url = source.removeprefix("sparse+") + sharded_path(name.lower())
                metadata_path = "registry_metadata_%s.jsonl" % len(state.in_flight_registry_fetches_by_source_and_crate)
                in_flight_fetch = struct(
                    path = metadata_path,
                    token = mctx.download(
                        url,
                        metadata_path,
                        headers = registry_auth_headers(cargo_credentials, source),
                        block = False,
                    ),
                )
                state.in_flight_registry_fetches_by_source_and_crate[metadata_key] = in_flight_fetch

            package["registry_metadata_info"] = in_flight_fetch
        elif source.startswith("git+"):
            # TODO(zbarsky): Ideally other forges could use the single-file fastpath...
            if source.startswith("git+https://github.com/"):
                # Github already handled above
                continue

            annotation = annotation_for(annotations, name, version, package["hub_name"])
            lookup_key = git_cargo_toml_fact_key(
                source,
                name,
                annotation.workspace_cargo_toml,
                annotation.strip_prefix,
            )
            fact = current_cargo_toml_fact(state, lookup_key, existing_facts.get(lookup_key))
            if fact != None:
                package["strip_prefix"] = fact["strip_prefix"]
                continue

            clone_state = state.pending_git_clones_by_source.get(source)
            if clone_state:
                clone_state.packages.append(package)
                continue

            remote, commit = parse_git_url(source)
            state.pending_git_clones_by_source[source] = struct(
                clone_config = struct(
                    delete = lambda _: 0,
                    execute = mctx.execute,
                    os = mctx.os,
                    name = name,
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
                ),
                packages = [package],
            )
        elif source.startswith("path+"):
            continue
        else:
            fail("Unknown source " + source)

def _ensure_cargo_toml_exists(cargo_toml_path, fetch_state):
    if not cargo_toml_path.exists:
        fail("""

ERROR: Could not download root Cargo.toml for {name} from git repository, perhaps the repo root is not the Cargo workspace root?
Please indicate the path to the workspace Cargo.toml (or the crate itself, if not part of a workspace) in MODULE.bazel, like so:

crate.annotation(
     crate = "{name}",
     workspace_cargo_toml = "path/to/Cargo.toml",
)

""".format(name = fetch_state.packages[0]["name"]))
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

def _workspace_member_by_package_name_from_github(mctx, workspace_cargo_toml_url, cargo_toml_json):
    in_flight_fetches = []
    for member in (cargo_toml_json.get("workspace") or {}).get("members", []):
        if "*" in member or "{" in member or "}" in member:
            continue

        member_cargo_toml_url = workspace_cargo_toml_url.replace("Cargo.toml", member + "/Cargo.toml")
        member_cargo_toml_path = _sanitize_path_fragment(member_cargo_toml_url)
        in_flight_fetches.append(struct(
            member = member,
            path = member_cargo_toml_path,
            token = mctx.download(
                member_cargo_toml_url,
                member_cargo_toml_path,
                allow_fail = True,
                block = False,
            ),
        ))

    member_by_package_name = {}
    for fetch in in_flight_fetches:
        fetch.token.wait()
        member_cargo_toml_json = run_toml2json(mctx, fetch.path)
        package_name = member_cargo_toml_json.get("package", {}).get("name")
        if package_name:
            member_by_package_name[package_name] = fetch.member

    return member_by_package_name

def _workspace_member_by_package_name_from_local_clone(mctx, workspace_cargo_toml_path, cargo_toml_json):
    member_by_package_name = {}
    workspace_cargo_toml_path_str = str(workspace_cargo_toml_path)

    for member in (cargo_toml_json.get("workspace") or {}).get("members", []):
        if "*" in member or "{" in member or "}" in member:
            continue

        member_cargo_toml_json = run_toml2json(
            mctx,
            workspace_cargo_toml_path_str.replace("Cargo.toml", member + "/Cargo.toml"),
        )
        package_name = member_cargo_toml_json.get("package", {}).get("name")
        if package_name:
            member_by_package_name[package_name] = member

    return member_by_package_name

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

def _annotations_for_package(annotations_by_hub_name, package):
    hub_name = package.get("hub_name")
    if not hub_name:
        fail("Missing hub_name for package %s" % package.get("name", "<unknown>"))

    annotations = annotations_by_hub_name.get(hub_name)
    if annotations == None:
        fail("Missing annotations for hub %s" % hub_name)

    return annotations

def download_metadata_for_git_crates(
        mctx,
        state,
        annotations_by_hub_name):
    for url, fetch_state in state.in_flight_git_crate_fetches_by_url.items():
        cargo_toml_path = _sanitize_path_fragment(url)
        _ensure_cargo_toml_exists(mctx.path(cargo_toml_path), fetch_state)

        cargo_toml_json = run_toml2json(mctx, cargo_toml_path)
        workspace_member_by_package_name = None

        for package in fetch_state.packages:
            name = package["name"]
            annotations = _annotations_for_package(annotations_by_hub_name, package)

            if cargo_toml_json.get("package", {}).get("name") != name:
                annotation = annotation_for(annotations, name, package["version"], package["hub_name"])
                strip_prefix = _compute_strip_prefix(annotation, cargo_toml_json, name)

                if not strip_prefix:
                    if workspace_member_by_package_name == None:
                        workspace_member_by_package_name = _workspace_member_by_package_name_from_github(
                            mctx,
                            url,
                            cargo_toml_json,
                        )
                    strip_prefix = workspace_member_by_package_name.get(name)

                if not strip_prefix:
                    fail("Could not compute strip_prefix for crate '%s'" % name)

                package["strip_prefix"] = strip_prefix
                child_url = url.replace("Cargo.toml", strip_prefix + "/Cargo.toml")

                # Deduplicate by URL so hubs sharing a workspace-member crate
                # share one download token. A hub that reuses another hub's fact
                # never waits its token, and Bazel does not allow pending
                # downloads to outlive the extension evaluation.
                member_fetch = state.in_flight_git_member_fetches_by_url.get(child_url)
                if not member_fetch:
                    child_cargo_toml_path = _sanitize_path_fragment(child_url)
                    member_fetch = struct(
                        token = mctx.download(child_url, child_cargo_toml_path, block = False),
                        path = child_cargo_toml_path,
                    )
                    state.in_flight_git_member_fetches_by_url[child_url] = member_fetch
                package["member_crate_cargo_toml_info"] = member_fetch

                package["workspace_cargo_toml_json"] = cargo_toml_json
            else:
                package["cargo_toml_json"] = cargo_toml_json
                if cargo_toml_json.get("workspace"):
                    package["workspace_cargo_toml_json"] = cargo_toml_json

    for source, clone_state in state.pending_git_clones_by_source.items():
        clone_dir = mctx.path(_sanitize_path_fragment(source))
        git_repo(clone_state.clone_config, clone_dir)

        cargo_tomls_by_path = {}
        workspace_members_by_path = {}

        for package in clone_state.packages:
            name = package["name"]
            annotations = _annotations_for_package(annotations_by_hub_name, package)
            annotation = annotation_for(annotations, name, package["version"], package["hub_name"])
            cargo_toml_path = clone_dir.get_child(annotation.workspace_cargo_toml)
            cargo_toml_path_key = str(cargo_toml_path)
            cargo_toml_json = cargo_tomls_by_path.get(cargo_toml_path_key)
            if cargo_toml_json == None:
                _ensure_cargo_toml_exists(cargo_toml_path, clone_state)
                cargo_toml_json = run_toml2json(mctx, cargo_toml_path)
                cargo_tomls_by_path[cargo_toml_path_key] = cargo_toml_json

            if cargo_toml_json.get("package", {}).get("name") != name:
                strip_prefix = _compute_strip_prefix(annotation, cargo_toml_json, name)

                if not strip_prefix:
                    workspace_member_by_package_name = workspace_members_by_path.get(cargo_toml_path_key)
                    if workspace_member_by_package_name == None:
                        workspace_member_by_package_name = _workspace_member_by_package_name_from_local_clone(
                            mctx,
                            cargo_toml_path,
                            cargo_toml_json,
                        )
                        workspace_members_by_path[cargo_toml_path_key] = workspace_member_by_package_name
                    strip_prefix = workspace_member_by_package_name.get(name)

                if not strip_prefix:
                    fail("Could not compute strip_prefix for crate '%s'" % name)

                package["strip_prefix"] = strip_prefix
                package["workspace_cargo_toml_json"] = cargo_toml_json
                child_cargo_toml_path = cargo_toml_path.dirname.get_child(strip_prefix).get_child("Cargo.toml")
                package["cargo_toml_json"] = run_toml2json(mctx, child_cargo_toml_path)
            else:
                package["cargo_toml_json"] = cargo_toml_json
                if cargo_toml_json.get("workspace"):
                    package["workspace_cargo_toml_json"] = cargo_toml_json
