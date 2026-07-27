//! Snapshot-based voting power for grant round proposals.
//!
//! The original ask ("inherit ERC20Snapshot", "getVotes(account,
//! blockNumber)") is Solidity/OpenZeppelin vocabulary that doesn't map onto
//! this Soroban codebase -- there's no ERC20Snapshot to inherit and no
//! Governor contract here to integrate with. The underlying problem it's
//! solving does apply though: if voting power is read from an account's
//! *current* balance at the moment a vote is cast, someone can flash-loan a
//! large balance, vote, and return it in the same transaction, since nothing
//! stops the balance from changing again before or after the vote.
//!
//! The fix here is the same idea OpenZeppelin's checkpoint-based
//! `ERC20Votes` uses, adapted to Soroban's primitives: instead of snapshotting
//! *all* balances at proposal creation (what a literal `ERC20Snapshot` does,
//! which is O(n) in the number of holders), each account keeps a history of
//! `(ledger_sequence, balance)` checkpoints. Creating a proposal pins a
//! ledger sequence number (Soroban's equivalent of a block number) as that
//! proposal's voting snapshot. Reading voting power for a proposal means
//! "find the most recent checkpoint at or before that sequence number" -- a
//! later balance change can't retroactively change what already happened at
//! an earlier ledger sequence.
//!
//! These are free functions rather than their own `#[contract]`, so they
//! plug into `GrantRoundContract`'s existing storage the same way `math` or
//! `zk` would: called from `GrantRoundContract`'s `#[contractimpl]` methods,
//! not deployed as a second contract. (A second `#[contract]` in this crate
//! does compile, but it roughly doubles the exported symbol count, and this
//! crate's Windows/gnu test toolchain hits the linker's PE export-ordinal
//! limit as soon as a second contract's worth of generated exports gets
//! added on top of the first -- caught by just trying to run the full test
//! suite, not something obvious from reading the code.)

use soroban_sdk::{contracttype, Address, Env, Vec};

#[contracttype]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub ledger_sequence: u32,
    pub balance: i128,
}

#[contracttype]
#[derive(Clone)]
pub enum GovernanceDataKey {
    Checkpoints(Address),
    ProposalCount,
    ProposalSnapshot(u32),
}

/// Records `account`'s balance at the current ledger sequence. If a
/// checkpoint already exists for this exact sequence, it's overwritten
/// rather than duplicated -- see `create_proposal`'s doc comment for why
/// that matters for same-ledger flash-loan resistance.
pub fn set_balance(env: &Env, account: &Address, balance: i128) {
    assert!(balance >= 0, "balance must be non-negative");

    let key = GovernanceDataKey::Checkpoints(account.clone());
    let mut checkpoints: Vec<Checkpoint> = env.storage().persistent().get(&key).unwrap_or(Vec::new(env));
    let current_seq = env.ledger().sequence();

    let new_checkpoint = Checkpoint { ledger_sequence: current_seq, balance };
    if let Some(last) = checkpoints.last() {
        assert!(current_seq >= last.ledger_sequence, "ledger sequence went backwards");
        if last.ledger_sequence == current_seq {
            checkpoints.set(checkpoints.len() - 1, new_checkpoint);
        } else {
            checkpoints.push_back(new_checkpoint);
        }
    } else {
        checkpoints.push_back(new_checkpoint);
    }

    env.storage().persistent().set(&key, &checkpoints);
}

/// Voting power `account` had at `ledger_sequence`: the balance recorded by
/// the last checkpoint at or before that sequence, or 0 if the account had
/// no checkpoint yet by then.
pub fn get_votes(env: &Env, account: &Address, ledger_sequence: u32) -> i128 {
    let checkpoints: Vec<Checkpoint> = env
        .storage()
        .persistent()
        .get(&GovernanceDataKey::Checkpoints(account.clone()))
        .unwrap_or(Vec::new(env));

    checkpoint_at_or_before(&checkpoints, ledger_sequence)
}

/// Pins the *previous* ledger sequence as a new proposal's voting snapshot
/// and returns the proposal id.
///
/// This deliberately snapshots `current - 1`, not `current`: since
/// `set_balance` overwrites (rather than appends to) the checkpoint for
/// whatever sequence is currently open, a balance change landing in the same
/// sequence as `create_proposal` could otherwise still mutate the very
/// checkpoint this snapshot reads from. Snapshotting the already-closed
/// previous sequence -- the same trick OpenZeppelin's Governor uses -- means
/// the snapshot reads from a checkpoint that can no longer change no matter
/// what happens in the current one.
pub fn create_proposal(env: &Env) -> u32 {
    let mut proposal_count: u32 = env
        .storage()
        .instance()
        .get(&GovernanceDataKey::ProposalCount)
        .unwrap_or(0);
    proposal_count += 1;

    let snapshot_sequence = env.ledger().sequence().saturating_sub(1);
    env.storage()
        .instance()
        .set(&GovernanceDataKey::ProposalSnapshot(proposal_count), &snapshot_sequence);
    env.storage()
        .instance()
        .set(&GovernanceDataKey::ProposalCount, &proposal_count);

    proposal_count
}

