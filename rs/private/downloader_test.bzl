"""Git metadata scratch paths (issue #276)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":downloader.bzl", "git_source_path")

def _git_source_paths_impl(ctx):
    env = unittest.begin(ctx)
    sources = [
        "git+file:///workspace/" + "long-directory-" * 40 + "/Cargo.toml",
        "git+https://example.com/" + "common-prefix/" * 40 + "first?rev=abc",
        "git+https://example.com/" + "common-prefix/" * 40 + "second?rev=abc",
        "https://example.com/a_b/Cargo.toml",
        "https://example.com/a/b/Cargo.toml",
        "https://example.com/a%2Fb/Cargo.toml",
        "a" * 60,
        "a" * 120,
    ]
    paths = [git_source_path(source) for source in sources]
    asserts.equals(env, len(paths), len(set(paths)))
    for path in paths:
        asserts.true(env, path.endswith("/Cargo.toml"))
        for component in path.split("/"):
            asserts.true(env, len(component) <= 65, component)
        for other in paths:
            asserts.false(env, other.startswith(path + "/"), "File used as parent directory: " + path)
    return unittest.end(env)

git_source_paths_test = unittest.make(_git_source_paths_impl)

def downloader_tests():
    unittest.suite("downloader_tests", git_source_paths_test)
