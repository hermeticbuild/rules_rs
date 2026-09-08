#!/usr/bin/env python3

"""End-to-end test for canonical sparse-registry authentication."""

import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tarfile
import tempfile
import threading

TOKEN = "fixture-token"


def _crate_archive(crate_name, value=42):
    contents = {
        f"{crate_name}-1.0.0/Cargo.toml": f"""\
[package]
name = "{crate_name}"
version = "1.0.0"
edition = "2021"
""".encode(),
        f"{crate_name}-1.0.0/src/lib.rs": f"pub fn value() -> u32 {{ {value} }}\n".encode(),
    }
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name, content in contents.items():
            info = tarfile.TarInfo(name)
            info.mtime = 0
            info.mode = 0o644
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    return output.getvalue()


class _RegistryHandler(http.server.BaseHTTPRequestHandler):
    archives = {}
    checksums = {}
    requests = []

    def do_GET(self):
        token = self.headers.get("Authorization")
        self.__class__.requests.append((self.path, token))

        is_private = self.path.startswith("/private-")
        is_public = self.path.startswith("/public-")
        if is_private and token != TOKEN:
            self.send_error(http.HTTPStatus.UNAUTHORIZED)
            return
        if is_public and token is not None:
            self.send_error(http.HTTPStatus.BAD_REQUEST, "credential sent to public registry")
            return

        port = self.server.server_address[1]
        if self.path == "/private-index/config.json":
            self._send_json({
                "auth-required": True,
                "dl": f"https://127.0.0.1:{port}/private-api",
            })
        elif self.path == "/public-index/config.json":
            self._send_json({
                "auth-required": False,
                "dl": f"https://127.0.0.1:{port}/public-api",
            })
        elif self.path in (
            "/private-index/pr/iv/private-crate",
            "/public-index/pu/bl/public-crate",
            "/private-index/sh/ad/shadowed-crate",
            "/public-index/sh/ad/shadowed-crate",
        ):
            crate_name = self.path.rsplit("/", 1)[1]
            archive_key = ("private-" if is_private else "public-") + crate_name
            self._send_json(
                {
                    "name": crate_name,
                    "vers": "1.0.0",
                    "deps": [],
                    "cksum": self.checksums[archive_key],
                    "features": {},
                    "yanked": False,
                }
            )
        elif self.path in (
            "/private-api/private-crate/1.0.0/download",
            "/public-api/public-crate/1.0.0/download",
            "/private-api/shadowed-crate/1.0.0/download",
            "/public-api/shadowed-crate/1.0.0/download",
        ):
            crate_name = self.path.split("/")[2]
            archive_key = ("private-" if is_private else "public-") + crate_name
            archive = self.archives[archive_key]
            self.send_response(http.HTTPStatus.OK)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Length", str(len(archive)))
            self.end_headers()
            self.wfile.write(archive)
        else:
            self.send_error(http.HTTPStatus.NOT_FOUND)

    def _send_json(self, value):
        body = json.dumps(value, separators=(",", ":")).encode() + b"\n"
        self.send_response(http.HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def _write_fixture(root, rules_rs, port, checksums):
    private_source = f"sparse+https://127.0.0.1:{port}/private-index/"
    public_source = f"sparse+https://127.0.0.1:{port}/public-index/"
    (root / ".cargo").mkdir()
    (root / "src").mkdir()
    (root / "cargo-home").mkdir()

    (root / "MODULE.bazel").write_text(f"""\
module(name = "private_registry_fetch_fixture")

bazel_dep(name = "rules_rs", version = "0.0.0")
local_path_override(
    module_name = "rules_rs",
    path = {json.dumps(str(rules_rs))},
)

crate = use_extension("@rules_rs//rs:extensions.bzl", "crate")
crate.from_cargo(
    name = "a_anonymous",
    cargo_lock = "//:Cargo.lock",
    cargo_toml = "//:Cargo.toml",
    platform_triples = ["x86_64-unknown-linux-gnu"],
)
crate.from_cargo(
    name = "z_authenticated",
    cargo_config = "//:.cargo/config.toml",
    cargo_lock = "//:Cargo.lock",
    cargo_toml = "//:Cargo.toml",
    platform_triples = ["x86_64-unknown-linux-gnu"],
    use_home_cargo_credentials = True,
)
crate.from_cargo(
    name = "public_shadow",
    cargo_config = "//:.cargo/config.toml",
    cargo_lock = "//:public-shadow/Cargo.lock",
    cargo_toml = "//:public-shadow/Cargo.toml",
    platform_triples = ["x86_64-unknown-linux-gnu"],
)
crate.from_cargo(
    name = "private_shadow",
    cargo_config = "//:.cargo/config.toml",
    cargo_lock = "//:private-shadow/Cargo.lock",
    cargo_toml = "//:private-shadow/Cargo.toml",
    platform_triples = ["x86_64-unknown-linux-gnu"],
    use_home_cargo_credentials = True,
)
use_repo(crate, "a_anonymous", "z_authenticated", "public_shadow", "private_shadow")
""")
    (root / "BUILD.bazel").write_text("""\
alias(
    name = "anonymous_facade",
    actual = "@a_anonymous//:private-crate",
)

alias(
    name = "authenticated_facade",
    actual = "@z_authenticated//:private-crate",
)

alias(
    name = "anonymous_public_facade",
    actual = "@a_anonymous//:public-crate",
)

alias(
    name = "authenticated_public_facade",
    actual = "@z_authenticated//:public-crate",
)

alias(
    name = "public_shadow_facade",
    actual = "@public_shadow//:shadowed-crate",
)

alias(
    name = "private_shadow_facade",
    actual = "@private_shadow//:shadowed-crate",
)
""")
    (root / "Cargo.toml").write_text("""\
[package]
name = "private-registry-fixture"
version = "0.1.0"
edition = "2021"

[dependencies]
private-crate = "1.0.0"
public-crate = "1.0.0"
""")
    (root / "Cargo.lock").write_text(f"""\
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "private-crate"
version = "1.0.0"
source = {json.dumps(private_source)}
checksum = {json.dumps(checksums["private-private-crate"])}

[[package]]
name = "public-crate"
version = "1.0.0"
source = {json.dumps(public_source)}
checksum = {json.dumps(checksums["public-public-crate"])}

[[package]]
name = "private-registry-fixture"
version = "0.1.0"
dependencies = [
 "private-crate",
 "public-crate",
]
""")
    for registry, source in (("public", public_source), ("private", private_source)):
        shadow_root = root / f"{registry}-shadow"
        shadow_root.mkdir()
        (shadow_root / "src").mkdir()
        (shadow_root / "src/lib.rs").write_text("pub fn fixture() {}\n")
        (shadow_root / "Cargo.toml").write_text(f"""\
[package]
name = "{registry}-shadow-fixture"
version = "0.1.0"
edition = "2021"

[dependencies]
shadowed-crate = "1.0.0"
""")
        (shadow_root / "Cargo.lock").write_text(f"""\
# This file is automatically @generated by Cargo.
version = 4

[[package]]
name = "shadowed-crate"
version = "1.0.0"
source = {json.dumps(source)}
checksum = {json.dumps(checksums[registry + "-shadowed-crate"])}

[[package]]
name = "{registry}-shadow-fixture"
version = "0.1.0"
dependencies = [
 "shadowed-crate",
]
""")
    (root / "src/lib.rs").write_text("pub fn fixture() {}\n")
    (root / ".cargo/config.toml").write_text(f"""\
[registries.private]
index = {json.dumps(private_source)}

[registries.public]
index = {json.dumps(public_source)}
""")
    (root / "cargo-home/credentials.toml").write_text(f"""\
[registries.private]
token = {json.dumps(TOKEN)}

[registries.public]
token = {json.dumps(TOKEN)}
""")


def main():
    bazel = shutil.which("bazel")
    if not bazel:
        raise RuntimeError("bazel must be on PATH for the nested Bazel fixture")

    rules_rs = Path(__file__).resolve().parents[2]
    java_home = Path(
        subprocess.check_output(
            [bazel, "info", "java-home"],
            cwd=rules_rs,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    )
    keytool = java_home / "bin/keytool"
    default_truststore = java_home / "lib/security/cacerts"
    archives = {
        "private-private-crate": _crate_archive("private-crate"),
        "public-public-crate": _crate_archive("public-crate"),
        "private-shadowed-crate": _crate_archive("shadowed-crate", value=1),
        "public-shadowed-crate": _crate_archive("shadowed-crate", value=2),
    }
    checksums = {
        crate_name: hashlib.sha256(archive).hexdigest()
        for crate_name, archive in archives.items()
    }
    _RegistryHandler.archives = archives
    _RegistryHandler.checksums = checksums
    _RegistryHandler.requests = []

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        ca_certificate = root / "ca-certificate.pem"
        ca_key = root / "ca-key.pem"
        certificate = root / "server-certificate.pem"
        certificate_request = root / "server.csr"
        private_key = root / "server-key.pem"
        certificate_extensions = root / "certificate-extensions"
        certificate_extensions.write_text(
            "subjectAltName=IP:127.0.0.1\n"
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
        )
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-keyout",
                ca_key,
                "-out",
                ca_certificate,
                "-days",
                "1",
                "-nodes",
                "-subj",
                "/CN=private-registry-fixture-ca",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                "openssl",
                "req",
                "-newkey",
                "rsa:2048",
                "-keyout",
                private_key,
                "-out",
                certificate_request,
                "-nodes",
                "-subj",
                "/CN=127.0.0.1",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                "openssl",
                "x509",
                "-req",
                "-in",
                certificate_request,
                "-CA",
                ca_certificate,
                "-CAkey",
                ca_key,
                "-CAcreateserial",
                "-out",
                certificate,
                "-days",
                "1",
                "-extfile",
                certificate_extensions,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        truststore = root / "truststore.jks"
        shutil.copyfile(default_truststore, truststore)
        subprocess.run(
            [
                keytool,
                "-importcert",
                "-noprompt",
                "-trustcacerts",
                "-alias",
                "private-registry-fixture",
                "-file",
                ca_certificate,
                "-keystore",
                truststore,
                "-storepass",
                "changeit",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _RegistryHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            _write_fixture(root, rules_rs, server.server_address[1], checksums)
            environment = os.environ.copy()
            environment["CARGO_HOME"] = str(root / "cargo-home")
            query = " + ".join([
                "deps(//:anonymous_facade, 3)",
                "deps(//:authenticated_facade, 3)",
                "deps(//:anonymous_public_facade, 3)",
                "deps(//:authenticated_public_facade, 3)",
                "deps(//:public_shadow_facade, 3)",
                "deps(//:private_shadow_facade, 3)",
            ])
            result = subprocess.run(
                [
                    bazel,
                    f"--output_base={root / 'bazel-output-base'}",
                    f"--host_jvm_args=-Djavax.net.ssl.trustStore={truststore}",
                    "--host_jvm_args=-Djavax.net.ssl.trustStorePassword=changeit",
                    "--ignore_all_rc_files",
                    "query",
                    query,
                    "--registry=https://bcr.bazel.build",
                    "--output=label",
                ],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if result.returncode:
                raise RuntimeError(result.stdout)

            for crate_name in ("private-crate", "public-crate"):
                canonical = {
                    line.split("//", 1)[0]
                    for line in result.stdout.splitlines()
                    if (
                        line.startswith("@@") and
                        f"rs_pkg__{crate_name}-1.0.0__registry_" in line
                    )
                }
                if len(canonical) != 1:
                    raise AssertionError(
                        f"expected one canonical {crate_name}, got {sorted(canonical)}\n{result.stdout}"
                    )

            shadowed = {
                line.split("//", 1)[0]
                for line in result.stdout.splitlines()
                if line.startswith("@@") and "rs_pkg__shadowed-crate-1.0.0__registry_" in line
            }
            if len(shadowed) != 2:
                raise AssertionError(
                    "expected source-distinct canonical shadowed-crate repositories, "
                    f"got {sorted(shadowed)}\n{result.stdout}"
                )
        finally:
            server.shutdown()
            thread.join()

        requested_paths = {path for path, _token in _RegistryHandler.requests}
        expected_paths = {
            "/private-index/config.json",
            "/private-index/pr/iv/private-crate",
            "/private-api/private-crate/1.0.0/download",
            "/private-index/sh/ad/shadowed-crate",
            "/private-api/shadowed-crate/1.0.0/download",
            "/public-index/config.json",
            "/public-index/pu/bl/public-crate",
            "/public-api/public-crate/1.0.0/download",
            "/public-index/sh/ad/shadowed-crate",
            "/public-api/shadowed-crate/1.0.0/download",
        }
        if not expected_paths.issubset(requested_paths):
            raise AssertionError(f"missing authenticated registry requests: {sorted(expected_paths - requested_paths)}")
        private_requests = [
            (path, token)
            for path, token in _RegistryHandler.requests
            if path.startswith("/private-")
        ]
        public_requests = [
            (path, token)
            for path, token in _RegistryHandler.requests
            if path.startswith("/public-")
        ]
        private_config_tokens = [
            token
            for path, token in private_requests
            if path == "/private-index/config.json"
        ]
        if private_config_tokens != [None, TOKEN]:
            raise AssertionError(
                f"private config.json did not use anonymous-then-authenticated requests: {private_config_tokens}"
            )
        if any(token != TOKEN for path, token in private_requests if path != "/private-index/config.json"):
            raise AssertionError("private registry request did not receive the selected credential")
        if any(token is not None for _path, token in public_requests):
            raise AssertionError("public registry received a credential")


if __name__ == "__main__":
    main()
