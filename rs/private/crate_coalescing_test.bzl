"""Crate coalescing test."""

load("@bazel_skylib//lib:unittest.bzl", "unittest")
load("//rs/private:crate_coalescer_test.bzl", "additive_dependency_accepts_same_receiving_hub_class_test", "additive_dependency_allows_disjoint_platform_class_test", "additive_dependency_checks_every_existing_hub_test", "additive_dependency_respects_receiving_hub_class_test", "canonical_repository_collision_fails_test", "checksum_conflict_fails_test", "class_assignments_are_semantically_permutation_invariant_test", "finalize_materializes_one_repository_once_test", "finalize_twice_fails_test", "missing_finalized_assignment_fails_test", "multiple_compatibility_classes_compare_every_class_test", "valid_fingerprint_property_test", _canonical_repository_collision_subject = "canonical_repository_collision_subject", _checksum_conflict_subject = "checksum_conflict_subject", _finalize_twice_subject = "finalize_twice_subject", _missing_finalized_assignment_subject = "missing_finalized_assignment_subject")
load("//rs/private:crate_compatibility_test.bzl", "alias_compatibility_is_validated_test", "different_build_script_env_files_split_test", "different_link_deps_split_test", "git_checkout_and_compilation_inputs_test", "identical_and_additive_fingerprints_merge_test", "identical_annotation_values_permit_coalescing_test", "missing_compatibility_input_fails_test", "nonadditive_inputs_split_test", "normal_and_build_action_collisions_are_rejected_test", "selected_direct_dependency_is_not_repeated_test", "undecided_annotation_policy_fails_test", "unknown_compatibility_input_fails_test", _missing_compatibility_input_subject = "missing_compatibility_input_subject", _undecided_annotation_policy_subject = "undecided_annotation_policy_subject", _unknown_compatibility_input_subject = "unknown_compatibility_input_subject")
load("//rs/private:crate_dependency_order_test.bzl", "dependency_order_deduplicates_and_ignores_external_test", "dependency_order_dense_sliding_window_test", "dependency_order_empty_singleton_test", "dependency_order_large_chain_test", "dependency_order_randomized_input_is_deterministic_test", "dependency_order_wide_fan_test", "duplicate_package_key_fails_test", "self_cycle_fails_test", "two_node_cycle_fails_test", _duplicate_package_key_subject = "duplicate_package_key_subject", _self_cycle_subject = "self_cycle_subject", _two_node_cycle_subject = "two_node_cycle_subject")
load("//rs/private:crate_identity_test.bzl", "canonical_repository_names_are_bounded_test", "crate_identity_is_reserved_and_stable_test", "git_identity_dimensions_and_normalization_test", "path_packages_and_versions_remain_distinct_test", "registry_identity_dimensions_test", "structured_identity_delimiters_do_not_collide_test")
load("//rs/private:crate_metadata_test.bzl", "conflicting_registry_credentials_fails_test", "duplicate_hub_name_fails_test", "fact_keys_are_schema_qualified_test", "incompatible_git_overlay_fails_test", "registry_fetch_selection_remains_deterministic_test", "registry_metadata_prefixes_are_order_independent_test", _conflicting_registry_credentials_subject = "conflicting_registry_credentials_subject", _duplicate_hub_name_subject = "duplicate_hub_name_subject", _incompatible_git_overlay_subject = "incompatible_git_overlay_subject")
load("//rs/private:crate_weak_features_test.bzl", "feature_sensitive_dependencies_require_identical_features_test", "weak_feature_detection_test", "weak_features_compare_effective_not_encoded_closures_test", "weak_features_ignore_additive_outputs_test", "weak_features_merge_disjoint_domains_without_leaking_test", "weak_features_merge_rustix_shape_test", "weak_features_reject_only_cross_terms_test", "weak_features_still_reject_alias_collisions_test", "weak_features_use_effective_legacy_domains_test")

