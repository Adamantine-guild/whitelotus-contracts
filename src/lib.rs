#![no_std]

use soroban_sdk::{
    contract, contractimpl, contracttype, token, Address, Env, String, Vec
};

mod storage_layout;

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

/// `#[contracttype]` encodes each unit variant as its name, stored as a
/// Symbol -- not by declaration order -- so reordering these is harmless.
/// Renaming or removing a variant is not: see `storage_layout`'s test,
/// which pins the current encoding of every variant.
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
