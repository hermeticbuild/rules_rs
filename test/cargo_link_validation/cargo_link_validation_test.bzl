load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _conflict_test():
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(
            env,
            "would link incompatible instances of the same Rust library",
        )
        return analysistest.end(env)

    return analysistest.make(_impl, expect_failure = True)

cargo_link_conflict_test = _conflict_test()

def _success_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

cargo_link_success_test = analysistest.make(_success_test_impl)

def _sanitized_diagnostic_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        '  logical identity: cargo:["registry","sparse+https://index.crates.io/","duplicate","1.0.0"]',
    )
    return analysistest.end(env)

cargo_link_sanitized_diagnostic_test = analysistest.make(
    _sanitized_diagnostic_test_impl,
    expect_failure = True,
)

def cargo_link_validation_tests():
    failure_targets = [
        "build_script_conflict_",
        "cdylib_conflict",
        "crate_test_conflict",
        "direct_conflict",
        "extension_generated_conflict",
        "proc_macro_conflict",
        "standalone_test_conflict",
        "staticlib_conflict",
        "transitive_conflict",
    ]
    for target in failure_targets:
        cargo_link_conflict_test(
            name = target + "_analysis_test",
            target_under_test = ":" + target,
        )

    success_targets = [
        "build_script_isolation",
        "different_source_pass",
        "different_version_pass",
        "platform_single_active_pass",
        "proc_macro_isolation",
        "separate_class_one",
        "separate_class_two",
    ]
    for target in success_targets:
        cargo_link_success_test(
            name = target + "_analysis_test",
            target_under_test = ":" + target,
        )

    cargo_link_sanitized_diagnostic_test(
        name = "sanitized_diagnostic_analysis_test",
        target_under_test = ":direct_conflict",
    )

    native.test_suite(
        name = "cargo_link_conflict_tests",
        tests = (
            [":" + target + "_analysis_test" for target in failure_targets] +
            [":" + target + "_analysis_test" for target in success_targets] +
            [":sanitized_diagnostic_analysis_test"]
        ),
    )
