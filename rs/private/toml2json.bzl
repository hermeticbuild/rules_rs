load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")

def _host_toml2json():
    for os, binary_os in [("osx", "darwin"), ("linux", "linux"), ("windows", "windows")]:
        if "@platforms//os:" + os not in HOST_CONSTRAINTS:
            continue
        for cpu, binary_arch in [("x86_64", "amd64"), ("aarch64", "arm64")]:
            if "@platforms//cpu:" + cpu in HOST_CONSTRAINTS:
                return Label("@toml2json_%s_%s//file:downloaded" % (binary_os, binary_arch))
    return None

_TOML2JSON = _host_toml2json()

def run_toml2json(ctx, toml_file):
    if not _TOML2JSON:
        fail("No toml2json binary for host constraints %s" % HOST_CONSTRAINTS)
    result = ctx.execute([_TOML2JSON, toml_file])
    if result.return_code != 0:
        fail(result.stdout + result.stderr)

    return json.decode(result.stdout)
