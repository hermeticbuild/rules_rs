use proc_macro::TokenStream;

#[proc_macro]
pub fn check_exec_feature(_input: TokenStream) -> TokenStream {
    feature_split_shared::exec_only();
    TokenStream::new()
}
