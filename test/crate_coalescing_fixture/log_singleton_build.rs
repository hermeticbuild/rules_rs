fn logger_data_ptr() -> *const () {
    log::logger() as *const dyn log::Log as *const ()
}

fn main() {
    let logger_paths = (
        logger_data_ptr(),
        crate_coalescing_root_b_log::logger_data_ptr(),
        library_bar::logger_data_ptr(),
    );

    std::hint::black_box(logger_paths);
}
