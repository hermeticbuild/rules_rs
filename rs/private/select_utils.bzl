def platform_label(triple, use_legacy_rules_rust_platforms):
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def compute_select(non_platform_items, platform_items):
    if not platform_items:
        return non_platform_items, {}

    item_values = platform_items.values()
    common_items = set(item_values[0])
    for values in item_values[1:]:
        common_items.intersection_update(values)
        if not common_items:
            break

    common_items.update(non_platform_items)

    branches = {}
    for platform, items in platform_items.items():
        items = set(items)
        items.difference_update(common_items)
        if items:
            branches[platform] = sorted(items)

    return common_items, branches

def shared_and_per_platform(platform_items, use_legacy_rules_rust_platforms):
    by_platform = {}
    for triple, items in platform_items.items():
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        by_platform.setdefault(platform, set()).update(items)

    items, per_platform = compute_select([], by_platform)
    return sorted(items), per_platform
