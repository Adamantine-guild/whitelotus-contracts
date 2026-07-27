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
