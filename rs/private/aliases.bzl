load(":select_utils.bzl", "compute_select_dict")

def aliases(dep_data, platforms):
    shared_aliases = dep_data["aliases"]
    aliases_by_platform = {
        platform: dep_data["aliases_by_platform"].get(platform, {})
        for platform in platforms
    }

    aliases, per_platform = compute_select_dict(shared_aliases, aliases_by_platform)

    branches = {platform: aliases for platform, aliases in sorted(per_platform.items())}
    branches["//conditions:default"] = {}
    return aliases | select(branches)
