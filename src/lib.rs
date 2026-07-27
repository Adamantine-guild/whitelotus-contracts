#![no_std]

use soroban_sdk::{
    contract, contracterror, contractimpl, contracttype, token, Address, Env, String, Vec,
};

// ─── Custom Errors ──────────────────────────────────────────────────────────
//
// Custom errors cost no ledger bytes on revert — the EVM/Wasm runtime encodes
// only the 4-byte (u32) discriminant instead of an arbitrary string. This
// mirrors the Solidity custom-error pattern for gas/resource savings.

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum Error {
    /// `initialize` called on an already-initialized contract.
    AlreadyInitialized = 1,
    /// The application URI string was empty.
    EmptyUri = 2,
    /// The application does not exist in storage.
    ApplicationNotFound = 3,
    /// The application is not in the expected `Pending` status.
    NotPending = 4,
    /// The application is not in `Approved` status.
    NotApproved = 5,
    /// Milestones have already been created for this application.
    MilestonesAlreadySet = 6,
    /// The milestones list was empty.
    NoMilestones = 7,
    /// A milestone amount must be greater than zero.
    ZeroAmount = 8,
    /// The milestone set does not exist in storage.
    MilestonesNotFound = 9,
    /// The milestone index is out of range.
    BadIndex = 10,
    /// Evidence has already been submitted for this milestone.
    AlreadySubmitted = 11,
    /// The evidence URI string was empty.
    EmptyEvidence = 12,
    /// The milestone has not yet been submitted by the grantee.
    NotSubmitted = 13,
    /// The milestone has already been approved.
    AlreadyApproved = 14,
    /// The milestone has not been approved yet.
    NotApprovedMilestone = 15,
    /// The milestone payout has already been made.
    AlreadyPaid = 16,
}

// ─── Types ───────────────────────────────────────────────────────────────────
mod governance;
mod storage_layout;
/// Lifecycle state of an [`Application`].
pub mod math;
pub mod zk;

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AppStatus {
    /// Submitted, awaiting admin review.
    Pending,
    /// Approved by the admin; milestones can now be created against it.
    Approved,
    /// Rejected by the admin; terminal state, no further action possible.
    Rejected,
}

/// A grant application submitted by a prospective recipient.
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Application {
    /// The address that submitted the application and will receive payouts.
    pub applicant: Address,
    /// Off-chain URI (e.g. IPFS) pointing at the application's content.
    pub uri: String,
    pub status: AppStatus,
}

/// A single funding milestone belonging to an approved [`Application`].
#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Milestone {
    /// Amount paid out, in the grant round's token, once this milestone
    /// is approved and released.
    pub amount: i128,
    /// Off-chain URI pointing at proof-of-completion evidence. Empty until
    /// the applicant calls [`GrantRoundContract::submit_milestone_evidence`].
    pub evidence_uri: String,
    /// Set once the applicant has submitted evidence.
    pub submitted: bool,
    /// Set once the admin has approved the submitted evidence.
    pub approved: bool,
    /// Set once funds have been transferred to the applicant.
    pub paid: bool,
}

/// `#[contracttype]` encodes each unit variant as its name, stored as a
/// Symbol -- not by declaration order -- so reordering these is harmless.
/// Renaming or removing a variant is not: see `storage_layout`'s test,
/// which pins the current encoding of every variant.
/// Storage keys for the contract's instance and persistent storage.
///
/// `#[contracttype]` encodes each unit variant as its name, stored as a
/// Symbol -- not by declaration order -- so reordering these is harmless.
/// Renaming or removing a variant is not: any storage entry already keyed
/// under the old name becomes unreachable after an upgrade, since nothing
/// will construct that `DataKey` again to look it up.
#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    Admin,
    Title,
    MetadataURI,
    Budget,
    Token,
    AppCount,
    /// Keyed by application id (1-indexed, see [`GrantRoundContract::submit_application`]).
    Application(u32),
    /// Keyed by application id; holds that application's `Vec<Milestone>`.
    Milestones(u32),
}

// ─── Contract ────────────────────────────────────────────────────────────────

#[contract]
pub struct GrantRoundContract;

#[contractimpl]
impl GrantRoundContract {
    /// Initializes the grant round. Can only be called once per contract
    /// instance; panics if `Admin` is already set.
    ///
    /// - `admin`: address authorized to approve/reject applications and
    ///   milestones, and to release payouts and claw back unspent funds.
    /// - `title`, `metadata_uri`: display metadata for the round.
    /// - `budget`: informational total budget; not enforced on-chain here.
    /// - `token`: the SEP-41 token contract payouts are made in.
    pub fn initialize(
        env: Env,
        admin: Address,
        title: String,
        metadata_uri: String,
        budget: i128,
        token: Address,
    ) {
        if env.storage().instance().has(&DataKey::Admin) {
            env.panic_with_error(Error::AlreadyInitialized);
        }
        env.storage().instance().set(&DataKey::Admin, &admin);
        env.storage().instance().set(&DataKey::Title, &title);
        env.storage().instance().set(&DataKey::MetadataURI, &metadata_uri);
        env.storage().instance().set(&DataKey::Budget, &budget);
        env.storage().instance().set(&DataKey::Token, &token);
        env.storage().instance().set(&DataKey::AppCount, &0u32);
    }

