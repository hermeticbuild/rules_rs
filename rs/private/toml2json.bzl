load("@bazel_lib_host//:defs.bzl", "host")

_TOML2JSON = Label("@toml2json_%s//file:downloaded" % host.platform)

def run_toml2json(ctx, toml_file):
    result = ctx.execute([_TOML2JSON, toml_file])
    if result.return_code != 0:
        fail(result.stdout + result.stderr)

    return json.decode(result.stdout)
