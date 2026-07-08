def compute_select_dict(non_platform_items, platform_items):
    if not platform_items:
        return non_platform_items, {}

    item_values = platform_items.values()
    common_keys = set(item_values[0].keys())

    # FIXME: Currently we override values if the same value exists in
    #        both platform and non-platform items (or in multiple platforms).
    #        We should instead keep them in selects if they are different instead
    #        of merging.
    all_values = {key: item_values[0][key] for key in common_keys}

    for values in item_values[1:]:
        common_keys.intersection_update(values.keys())
        all_values = {
            key: all_values.get(key, values[key])
            for key in common_keys
        }
        if not common_keys:
            break

    common_keys.update(non_platform_items.keys())
    all_values.update(non_platform_items)

    branches = {}
    for platform, items in platform_items.items():
        keys = set(items.keys())
        keys.difference_update(non_platform_items.keys())
        keys.difference_update(common_keys)
        if keys:
            branches[platform] = sorted(keys)
            for key in keys:
                all_values[key] = items[key]

    return {
        key: all_values[key]
        for key in common_keys
    }, {
        platform: {
            key: all_values[key]
            for key in keys
        }
        for platform, keys in branches.items()
    }

def compute_select_list(non_platform_items, platform_items):
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
        items.difference_update(non_platform_items)
        items.difference_update(common_items)
        if items:
            branches[platform] = sorted(items)

    return common_items, branches
