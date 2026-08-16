use core::fmt::{Display, Write as _};

pub trait Integer: Display {}

impl<T: Display> Integer for T {}

pub struct Buffer {
    value: String,
}

impl Buffer {
    pub fn new() -> Self {
        Self {
            value: String::new(),
        }
    }

    pub fn format<I: Integer>(&mut self, value: I) -> &str {
        self.value.clear();
        let result = write!(&mut self.value, "{value}");
        debug_assert!(result.is_ok());
        &self.value
    }
}
