fn main() {
    feature_split_build_macro::check_exec_feature!();
    build_only_helper::check();
    feature_split_shared::exec_only();
}
