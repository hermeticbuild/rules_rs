load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":registry_utils.bzl", "registry_download_url")

def _registry_download_url_uses_directory_prefix_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "https://registry.example/My/Cr/my/cr/MyCrate-1.2.3-deadbeef.crate",
        registry_download_url(
            {"dl": "https://registry.example/{prefix}/{lowerprefix}/{crate}-{version}-{sha256-checksum}.crate"},
            "MyCrate",
            "1.2.3",
            "deadbeef",
        ),
    )
    for crate, prefix in [("a", "1"), ("ab", "2"), ("abc", "3/a"), ("cargo", "ca/rg")]:
        asserts.equals(
            env,
            "https://registry.example/" + prefix,
            registry_download_url({"dl": "https://registry.example/{prefix}"}, crate, "1.0.0", "checksum"),
        )
    return unittest.end(env)

registry_download_url_uses_directory_prefix_test = unittest.make(_registry_download_url_uses_directory_prefix_impl)

def registry_utils_tests():
    return unittest.suite(
        "registry_utils_tests",
        registry_download_url_uses_directory_prefix_test,
    )
