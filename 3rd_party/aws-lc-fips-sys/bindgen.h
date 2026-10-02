// Bindgen adds the symbol namespace with --prefix-link-name. Disable C macro
// renaming here so Rust exposes the upstream API names, including the wrapper
// functions, and applies the namespace exactly once to their link names.
#undef BORINGSSL_PREFIX
#include "rust_wrapper.h"
