const _: [(); 2] = [(); helper::MODE];
const _: [(); 2] = [(); shared::MODE];
const _: [(); 2] = [(); bridge::MODE];
const _: [(); 2] = [(); build_macro::exec_mode!()];

fn main() {
    let _: helper::HelperToken = bridge::helper_token();
    let direct: shared::Token = helper::token();
    let indirect: shared::Token = bridge::token();
    let _: helper::Token = bridge::token();
    let direct_leaf: leaf::Token = helper::leaf_token();
    let indirect_leaf: leaf::Token = bridge::leaf_token();
    assert_eq!(direct.0 .0, indirect.0 .0);
    assert_eq!(direct_leaf.0, indirect_leaf.0);
    assert_eq!(helper::exec_only(), 23);
}
