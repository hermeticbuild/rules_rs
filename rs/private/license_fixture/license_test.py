"""Regression tests for https://github.com/hermeticbuild/rules_rs/issues/280."""

import json
import sys
from pathlib import Path

from python.runfiles import runfiles


def main():
    manifest, purl, expression, *original = sys.argv[1:]
    resolver = runfiles.Create()
    entries = json.loads(Path(resolver.Rlocation(manifest)).read_text())
    files = {entry["path"]: Path(resolver.Rlocation(entry["runfile"])) for entry in entries}
    packages = [
        json.loads(file.read_text())
        for path, file in files.items()
        if path.endswith(".package-metadata.json")
    ]
    matches = [package for package in packages if package["purl"] == purl]
    assert len(matches) == 1, (purl, packages)
    attributes = matches[0]["attributes"]
    if not expression:
        assert attributes == {}, attributes
        return
    assert set(attributes) == {"build.bazel.attribute.license"}, attributes
    license_document = json.loads(files[attributes["build.bazel.attribute.license"]].read_text())
    assert license_document["kind"]["identifier"] == expression, license_document
    if original:
        collected_text = files[license_document["text"]].read_bytes()
        original_text = Path(resolver.Rlocation(original[0])).read_bytes()
        assert collected_text == original_text
    else:
        assert "text" not in license_document, license_document


if __name__ == "__main__":
    main()
