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
    for triple in sorted(platform_items):
        platform = platform_label(triple, use_legacy_rules_rust_platforms)
        by_platform.setdefault(platform, {}).update(platform_items[triple])

    values = by_platform.values()
    common = {dep: values[0][dep] for dep in sorted(values[0])} if values else {}
    for deps in values[1:]:
        if not common:
            break
        for dep in list(common):
            if dep not in deps or common[dep] != deps[dep]:
                common.pop(dep)
    return common, {
        platform: {dep: by_platform[platform][dep] for dep in sorted(by_platform[platform]) if dep not in common}
        for platform in sorted(by_platform)
        if by_platform[platform] != common
    }
