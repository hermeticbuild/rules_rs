load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load(":toml2json.bzl", "run_toml2json")

def load_cargo_credentials(mctx, cargo_config):
    cargo_home = mctx.getenv("CARGO_HOME")
    if cargo_home:
        credentials_path = cargo_home + "/credentials.toml"
    else:
        home_directory = repo_utils.get_home_directory(mctx)
        if not home_directory:
            fail("""
ERROR: Cannot determine home directory in order to load home `.cargo/credentials.toml` file.
""")

        credentials_path = home_directory + "/.cargo/credentials.toml"

    credentials = run_toml2json(mctx, credentials_path)["registries"]
    result = {}
    for name, data in cargo_config["registries"].items():
        index = data["index"]
        if name in credentials:
            result[index] = credentials[name]["token"]

    return result

def registry_auth_headers(cargo_credentials, source):
    token = cargo_credentials.get(source)
    if token:
        return {"Authorization": token}

    return {}

def repository_registry_auth_headers(rctx):
    # TODO(zbarsky): Is there a better way than fetching this in every crate repository?
    if not rctx.attr.use_home_cargo_credentials:
        return {}
    cargo_config = run_toml2json(rctx, rctx.attr.cargo_config)
    return registry_auth_headers(load_cargo_credentials(rctx, cargo_config), rctx.attr.source)
