use proc_macro::TokenStream;

const _: [(); 2] = [(); helper::MODE];
const _: [(); 2] = [(); shared::MODE];

#[proc_macro]
pub fn exec_mode(_: TokenStream) -> TokenStream {
    let _: shared::Token = helper::token();
    helper::MODE.to_string().parse().unwrap()
}
