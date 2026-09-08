"""Analysis tests for mixed Rust/C++ final links.

The Rust link rules validate their own target-runtime closure intrinsically
(`rustc.bzl:validate_crate_identity_closure`). A native binary that links two
`rust_static_library`s is outside that intrinsic check. Raw `cc_binary` rules
do not apply the validation aspect, so this surface is covered by the
`rust_link_checked_cc_*` wrappers, which apply the aspect and fail during
analysis; and by the command-line aspect applied to a raw target.

>>> Conflict: two static libs carrying two instances of one logical Rust
>>> library meet in one checked native link. This must FAIL during analysis.
>>> Isolation: the same two instances in SEPARATE native links, or split across
>>> dynamic shared-library boundaries, must PASS.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_CONFLICT_MESSAGE = "would link incompatible instances of the same Rust library"

def _cc_mixed_conflict_test():
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(
            env,
            _CONFLICT_MESSAGE,
        )
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

cc_mixed_conflict_test = _cc_mixed_conflict_test()

def _cc_mixed_separate_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

cc_mixed_separate_test = analysistest.make(_cc_mixed_separate_test_impl)

def cc_mixed_link_tests():
    # Conflicting static Rust closures meeting in one checked native link fail.
    for target in [
        "cc_mixed_conflict",
        "cc_transitive_conflict",
        "cc_shared_conflict",
    ]:
        cc_mixed_conflict_test(
            name = target + "_analysis_test",
            target_under_test = ":" + target,
        )

    # Raw native rules without the wrapper or the aspect are unchecked, even in
    # the presence of the same conflict.
    cc_mixed_separate_test(
        name = "cc_mixed_conflict_unchecked_analysis_test",
        target_under_test = ":cc_mixed_conflict_unchecked",
    )

    # Isolation and acceptable topologies must build.
    for target in [
        "cc_same_instance_two_paths",
        "cc_separate_one",
        "cc_separate_two",
        "cc_two_dynamic_boundaries",
    ]:
        cc_mixed_separate_test(
            name = target + "_analysis_test",
            target_under_test = ":" + target,
        )

    native.test_suite(
        name = "cc_mixed_link_analysis_tests",
        tests = [
            ":cc_mixed_conflict_analysis_test",
            ":cc_mixed_conflict_unchecked_analysis_test",
            ":cc_same_instance_two_paths_analysis_test",
            ":cc_separate_one_analysis_test",
            ":cc_separate_two_analysis_test",
            ":cc_shared_conflict_analysis_test",
            ":cc_transitive_conflict_analysis_test",
            ":cc_two_dynamic_boundaries_analysis_test",
        ],
    )
