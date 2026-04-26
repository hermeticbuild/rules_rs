#[cfg(not(miri))]
compile_error!("miri_dep_graph_test must run with cfg(miri)");

#[cfg(miri)]
const _: () = ();

#[test]
fn uses_miri_compiled_dependency() {
    assert_eq!(miri_dep::value_from_miri_dep() + 1, 42);
}
