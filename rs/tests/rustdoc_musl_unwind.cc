extern "C" int rustdoc_musl_unwind_value() {
    try {
        throw 430;
    } catch (int value) {
        return value;
    }
}
