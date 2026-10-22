CRATES_IO_REGISTRY = "sparse+https://index.crates.io/"
CRATES_IO_LOCK_SOURCE = "registry+https://github.com/rust-lang/crates.io-index"

def resolve_registry_source(source, crates_io_source = CRATES_IO_REGISTRY):
    """Normalizes a Cargo.lock source using the resolved crates.io registry."""
    if source == None:
        return None

    if source.startswith("registry+sparse+"):
        return source.removeprefix("registry+")

    if source != CRATES_IO_LOCK_SOURCE:
        return source

    return crates_io_source

def _cargo_field(value, key, path, required = False):
    if value == None and not required:
        return None
    if type(value) == "dict":
        return value.get(key)
    fail("Cargo configuration %s must be a table" % path)

def _cargo_string(table, key, path):
    value = _cargo_field(table, key, path)
    if value == None:
        return None
    if type(value) == "string":
        return value
    fail("Cargo configuration %s.%s must be a string" % (path, key))

def resolve_crates_io_source(cargo_config):
    """Resolves the active crates.io replacement in a decoded Cargo config."""
    sources = _cargo_field(cargo_config, "source", "root", required = True)
    if sources == None:
        return CRATES_IO_REGISTRY
    if type(sources) != "dict":
        fail("Cargo configuration source must be a table")
    crates_io = _cargo_field(sources, "crates-io", "source")
    replacement = _cargo_string(crates_io, "replace-with", "source.crates-io")
    if not replacement:
        return CRATES_IO_REGISTRY

    visited = ["crates-io"]
    for _ in range(len(sources) + 1):
        if replacement in visited:
            fail("Cargo registry source replacement cycle: %s" % " -> ".join(visited + [replacement]))
        visited.append(replacement)

        replacement_source = _cargo_field(sources, replacement, "source")
        replacement_path = "source.%s" % replacement
        next_replacement = _cargo_string(replacement_source, "replace-with", replacement_path)
        if next_replacement:
            replacement = next_replacement
            continue

        registry = _cargo_string(replacement_source, "registry", replacement_path)
        if not registry:
            registries = _cargo_field(cargo_config, "registries", "root")
            replacement_registry = _cargo_field(registries, replacement, "registries")
            registry = _cargo_string(replacement_registry, "index", "registries.%s" % replacement)
        if not registry:
            fail("Cargo registry source replacement %s does not define a registry index" % replacement)
        if not registry.startswith("sparse+"):
            fail("Cargo registry source replacement %s must use a sparse registry index: %s" % (replacement, registry))
        return registry

    fail("Cargo registry source replacements could not be resolved")

def registry_download_template(config):
    """Returns the crate download template from a decoded registry config.

    Args:
        config: Decoded registry config.json.

    Returns:
        A download URL template using Cargo's registry placeholders.
    """
    if type(config) != "dict":
        fail("Cargo registry config.json must be an object")
    dl = config.get("dl")
    if type(dl) != "string":
        fail("Cargo registry config.json field dl must be a string")
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
