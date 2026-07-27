#![cfg(test)]

use super::*;
use soroban_sdk::{testutils::Address as _, Address, Env, String, Vec};
use soroban_sdk::token::Client as TokenClient;
use soroban_sdk::token::StellarAssetClient;

fn create_token_contract<'a>(env: &Env, admin: &Address) -> (Address, StellarAssetClient<'a>, TokenClient<'a>) {
    let contract_id = env.register_stellar_asset_contract(admin.clone());
    (
        contract_id.clone(),
        StellarAssetClient::new(env, &contract_id),
        TokenClient::new(env, &contract_id),
    )
}

struct Setup {
    contract_id: Address,
    admin: Address,
    applicant: Address,
    token_id: Address,
}

fn setup(env: &Env) -> Setup {
    env.mock_all_auths();
    let admin = Address::generate(env);
    let applicant = Address::generate(env);
    let (token_id, _token_admin, _token_client) = create_token_contract(env, &admin);

    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(env, "Test Round"),
        &String::from_str(env, "ipfs://meta"),
        &1000,
        &token_id,
    );
    Setup { contract_id, admin, applicant, token_id }
}

// ── Happy path ───────────────────────────────────────────────────────────────

#[test]
fn test_grant_round_flow() {
    let env = Env::default();
    env.mock_all_auths();

    let admin = Address::generate(&env);
    let applicant = Address::generate(&env);

    let (token_id, token_admin_client, token_client) = create_token_contract(&env, &admin);

    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "Test Round"),
        &String::from_str(&env, "ipfs://test"),
        &1000,
        &token_id,
    );

    let app_id = client.submit_application(&applicant, &String::from_str(&env, "ipfs://app1"));
    assert_eq!(app_id, 1);

    client.approve_application(&app_id);

    let mut amounts = Vec::new(&env);
    amounts.push_back(100);
    amounts.push_back(200);

    client.create_milestones(&app_id, &amounts);

    let milestones = client.get_milestones(&app_id);
    assert_eq!(milestones.len(), 2);
    assert_eq!(milestones.get(0).unwrap().amount, 100);

    client.submit_milestone_evidence(&app_id, &0, &String::from_str(&env, "ipfs://evidence"));

    let milestones = client.get_milestones(&app_id);
    assert_eq!(milestones.get(0).unwrap().submitted, true);

    client.approve_milestone(&app_id, &0);

    let milestones = client.get_milestones(&app_id);
    assert_eq!(milestones.get(0).unwrap().approved, true);

    // Fund the contract
    token_admin_client.mint(&contract_id, &1000);
    assert_eq!(token_client.balance(&contract_id), 1000);

    // Release payout
    client.release_payout(&app_id, &0);

    let milestones = client.get_milestones(&app_id);
    assert_eq!(milestones.get(0).unwrap().paid, true);
    assert_eq!(token_client.balance(&applicant), 100);
    assert_eq!(token_client.balance(&contract_id), 900);

    // Clawback
    client.clawback_unspent_funds(&admin);
    assert_eq!(token_client.balance(&contract_id), 0);
    assert_eq!(token_client.balance(&admin), 900);
}

// ── Error path coverage ──────────────────────────────────────────────────────

#[test]
fn test_initialize_twice_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let (second_token, _, _) = create_token_contract(&env, &s.admin);
    let result = client.try_initialize(
        &s.admin,
        &String::from_str(&env, "x"),
        &String::from_str(&env, "y"),
        &1,
        &second_token,
    );
    assert_eq!(result, Err(Ok(Error::AlreadyInitialized)));
}

#[test]
fn test_submit_application_empty_uri_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let result = client.try_submit_application(&s.applicant, &String::from_str(&env, ""));
    assert_eq!(result, Err(Ok(Error::EmptyUri)));
}

#[test]
fn test_approve_nonexistent_application_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let result = client.try_approve_application(&99);
    assert_eq!(result, Err(Ok(Error::ApplicationNotFound)));
}

#[test]
fn test_approve_already_approved_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);

    let result = client.try_approve_application(&app_id);
    assert_eq!(result, Err(Ok(Error::NotPending)));
}

#[test]
fn test_reject_nonexistent_application_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let result = client.try_reject_application(&99);
    assert_eq!(result, Err(Ok(Error::ApplicationNotFound)));
}

