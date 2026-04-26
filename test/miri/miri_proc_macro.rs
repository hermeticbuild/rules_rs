extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn make_miri_value(_input: TokenStream) -> TokenStream {
    "fn proc_macro_generated_value() -> i32 { 7 }"
        .parse()
        .unwrap()
}
