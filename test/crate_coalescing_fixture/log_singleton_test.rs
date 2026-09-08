const ROOT_A_TARGET: &str = "crate_coalescing::root_a";

fn root_logger_data_ptr() -> *const () {
    log::logger() as *const dyn log::Log as *const ()
}

#[test]
fn one_logger_is_shared_across_every_bzlmod_dependency_path() {
    // Install through a child module. Emission below deliberately enters `log`
    // through two root hubs and two independently resolved child-module hubs.
    let installed_logger = library_bar::install_log_probe();

    assert_eq!(library_bar::log_probe_counts(), (0, 0, 0, 0));
    assert_eq!(
        root_logger_data_ptr(),
        installed_logger,
        "the first root hub observes a different log global",
    );
    assert_eq!(
        crate_coalescing_root_b_log::logger_data_ptr(),
        installed_logger,
        "the second root hub observes a different log global",
    );
    assert_eq!(
        library_bar::logger_data_ptr(),
        installed_logger,
        "the installing child does not observe its installed logger",
    );
    assert_eq!(
        library_baz::logger_data_ptr(),
        installed_logger,
        "the second child module observes a different log global",
    );

    log::info!(target: ROOT_A_TARGET, "first root hub reached the shared logger");
    crate_coalescing_root_b_log::emit_log_probe();
    library_bar::emit_log_probe();
    library_baz::emit_log_probe();

    assert_eq!(
        library_bar::log_probe_counts(),
        (1, 1, 1, 1),
        "every dependency path must deliver exactly one record to the singleton logger",
    );
}
