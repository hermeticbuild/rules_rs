#![no_std]

extern crate alloc;

use alloc::vec::Vec;

pub fn len(values: Vec<u8>) -> usize {
    values.len()
}
