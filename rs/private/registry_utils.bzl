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
