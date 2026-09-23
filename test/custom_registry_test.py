#!/usr/bin/env python3
"""Queries Rust targets generated from registry, path, and Git dependencies."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET


CRATE_NAME = "registry_smoke"
CRATE_VERSION = "1.0.0"


def _write_files(directory: pathlib.Path, files: dict[str, str]) -> None:
    for name, content in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content))


def _write_registry(directory: pathlib.Path) -> tuple[str, str]:
    index = directory / "index"
    crate = directory / f"{CRATE_NAME}-{CRATE_VERSION}"
    archive_path = directory / "crates" / CRATE_NAME / CRATE_VERSION / "download"

    _write_files(
        crate,
        {
            "Cargo.toml": f"""\
                [package]
                name = "{CRATE_NAME}"
                version = "{CRATE_VERSION}"
                edition = "2021"
                """,
            "src/lib.rs": "pub fn answer() -> u32 { 42 }\n",
            "build.rs": 'fn main() { println!("cargo:warning=dependency warning"); }\n',
        },
    )
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, mode="w:gz") as archive:
        archive.add(crate, arcname=crate.name)
    checksum = hashlib.sha256(archive_path.read_bytes()).hexdigest()

    _write_files(
        directory,
        {
            "index/config.json": json.dumps(
                {"dl": (directory / "crates").as_uri()}
            )
            + "\n",
            f"index/re/gi/{CRATE_NAME}": json.dumps(
                {
                    "name": CRATE_NAME,
                    "vers": CRATE_VERSION,
                    "deps": [],
                    "cksum": checksum,
                    "features": {},
                    "yanked": False,
                }
            )
            + "\n",
        },
    )
    return f"sparse+{index.as_uri()}/", checksum


class CustomRegistryTest(unittest.TestCase):
    def test_dependency_sources(self) -> None:
        bazel = shutil.which("bazel")
        self.assertIsNotNone(bazel, "The custom registry test requires bazel on PATH")

        rules_rs_root = pathlib.Path(__file__).resolve().parent.parent
        self.assertTrue(
            (rules_rs_root / "rs" / "extensions.bzl").is_file(),
            f"Could not locate the rules_rs source checkout at {rules_rs_root}",
        )
        bazel_environment = dict(os.environ)
        # Nested Bazel must use the normal Bazel cache rather than TEST_TMPDIR.
        bazel_environment.pop("TEST_TMPDIR", None)
        if os.name == "posix":
            import pwd

            bazel_environment["HOME"] = pwd.getpwuid(os.getuid()).pw_dir

        # Bazel includes file registry URLs in repository names, so keep the
        # registry outside Bazel's deeply nested TEST_TMPDIR.
        with tempfile.TemporaryDirectory(prefix="rs-registry-") as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            registry_source, checksum = _write_registry(temporary_root / "registry")
            crate_directory = temporary_root / "registry" / f"{CRATE_NAME}-{CRATE_VERSION}"
            for args in (
                ["init", "--quiet"],
                ["add", "."],
                [
                    "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "--quiet", "-m", "Test crate",
                ],
            ):
                subprocess.run(["git", *args], cwd=crate_directory, check=True)
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=crate_directory, text=True,
            ).strip()
            for dependency_kind in ("named", "replacement", "path", "git"):
                with self.subTest(dependency_kind=dependency_kind):
                    workspace = temporary_root / "workspace"
                    hub_name = self._write_workspace(
                        workspace,
                        rules_rs_root,
                        registry_source,
                        checksum,
                        dependency_kind,
                    )

                    if dependency_kind in ("path", "git"):
                        manifest = workspace / "Cargo.toml"
                        if dependency_kind == "path":
                            shutil.copytree(crate_directory, workspace / "dependency")
                        dependency = (
                            'path = "dependency"'
                            if dependency_kind == "path"
                            else f'git = "{crate_directory.as_uri()}"'
                        )
                        manifest.write_text(manifest.read_text().replace(
                            f'{CRATE_NAME} = "={CRATE_VERSION}"',
                            f'{CRATE_NAME} = {{ {dependency} }}',
                        ))
                        lockfile = workspace / "Cargo.lock"
                        source = (
                            "" if dependency_kind == "path"
                            else f'source = "git+{crate_directory.as_uri()}#{commit}"\n'
                        )
                        lockfile.write_text(lockfile.read_text().replace(
                            'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                            f'checksum = "{checksum}"\n',
                            source,
                        ))

                    result = subprocess.run(
                        [
                            bazel,
                            "--ignore_all_rc_files",
                            "--batch",
                            f"--output_base={temporary_root / 'bazel'}",
                            "query",
                            "--lockfile_mode=off",
                            "--noimplicit_deps",
                            "--output=xml",
                            f"deps(@{hub_name}//:{CRATE_NAME}, 4)",
                        ],
                        cwd=workspace,
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=120,
                        env=bazel_environment,
                    )
                    self.assertEqual(
                        result.returncode,
                        0,
                        f"{dependency_kind} dependency Bazel query failed\n"
                        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
                    )
                    rules = ET.fromstring(result.stdout).findall("rule")
                    labels = [rule.attrib["name"] for rule in rules]
                    warnings = [
                        value.attrib["value"]
                        for rule in rules
                        for value in rule.findall("boolean[@name='emit_warnings']")
                    ]
                    self.assertEqual(
                        warnings,
                        ["true" if dependency_kind == "path" else "false"],
                        f"Unexpected build-script warnings for {dependency_kind} dependency:\n"
                        f"{result.stdout}",
                    )
                    self.assertIn(f"@{hub_name}//:{CRATE_NAME}", labels)
                    self.assertTrue(
                        any(
                            f"{hub_name}__" in label
                            and f"{CRATE_NAME}-{CRATE_VERSION}" in label
                            and label.endswith(f"//:{CRATE_NAME}")
                            for label in labels
                        ),
                        f"{dependency_kind} dependency query did not generate the "
                        f"{CRATE_NAME} {CRATE_VERSION} crate target: {labels}",
                    )

    def _write_workspace(
        self,
        workspace: pathlib.Path,
        rules_rs_root: pathlib.Path,
        registry_source: str,
        checksum: str,
        dependency_kind: str,
    ) -> str:
        hub_name = "custom_registry_crates_" + dependency_kind

        if dependency_kind == "named":
            cargo_config = f"""\
                [registries.artifactory]
                index = "{registry_source}"
                """
            dependency = (
                f'{CRATE_NAME} = {{ version = "={CRATE_VERSION}", '
                'registry = "artifactory" }'
            )
            lock_source = registry_source
        else:
            cargo_config = f"""\
                [source.crates-io]
                replace-with = "artifactory"

                [source.artifactory]
                registry = "{registry_source}"
                """
            dependency = f'{CRATE_NAME} = "={CRATE_VERSION}"'
            lock_source = "registry+https://github.com/rust-lang/crates.io-index"

        _write_files(
            workspace,
            {
                ".cargo/config.toml": cargo_config,
                "Cargo.toml": f"""\
                [package]
                name = "custom_registry"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                {dependency}
                """,
                "Cargo.lock": f"""\
                version = 4

                [[package]]
                name = "custom_registry"
                version = "0.1.0"
                dependencies = ["{CRATE_NAME}"]

                [[package]]
                name = "{CRATE_NAME}"
                version = "{CRATE_VERSION}"
                source = "{lock_source}"
                checksum = "{checksum}"
                """,
                "src/lib.rs": (
                    "pub fn registry_answer() -> u32 { registry_smoke::answer() }\n"
                ),
                "BUILD.bazel": "",
                "MODULE.bazel": f"""\
                module(name = "custom_registry_test")

                bazel_dep(name = "rules_rs", version = "0.0.0")
                local_path_override(
                    module_name = "rules_rs",
                    path = {str(rules_rs_root)!r},
                )

                crate = use_extension("@rules_rs//rs:extensions.bzl", "crate")
                crate.from_cargo(
                    name = "{hub_name}",
                    cargo_config = "//:.cargo/config.toml",
                    cargo_lock = "//:Cargo.lock",
                    cargo_toml = "//:Cargo.toml",
                    platform_triples = ["x86_64-unknown-linux-gnu"],
                )
                use_repo(crate, "{hub_name}")
                """,
            },
        )
        return hub_name


if __name__ == "__main__":
    unittest.main()
