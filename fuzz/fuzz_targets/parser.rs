#![no_main]
#[macro_use]
extern crate libfuzzer_sys;
extern crate ion_shell;

use ion_shell::parser::fuzzing::*;

fuzz_target!(|data: &str| {
    let _ = statement_parse(data, &ion_shell::builtins::BuiltinMap::default());
});
