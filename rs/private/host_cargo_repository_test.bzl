"""Tests for host Cargo platform selection."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":host_cargo_repository.bzl", "HOST_CARGO_ATTRS", "host_cargo_platform")

def _host_cargo_platform_test_impl(ctx):
    env = unittest.begin(ctx)
    for os_name, prefix in [
        ("linux", "linux"),
        ("mac os x", "macos"),
        ("windows 11", "windows"),
    ]:
        for arch, suffix in [
            ("amd64", "amd64"),
            ("x86_64", "amd64"),
            ("x64", "amd64"),
            ("arm64", "arm64"),
            ("aarch64", "arm64"),
        ]:
            expected = "%s_%s" % (prefix, suffix)
            asserts.equals(env, expected, host_cargo_platform(os_name, arch))
            asserts.equals(env, expected, host_cargo_platform(os_name.upper(), arch.upper()))
            asserts.true(env, expected in HOST_CARGO_ATTRS)
    asserts.false(env, host_cargo_platform("linux", "riscv64") in HOST_CARGO_ATTRS)
    asserts.false(env, host_cargo_platform("freebsd", "amd64") in HOST_CARGO_ATTRS)
    return unittest.end(env)

_host_cargo_platform_test = unittest.make(_host_cargo_platform_test_impl)

def host_cargo_repository_tests():
    _host_cargo_platform_test(name = "host_cargo_platform_test")
    native.test_suite(
        name = "host_cargo_repository_tests",
        tests = [":host_cargo_platform_test"],
    )
