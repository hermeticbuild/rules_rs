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
mkdir hub_metadata
cat > hub_metadata/BUILD.bazel <<'BUILD'
load("@crates//:defs.bzl", "edition")
filegroup(name = "edition_" + edition("vendor/dependency"))
BUILD
cat > BUILD.bazel <<'BUILD'
load("@crates//:packages.bzl", "PACKAGES")
load("@crates//vendored-dependency:data.bzl", "crate_data")
filegroup(name = PACKAGES["vendor/dependency"] + "_" + crate_data()["edition"])
BUILD
query "set(//hub_metadata:edition_2021 //:vendored-dependency_2021)"
sed -i.bak 's/edition = "2021"/edition = "2024"/' "$manifest"
query "set(//hub_metadata:edition_2024 //:vendored-dependency_2024)"

# Omit hub-wide metadata while keeping root aliases and per-member loads.
sed -i.bak 's/incompatible_no_root_alias_targets = True/incompatible_no_root_crate_data = True/' MODULE.bazel
query "set(@crates//:vendored-dependency-0.1.0 //:vendored-dependency_2024)"
hub_build=$(query --output=location @crates//:_workspace_deps)
hub_dir=${hub_build%/BUILD.bazel:*}
[[ -f "$hub_dir/packages.bzl" && ! -e "$hub_dir/data.bzl" && ! -e "$hub_dir/defs.bzl" ]]
