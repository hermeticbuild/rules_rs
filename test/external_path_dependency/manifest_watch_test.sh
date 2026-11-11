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
    incompatible_no_root_alias_targets = False,
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
spoke='labels(actual, @crates//vendored-dependency-0.1.0)'
printf '\n[features]\ndefault = ["before"]\nbefore = []\nafter = []\n' >> "$manifest"
query "some(attr(crate_features, before, $spoke intersect labels(actual, @crates//:vendored-dependency-0.1.0)))"
sed -i.bak 's/incompatible_no_root_alias_targets = False/incompatible_no_root_alias_targets = True/' MODULE.bazel
root_aliases=$(query 'kind("alias rule", @crates//:*)')
[[ -z "$root_aliases" ]]
sed -i.bak 's/default = \["before"\]/default = ["after"]/' "$manifest"
query "some(attr(crate_features, after, $spoke))"

# Both metadata files must pick up changes to a workspace member's edition.
sed -i.bak 's/exclude =/members =/' "$fixture/Cargo.toml"
cat > BUILD.bazel <<'BUILD'
load("@crates//:defs.bzl", "edition")
load("@crates//packages/vendor/dependency:data.bzl", "crate_data")
filegroup(name = "edition_" + edition("vendor/dependency"))
filegroup(name = "member_edition_" + crate_data()["edition"])
BUILD
query "set(//:edition_2021 //:member_edition_2021)"
sed -i.bak 's/edition = "2021"/edition = "2024"/' "$manifest"
query "set(//:edition_2024 //:member_edition_2024)"
