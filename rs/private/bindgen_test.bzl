"""Tests for bindgen helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":bindgen.bzl", "normalize_msvc_compile_flags")

def _normalize_msvc_compile_flags_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        [
            "-I",
            "/Users/include",
            "-isystem",
            "C:/SDK/include",
            "-include",
            "forced.h",
            "-D",
            "DEBUG",
            "-U",
            "OLD",
            "-std=c17",
            "-x",
            "c",
            "-fms-runtime-lib=dll_dbg",
        ],
        normalize_msvc_compile_flags([
            "/I",
            "/Users/include",
            "/EXTERNAL:IC:/SDK/include",
            "/FIforced.h",
            "/clang:/DDEBUG",
            "/uOLD",
            "/std:C17",
            "/TC",
            "/MDd",
        ]),
    )

    return unittest.end(env)

def _normalize_msvc_runtime_libraries_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        [
            "-isystem",
            "/Users/SDK",
            "-fms-runtime-lib=static",
            "-fms-runtime-lib=static_dbg",
            "-fms-runtime-lib=dll",
            "-fms-runtime-lib=dll_dbg",
        ],
        normalize_msvc_compile_flags([
            "-isystem",
            "/Users/SDK",
            "/MT",
            "/mtd",
            "/MD",
            "/mDd",
        ]),
    )

    return unittest.end(env)

def _preserve_other_msvc_options_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        [
            "/utf-8",
            "/DYNAMICBASE",
            "/diagnostics:caret",
            "/ifcOutput",
        ],
        normalize_msvc_compile_flags([
            "/utf-8",
            "/DYNAMICBASE",
            "/diagnostics:caret",
            "/ifcOutput",
        ]),
    )

    asserts.equals(
        env,
        [
            "-Xclang",
            "-fno-cxx-modules",
        ],
        normalize_msvc_compile_flags([
            "/clang:-Xclang",
            "/clang:-fno-cxx-modules",
        ]),
    )

    return unittest.end(env)

normalize_msvc_compile_flags_test = unittest.make(_normalize_msvc_compile_flags_impl)
normalize_msvc_runtime_libraries_test = unittest.make(_normalize_msvc_runtime_libraries_impl)
preserve_other_msvc_options_test = unittest.make(_preserve_other_msvc_options_impl)

def bindgen_tests():
    return unittest.suite(
        "bindgen_tests",
        normalize_msvc_compile_flags_test,
        normalize_msvc_runtime_libraries_test,
        preserve_other_msvc_options_test,
    )
