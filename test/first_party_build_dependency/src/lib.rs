const _: [(); 1] = [(); helper::MODE];
const _: [(); 1] = [(); shared::MODE];
const _: [(); 1] = [(); bridge::MODE];

pub fn token() -> shared::Token {
    let _: helper::HelperToken = bridge::helper_token();
    let _: shared::Token = helper::token();
    bridge::token()
}

pub fn leaf_token() -> leaf::Token {
    let _: leaf::Token = helper::leaf_token();
    let _: leaf::Token = shared::token().0;
    bridge::leaf_token()
}
