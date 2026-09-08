use std::collections::HashMap;

const BAZ_TARGET: &str = "crate_coalescing::baz";

pub fn logger_data_ptr() -> *const () {
    log::logger() as *const dyn log::Log as *const ()
}

pub fn emit_log_probe() {
    log::info!(target: BAZ_TARGET, "baz dependency path reached the shared logger");
}

pub fn inspect(request: http::Request<String>) -> String {
    format!(
        "{}:{}:{}",
        request.uri().path(),
        request.body(),
        local_helper::tag(),
    )
}

pub fn std_feature_is_enabled() {
    fn assert_serialize<T: serde::Serialize>() {}
    assert_serialize::<HashMap<String, String>>();
}