pub fn get_proposal_snapshot(env: &Env, proposal_id: u32) -> u32 {
    env.storage()
        .instance()
        .get(&GovernanceDataKey::ProposalSnapshot(proposal_id))
        .expect("proposal !exists")
}

pub fn get_votes_for_proposal(env: &Env, account: &Address, proposal_id: u32) -> i128 {
    let snapshot_sequence = get_proposal_snapshot(env, proposal_id);
    get_votes(env, account, snapshot_sequence)
}

/// Binary search for the last checkpoint whose ledger sequence is <= the
/// target, mirroring how `ERC20Votes._checkpointsLookup` avoids a linear
/// scan over an account's whole history.
fn checkpoint_at_or_before(checkpoints: &Vec<Checkpoint>, ledger_sequence: u32) -> i128 {
    if checkpoints.is_empty() {
        return 0;
    }

    let mut low: u32 = 0;
    let mut high: u32 = checkpoints.len();

    while low < high {
        let mid = low + (high - low) / 2;
        if checkpoints.get(mid).unwrap().ledger_sequence > ledger_sequence {
            high = mid;
        } else {
            low = mid + 1;
        }
    }

    if low == 0 {
        0
    } else {
        checkpoints.get(low - 1).unwrap().balance
    }
}

#[cfg(test)]
mod test {
    use crate::{GrantRoundContract, GrantRoundContractClient};
    use soroban_sdk::testutils::{Address as _, Ledger};
    use soroban_sdk::{token, Address, Env, String};

    fn set_ledger_sequence(env: &Env, sequence: u32) {
        env.ledger().with_mut(|li| li.sequence_number = sequence);
    }

    fn setup(env: &Env) -> (Address, GrantRoundContractClient<'_>) {
        env.mock_all_auths();
        let admin = Address::generate(env);
        let token_id = env.register_stellar_asset_contract(admin.clone());

        let contract_id = env.register_contract(None, GrantRoundContract);
        let client = GrantRoundContractClient::new(env, &contract_id);
        client.initialize(
            &admin,
            &String::from_str(env, "Test Round"),
            &String::from_str(env, "ipfs://test"),
            &1000,
            &token_id,
        );
        let _ = token::Client::new(env, &token_id);
        (admin, client)
    }

    #[test]
    fn get_votes_reflects_balance_at_the_requested_sequence() {
        let env = Env::default();
        let (_admin, client) = setup(&env);
        let alice = Address::generate(&env);

        set_ledger_sequence(&env, 100);
        client.set_voting_balance(&alice, &1_000);

        set_ledger_sequence(&env, 200);
        client.set_voting_balance(&alice, &5_000);

        assert_eq!(client.get_votes(&alice, &100), 1_000);
        assert_eq!(client.get_votes(&alice, &150), 1_000);
        assert_eq!(client.get_votes(&alice, &200), 5_000);
        assert_eq!(client.get_votes(&alice, &50), 0);
    }

    #[test]
    fn later_balance_change_cannot_alter_a_pinned_proposal_snapshot() {
        let env = Env::default();
        let (_admin, client) = setup(&env);
        let attacker = Address::generate(&env);

        set_ledger_sequence(&env, 10);
        client.set_voting_balance(&attacker, &0);

        // Proposal created while the attacker holds nothing; its snapshot
        // pins ledger sequence 9 (current - 1).
        let proposal_id = client.create_voting_proposal();

        // Same ledger sequence as proposal creation, attacker flash-loans a
        // large balance in, attempting to vote with it.
        client.set_voting_balance(&attacker, &1_000_000);
        assert_eq!(client.get_votes_for_proposal(&attacker, &proposal_id), 0);

        // A later, real balance change also can't retroactively apply to a
        // proposal that already snapshotted an earlier sequence.
        set_ledger_sequence(&env, 11);
        client.set_voting_balance(&attacker, &1_000_000);
        assert_eq!(client.get_votes_for_proposal(&attacker, &proposal_id), 0);
    }

    #[test]
    fn repeated_set_balance_in_the_same_sequence_overwrites_not_appends() {
        let env = Env::default();
        let (_admin, client) = setup(&env);
        let alice = Address::generate(&env);

        set_ledger_sequence(&env, 5);
        client.set_voting_balance(&alice, &100);
        client.set_voting_balance(&alice, &200);
        client.set_voting_balance(&alice, &300);

        assert_eq!(client.get_votes(&alice, &5), 300);
    }
}