    /// Submits a new application on behalf of `applicant`. Requires
    /// `applicant`'s authorization. Returns the new application's id
    /// (1-indexed).
    ///
    /// Panics if `uri` is empty.
    pub fn submit_application(env: Env, applicant: Address, uri: String) -> u32 {
        applicant.require_auth();
        if uri.len() == 0 {
            env.panic_with_error(Error::EmptyUri);
        }

        let mut app_count: u32 = env.storage().instance().get(&DataKey::AppCount).unwrap();
        app_count += 1;

        let app = Application {
            applicant: applicant.clone(),
            uri: uri.clone(),
            status: AppStatus::Pending,
        };

        env.storage().persistent().set(&DataKey::Application(app_count), &app);
        env.storage().instance().set(&DataKey::AppCount, &app_count);

        app_count
    }

    /// Approves a pending application. Admin-only.
    ///
    /// Panics if `app_id` doesn't exist or the application isn't `Pending`.
    pub fn approve_application(env: Env, app_id: u32) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let mut app: Application = env
            .storage()
            .persistent()
            .get(&DataKey::Application(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::ApplicationNotFound));

        if app.status != AppStatus::Pending {
            env.panic_with_error(Error::NotPending);
        }
        app.status = AppStatus::Approved;
        env.storage().persistent().set(&DataKey::Application(app_id), &app);
    }

    /// Rejects a pending application. Admin-only.
    ///
    /// Panics if `app_id` doesn't exist or the application isn't `Pending`.
    pub fn reject_application(env: Env, app_id: u32) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let mut app: Application = env
            .storage()
            .persistent()
            .get(&DataKey::Application(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::ApplicationNotFound));

        if app.status != AppStatus::Pending {
            env.panic_with_error(Error::NotPending);
        }
        app.status = AppStatus::Rejected;
        env.storage().persistent().set(&DataKey::Application(app_id), &app);
    }

    /// Creates the milestone schedule for an approved application, one
    /// entry per amount in `amounts`. Admin-only, and can only be called
    /// once per application.
    ///
    /// Panics if `app_id` doesn't exist, isn't `Approved`, already has
    /// milestones, `amounts` is empty, or any amount is zero.
    pub fn create_milestones(env: Env, app_id: u32, amounts: Vec<i128>) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let app: Application = env
            .storage()
            .persistent()
            .get(&DataKey::Application(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::ApplicationNotFound));

        if app.status != AppStatus::Approved {
            env.panic_with_error(Error::NotApproved);
        }
        if env.storage().persistent().has(&DataKey::Milestones(app_id)) {
            env.panic_with_error(Error::MilestonesAlreadySet);
        }
        if amounts.len() == 0 {
            env.panic_with_error(Error::NoMilestones);
        }

        let mut milestones = Vec::new(&env);
        for amount in amounts.iter() {
            if amount <= 0 {
                env.panic_with_error(Error::ZeroAmount);
            }
            milestones.push_back(Milestone {
                amount,
                evidence_uri: String::from_str(&env, ""),
                submitted: false,
                approved: false,
                paid: false,
            });
        }
        env.storage().persistent().set(&DataKey::Milestones(app_id), &milestones);
    }

    /// Submits proof-of-completion evidence for one milestone. Requires the
    /// application's `applicant`'s authorization.
    ///
    /// Panics if the application or milestone index doesn't exist, the
    /// application isn't `Approved`, the milestone was already submitted,
    /// or `evidence_uri` is empty.
    pub fn submit_milestone_evidence(env: Env, app_id: u32, index: u32, evidence_uri: String) {
        let app: Application = env
            .storage()
            .persistent()
            .get(&DataKey::Application(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::ApplicationNotFound));

        app.applicant.require_auth();

        if app.status != AppStatus::Approved {
            env.panic_with_error(Error::NotApproved);
        }

        let mut milestones: Vec<Milestone> = env
            .storage()
            .persistent()
            .get(&DataKey::Milestones(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::MilestonesNotFound));

        if index >= milestones.len() {
            env.panic_with_error(Error::BadIndex);
        }
        let mut m = milestones.get(index).unwrap();
        if m.submitted {
            env.panic_with_error(Error::AlreadySubmitted);
        }
        if evidence_uri.len() == 0 {
            env.panic_with_error(Error::EmptyEvidence);
        }

        m.evidence_uri = evidence_uri;
        m.submitted = true;
        milestones.set(index, m);
        env.storage().persistent().set(&DataKey::Milestones(app_id), &milestones);
    }

    /// Approves a submitted milestone, making it eligible for payout.
    /// Admin-only.
    ///
    /// Panics if the milestone index doesn't exist, hasn't been submitted,
    /// or was already approved.
    pub fn approve_milestone(env: Env, app_id: u32, index: u32) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let mut milestones: Vec<Milestone> = env
            .storage()
            .persistent()
            .get(&DataKey::Milestones(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::MilestonesNotFound));

        if index >= milestones.len() {
            env.panic_with_error(Error::BadIndex);
        }
        let mut m = milestones.get(index).unwrap();
        if !m.submitted {
            env.panic_with_error(Error::NotSubmitted);
        }
        if m.approved {
            env.panic_with_error(Error::AlreadyApproved);
        }

        m.approved = true;
        milestones.set(index, m);
        env.storage().persistent().set(&DataKey::Milestones(app_id), &milestones);
    }

    /// Transfers an approved milestone's funds to the applicant. Admin-only.
    ///
    /// Panics if the milestone index doesn't exist, hasn't been approved,
    /// or was already paid.
    pub fn release_payout(env: Env, app_id: u32, index: u32) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let app: Application = env
            .storage()
            .persistent()
            .get(&DataKey::Application(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::ApplicationNotFound));

        let mut milestones: Vec<Milestone> = env
            .storage()
            .persistent()
            .get(&DataKey::Milestones(app_id))
            .unwrap_or_else(|| env.panic_with_error(Error::MilestonesNotFound));

        if index >= milestones.len() {
            env.panic_with_error(Error::BadIndex);
        }
        let mut m = milestones.get(index).unwrap();
        if !m.approved {
            env.panic_with_error(Error::NotApprovedMilestone);
        }
        if m.paid {
            env.panic_with_error(Error::AlreadyPaid);
        }

        m.paid = true;
        let amount = m.amount;
        milestones.set(index, m);
        env.storage().persistent().set(&DataKey::Milestones(app_id), &milestones);

        // Transfer funds
        let token_id: Address = env.storage().instance().get(&DataKey::Token).unwrap();
        let token_client = token::Client::new(&env, &token_id);
        token_client.transfer(&env.current_contract_address(), &app.applicant, &amount);
    }

    /// Returns `app_id`'s milestone list, or an empty vector if none have
    /// been created yet.
    pub fn get_milestones(env: Env, app_id: u32) -> Vec<Milestone> {
        env.storage().persistent().get(&DataKey::Milestones(app_id)).unwrap_or(Vec::new(&env))
    }

    /// Sets `account`'s voting-power balance, admin-gated the same way the
    /// rest of this contract's writes are. See `governance` for how this
    /// interacts with proposal snapshots.
    pub fn set_voting_balance(env: Env, account: Address, balance: i128) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();
        governance::set_balance(&env, &account, balance);
    }

    pub fn get_votes(env: Env, account: Address, ledger_sequence: u32) -> i128 {
        governance::get_votes(&env, &account, ledger_sequence)
    }

    pub fn create_voting_proposal(env: Env) -> u32 {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();
        governance::create_proposal(&env)
    }

    pub fn get_votes_for_proposal(env: Env, account: Address, proposal_id: u32) -> i128 {
        governance::get_votes_for_proposal(&env, &account, proposal_id)
    }

    /// Sweeps the contract's entire remaining token balance to `to`.
    /// Admin-only. No-op if the balance is zero.
    pub fn clawback_unspent_funds(env: Env, to: Address) {
        let admin: Address = env.storage().instance().get(&DataKey::Admin).unwrap();
        admin.require_auth();

        let token_id: Address = env.storage().instance().get(&DataKey::Token).unwrap();
        let token_client = token::Client::new(&env, &token_id);
        let balance = token_client.balance(&env.current_contract_address());

        if balance > 0 {
            token_client.transfer(&env.current_contract_address(), &to, &balance);
        }
    }

    /// Verifies a Groth16 proof against `vk` and `public_inputs` using the
    /// host's native BLS12-381 pairing check. Panics on an invalid proof;
    /// returns `true` on a valid one.
    pub fn verify_zk_proof(
        env: Env,
        vk: zk::VerifyingKey,
        proof: zk::Groth16Proof,
        public_inputs: Vec<soroban_sdk::crypto::bls12_381::Fr>,
    ) -> bool {
        zk::require_valid_groth16(&env, &vk, &proof, &public_inputs);
        true
    }
}

mod test;
