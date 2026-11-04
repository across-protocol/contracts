//! IDL build tooling: export hidden V5 wire schemas using the actual Rust derives.
use anchor_lang::idl::IdlBuild;
use std::collections::BTreeMap;
use svm_spoke::v5::codec::{AcrossDepositJitParams, V5AdapterInput, V5FillJit};

fn main() {
    let mut types = BTreeMap::new();
    types.insert(V5AdapterInput::get_full_path(), V5AdapterInput::create_type().expect("V5AdapterInput IDL schema"));
    V5AdapterInput::insert_types(&mut types);
    types.insert(
        AcrossDepositJitParams::get_full_path(),
        AcrossDepositJitParams::create_type().expect("AcrossDepositJitParams IDL schema"),
    );
    AcrossDepositJitParams::insert_types(&mut types);
    types.insert(V5FillJit::get_full_path(), V5FillJit::create_type().expect("V5FillJit IDL schema"));
    V5FillJit::insert_types(&mut types);
    println!("{}", serde_json::to_string(&types.into_values().collect::<Vec<_>>()).unwrap());
}
