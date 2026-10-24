extern crate proc_macro;

use proc_macro::TokenStream;

#[proc_macro]
pub fn make_miri_value(_input: TokenStream) -> TokenStream {
    let path = std::path::Path::new(file!()).with_file_name("proc_macro_value.txt");
    let value = std::fs::read_to_string(path).expect("read proc macro data");
    format!("fn proc_macro_generated_value() -> i32 {{ {value} }}")
        .parse()
        .unwrap()
}
