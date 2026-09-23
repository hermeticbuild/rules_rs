use proc_macro::TokenStream;

#[proc_macro]
pub fn check(_: TokenStream) -> TokenStream {
    feature_split_macro_helper::expression().parse().unwrap()
}
