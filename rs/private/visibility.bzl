"""Visibility selection for generated Cargo targets."""

def visibility_for(settings, hub_name, crate_name, internal_packages = []):
    """Select consumer visibility, retaining access for generated dependencies.

    Args:
        settings: Visibility tags from the declaring module.
        hub_name: Cargo hub repository being generated.
        crate_name: Cargo package name, without a version suffix.
        internal_packages: Visibility labels for repositories in this closure.

    Returns:
        A list of visibility labels, public by default.
    """
    result = None
    for setting in settings:
        if setting.repositories and hub_name not in setting.repositories:
            continue
        if not setting.crates:
            fail("crate.visibility requires at least one crate name or prefix")
        matches = False
        for pattern in setting.crates:
            if not pattern or "*" in pattern[:-1]:
                fail("crate.visibility accepts exact names or a trailing *: %r" % pattern)
            if crate_name.startswith(pattern[:-1]) if pattern.endswith("*") else crate_name == pattern:
                matches = True
        if matches:
            if result != None:
                fail("Overlapping crate.visibility settings for %s in %s" % (crate_name, hub_name))
            result = [str(label) for label in setting.visibility]
    if result == None or any([label.endswith("//visibility:public") for label in result]):
        return ["//visibility:public"]

    # Private/empty consumer visibility still permits the hub and other generated
    # crates to use this crate as a transitive dependency.
    return [label for label in result if not label.endswith("//visibility:private")] + internal_packages
