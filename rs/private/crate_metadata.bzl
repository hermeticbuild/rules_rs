"""Crate metadata."""

def git_checkout_fingerprint(annotation):
    """Returns the repository-wide inputs that determine a Git checkout."""
    return {
        "patch_args": annotation.patch_args,
        "patch_tool": annotation.patch_tool or "",
        # Patch order is significant because each patch sees the output of the
        # preceding patch.
        "patches": [str(patch) for patch in annotation.patches],
        "workspace_cargo_toml": annotation.workspace_cargo_toml,
    }

def registry_fact_key(source, name, version):
    """Returns the source-qualified cache key for registry package facts."""
    return "rs_crate_fact_v2_registry_" + json.encode({
        "name": name,
        "source": source,
        "version": version,
    })

def git_fact_key(source, name, version, annotation, strip_prefix):
    """Returns the checkout- and layout-qualified cache key for Git facts."""
    return "rs_crate_fact_v2_git_" + json.encode({
        "checkout": git_checkout_fingerprint(annotation),
        "name": name,
        "source": source,
        "strip_prefix": strip_prefix or "",
        "version": version,
    })

def record_hub_config(configs_by_hub_name, cfg, mod):
    if cfg.name in configs_by_hub_name:
        fail("Duplicate crate.from_cargo repository name %s" % cfg.name)
    configs_by_hub_name[cfg.name] = struct(cfg = cfg, mod = mod)

def add_registry_fetch_config(
        configs_by_source,
        hub_name,
        source,
        cargo_config,
        use_home_cargo_credentials,
        cargo_credentials):
    """Collects one deterministic usable fetch configuration per registry."""
    token = cargo_credentials.get(source) if use_home_cargo_credentials else None
    candidate = {
        "auth_required": None,
        "cargo_config": cargo_config,
        "hub_name": hub_name,
        "token": token,
        "use_home_cargo_credentials": bool(token),
    }
    previous = configs_by_source.get(source)
    if not previous:
        configs_by_source[source] = candidate
        return

    if previous["token"] and token and previous["token"] != token:
        fail("""Conflicting Cargo registry credentials for {source}:
  {first_hub}: authenticated
  {second_hub}: authenticated
Use the same credential for a registry shared by coalesced crates.""".format(
            source = source,
            first_hub = previous["hub_name"],
            second_hub = hub_name,
        ))

    # Authenticated access is usable for both public and private registries.
    # For equivalent modes, hub name provides a stable traversal-independent
    # tie-breaker without serializing credential contents.
    if (token and not previous["token"]) or (
        bool(token) == bool(previous["token"]) and
        hub_name < previous["hub_name"]
    ):
        configs_by_source[source] = candidate

def selected_registry_credentials(configs_by_source):
    """Returns the selected source-to-token mapping for module downloads."""
    return {
        source: config["token"]
        for source, config in configs_by_source.items()
        if config["token"] and config["auth_required"]
    }

def registry_metadata_prefixes(fetch_configs_by_source):
    """Assigns a deterministic staging prefix per registry source.

    The prefix depends only on the sorted source set, never on the order the
    hubs were traversed, so separate hubs select identical per-source metadata
    paths and the same crate name pulled from two registries lands in distinct
    metadata files.
    """
    return {
        source: "registry_metadata_%d" % index
        for index, source in enumerate(sorted(fetch_configs_by_source))
    }

def add_git_build_file(git_repo, source, build_file_path, content, hub_name):
    previous = git_repo["build_files"].get(build_file_path)
    if previous != None and previous != content:
        fail("Git crate %s has incompatible additive BUILD content in hubs %s and %s" % (
            source,
            git_repo["first_hub"],
            hub_name,
        ))
    git_repo["build_files"][build_file_path] = content
