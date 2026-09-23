#[cfg(not(any(feature = "target_feature", feature = "exec_feature")))]
compile_error!("helper must select target or build features");

#[cfg(feature = "target_feature")]
pub const MODE: usize = 1;
#[cfg(feature = "exec_feature")]
pub const MODE: usize = 2;

const _: [(); MODE] = [(); shared::MODE];

pub use shared::Token;

pub struct HelperToken;

pub fn helper_token() -> HelperToken {
    HelperToken
}

pub fn token() -> Token {
    shared::token()
}

pub fn leaf_token() -> leaf::Token {
    shared::token().0
}

#[cfg(feature = "exec_feature")]
pub fn exec_only() -> u8 {
    optional_helper::VALUE
}
