"""Crate identity."""

load("//rs/private:downloader.bzl", "parse_git_url")

_HASH_MODULUS = 2305843009213693951

_HASH_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

_HASH_CHARACTERS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

_HASH_BASE = len(_HASH_DIGITS)

_HASH_DIGEST_LENGTH = 12

def spoke_repo(hub_name, name, version):
    s = "%s__%s-%s" % (hub_name, name, version)
    if "+" in s:
        s = s.replace("+", "-")
    return s

def repo_component(value):
    """Returns a deterministic repository-name-safe encoding."""

    # Escape the escape marker first so these substitutions remain injective.
    value = value.replace("_", "_underscore_")
    for char, replacement in [
        ("+", "_plus_"),
        (":", "_colon_"),
        ("/", "_slash_"),
        ("@", "_at_"),
        ("?", "_question_"),
        ("&", "_ampersand_"),
        ("=", "_equals_"),
        ("#", "_hash_"),
        ("%", "_percent_"),
        ("~", "_tilde_"),
        ("!", "_bang_"),
        ("$", "_dollar_"),
        ("'", "_quote_"),
        ("(", "_lparen_"),
        (")", "_rparen_"),
        ("*", "_star_"),
        (",", "_comma_"),
        (";", "_semicolon_"),
        ("[", "_lbracket_"),
        ("]", "_rbracket_"),
        ("\\", "_backslash_"),
    ]:
        value = value.replace(char, replacement)
    return value

def stable_identity_digest(value):
    """Returns a compact deterministic digest for an ASCII Cargo identity."""
    result = 0
    for char in value.elems():
        code = _HASH_CHARACTERS.find(char)
        if code == -1:
            fail("Cannot hash non-ASCII Cargo identity component %r" % char)
        result = (result * 257 + code + 1) % _HASH_MODULUS

    encoded = ""
    for _ in range(_HASH_DIGEST_LENGTH):
        encoded = _HASH_DIGITS[result % _HASH_BASE] + encoded
        result = result // _HASH_BASE
    return encoded

def normalize_git_remote(remote):
    """Normalizes syntax that does not change a Git repository's identity."""
    remote = remote.removesuffix("/")
    remote = remote.removesuffix(".git")

    scheme_separator = remote.find("://")
    if scheme_separator == -1:
        return remote

    scheme = remote[:scheme_separator].lower()
    remainder = remote[scheme_separator + len("://"):]
    path_separator = remainder.find("/")
    if path_separator == -1:
        return scheme + "://" + remainder.lower()

    authority = remainder[:path_separator].lower()
    path = remainder[path_separator:]
    return scheme + "://" + authority + path

def canonical_spoke_repo(package, package_path = "", class_index = 0):
    """Returns the repository name for one compatibility class."""
    source = package["source"]
    name = repo_component(package["name"])
    version = repo_component(package["version"])
    identity = package_identity(package, package_path)

    if source.startswith("sparse+"):
        base = "rs_pkg__%s-%s__registry_%s" % (
            name,
            version,
            stable_identity_digest(identity),
        )
    elif source.startswith("git+"):
        base = "rs_pkg__%s-%s__git_%s" % (
            name,
            version,
            stable_identity_digest(identity),
        )
    else:
        fail("Cannot create a canonical spoke name for %s" % source)

    if class_index:
        return "%s__class_%d" % (base, class_index + 1)
    return base

def canonical_git_repo(remote, commit, checkout_fingerprint):
    identity = json.encode([
        normalize_git_remote(remote),
        commit,
        checkout_fingerprint,
    ])
    return "rs_git__%s" % stable_identity_digest(identity)

def package_identity(package, package_path = ""):
    source = package["source"]
    if source.startswith("sparse+"):
        return json.encode([
            "registry",
            source,
            package["name"],
            package["version"],
        ])
    if source.startswith("git+"):
        remote, commit = parse_git_url(source)
        return json.encode([
            "git",
            normalize_git_remote(remote),
            commit,
            package_path,
            package["name"],
            package["version"],
        ])
    return None

def crate_identity(package, package_path = ""):
    """Returns the reserved ``cargo:`` logical library identity for a package.

    Cargo Package IDs are opaque and complete: registry provenance carries the
    fully qualified source, Git provenance carries the normalized remote, pinned
    commit, and workspace member path. The same configured package always yields
    the same identity, so distinct compatibility classes for one package still
    share one logical ID and are caught by the link-unit validator when they
    converge in one artifact.
    """
    identity = package_identity(package, package_path)
    if not identity:
        return None
    return "cargo:" + identity
