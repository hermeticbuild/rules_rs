load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_rust//rust:rust_common.bzl", "CrateInfo")

_EXPECTED_LOG_IDENTITY = 'cargo:["registry","sparse+https://index.crates.io/","log","0.4.29"]'

_IdentityPairInfo = provider(fields = [
    "first",
    "second",
])

def _identity_pair_impl(ctx):
    return [_IdentityPairInfo(
        first = ctx.attr.first[CrateInfo].crate_identity,
        second = ctx.attr.second[CrateInfo].crate_identity,
    )]

_identity_pair = rule(
    implementation = _identity_pair_impl,
    attrs = {
        "first": attr.label(
            mandatory = True,
            providers = [CrateInfo],
        ),
        "second": attr.label(
            mandatory = True,
            providers = [CrateInfo],
        ),
    },
)

def _identity_check(expect_set):
    """Creates an analysis test asserting the target's crate_identity presence.

    `expect_set` True asserts a RustCrateIdentityInfo whose crate_instance is the
    configured CrateInfo output; False asserts the identity is absent.
    """

    def _impl(ctx):
        env = analysistest.begin(ctx)
        target = analysistest.target_under_test(env)
        identity = target[CrateInfo].crate_identity
        if expect_set:
            asserts.true(env, identity != None)
            asserts.equals(env, target.label, identity.owner)
            asserts.equals(env, target[CrateInfo].output, identity.crate_instance)
            asserts.equals(env, target[CrateInfo].name, identity.display_name)
        else:
            asserts.equals(env, None, identity)
        return analysistest.end(env)

    return analysistest.make(_impl)

library_identity_test = _identity_check(expect_set = True)
proc_macro_identity_test = _identity_check(expect_set = True)
no_identity_test = _identity_check(expect_set = False)

def _generated_identity_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    identity = target[CrateInfo].crate_identity

    asserts.true(env, identity != None)
    asserts.true(env, identity.logical_id.startswith("cargo:["))
    asserts.true(env, '"log"' in identity.logical_id)
    asserts.true(env, '"0.4.29"' in identity.logical_id)
    return analysistest.end(env)

generated_identity_test = analysistest.make(_generated_identity_impl)

def _git_generated_identity_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    identity = target[CrateInfo].crate_identity

    asserts.true(env, identity != None)
    asserts.true(env, identity.logical_id.startswith("cargo:[\"git\","))
    asserts.true(env, '"o2o"' in identity.logical_id)
    asserts.true(env, '"0.5.4"' in identity.logical_id)
    return analysistest.end(env)

git_generated_identity_test = analysistest.make(_git_generated_identity_impl)

def _generated_incompatible_classes_share_identity_impl(ctx):
    env = analysistest.begin(ctx)
    pair = analysistest.target_under_test(env)[_IdentityPairInfo]
    first = pair.first
    second = pair.second

    asserts.true(env, first != None)
    asserts.true(env, second != None)
    asserts.equals(env, _EXPECTED_LOG_IDENTITY, first.logical_id)
    asserts.equals(env, _EXPECTED_LOG_IDENTITY, second.logical_id)
    asserts.equals(env, first.logical_id, second.logical_id)
    asserts.true(env, first.owner != second.owner)
    asserts.true(env, first.crate_instance != second.crate_instance)
    return analysistest.end(env)

generated_incompatible_classes_share_identity_test = analysistest.make(
    _generated_incompatible_classes_share_identity_impl,
)

def cargo_crate_identity_info_tests():
    library_identity_test(
        name = "library_identity_test",
        target_under_test = ":metadata_crate",
    )
    proc_macro_identity_test(
        name = "proc_macro_identity_test",
        target_under_test = ":proc_metadata",
    )

    # Cargo binaries and build-script executables carry no logical identity.
    no_identity_test(
        name = "generated_binary_no_identity_test",
        target_under_test = ":tool__bin",
    )
    no_identity_test(
        name = "build_script_no_identity_test",
        target_under_test = ":_bs_",
    )
    generated_identity_test(
        name = "extension_generated_identity_test",
        target_under_test = "@crate_coalescing_a//:log",
    )
    git_generated_identity_test(
        name = "git_extension_generated_identity_test",
        target_under_test = "@git_crates//:o2o-0.5.4",
    )
    _identity_pair(
        name = "generated_incompatible_log_classes",
        first = "@crate_coalescing_a//:log-0.4.29",
        second = "@crate_link_validation_class//:log-0.4.29",
    )
    generated_incompatible_classes_share_identity_test(
        name = "generated_incompatible_classes_share_identity_test",
        target_under_test = ":generated_incompatible_log_classes",
    )

    native.test_suite(
        name = "cargo_crate_identity_info_tests",
        tests = [
            ":build_script_no_identity_test",
            ":extension_generated_identity_test",
            ":generated_binary_no_identity_test",
            ":generated_incompatible_classes_share_identity_test",
            ":git_extension_generated_identity_test",
            ":library_identity_test",
            ":proc_macro_identity_test",
        ],
    )
