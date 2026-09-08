"""Crate dependency order test."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/private:crate_dependency_order.bzl", "packages_in_dependency_order")
load("//rs/private:crate_test_fixtures.bzl", _OTHER_REGISTRY = "OTHER_REGISTRY", _REGISTRY = "REGISTRY", _assert_dependency_order = "assert_dependency_order", _chain_graph = "chain_graph", _expect_failure = "expect_failure", _fq = "fq", _numbered_name = "numbered_name", _package = "package", _resolution = "resolution")

def _dependency_order_empty_singleton_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], packages_in_dependency_order([], {}, "hub"))
    package = _package(name = "only")
    resolutions = {_fq(package): _resolution()}
    ordered = packages_in_dependency_order([package], resolutions, "hub")
    asserts.equals(env, ["only"], [item["name"] for item in ordered])
    _assert_dependency_order(env, ordered, resolutions, "hub")
    return unittest.end(env)

def _dependency_order_large_chain_impl(ctx):
    env = unittest.begin(ctx)
    packages, resolutions = _chain_graph(10000)
    ordered = packages_in_dependency_order(reversed(packages), resolutions, "hub")
    _assert_dependency_order(env, ordered, resolutions, "hub")
    asserts.equals(env, "node-00000", ordered[0]["name"])
    asserts.equals(env, "node-09999", ordered[-1]["name"])
    return unittest.end(env)

def _dependency_order_wide_fan_impl(ctx):
    env = unittest.begin(ctx)
    packages = []
    resolutions = {}
    root_deps = []
    for i in range(1024):
        package = _package(name = _numbered_name("leaf-", i, 4), version = "1.0.0")
        packages.append(package)
        resolutions[_fq(package)] = _resolution()
        root_deps.append("@hub//:%s" % _fq(package))
    root = _package(name = "root", version = "1.0.0")
    packages.insert(0, root)
    resolutions[_fq(root)] = _resolution(deps = {"all": root_deps})
    ordered = packages_in_dependency_order(packages, resolutions, "hub")
    _assert_dependency_order(env, ordered, resolutions, "hub")
    asserts.equals(env, [_numbered_name("leaf-", i, 4) for i in range(1024)] + ["root"], [item["name"] for item in ordered])
    return unittest.end(env)

def _dependency_order_dense_sliding_window_impl(ctx):
    env = unittest.begin(ctx)
    size = 2000
    width = 16
    packages = []
    resolutions = {}
    for i in range(size):
        package = _package(name = _numbered_name("dense-", i, 4), version = "1.0.0")
        packages.append(package)
        start = max(0, i - width)
        labels = ["@hub//:%s-1.0.0" % _numbered_name("dense-", j, 4) for j in range(start, i)]
        resolutions[_fq(package)] = _resolution(deps = {"linux": labels})
    ordered = packages_in_dependency_order(reversed(packages), resolutions, "hub")
    _assert_dependency_order(env, ordered, resolutions, "hub")
    asserts.equals(env, [_numbered_name("dense-", i, 4) for i in range(size)], [item["name"] for item in ordered])
    return unittest.end(env)

def _dependency_order_deduplicates_and_ignores_external_impl(ctx):
    env = unittest.begin(ctx)
    leaf = _package(name = "leaf")
    top = _package(name = "top")
    resolutions = {
        _fq(leaf): _resolution(),
        _fq(top): _resolution(
            deps = {
                "linux": ["@hub//:leaf-1.2.3", "@other//:unrelated"],
                "macos": ["@hub//:leaf-1.2.3"],
            },
            build_deps = {"linux": ["@hub//:leaf-1.2.3"]},
        ),
    }
    ordered = packages_in_dependency_order([top, leaf], resolutions, "hub")
    _assert_dependency_order(env, ordered, resolutions, "hub")
    asserts.equals(env, ["leaf", "top"], [item["name"] for item in ordered])
    return unittest.end(env)

def _dependency_order_randomized_input_is_deterministic_impl(ctx):
    env = unittest.begin(ctx)
    packages, resolutions = _chain_graph(101)
    permuted = [packages[(i * 37) % 101] for i in range(101)]
    expected = [package["name"] for package in packages]
    for candidate in [packages, reversed(packages), permuted]:
        ordered = packages_in_dependency_order(candidate, resolutions, "hub")
        _assert_dependency_order(env, ordered, resolutions, "hub")
        asserts.equals(env, expected, [package["name"] for package in ordered])
    return unittest.end(env)

def _two_node_cycle_subject_impl(_ctx):
    packages = [_package(name = "first"), _package(name = "second")]
    resolutions = {
        "first-1.2.3": _resolution(deps = {"linux": ["@hub//:second-1.2.3"]}),
        "second-1.2.3": _resolution(deps = {"linux": ["@hub//:first-1.2.3"]}),
    }
    packages_in_dependency_order(packages, resolutions, "hub")
    return []

def _self_cycle_subject_impl(_ctx):
    package = _package(name = "self")
    packages_in_dependency_order(
        [package],
        {_fq(package): _resolution(deps = {"linux": ["@hub//:self-1.2.3"]})},
        "hub",
    )
    return []

def _duplicate_package_key_subject_impl(_ctx):
    packages = [
        _package(source = _REGISTRY),
        _package(source = _OTHER_REGISTRY),
    ]
    packages_in_dependency_order(packages, {_fq(packages[0]): _resolution()}, "hub")
    return []

two_node_cycle_subject = rule(implementation = _two_node_cycle_subject_impl)

_two_node_cycle_subject = two_node_cycle_subject

self_cycle_subject = rule(implementation = _self_cycle_subject_impl)

_self_cycle_subject = self_cycle_subject

duplicate_package_key_subject = rule(implementation = _duplicate_package_key_subject_impl)

_duplicate_package_key_subject = duplicate_package_key_subject

dependency_order_empty_singleton_test = unittest.make(_dependency_order_empty_singleton_impl)

dependency_order_large_chain_test = unittest.make(_dependency_order_large_chain_impl)

dependency_order_wide_fan_test = unittest.make(_dependency_order_wide_fan_impl)

dependency_order_dense_sliding_window_test = unittest.make(_dependency_order_dense_sliding_window_impl)

dependency_order_deduplicates_and_ignores_external_test = unittest.make(_dependency_order_deduplicates_and_ignores_external_impl)

dependency_order_randomized_input_is_deterministic_test = unittest.make(_dependency_order_randomized_input_is_deterministic_impl)

two_node_cycle_fails_test = _expect_failure("contains a dependency cycle among [\"first-1.2.3\", \"second-1.2.3\"]")

self_cycle_fails_test = _expect_failure("contains a dependency cycle among [\"self-1.2.3\"]")

duplicate_package_key_fails_test = _expect_failure("contains multiple packages with the same name and version")
