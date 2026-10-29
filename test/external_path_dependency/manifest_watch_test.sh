#!/usr/bin/env bash
set -euo pipefail

package=$(dirname "$(realpath "$0")")
rules_rs=$(cd "$package/../.." && pwd)
tmp=$(mktemp -d)
bazel=(bazel --ignore_all_rc_files --output_base="$tmp/output")
trap '"${bazel[@]}" shutdown; rm -rf "$tmp"' EXIT
unset TEST_TMPDIR

mkdir -p "$tmp/workspace/external_path_dependency"
cd "$tmp/workspace"
cp "$rules_rs/.bazelversion" .
cp -R "$package/fixture" "$package/source_repository.bzl" external_path_dependency/
touch external_path_dependency/BUILD.bazel
cat > MODULE.bazel <<'MODULE'
bazel_dep(name = "rules_rs", version = "0.0.0")
source = use_repo_rule("//external_path_dependency:source_repository.bzl", "source_repository")
source(name = "source")
crate = use_extension("@rules_rs//rs:extensions.bzl", "crate", isolate = True)
crate.from_cargo(
    cargo_lock = "@source//:Cargo.lock",
    cargo_toml = "@source//:Cargo.toml",
    platform_triples = ["x86_64-unknown-linux-gnu"],
)
use_repo(crate, "crates")
MODULE
query() {
    "${bazel[@]}" query --override_module="rules_rs=$rules_rs" \
        --experimental_isolated_extension_usages --repo_contents_cache="$tmp/repos" "$@"
}

fixture=external_path_dependency/fixture
manifest=$fixture/vendor/dependency/Cargo.toml
spoke='labels(actual, @crates//:vendored-dependency-0.1.0)'
printf '\n[features]\ndefault = ["before"]\nbefore = []\nafter = []\n' >> "$manifest"
query "attr(crate_features, before, $spoke)" | grep -F '//:vendored-dependency'
sed -i.bak 's/default = \["before"\]/default = ["after"]/' "$manifest"
query "attr(crate_features, after, $spoke)" | grep -F '//:vendored-dependency'

# The same crate can also be a workspace member. Its edition is part of the hub.
sed -i.bak 's/exclude =/members =/' "$fixture/Cargo.toml"
cat > BUILD.bazel <<'BUILD'
load("@crates//:defs.bzl", "edition")
filegroup(name = "edition_" + edition("vendor/dependency"))
BUILD
query //:all | grep -Fx //:edition_2021
sed -i.bak 's/edition = "2021"/edition = "2024"/' "$manifest"
query //:all | grep -Fx //:edition_2024
