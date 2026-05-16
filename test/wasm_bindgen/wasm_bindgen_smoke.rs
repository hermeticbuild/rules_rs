use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub fn add_one(input: u32) -> u32 {
    input + 1
}
