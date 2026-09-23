const _: [(); 2] = [(); helper::MODE];
const _: [(); 2] = [(); shared::MODE];
const _: [(); 2] = [(); bridge::MODE];
const _: [(); 2] = [(); build_macro::exec_mode!()];

fn main() {
    let _: helper::HelperToken = bridge::helper_token();
    let _: shared::Token = helper::token();
    let _: shared::Token = bridge::token();
    let _: leaf::Token = helper::leaf_token();
    let _: leaf::Token = bridge::leaf_token();
    assert_eq!(helper::exec_only(), 23);
}
