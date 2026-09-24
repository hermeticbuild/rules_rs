#[cfg(all(feature = "native", target_arch = "wasm32"))]
compile_error!("a native-only feature leaked into the wasm resolution");

pub fn portable_value() -> &'static str {
    leaf::enabled()
}
