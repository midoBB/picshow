use std::process::Command;

fn run_git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?;
    Some(s.trim().to_string())
}

fn main() {
    // Detect if HEAD is exactly at a tag (annotated or lightweight)
    let tag = run_git(&["describe", "--tags", "--exact-match"]);

    // Short SHA as fallback
    let sha = run_git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".into());

    // Optional: ensure working tree is clean
    let is_clean = run_git(&["status", "--porcelain"])
        .map(|s| s.is_empty())
        .unwrap_or(false);

    if let Some(tag) = tag.filter(|_| is_clean) {
        println!("cargo:rustc-env=APP_VERSION={}", tag);
    } else {
        println!("cargo:rustc-env=APP_VERSION={}", sha);
    }

    // Rebuild triggers
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-changed=.git/refs");
    println!("cargo:rerun-if-changed=.git/index"); // tracks working tree changes
}
