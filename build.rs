fn main() {
    use vergen::EmitBuilder;

    EmitBuilder::builder()
        .all_git()
        .emit()
        .expect("vergen failed");
}
