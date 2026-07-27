//! Guards against accidentally breaking storage compatibility across an
//! upgrade.
//!
//! Soroban has no proxy/implementation split the way an upgradeable
//! Solidity contract does (there's no separate storage contract and no
//! `__gap` slots), so "storage collision" here means something more direct:
//! `#[contracttype]` encodes a unit enum variant as its *name*, stored as a
//! Symbol (see `DataKey`'s doc comment in `lib.rs`). Renaming or removing a
//! `DataKey` variant after deploying means any storage entry already keyed
//! under the old name becomes permanently unreadable, since nothing in the
//! new code will ever construct that key again to look it up.
//!
//! The test in this module catches that class of mistake by checking each
//! variant's *actual* serialized encoding (not a hand-maintained guess at
//! what it should be) against the name that was true when this was
//! written. If the derive macro's output for a variant ever stops matching
//! the name pinned here, the test fails, forcing whoever made the change
//! to look at what they just broke instead of finding out after deploying.

#[cfg(test)]
mod test {
    use crate::DataKey;
    use soroban_sdk::{Env, IntoVal, Symbol, TryFromVal, Val, Vec};

    fn variant_symbol(env: &Env, key: DataKey) -> Symbol {
        let val: Val = key.into_val(env);
        let encoded: Vec<Val> = Vec::try_from_val(env, &val).unwrap();
        Symbol::try_from_val(env, &encoded.get(0).unwrap()).unwrap()
    }

    #[test]
    fn data_key_variant_names_match_pinned_encoding() {
        let env = Env::default();

        // Only append to this list -- an entry disappearing, or its
        // expected name changing, means an existing DataKey variant got
        // renamed or removed, which orphans whatever storage was already
        // written under that name.
        let cases: &[(DataKey, &str)] = &[
            (DataKey::Admin, "Admin"),
            (DataKey::Title, "Title"),
            (DataKey::MetadataURI, "MetadataURI"),
            (DataKey::Budget, "Budget"),
            (DataKey::Token, "Token"),
            (DataKey::AppCount, "AppCount"),
            (DataKey::Application(0), "Application"),
            (DataKey::Milestones(0), "Milestones"),
        ];

        for (key, expected_name) in cases {
            let actual = variant_symbol(&env, key.clone());
            let expected = Symbol::new(&env, expected_name);
            assert_eq!(
                actual, expected,
                "DataKey variant no longer encodes as {expected_name:?} -- \
                 existing storage entries under that key are now unreachable"
            );
        }
    }
}
