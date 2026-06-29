use proc_macro::TokenStream;

#[proc_macro_attribute]
pub fn identity(_attr: TokenStream, item: TokenStream) -> TokenStream {
    feature_split_shared::exec_only();
    item
}
