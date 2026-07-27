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

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AppStatus {
    Pending,
    Approved,
    Rejected,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Application {
    pub applicant: Address,
    pub uri: String,
    pub status: AppStatus,
}

#[contracttype]
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Milestone {
    pub amount: i128,
    pub evidence_uri: String,
    pub submitted: bool,
    pub approved: bool,
    pub paid: bool,
}

#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    Admin,
    Title,
    MetadataURI,
    Budget,
    Token,
    AppCount,
    Application(u32),
    Milestones(u32),
}

// ─── Contract ────────────────────────────────────────────────────────────────

#[contract]
pub struct GrantRoundContract;

#[contractimpl]
impl GrantRoundContract {
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
        milestones.set(index, m);
        env.storage().persistent().set(&DataKey::Milestones(app_id), &milestones);

        // Transfer funds
        let token_id: Address = env.storage().instance().get(&DataKey::Token).unwrap();
        let token_client = token::Client::new(&env, &token_id);
        token_client.transfer(&env.current_contract_address(), &app.applicant, &m.amount);
    }

    pub fn get_milestones(env: Env, app_id: u32) -> Vec<Milestone> {
        env.storage().persistent().get(&DataKey::Milestones(app_id)).unwrap_or(Vec::new(&env))
    }

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
}

mod test;
