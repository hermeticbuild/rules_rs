"""Tests for bindgen helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":bindgen.bzl", "clang_cl_compile_flags", "clang_cl_user_flags", "normalize_msvc_compile_flags")

def _clang_cl_native_flags_impl(ctx):
    env = unittest.begin(ctx)
    for opt_out in [[], ["/X"], ["-nostdinc"], ["/clang:-nostdlibinc"], ["/clang:-nobuiltininc"]]:
        flags = [
            "--target=x86_64-pc-windows-msvc",
            "/imsvc",
            "/Users/SDK",
            "/external:Iexternal",
            "/MT",
            "/clang:-fms-compatibility-version=19.50.35717",
            "/clang:-ivfsoverlay",
            "/clang:/Users/overlay.json",
        ] + opt_out
        asserts.equals(env, ["--driver-mode=cl"] + flags, clang_cl_compile_flags(flags))
    return unittest.end(env)

def _clang_cl_mixed_user_flags_impl(ctx):
    env = unittest.begin(ctx)

    # Mixed synonyms must retain order, not get split between the native argv
    # and /clang:'s append-at-the-end stream.
    for flags, expected in [
        (["-DVALUE=1", "/UVALUE"], ["-DVALUE=1", "-U", "VALUE"]),
        (["/UVALUE", "-DVALUE=1"], ["-U", "VALUE", "-DVALUE=1"]),
        (["-Ifirst", "/Isecond"], ["-Ifirst", "-I", "second"]),
        (["/Isecond", "-Ifirst"], ["-I", "second", "-Ifirst"]),
        (["-std=c++20", "/std:c++17"], ["/clang:-std=c++20", "/clang:-std=c++17"]),
        (["/std:c++17", "-std=c++20"], ["/clang:-std=c++17", "/clang:-std=c++20"]),
        (["-fms-runtime-lib=static", "/MD"], ["/clang:-fms-runtime-lib=static", "/clang:-fms-runtime-lib=dll"]),
        (["/MD", "-fms-runtime-lib=static"], ["/clang:-fms-runtime-lib=dll", "/clang:-fms-runtime-lib=static"]),
        (["-isystem", "first", "/external:Isecond"], ["/external:I", "first", "/external:I", "second"]),
        (["/FIsecond.h", "-include", "first.h"], ["/FI", "second.h", "/FI", "first.h"]),
        (["/TP", "-x", "c"], ["-x", "c++", "-x", "c"]),
    ]:
        asserts.equals(env, expected, clang_cl_user_flags(flags))
    return unittest.end(env)

def _clang_cl_operands_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [
            "-I",
            "/Users/include",
            "/imsvc",
            "-nostdlibinc",
            "/clang:-ivfsoverlay",
            "/clang:/Users/overlay.json",
            "/clang:-Xclang",
            "/clang:-ivfsoverlay",
            "/clang:-Xclang",
            "/clang:/Users/other.json",
            "/clang:-Xpreprocessor",
            "/clang:-DVALUE=1",
            "-target",
            "aarch64-pc-windows-msvc",
            "-x",
            "c++",
        ],
        clang_cl_user_flags([
            "/I",
            "/Users/include",
            "/imsvc",
            "-nostdlibinc",
            "-ivfsoverlay",
            "/Users/overlay.json",
            "-Xclang",
            "-ivfsoverlay",
            "-Xclang",
            "/Users/other.json",
            "-Xpreprocessor",
            "-DVALUE=1",
            "--target",
            "aarch64-pc-windows-msvc",
            "-x",
            "c++",
        ]),
    )
    asserts.equals(
        env,
        ["--driver-mode=cl", "-target", "aarch64-pc-windows-msvc", "/I", "/Fo", "/FI", "/ftime-trace"],
        clang_cl_compile_flags(["/clang:-target", "/clang:aarch64-pc-windows-msvc", "/I", "/Fo", "/FI", "/ftime-trace"]),
    )
    asserts.equals(
        env,
        ["-x", "c++", "/external:I", "/Users/SDK", "-resource-dir", "/Users/clang", "-I", "/clang:/literal"],
        clang_cl_user_flags([
            "/clang:-x",
            "/clang:c++",
            "/clang:-isystem",
            "/clang:/Users/SDK",
            "/clang:-resource-dir",
            "/clang:/Users/clang",
            "-I",
            "/clang:/literal",
        ]),
    )
    return unittest.end(env)

def _clang_cl_non_frontend_flags_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--driver-mode=cl", "/clang:-Xclang", "/clang:-ivfsoverlay", "/clang:-Xclang", "/clang:overlay.json", "/MT", "/GR-", "/EHsc"],
        clang_cl_compile_flags([
            "/nologo",
            "/c",
            "/Fooutput.obj",
            "/Fd",
            "debug.pdb",
            "/clang:-ftime-trace",
            "/clang:-fplugin=plugin.so",
            "/clang:-Xclang",
            "/clang:-load",
            "/clang:-Xclang",
            "/clang:plugin.so",
            "-Xclang",
            "-plugin-arg-plugin",
            "-Xclang",
            "argument",
            "-Xclang",
            "-fno-cxx-modules",
            "/clang:-Xclang",
            "/clang:-ivfsoverlay",
            "/clang:-Xclang",
            "/clang:overlay.json",
            "/MT",
            "/GR-",
            "/EHsc",
        ]),
    )
    return unittest.end(env)

def _clang_cl_warning_policy_impl(ctx):
    env = unittest.begin(ctx)
    for flag in ["/WX", "-WX", "/clang:-Werror", "/clang:-Werror=unknown-argument"]:
        flags = ["/W4", flag, "/clang:-Wunknown-argument"]
        asserts.equals(env, ["--driver-mode=cl", "/W4", "/clang:-Wunknown-argument"], clang_cl_compile_flags(flags))
        asserts.equals(env, ["--driver-mode=cl"] + flags, clang_cl_compile_flags(flags, user_flags = [flag]))
    asserts.equals(env, ["--driver-mode=cl", "/WX-", "/clang:-Wno-error"], clang_cl_compile_flags(["/WX-", "/clang:-Wno-error"]))
    return unittest.end(env)

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
clang_cl_native_flags_test = unittest.make(_clang_cl_native_flags_impl)
clang_cl_mixed_user_flags_test = unittest.make(_clang_cl_mixed_user_flags_impl)
clang_cl_operands_test = unittest.make(_clang_cl_operands_impl)
clang_cl_non_frontend_flags_test = unittest.make(_clang_cl_non_frontend_flags_impl)
clang_cl_warning_policy_test = unittest.make(_clang_cl_warning_policy_impl)

def bindgen_tests():
    return unittest.suite(
        "bindgen_tests",
        normalize_msvc_compile_flags_test,
        normalize_msvc_runtime_libraries_test,
        preserve_other_msvc_options_test,
        clang_cl_native_flags_test,
        clang_cl_mixed_user_flags_test,
        clang_cl_operands_test,
        clang_cl_non_frontend_flags_test,
        clang_cl_warning_policy_test,
    )
