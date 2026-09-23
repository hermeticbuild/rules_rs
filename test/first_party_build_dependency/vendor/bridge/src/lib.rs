pub const MODE: usize = helper::MODE;
const _: [(); MODE] = [(); shared::MODE];

pub fn helper_token() -> helper::HelperToken {
    helper::HelperToken
}

pub fn token() -> shared::Token {
    helper::token()
}

pub fn leaf_token() -> leaf::Token {
    helper::leaf_token()
}
