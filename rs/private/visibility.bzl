"""Visibility for generated Cargo targets."""

def visibility_with_internal_access(visibility, internal_packages):
    """Retain generated dependency access alongside consumer visibility.

    Args:
        visibility: Consumer visibility labels from the selected annotation.
        internal_packages: Visibility labels for repositories in this closure.

    Returns:
        Visibility label strings suitable for generated targets and hub aliases.
    """
    labels = [str(label) for label in visibility]
    if any([label.endswith("//visibility:public") for label in labels]):
        return ["//visibility:public"]

    # Private/empty consumer visibility still permits the hub and other generated
    # crates to use this crate as a transitive dependency.
    return [label for label in labels if not label.endswith("//visibility:private")] + internal_packages
