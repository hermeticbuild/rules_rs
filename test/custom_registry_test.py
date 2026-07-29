"""Queries Rust targets generated from on-disk Cargo sparse registries."""

from __future__ import annotations

import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import textwrap
import unittest


CRATE_NAME = "registry_smoke"
CRATE_VERSION = "1.0.0"
CRATE_SOURCE = "pub fn answer() -> u32 { 42 }\n"


def _crate_archive() -> bytes:
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w:gz") as tar:
        files = {
            "Cargo.toml": (
                "[package]\n"
                f'name = "{CRATE_NAME}"\n'
                f'version = "{CRATE_VERSION}"\n'
                'edition = "2021"\n'
            ),
            "src/lib.rs": CRATE_SOURCE,
        }
        for name, content in files.items():
            encoded = content.encode()
            entry = tarfile.TarInfo(f"{CRATE_NAME}-{CRATE_VERSION}/{name}")
            entry.size = len(encoded)
            entry.mode = 0o644
            tar.addfile(entry, io.BytesIO(encoded))
    return archive.getvalue()


def _write_files(directory: pathlib.Path, files: dict[str, str]) -> None:
    for name, content in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content))


def _write_registry(
    directory: pathlib.Path, registry_kind: str
) -> tuple[str, str]:
    archive = _crate_archive()
    checksum = hashlib.sha256(archive).hexdigest()
    index = directory / "index"
    archive_path = directory / "crates" / CRATE_NAME / CRATE_VERSION / "download"

    archive_path.parent.mkdir(parents=True, exist_ok=True)
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
                    "features": {f"{registry_kind}_fixture": []},
                    "yanked": False,
                }
            )
            + "\n",
        },
    )
    archive_path.write_bytes(archive)
    return f"sparse+{index.as_uri()}/", checksum


class CustomRegistryTest(unittest.TestCase):
    def test_sparse_registry(self) -> None:
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
            for registry_kind in ("named", "replacement"):
                with self.subTest(registry_kind=registry_kind):
                    registry_source, checksum = _write_registry(
                        temporary_root / "registries" / registry_kind,
                        registry_kind,
                    )
                    workspace = temporary_root / "workspace"
                    self._write_workspace(
                        workspace,
                        rules_rs_root,
                        registry_source,
                        checksum,
                        registry_kind,
                    )

                    print(f"Querying {registry_kind} on-disk sparse registry", flush=True)
                    result = subprocess.run(
                        [
                            bazel,
                            "--ignore_all_rc_files",
                            "--batch",
                            f"--output_base={temporary_root / 'bazel'}",
                            "query",
                            "--lockfile_mode=off",
                            "--noimplicit_deps",
                            "deps(//:custom_registry, 3)",
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
                        f"{registry_kind} registry Bazel query failed\n"
                        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
                    )
                    labels = result.stdout.splitlines()
                    self.assertIn("//:custom_registry", labels)
                    hub_name = "custom_registry_crates_" + registry_kind
                    self.assertIn(f"@{hub_name}//:{CRATE_NAME}", labels)
                    self.assertTrue(
                        any(
                            f"{hub_name}__{CRATE_NAME}-{CRATE_VERSION}" in label
                            and label.endswith(f"//:{CRATE_NAME}")
                            for label in labels
                        ),
                        f"{registry_kind} registry query did not generate the "
                        f"{CRATE_NAME} {CRATE_VERSION} crate target: {labels}",
                    )

    def _write_workspace(
        self,
        workspace: pathlib.Path,
        rules_rs_root: pathlib.Path,
        registry_source: str,
        checksum: str,
        registry_kind: str,
    ) -> None:
        hub_name = "custom_registry_crates_" + registry_kind

        if registry_kind == "named":
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
                "BUILD.bazel": f"""\
                load("@rules_rs//rs:rust_library.bzl", "rust_library")

                rust_library(
                    name = "custom_registry",
                    srcs = ["src/lib.rs"],
                    edition = "2021",
                    deps = ["@{hub_name}//:{CRATE_NAME}"],
                )
                """,
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


if __name__ == "__main__":
    unittest.main()
