#![feature(rustc_private)]

use anyhow::Result;
use std::env;

fn main() -> Result<()> {
    env_logger::init();
    let args: Vec<_> = env::args_os().collect();
    dylint_driver::dylint_driver(&args)
}
