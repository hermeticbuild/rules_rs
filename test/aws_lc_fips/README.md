# AWS-LC FIPS adapter smoke tests

The two Cargo fixtures test `aws-lc-fips-sys` with and without its `ssl` feature.
They use separate crate hubs with scoped annotations in `test/MODULE.bazel`.
Both exercise the native Rust wrapper, AWS-LC FIPS initialization, and
`aws-lc-rs` metadata forwarding. The SSL test creates and frees an SSL context.

Run from `test/` on x86_64 or aarch64 Linux:

```sh
bazel --nosystem_rc --nohome_rc test //aws_lc_fips:all
```

Until `aws-lc-fips@3.1.0` is published in BCR, add a registry checkout containing
its pending submission:

```sh
bazel --nosystem_rc --nohome_rc test //aws_lc_fips:all \
  --registry=file:///absolute/path/to/bazel-central-registry \
  --registry=https://bcr.bazel.build
```

The test module applies `compiler-runtime.patch` to remove the pending native
module's explicit `-lgcc` flag, allowing the hermetic LLVM toolchain to supply
its compiler runtime. This patch does not change the SSL bindings or symbols.
