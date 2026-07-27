#![no_std]

use soroban_sdk::{
    contract, contractimpl, contracttype, token, Address, Env, String, Vec
};

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
        assert!(
            !env.storage().instance().has(&DataKey::Admin),
            "Already initialized"
        );
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
        assert!(uri.len() > 0, "uri empty");

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
            .expect("app !exists");

        assert!(app.status == AppStatus::Pending, "not pending");
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
            .expect("app !exists");

        assert!(app.status == AppStatus::Pending, "not pending");
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
            .expect("app !exists");

        assert!(app.status == AppStatus::Approved, "app !approved");
        assert!(!env.storage().persistent().has(&DataKey::Milestones(app_id)), "already set");
        assert!(amounts.len() > 0, "no milestones");

        let mut milestones = Vec::new(&env);
        for amount in amounts.iter() {
            assert!(amount > 0, "amount 0");
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
            .expect("app !exists");

        app.applicant.require_auth();
        assert!(app.status == AppStatus::Approved, "app !approved");

        let mut milestones: Vec<Milestone> = env
            .storage()
            .persistent()
            .get(&DataKey::Milestones(app_id))
            .expect("milestones !exist");

        assert!(index < milestones.len(), "bad index");
        let mut m = milestones.get(index).unwrap();
        assert!(!m.submitted, "already submitted");
        assert!(evidence_uri.len() > 0, "evidence empty");

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
            .expect("milestones !exist");

        assert!(index < milestones.len(), "bad index");
        let mut m = milestones.get(index).unwrap();
        assert!(m.submitted, "not submitted");
        assert!(!m.approved, "already approved");

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
            .expect("app !exists");

        let mut milestones: Vec<Milestone> = env
            .storage()
            .persistent()
            .get(&DataKey::Milestones(app_id))
            .expect("milestones !exist");

        assert!(index < milestones.len(), "bad index");
        let mut m = milestones.get(index).unwrap();
        assert!(m.approved, "!approved");
        assert!(!m.paid, "paid");

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
