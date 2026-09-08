const ROOT_B_TARGET: &str = "crate_coalescing::root_b";

pub fn logger_data_ptr() -> *const () {
    log::logger() as *const dyn log::Log as *const ()
}

pub fn emit_log_probe() {
    log::info!(target: ROOT_B_TARGET, "second root hub reached the shared logger");
}
