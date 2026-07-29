CRATES_IO_REGISTRY = "sparse+https://index.crates.io/"

def resolve_registry_source(source, cargo_config = {}):
    """Resolves a Cargo.lock registry source using Cargo source replacements."""
    if source == None:
        return None

    if source.startswith("registry+sparse+"):
        return source.removeprefix("registry+")

    if source != "registry+https://github.com/rust-lang/crates.io-index":
        return source

    sources = cargo_config.get("source", {})
    replacement = sources.get("crates-io", {}).get("replace-with")
    if not replacement:
        return CRATES_IO_REGISTRY

    visited = ["crates-io"]
    for _ in range(len(sources) + 1):
        if replacement in visited:
            fail("Cargo registry source replacement cycle: %s" % " -> ".join(visited + [replacement]))
        visited.append(replacement)

        replacement_source = sources.get(replacement, {})
        next_replacement = replacement_source.get("replace-with")
        if next_replacement:
            replacement = next_replacement
            continue

        registry = replacement_source.get("registry") or cargo_config.get("registries", {}).get(replacement, {}).get("index")
        if not registry:
            fail("Cargo registry source replacement %s does not define a registry index" % replacement)
        if not registry.startswith("sparse+"):
            fail("Cargo registry source replacement %s must use a sparse registry index: %s" % (replacement, registry))
        return registry

    fail("Cargo registry source replacements could not be resolved")

def registry_download_template(config):
    """Returns the crate download template from a registry config.

    Args:
        config: Decoded registry config.json object.

    Returns:
        A download URL template using Cargo's registry placeholders.
    """
    dl = config["dl"]
    if not (
        "{crate}" in dl or
        "{version}" in dl or
        "{sha256-checksum}" in dl or
        "{prefix}" in dl or
        "{lowerprefix}" in dl
    ):
        dl += "/{crate}/{version}/download"
    return dl

def registry_download_url_from_template(template, crate, version, checksum):
    """Expands a registry download template for one crate.

    Args:
        template: Download URL template from a registry config.json.
        crate: Published crate name.
        version: Published crate version.
        checksum: Registry checksum for the published archive.

    Returns:
        The archive download URL.
    """
    return template.format(**{
        "crate": crate,
        "version": version,
        "prefix": registry_path_prefix(crate),
        "lowerprefix": registry_path_prefix(crate.lower()),
        "sha256-checksum": checksum,
    })

def registry_download_url(config, crate, version, checksum):
    """Expands a registry config into the download URL for one crate."""
    return registry_download_url_from_template(
        registry_download_template(config),
        crate,
        version,
        checksum,
    )

def registry_config_repo_name(hub_name, source):
    return hub_name + "_" + registry_repo_name(source)

def registry_repo_name(source):
    return source.removeprefix("sparse+").replace(":", "_").replace("/", "_")

def registry_path_prefix(crate):
    """Returns Cargo's case-preserving registry directory prefix.

    Args:
        crate: Published crate name.

    Returns:
        The directory portion of the crate's sharded registry path.
    """
    n = len(crate)
    if n == 0:
        fail("empty crate name")
    if n == 1:
        return "1"
    if n == 2:
        return "2"
    if n == 3:
        return "3/%s" % crate[0]
    return "%s/%s" % (crate[0:2], crate[2:4])

def sharded_path(crate):
    """Returns the sparse-index path containing a crate's metadata."""
    return registry_path_prefix(crate) + "/" + crate
