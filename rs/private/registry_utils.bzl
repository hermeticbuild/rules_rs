CRATES_IO_REGISTRY = "sparse+https://index.crates.io/"

def registry_config_repo_name(hub_name, source):
    return hub_name + "_" + registry_repo_name(source)

def registry_repo_name(source):
    return source.removeprefix("sparse+").replace(":", "_").replace("/", "_")

def sharded_path(crate):
    n = len(crate)
    if n == 0:
        fail("empty crate name")
    if n == 1:
        return "1/" + crate
    if n == 2:
        return "2/" + crate
    if n == 3:
        return "3/%s/%s" % (crate[0], crate)
    return "%s/%s/%s" % (crate[0:2], crate[2:4], crate)

def parse_dl_template(config_json):
    """Extracts the `.crate` download URL template from a registry's config.json.

    Mirrors cargo: if the `dl` value contains no markers, the default
    `/{crate}/{version}/download` suffix is appended.
    """
    dl = json.decode(config_json)["dl"]
    if not (
        "{crate}" in dl or
        "{version}" in dl or
        "{sha256-checksum}" in dl or
        "{prefix}" in dl or
        "{lowerprefix}" in dl
    ):
        dl += "/{crate}/{version}/download"
    return dl

def crate_archive_url(dl, crate_name, version, sha256):
    """Fills a registry `dl` template to produce a crate's `.crate` archive URL."""
    return dl.format(**{
        "crate": crate_name,
        "version": version,
        "prefix": sharded_path(crate_name),
        "lowerprefix": sharded_path(crate_name.lower()),
        "sha256-checksum": sha256,
    })

def sparse_fact_is_current(cached_fact):
    """Whether a cached `sparse+` fact is from this ruleset version.

    Facts persisted before proc-macro sniffing lack the `is_proc_macro` bit, so
    they must be re-downloaded and re-sniffed rather than served stale (which
    would silently misclassify registry proc-macros on a warm cache).
    """
    return "is_proc_macro" in json.decode(cached_fact)
