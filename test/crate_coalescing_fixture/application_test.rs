#[test]
fn third_party_type_crosses_first_party_module_boundary() {
    let request = library_bar::request("/coalesced");
    assert_eq!(library_baz::inspect(request), "/coalesced:bar:baz");
    assert_eq!(library_bar::derived("merged").value, "merged");
    library_baz::std_feature_is_enabled();
}
