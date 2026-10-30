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

    # Hermetic clang-cl searches builtin headers before its explicit SDK roots.
    # These roots precede original -idirafter paths, regardless of argv order.
    for no_stdlibinc in ["-nostdlibinc", "/clang:-nostdlibinc"]:
        asserts.equals(
            env,
            [
                "-idirafter",
                "SDK/first",
                "-idirafter",
                "/Users/SDK/second",
                "-idirafter",
                "fallback",
                "-isystem",
                "external",
                "-nostdlibinc",
            ],
            normalize_msvc_compile_flags([
                "-idirafter",
                "fallback",
                "/imsvcSDK/first",
                "/IMsvc",
                "/Users/SDK/second",
                "/external:Iexternal",
                no_stdlibinc,
            ]),
        )

    # Native discovery is unchanged; an option-looking path is not a flag.
    asserts.equals(
        env,
        ["-isystem", "SDK", "-I", "-nostdlibinc"],
        normalize_msvc_compile_flags(["/imsvcSDK", "/I", "-nostdlibinc"]),
    )

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
