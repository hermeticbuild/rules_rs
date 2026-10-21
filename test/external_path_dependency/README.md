# External vendored path dependency regression test

Run from the `test/` workspace:

```sh
bazel --ignore_all_rc_files test --lockfile_mode=off //external_path_dependency:external_path_dependency_test
```

The existing test workspace loads rules_rs from the surrounding checkout.
The fixture uses only synthetic source files and public toolchain dependencies.

The Rust test depends on a generated vendored-crate target and calls that crate's
function, checking that the dependency resolves, compiles, and links. On unmodified
rules_rs main after #213, dependency resolution fails before the test runs:

```text
mctx.watch(mctx.path(cargo_toml_path))
Error in watch: attempted to watch path outside workspace, but it's prohibited in the current context
```

The source repository copies five tiny checked-in Cargo/Rust files and declares
itself reproducible, matching the cached repository behavior of `http_archive`
without an archive download. Cargo excludes the vendored dependency from workspace
membership, ensuring rules_rs processes it as a path dependency. Cargo reports
its manifest under Bazel's repository contents cache, outside the workspace;
`module_ctx.watch` rejects that path.

Ignoring ambient bazelrc files and disabling module lockfile reuse prevents a
previously cached successful extension evaluation from hiding the failure. The
existing CI test matrix runs this target with the other integration tests.

The resolver watches path dependency manifests only for local workspaces. External
source repositories are tracked through their repository inputs. With this fix,
the same Bazel target resolves, compiles, links, and passes its Rust assertion.
