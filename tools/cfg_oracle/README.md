# Cargo cfg oracle data

`rules_rs` uses the registered Rust compiler's baseline cfg values when it
evaluates Cargo target predicates. The checked-in table is generated for every
triple in `ALL_TARGET_TRIPLES` by running:

```text
rustc --print=cfg --target=<triple>
```

Regenerate the tables after changing the registered Rust version or the list
of supported triples:

```sh
bazel run //rs/private:update_cfg_target_data
bazel test //rs/private:cfg_parser_tests
bazel test //rs/private:update_cfg_target_data_tests
```

The generated-source test reruns the oracle and detects stale data. Target
triples not present in `ALL_TARGET_TRIPLES` are rejected.