def crate_coalescing_tests():
    unittest.suite(
        "crate_coalescing_unit_tests",
        dependency_order_empty_singleton_test,
        dependency_order_large_chain_test,
        dependency_order_wide_fan_test,
        dependency_order_dense_sliding_window_test,
        dependency_order_deduplicates_and_ignores_external_test,
        dependency_order_randomized_input_is_deterministic_test,
        registry_identity_dimensions_test,
        git_identity_dimensions_and_normalization_test,
        structured_identity_delimiters_do_not_collide_test,
        identical_and_additive_fingerprints_merge_test,
        selected_direct_dependency_is_not_repeated_test,
        alias_compatibility_is_validated_test,
        normal_and_build_action_collisions_are_rejected_test,
        nonadditive_inputs_split_test,
        identical_annotation_values_permit_coalescing_test,
        different_build_script_env_files_split_test,
        different_link_deps_split_test,
        additive_dependency_respects_receiving_hub_class_test,
        additive_dependency_accepts_same_receiving_hub_class_test,
        additive_dependency_allows_disjoint_platform_class_test,
        additive_dependency_checks_every_existing_hub_test,
        registry_metadata_prefixes_are_order_independent_test,
        weak_features_reject_only_cross_terms_test,
        weak_features_merge_rustix_shape_test,
        feature_sensitive_dependencies_require_identical_features_test,
        weak_features_merge_disjoint_domains_without_leaking_test,
        weak_features_compare_effective_not_encoded_closures_test,
        weak_features_ignore_additive_outputs_test,
        weak_features_still_reject_alias_collisions_test,
        weak_features_use_effective_legacy_domains_test,
        multiple_compatibility_classes_compare_every_class_test,
        class_assignments_are_semantically_permutation_invariant_test,
        finalize_materializes_one_repository_once_test,
        valid_fingerprint_property_test,
        fact_keys_are_schema_qualified_test,
        weak_feature_detection_test,
        git_checkout_and_compilation_inputs_test,
        path_packages_and_versions_remain_distinct_test,
        crate_identity_is_reserved_and_stable_test,
        canonical_repository_names_are_bounded_test,
        registry_fetch_selection_remains_deterministic_test,
    )

    failure_tests = []
    for name, subject_rule, test_rule in [
        ("checksum_conflict", _checksum_conflict_subject, checksum_conflict_fails_test),
        ("canonical_repository_collision", _canonical_repository_collision_subject, canonical_repository_collision_fails_test),
        ("two_node_cycle", _two_node_cycle_subject, two_node_cycle_fails_test),
        ("self_cycle", _self_cycle_subject, self_cycle_fails_test),
        ("duplicate_package_key", _duplicate_package_key_subject, duplicate_package_key_fails_test),
        ("finalize_twice", _finalize_twice_subject, finalize_twice_fails_test),
        ("missing_finalized_assignment", _missing_finalized_assignment_subject, missing_finalized_assignment_fails_test),
        ("duplicate_hub_name", _duplicate_hub_name_subject, duplicate_hub_name_fails_test),
        ("incompatible_git_overlay", _incompatible_git_overlay_subject, incompatible_git_overlay_fails_test),
        ("conflicting_registry_credentials", _conflicting_registry_credentials_subject, conflicting_registry_credentials_fails_test),
        ("unknown_compatibility_input", _unknown_compatibility_input_subject, unknown_compatibility_input_fails_test),
        ("missing_compatibility_input", _missing_compatibility_input_subject, missing_compatibility_input_fails_test),
        ("undecided_annotation_policy", _undecided_annotation_policy_subject, undecided_annotation_policy_fails_test),
    ]:
        subject_name = name + "_failure_subject"
        test_name = name + "_fails_test"
        subject_rule(name = subject_name, tags = ["manual"])
        test_rule(name = test_name, target_under_test = ":" + subject_name)
        failure_tests.append(":" + test_name)

    native.test_suite(
        name = "crate_coalescing_tests",
        tests = [":crate_coalescing_unit_tests"] + failure_tests,
    )