#[test]
fn test_reject_approved_application_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);

    let result = client.try_reject_application(&app_id);
    assert_eq!(result, Err(Ok(Error::NotPending)));
}

#[test]
fn test_create_milestones_not_approved_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);

    let result = client.try_create_milestones(&app_id, &amounts);
    assert_eq!(result, Err(Ok(Error::NotApproved)));
}

#[test]
fn test_create_milestones_already_set_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);

    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);

    let result = client.try_create_milestones(&app_id, &amounts);
    assert_eq!(result, Err(Ok(Error::MilestonesAlreadySet)));
}

#[test]
fn test_create_milestones_empty_amounts_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);

    let amounts: Vec<i128> = Vec::new(&env);
    let result = client.try_create_milestones(&app_id, &amounts);
    assert_eq!(result, Err(Ok(Error::NoMilestones)));
}

#[test]
fn test_create_milestones_zero_amount_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);

    let mut amounts = Vec::new(&env);
    amounts.push_back(0i128);
    let result = client.try_create_milestones(&app_id, &amounts);
    assert_eq!(result, Err(Ok(Error::ZeroAmount)));
}

#[test]
fn test_submit_evidence_bad_index_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);

    let result = client.try_submit_milestone_evidence(
        &app_id,
        &99,
        &String::from_str(&env, "ipfs://evidence"),
    );
    assert_eq!(result, Err(Ok(Error::BadIndex)));
}

#[test]
fn test_submit_evidence_already_submitted_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);
    client.submit_milestone_evidence(&app_id, &0, &String::from_str(&env, "ipfs://ev"));

    let result = client.try_submit_milestone_evidence(
        &app_id,
        &0,
        &String::from_str(&env, "ipfs://ev2"),
    );
    assert_eq!(result, Err(Ok(Error::AlreadySubmitted)));
}

#[test]
fn test_submit_evidence_empty_uri_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);

    let result = client.try_submit_milestone_evidence(
        &app_id,
        &0,
        &String::from_str(&env, ""),
    );
    assert_eq!(result, Err(Ok(Error::EmptyEvidence)));
}

#[test]
fn test_approve_milestone_not_submitted_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);

    let result = client.try_approve_milestone(&app_id, &0);
    assert_eq!(result, Err(Ok(Error::NotSubmitted)));
}

#[test]
fn test_approve_milestone_already_approved_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);
    client.submit_milestone_evidence(&app_id, &0, &String::from_str(&env, "ipfs://ev"));
    client.approve_milestone(&app_id, &0);

    let result = client.try_approve_milestone(&app_id, &0);
    assert_eq!(result, Err(Ok(Error::AlreadyApproved)));
}

#[test]
fn test_release_payout_not_approved_errors() {
    let env = Env::default();
    let s = setup(&env);
    let client = GrantRoundContractClient::new(&env, &s.contract_id);

    let app_id = client.submit_application(&s.applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);
    client.submit_milestone_evidence(&app_id, &0, &String::from_str(&env, "ipfs://ev"));

    let result = client.try_release_payout(&app_id, &0);
    assert_eq!(result, Err(Ok(Error::NotApprovedMilestone)));
}

#[test]
fn test_release_payout_already_paid_errors() {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let applicant = Address::generate(&env);
    let (token_id, token_admin_client, _) = create_token_contract(&env, &admin);
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);
    client.initialize(
        &admin,
        &String::from_str(&env, "R"),
        &String::from_str(&env, "M"),
        &1000,
        &token_id,
    );

    let app_id = client.submit_application(&applicant, &String::from_str(&env, "ipfs://x"));
    client.approve_application(&app_id);
    let mut amounts = Vec::new(&env);
    amounts.push_back(100i128);
    client.create_milestones(&app_id, &amounts);
    client.submit_milestone_evidence(&app_id, &0, &String::from_str(&env, "ipfs://ev"));
    client.approve_milestone(&app_id, &0);
    token_admin_client.mint(&contract_id, &1000);
    client.release_payout(&app_id, &0);

    let result = client.try_release_payout(&app_id, &0);
    assert_eq!(result, Err(Ok(Error::AlreadyPaid)));
}
