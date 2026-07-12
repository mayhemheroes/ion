// Fuzz ion's statement parser — the same code path as upstream's fuzz/ crate
// (statement splitting + parse), reached through the crate's PUBLIC API:
// upstream's #[cfg(fuzzing)] helper references the private `statement::parse`
// module and no longer compiles, and its fuzz/ crate pins libfuzzer-sys to an
// unpinned git URL. StatementSplitter + parse_and_validate drive the identical
// splitter + statement::parse::parse machinery.
#![no_main]
use libfuzzer_sys::fuzz_target;

use ion_shell::parser::{parse_and_validate, StatementSplitter};

fuzz_target!(|data: &[u8]| {
    if let Ok(s) = std::str::from_utf8(data) {
        for statement in StatementSplitter::new(s) {
            if let Ok(variant) = statement {
                let _ = parse_and_validate(variant);
            }
        }
    }
});
