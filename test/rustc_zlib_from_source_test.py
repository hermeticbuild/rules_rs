#!/usr/bin/env python3
"""Builds and runs a Rust binary with rustc's zlib built from source."""

from __future__ import annotations

import os
import pathlib
import pwd
import shutil
import subprocess
import tempfile
import textwrap
import unittest


class RustcZlibFromSourceTest(unittest.TestCase):
    def test_rustc_runs_with_source_built_zlib(self) -> None:
        bazel = shutil.which("bazel")
        self.assertIsNotNone(bazel, "The zlib end-to-end test requires bazel on PATH")

        rules_rs_root = pathlib.Path(__file__).resolve().parent.parent
        bazel_environment = dict(os.environ)
        bazel_environment.pop("TEST_TMPDIR", None)
        bazel_environment["HOME"] = pwd.getpwuid(os.getuid()).pw_dir

        with tempfile.TemporaryDirectory(prefix="rs-zlib-") as temporary_directory:
            temporary_root = pathlib.Path(temporary_directory)
            workspace = temporary_root / "workspace"
            workspace.mkdir()
            self._write_workspace(workspace, rules_rs_root)

            result = subprocess.run(
                [
                    bazel,
                    "--ignore_all_rc_files",
                    "--batch",
                    f"--output_base={temporary_root / 'bazel'}",
                    "run",
                    "--lockfile_mode=off",
                    "--repo_env=BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1",
                    "--repo_env=BAZEL_NO_APPLE_CPP_TOOLCHAIN=1",
                    "--@rules_rs//rs/private:rustc_zlib_from_source=true",
                    "//:hello",
                ],
                cwd=workspace,
                check=False,
                capture_output=True,
                text=True,
                timeout=300,
                env=bazel_environment,
            )

            self.assertEqual(
                result.returncode,
                0,
                f"Bazel run failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            self.assertEqual(result.stdout.strip(), "zlib from source")

    @staticmethod
    def _write_workspace(workspace: pathlib.Path, rules_rs_root: pathlib.Path) -> None:
        files = {
            "MODULE.bazel": f"""\
                module(name = "rustc_zlib_from_source_test")

                bazel_dep(name = "llvm", version = "0.8.18")
                bazel_dep(name = "rules_rs", version = "0.0.0")
                local_path_override(
                    module_name = "rules_rs",
                    path = {str(rules_rs_root)!r},
                )

                toolchains = use_extension(
                    "@rules_rs//rs/toolchains:module_extension.bzl",
                    "toolchains",
                )
                use_repo(toolchains, "default_rust_toolchains")

                register_toolchains(
                    "@default_rust_toolchains//...",
                    "@llvm//toolchain:all",
                )
                """,
            "BUILD.bazel": """\
                load("@rules_rs//rs:rust_binary.bzl", "rust_binary")

                rust_binary(
                    name = "hello",
                    srcs = ["main.rs"],
                    edition = "2021",
                )
                """,
            "main.rs": 'fn main() { println!("zlib from source"); }\n',
        }
        for name, content in files.items():
            (workspace / name).write_text(textwrap.dedent(content))


if __name__ == "__main__":
    unittest.main()
