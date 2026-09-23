#[cfg(not(any(feature = "target_feature", feature = "exec_feature")))]
compile_error!("shared must select target or build features");

#[cfg(feature = "target_feature")]
pub const MODE: usize = 1;
#[cfg(feature = "exec_feature")]
pub const MODE: usize = 2;

pub struct Token(pub leaf::Token);

pub fn token() -> Token {
    Token(leaf::Token)
}
