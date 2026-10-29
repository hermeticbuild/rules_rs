# External Cargo manifests

Run both tests from the `test/` workspace.

```sh
bazel test //external_path_dependency:all
```

`source_repository` copies the Cargo workspace into a reproducible external
repository so Bazel can store it in the repository contents cache.
`external_path_dependency_test` builds and calls the vendored crate.

`manifest_watch_test` edits the vendored crate's default features and queries
the generated target on the same Bazel server. It then adds the crate to the
workspace, edits its edition, and queries the edition from `@crates//:defs.bzl`.
Both edits leave `Cargo.lock` unchanged.
