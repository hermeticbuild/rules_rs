"""Crate identity test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_coalescing.bzl", "coalesce_spoke")
load("//rs/private:crate_identity.bzl", "canonical_spoke_repo", "crate_identity", "normalize_git_remote", "package_identity", "repo_component")
load("//rs/private:crate_test_fixtures.bzl", _GIT = "GIT", _OTHER_REGISTRY = "OTHER_REGISTRY", _coalescer = "coalescer", _fingerprint = "fingerprint", _package = "package")

def _registry_identity_dimensions_impl(ctx):
    env = unittest.begin(ctx)
    base = _package()
    asserts.equals(env, package_identity(base), package_identity(dict(base)))
    for changed in [
        _package(source = _OTHER_REGISTRY),
        _package(name = "other"),
        _package(version = "9.9.9"),
    ]:
        asserts.true(env, package_identity(base) != package_identity(changed))
    return unittest.end(env)

def _git_identity_dimensions_and_normalization_impl(ctx):
    env = unittest.begin(ctx)
    base = _package(source = _GIT)
    equivalent = _package(source = "git+HTTPS://EXAMPLE.COM/workspace.git/?branch=main#0123456789abcdef")
    asserts.equals(env, package_identity(base, "crates/member"), package_identity(equivalent, "crates/member"))
    asserts.equals(env, "https://example.com/workspace", normalize_git_remote("HTTPS://EXAMPLE.COM/workspace.git/"))
    for package, path in [
        (_package(source = "git+https://other.example/workspace#0123456789abcdef"), "crates/member"),
        (_package(source = "git+https://example.com/workspace#fedcba9876543210"), "crates/member"),
        (base, "crates/other"),
        (_package(name = "other", source = _GIT), "crates/member"),
        (_package(version = "2.0.0", source = _GIT), "crates/member"),
    ]:
        asserts.true(env, package_identity(base, "crates/member") != package_identity(package, path))
    return unittest.end(env)

def _structured_identity_delimiters_do_not_collide_impl(ctx):
    env = unittest.begin(ctx)
    first = _package(name = "a,b", source = "sparse+https://registry.example/a:b/")
    second = _package(name = "b", source = "sparse+https://registry.example/a:b/,a/")
    asserts.true(env, package_identity(first) != package_identity(second))
    git = _package(name = "member", source = _GIT)
    asserts.true(env, package_identity(git, "a,b:c") != package_identity(git, "a,b/c"))
    asserts.true(env, repo_component("a/b") != repo_component("a_slash_b"))
    return unittest.end(env)

def _path_packages_and_versions_remain_distinct_impl(ctx):
    env = unittest.begin(ctx)
    coalescer = _coalescer()
    path_package = _package(source = "path+some/module/package")
    first_path = coalesce_spoke(coalescer, path_package, "", "first", {})
    second_path = coalesce_spoke(coalescer, path_package, "", "second", {})
    asserts.equals(env, "first__shared-1.2.3", first_path[0])
    asserts.equals(env, "second__shared-1.2.3", second_path[0])
    asserts.true(env, first_path[2])
    asserts.true(env, second_path[2])
    first_version = coalesce_spoke(coalescer, _package(version = "1.0.0"), "", "first", _fingerprint())[0]
    second_version = coalesce_spoke(coalescer, _package(version = "2.0.0"), "", "second", _fingerprint())[0]
    asserts.true(env, first_version != second_version)
    return unittest.end(env)

def _crate_identity_is_reserved_and_stable_impl(ctx):
    env = unittest.begin(ctx)
    package = _package()
    identity = crate_identity(package)
    asserts.equals(env, "cargo:" + package_identity(package), identity)
    asserts.true(env, identity.startswith("cargo:"))

    # Git packages keep their full provenance (pinned commit and member path).
    git_identity = crate_identity(_package(source = _GIT))
    asserts.true(env, '["git",' in git_identity)
    asserts.true(env, '"0123456789abcdef"' in git_identity)

    # Path packages carry no source identity and expose no logical ID.
    asserts.equals(env, None, crate_identity(_package(source = "path+file:///x")))
    return unittest.end(env)

def _canonical_repository_names_are_bounded_impl(ctx):
    env = unittest.begin(ctx)
    long_registry = "sparse+https://registry.example.com/" + ("very-long-segment/" * 40)
    first = canonical_spoke_repo(_package(source = long_registry))
    second = canonical_spoke_repo(_package(source = long_registry + "different"))
    asserts.true(env, len(first) < 100)
    asserts.true(env, first != second)
    return unittest.end(env)

registry_identity_dimensions_test = unittest.make(_registry_identity_dimensions_impl)

git_identity_dimensions_and_normalization_test = unittest.make(_git_identity_dimensions_and_normalization_impl)

structured_identity_delimiters_do_not_collide_test = unittest.make(_structured_identity_delimiters_do_not_collide_impl)

path_packages_and_versions_remain_distinct_test = unittest.make(_path_packages_and_versions_remain_distinct_impl)

crate_identity_is_reserved_and_stable_test = unittest.make(_crate_identity_is_reserved_and_stable_impl)

canonical_repository_names_are_bounded_test = unittest.make(_canonical_repository_names_are_bounded_impl)
