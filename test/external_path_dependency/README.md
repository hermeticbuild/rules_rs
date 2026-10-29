# External Cargo manifest tests

Run both tests from the `test/` workspace:

```sh
bazel test //external_path_dependency:all
```

The fixture copies its Cargo workspace into a reproducible Bazel repository so
Bazel can symlink it into the repository contents cache, as with `http_archive`.
The Rust test builds and calls a vendored path dependency from this repository.

The manifest watch test changes only the vendored crate's default features and
queries the generated target again on the same Bazel server. It then makes that
crate a workspace member and checks that editing its edition updates the hub.
Neither edit changes `Cargo.lock`.
