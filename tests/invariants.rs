// ============================================================================
// Fuzz Invariant Tests for GrantRoundContract (Soroban)
//
// Issue #25 (`Fuzz Testing Invariants for AMM logic`) calls for fuzz
// invariant testing with bounded inputs and 10,000+ runs. While the issue
// is phrased in Solidity / Echidna / Foundry terms (x*y=k AMM), this repo
// is a Soroban / Rust grants contracts project. We adapt the *spirit* of
// the issue to the actual `GrantRoundContract`:
//
//   Headline invariant (Soroban analog of x*y=k conservation):
//       At every step and at the end of every scenario, no tokens are
//       created or destroyed. Equivalently, the total of money-in-motion
//       equals the amount the contract was funded with:
//           paid_to_applicants_total
//           + live_contract_balance
//           + clawback_total_to_admin
//           == funded_initial
//       This is checked after every individual action as well as at end
//       of run, so a violation traces to a single call.
//
//   Other invariants:
//     INV-1  Cross-check that release_calls == paid_count (no double-pay).
//     INV-2  paid_total <= funded (no overdraw).
//     INV-3  approved_total <= budget (cumulative approval bounded).
//     INV-4  Mirror state agrees with the live contract for every
//            application + every milestone.
//     INV-5  Mirrored contract balance equals live token balance, and is
//            non-negative.
//     INV-6  Token conservation (the headline Soroban x*y=k analog).
//     INV-7  Per-applicant fidelity: each applicant's live token balance
//            equals the sum of paid milestones attributed to them.
//     INV-8  Clawback exactness: the admin's live balance gain equals
//            the cumulative clawback amount moved by the mirror.
//
//   Bounded inputs are used per the issue's "Bound inputs to avoid
//   artificial reverts" requirement. Available actions are filtered to
//   only those with at least one valid target at every step, so the
//   fuzz harness never asks the contract to revert on a precondition.
//   Per-action mirror updates keep paid/clawback/balance monotonic so
//   conservation can be asserted after *every* call.
//
//   Runs are deterministic via a splitmix64 PRNG seeded per scenario,
//   so the entire 10,000-run sweep is reproducible.
// ============================================================================

use soroban_sdk::{testutils::Address as _, vec, Address, Env, String, Vec};
use soroban_sdk::token::{Client as TokenClient, StellarAssetClient};
use whitelotus_contracts::{GrantRoundContract, GrantRoundContractClient, Milestone};

// ---------- Bounded input space (no artificial reverts) --------------------
const RUNS: u32 = 10_000;
const ACTIONS_PER_RUN: u32 = 12;
const LONG_RUNS: u32 = 1_000;
const LONG_ACTIONS_PER_RUN: u32 = 32;
const MAX_APPLICANTS: u32 = 5;
const MAX_MILESTONES_PER_APP: u32 = 4;
const MIN_MILESTONE_AMOUNT: i128 = 1;
const MAX_MILESTONE_AMOUNT: i128 = 1_000_000;
// Worst-case funded total: 5 apps * 4 milestones * 1_000_000 == 20_000_000 < MIN_BUDGET.
const MIN_BUDGET: i128 = 25_000_000;
const MAX_BUDGET: i128 = 50_000_000;
const BASE_SEED: u64 = 0x517A_DA7A_F1F1_C0DE;

// ---------- Deterministic PRNG (splitmix64) -------------------------------
fn splitmix64(x: u64) -> u64 {
    let z = (x ^ (x >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    let z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

#[derive(Clone)]
struct Prng(u64);

impl Prng {
    fn from_seed(seed: u64) -> Self {
        Self(splitmix64(seed))
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = splitmix64(self.0);
        self.0
    }

    fn range_u32(&mut self, lo: u32, hi: u32) -> u32 {
        assert!(lo < hi, "u32 range requires lo < hi");
        lo + (self.next_u64() as u32) % (hi - lo)
    }

    fn range_i128(&mut self, lo: i128, hi: i128) -> i128 {
        assert!(lo <= hi, "i128 range requires lo <= hi");
        // Span is bounded above by MAX_BUDGET - MIN_BUDGET + 1 = 25_000_001,
        // well within u64 range. The fuzz bounds are deliberately chosen
        // small so this `as u64` cast is always safe.
        let span = (hi - lo + 1) as u64;
        lo + (self.next_u64() % span) as i128
    }

    fn pick(&mut self, len: u32) -> u32 {
        assert!(len > 0, "pick requires len > 0");
        (self.next_u64() as u32) % len
    }
}

// ---------- Mirror state (tracks contract to detect divergence) -----------
#[derive(Clone, PartialEq, Eq, Debug)]
enum AppStatusMirror {
    Pending,
    Approved,
    Rejected,
}

#[derive(Clone, PartialEq, Eq, Debug)]
struct MilestoneMirror {
    amount: i128,
    submitted: bool,
    approved: bool,
    paid: bool,
}

#[derive(Clone, Debug)]
struct State {
    apps: std::vec::Vec<AppStatusMirror>,
    app_applicant_idx: std::vec::Vec<u32>, // local index into fuzz.applicants
    milestones: std::vec::Vec<std::vec::Vec<MilestoneMirror>>,
    budget: i128,
    funded: i128,
    /// Mirror of the contract's live token balance. Decremented by
    /// milestone amount on `ReleasePayout`; zeroed on `Clawback`.
    /// Used to gate `ReleasePayout` candidates so the harness never
    /// asks the Stellar token contract to overdraw.
    contract_balance: i128,
    /// Number of `release_payout` calls executed this scenario.
    release_calls: u32,
    /// Cumulative tokens moved by `Clawback` to the clawback recipient
    /// (the admin in this harness). Tracked so conservation and
    /// clawback-exactness invariants can be asserted.
    clawback_total_to_admin: i128,
    /// Per-applicant cumulative token receipts (sum of paid milestone
    /// amounts for that applicant). Indexed by `fuzz.applicants` slot,
    /// not by app_id, so the same address chosen for multiple apps is
    /// summed across them.
    per_applicant_paid: std::vec::Vec<i128>,
}

impl State {
    fn new() -> Self {
        Self {
            apps: std::vec::Vec::new(),
            app_applicant_idx: std::vec::Vec::new(),
            milestones: std::vec::Vec::new(),
            budget: 0,
            funded: 0,
            contract_balance: 0,
            release_calls: 0,
            clawback_total_to_admin: 0,
            per_applicant_paid: std::vec::Vec::new(),
        }
    }
}

// ---------- Test scaffolding ---------------------------------------------
struct Fuzz {
    env: Env,
    admin: Address,
    admin_token_balance_baseline: i128,
    client: GrantRoundContractClient,
    token_id: Address,
    token: TokenClient,
    token_admin: StellarAssetClient,
    applicants: Vec<Address>,
    state: State,
}

fn setup_fuzz(seed: u64) -> Fuzz {
    let env = Env::default();
    env.mock_all_auths(); // fuzzing focuses on state-machine, not auth surface.
    let mut rng = Prng::from_seed(seed);

    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let token = TokenClient::new(&env, &token_id);
    let token_admin = StellarAssetClient::new(&env, &token_id);

    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    let budget = rng.range_i128(MIN_BUDGET, MAX_BUDGET);
    // Always fully fund so even the worst-case sequence of payouts
    // remains token-balance-feasible. Mirrors "funded == budget".
    let funded = budget;

    client.initialize(
        &admin,
        &String::from_str(&env, "Fuzz Round"),
        &String::from_str(&env, "ipfs://fuzz"),
        &budget,
        &token_id,
    );
    if funded > 0 {
        token_admin.mint(&contract_id, &funded);
    }
    // Snapshot the admin's token balance *after* minting so the
    // clawback-exactness invariant (INV-8) can later compare against
    // it. Every clawback in this harness credits the admin, so any
    // delta in `admin.token_balance` over the scenario is attributable
    // to clawback.
    let admin_token_balance_baseline = token.balance(&admin);

    // Pre-generate the maximum number of applicant addresses we'll ever use.
    let mut applicants: Vec<Address> = Vec::new(&env);
    for _ in 0..MAX_APPLICANTS {
        applicants.push_back(Address::generate(&env));
    }

    let mut state = State::new();
    state.budget = budget;
    state.funded = funded;
    state.contract_balance = funded;
    // Per-applicant ledger, indexed by applicant slot, one entry per
    // pre-generated applicant address (some slots may never be picked).
    state.per_applicant_paid = vec![0i128; MAX_APPLICANTS as usize];

    Fuzz {
        env,
        admin,
        admin_token_balance_baseline,
        client,
        token_id,
        token,
        token_admin,
        applicants,
        state,
    }
}

// ---------- Action space ---------------------------------------------------
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    SubmitApplication,
    ApproveApplication,
    RejectApplication,
    CreateMilestones,
    SubmitEvidence,
    ApproveMilestone,
    ReleasePayout,
    Clawback,
}

/// Enumerate every action that has at least one valid target in the
/// current mirrored state. The caller picks uniformly from this set, so
/// every step is a valid transition (no artificial reverts).
///
/// Note: this list is *never* empty because `Clawback` is always
/// included — `clawback_unspent_funds` is a no-op when balance == 0, so
/// it is always a valid live call as long as the contract has been
/// initialized. (Initialization happens in `setup_fuzz`.)
fn available_actions(fuzz: &Fuzz) -> std::vec::Vec<Action> {
    let mut out: std::vec::Vec<Action> = std::vec::Vec::new();

    let n_apps = fuzz.state.apps.len() as u32;
    if n_apps < MAX_APPLICANTS {
        out.push(Action::SubmitApplication);
    }

    let mut has_pending = false;
    let mut apps_approved_without_ms: u32 = 0;
    let mut has_submitted_pending = false;
    let mut has_unsubmitted_ms = false;
    let mut safe_release_payout = false;

    for i in 0..n_apps {
        let status = fuzz.state.apps[i as usize].clone();
        match status {
            AppStatusMirror::Pending => has_pending = true,
            AppStatusMirror::Approved => {
                let mlist = fuzz.state.milestones[i as usize].clone();
                if mlist.is_empty() {
                    apps_approved_without_ms += 1;
                } else {
                    let mut any_unsubmitted = false;
                    for m in mlist.iter() {
                        if !m.submitted {
                            any_unsubmitted = true;
                        } else if !m.approved {
                            has_submitted_pending = true;
                        }
                        // Only count release_payout as feasible if the
                        // contract actually has enough balance to pay it.
                        if m.approved && !m.paid && m.amount <= fuzz.state.contract_balance {
                            safe_release_payout = true;
                        }
                    }
                    if any_unsubmitted {
                        has_unsubmitted_ms = true;
                    }
                }
            }
            AppStatusMirror::Rejected => {}
        }
    }

    if has_pending {
        out.push(Action::ApproveApplication);
        out.push(Action::RejectApplication);
    }
    if apps_approved_without_ms > 0 {
        out.push(Action::CreateMilestones);
    }
    if has_submitted_pending {
        out.push(Action::ApproveMilestone);
    }
    if safe_release_payout {
        out.push(Action::ReleasePayout);
    }
    if has_unsubmitted_ms {
        out.push(Action::SubmitEvidence);
    }
    out.push(Action::Clawback);
    out
}

fn pick_action(fuzz: &Fuzz, rng: &mut Prng) -> Action {
    let candidates = available_actions(fuzz);
    // `available_actions()` is never empty once `setup_fuzz` has run,
    // so this `pick` is total.
    let idx = rng.pick(candidates.len() as u32);
    candidates[idx as usize]
}

/// Apply an action; update the mirror. Returns `true` if the mirror
/// changed (i.e. the action was actually executed), `false` if there
/// were no valid targets even though the action was selected.
fn apply_action(fuzz: &mut Fuzz, action: Action, rng: &mut Prng) -> bool {
    match action {
        Action::SubmitApplication => {
            let n = fuzz.state.apps.len() as u32;
            if n >= MAX_APPLICANTS {
                return false;
            }
            let applicant_idx = rng.range_u32(0, fuzz.applicants.len() as u32);
            let applicant = fuzz.applicants.get(applicant_idx).unwrap();
            let _id = fuzz.client.submit_application(
                &applicant,
                &String::from_str(&fuzz.env, "ipfs://app"),
            );
            fuzz.state.apps.push(AppStatusMirror::Pending);
            fuzz.state.app_applicant_idx.push(applicant_idx);
            fuzz.state.milestones.push(std::vec::Vec::new());
            true
        }
        Action::ApproveApplication => {
            let mut pendings: std::vec::Vec<u32> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s == AppStatusMirror::Pending {
                    pendings.push(i as u32);
                }
            }
            if pendings.is_empty() {
                return false;
            }
            let pick = pendings[rng.pick(pendings.len() as u32) as usize];
            let app_id = pick + 1;
            fuzz.client.approve_application(&app_id);
            fuzz.state.apps[pick as usize] = AppStatusMirror::Approved;
            true
        }
        Action::RejectApplication => {
            let mut pendings: std::vec::Vec<u32> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s == AppStatusMirror::Pending {
                    pendings.push(i as u32);
                }
            }
            if pendings.is_empty() {
                return false;
            }
            let pick = pendings[rng.pick(pendings.len() as u32) as usize];
            let app_id = pick + 1;
            fuzz.client.reject_application(&app_id);
            fuzz.state.apps[pick as usize] = AppStatusMirror::Rejected;
            true
        }
        Action::CreateMilestones => {
            let mut candidates: std::vec::Vec<u32> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s != AppStatusMirror::Approved {
                    continue;
                }
                if fuzz.state.milestones[i].is_empty() {
                    candidates.push(i as u32);
                }
            }
            if candidates.is_empty() {
                return false;
            }
            let app_idx = candidates[rng.pick(candidates.len() as u32) as usize];
            let app_id = app_idx + 1;
            let count = rng.range_u32(1, MAX_MILESTONES_PER_APP + 1);
            let mut amounts: Vec<i128> = vec![&fuzz.env];
            for _ in 0..count {
                amounts.push_back(rng.range_i128(MIN_MILESTONE_AMOUNT, MAX_MILESTONE_AMOUNT));
            }
            fuzz.client.create_milestones(&app_id, &amounts);

            let mut mlist: std::vec::Vec<MilestoneMirror> = std::vec::Vec::new();
            for a in amounts.iter() {
                mlist.push(MilestoneMirror {
                    amount: a,
                    submitted: false,
                    approved: false,
                    paid: false,
                });
            }
            fuzz.state.milestones[app_idx as usize] = mlist;
            true
        }
        Action::SubmitEvidence => {
            let mut candidates: std::vec::Vec<(u32, u32)> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s != AppStatusMirror::Approved {
                    continue;
                }
                let mlist = fuzz.state.milestones[i].clone();
                for (k, m) in mlist.iter().enumerate() {
                    if !m.submitted {
                        candidates.push((i as u32, k as u32));
                    }
                }
            }
            if candidates.is_empty() {
                return false;
            }
            let (app_idx, m_idx) = candidates[rng.pick(candidates.len() as u32) as usize];
            let app_id = app_idx + 1;
            fuzz.client.submit_milestone_evidence(
                &app_id,
                &m_idx,
                &String::from_str(&fuzz.env, "ipfs://ev"),
            );
            fuzz.state.milestones[app_idx as usize][m_idx as usize].submitted = true;
            true
        }
        Action::ApproveMilestone => {
            let mut candidates: std::vec::Vec<(u32, u32)> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s != AppStatusMirror::Approved {
                    continue;
                }
                let mlist = fuzz.state.milestones[i].clone();
                for (k, m) in mlist.iter().enumerate() {
                    if m.submitted && !m.approved {
                        candidates.push((i as u32, k as u32));
                    }
                }
            }
            if candidates.is_empty() {
                return false;
            }
            let (app_idx, m_idx) = candidates[rng.pick(candidates.len() as u32) as usize];
            fuzz.client.approve_milestone(&(app_idx + 1), &m_idx);
            fuzz.state.milestones[app_idx as usize][m_idx as usize].approved = true;
            true
        }
        Action::ReleasePayout => {
            let mut candidates: std::vec::Vec<(u32, u32)> = std::vec::Vec::new();
            for (i, s) in fuzz.state.apps.iter().enumerate() {
                if *s != AppStatusMirror::Approved {
                    continue;
                }
                let mlist = fuzz.state.milestones[i].clone();
                for (k, m) in mlist.iter().enumerate() {
                    if m.approved && !m.paid && m.amount <= fuzz.state.contract_balance {
                        candidates.push((i as u32, k as u32));
                    }
                }
            }
            if candidates.is_empty() {
                return false;
            }
            let (app_idx, m_idx) = candidates[rng.pick(candidates.len() as u32) as usize];
            let applicant_idx = fuzz.state.app_applicant_idx[app_idx as usize];
            let m_amount = fuzz.state.milestones[app_idx as usize][m_idx as usize].amount;
            // Per-applicant balance BEFORE this payout, so we can do an
            // exact delta check (the per-applicant slot may have already
            // received payouts from earlier apps owned by the same
            // applicant, hence the +delta rather than a full-balance
            // equality check).
            let applicant = fuzz.applicants.get(applicant_idx).unwrap();
            let applicant_balance_before = fuzz.token.balance(&applicant);
            fuzz.client.release_payout(&(app_idx + 1), &m_idx);
            fuzz.state.milestones[app_idx as usize][m_idx as usize].paid = true;
            fuzz.state.contract_balance -= m_amount;
            fuzz.state.release_calls += 1;
            // Per-applicant ledger entry so we can later assert INV-7.
            fuzz.state.per_applicant_paid[applicant_idx as usize] += m_amount;

            // Exact delta cross-check: this release_payout increased
            // the applicant's balance by exactly `m_amount`. This
            // guards against bookkeeping drift (e.g., a buggy contract
            // that double-pays or under-pays this milestone). INV-7 at
            // end-of-run verifies the full cumulative balance.
            let applicant_balance_after = fuzz.token.balance(&applicant);
            assert_eq!(
                applicant_balance_after - applicant_balance_before,
                m_amount,
                "ReleasePayout: applicant balance delta({}) != milestone amount({})",
                applicant_balance_after - applicant_balance_before, m_amount,
            );
            true
        }
        Action::Clawback => {
            // Snapshot the live admin balance and contract balance *before*
            // the clawback. After the call we assert (INV-8) that the
            // admin's balance increased by exactly the clawback amount.
            let admin_balance_before = fuzz.token.balance(&fuzz.admin);
            let contract_balance_before = fuzz.token.balance(&fuzz.env.current_contract_address());
            fuzz.client.clawback_unspent_funds(&fuzz.admin);
            // The contract's clawback is a no-op when balance is zero,
            // but it is *always* callable (has no preconditions after
            // admin auth). So the mirror and live state must agree
            // whether amount moved or not.
            let admin_balance_after = fuzz.token.balance(&fuzz.admin);
            let clawback_amount = admin_balance_after - admin_balance_before;
            assert_eq!(
                clawback_amount, contract_balance_before,
                "Clawback exactness: admin gained {} but contract sent {}",
                clawback_amount, contract_balance_before,
            );
            fuzz.state.contract_balance = 0;
            fuzz.state.clawback_total_to_admin += clawback_amount;
            true
        }
    }
}

// ---------- Invariants ----------------------------------------------------
/// Aggregate accounting derived from the mirror.
struct Aggregate {
    paid_total: i128,
    approved_total: i128,
    paid_count: u32,
}

fn aggregate(state: &State) -> Aggregate {
    let mut paid_total: i128 = 0;
    let mut approved_total: i128 = 0;
    let mut paid_count: u32 = 0;
    for mlist in state.milestones.iter() {
        for m in mlist.iter() {
            if m.paid {
                paid_total += m.amount;
                paid_count += 1;
            }
            if m.approved {
                approved_total += m.amount;
            }
        }
    }
    Aggregate {
        paid_total,
        approved_total,
        paid_count,
    }
}

/// Verify all invariants. Used both for the post-setup sanity check
/// (before any action) and the end-of-run invariant assertion. Any
/// panic here indicates either a contract bug or a mirror bug.
fn assert_invariants(fuzz: &Fuzz) {
    let agg = aggregate(&fuzz.state);

    // INV-1: no double-pay. The number of release_payout calls equals
    // the number of paid milestones in the mirror (paid milestones
    // are never selected as candidates; the contract asserts !m.paid).
    assert_eq!(
        fuzz.state.release_calls, agg.paid_count,
        "INV-1 violated: release_calls({}) != paid milestones({})",
        fuzz.state.release_calls, agg.paid_count,
    );

    // INV-2: paid_total never exceeds funded.
    assert!(
        agg.paid_total <= fuzz.state.funded,
        "INV-2 violated: paid_total={} > funded={}",
        agg.paid_total, fuzz.state.funded,
    );

    // INV-3: cumulative approved_total never exceeds the budget.
    assert!(
        agg.approved_total <= fuzz.state.budget,
        "INV-3 violated: approved_total={} > budget={}",
        agg.approved_total, fuzz.state.budget,
    );

    // INV-4: mirror agrees with the live contract across every app
    // and every milestone that has been created.
    let n_apps = fuzz.state.apps.len() as u32;
    for i in 0..n_apps {
        let status = fuzz.state.apps[i as usize].clone();
        let app_id = i + 1;
        let live: Vec<Milestone> = fuzz.client.get_milestones(&app_id);
        match status {
            AppStatusMirror::Approved => {
                let mirror_ms = fuzz.state.milestones[i as usize].clone();
                assert_eq!(
                    live.len() as usize, mirror_ms.len(),
                    "INV-4 violated: milestone count differs for app {} (live={}, mirror={})",
                    app_id, live.len(), mirror_ms.len(),
                );
                for k in 0..mirror_ms.len() {
                    let mm = &mirror_ms[k];
                    let lm = live.get(k as u32).unwrap();
                    assert_eq!(mm.amount, lm.amount,
                        "INV-4 violated: amount differs at app {} m {}", app_id, k);
                    assert_eq!(mm.submitted, lm.submitted,
                        "INV-4 violated: submitted differs at app {} m {}", app_id, k);
                    assert_eq!(mm.approved, lm.approved,
                        "INV-4 violated: approved differs at app {} m {}", app_id, k);
                    assert_eq!(mm.paid, lm.paid,
                        "INV-4 violated: paid differs at app {} m {}", app_id, k);
                }
            }
            AppStatusMirror::Pending | AppStatusMirror::Rejected => {
                assert_eq!(live.len(), 0,
                    "INV-4 violated: non-approved app {} has milestones", app_id);
            }
        }
    }

    let live_balance = fuzz.token.balance(&fuzz.env.current_contract_address());

    // INV-5: live contract balance equals mirror, and is non-negative.
    assert_eq!(live_balance, fuzz.state.contract_balance,
        "INV-5 violated: live balance({}) != mirror balance({})",
        live_balance, fuzz.state.contract_balance);
    assert!(live_balance >= 0, "INV-5 violated: contract balance went negative");

    // INV-6: token conservation. Soroban analog of x*y=k: no token is
    // ever created or destroyed in this contract. The money that was
    // funded into the contract is now either still inside as
    // `live_balance`, was paid out to applicants (`paid_total`), or
    // was returned to the admin via clawback (`clawback_total_to_admin`).
    assert_eq!(
        agg.paid_total + live_balance + fuzz.state.clawback_total_to_admin,
        fuzz.state.funded,
        "INV-6 violated (token conservation): paid({}) + contract({}) + clawback_admin({}) != funded({})",
        agg.paid_total, live_balance, fuzz.state.clawback_total_to_admin, fuzz.state.funded,
    );

    // INV-7: per-applicant fidelity. Each applicant's live balance
    // must equal the cumulative paid milestone amounts we recorded
    // for that applicant. The harness never sends any tokens directly
    // to applicants outside of `ReleasePayout` (SubmitApplication is
    // auth-only and does not move tokens), so this is an equality.
    for i in 0..MAX_APPLICANTS {
        let applicant = fuzz.applicants.get(i).unwrap();
        let live = fuzz.token.balance(&applicant);
        let expected = fuzz.state.per_applicant_paid[i as usize];
        assert_eq!(live, expected,
            "INV-7 violated (per-applicant fidelity): applicant[{}] live({}) != expected paid({})",
            i, live, expected);
    }

    // INV-8: clawback exactness. The admin's live balance should have
    // grown by exactly the cumulative clawback amount we tracked in
    // the mirror, relative to its post-mint baseline.
    let admin_now = fuzz.token.balance(&fuzz.admin);
    let admin_delta = admin_now - fuzz.admin_token_balance_baseline;
    assert_eq!(admin_delta, fuzz.state.clawback_total_to_admin,
        "INV-8 violated (clawback exactness): admin delta({}) != mirror clawback total({})",
        admin_delta, fuzz.state.clawback_total_to_admin);
}

// ----------------------------------------------------------------------------
// Per-step conservation check (lighter than `assert_invariants`): every
// single action in the fuzz loop runs through this, so any divergence
// traces back to the specific call that broke it.
// ----------------------------------------------------------------------------
fn assert_conservation_after_step(fuzz: &Fuzz) {
    let agg = aggregate(&fuzz.state);
    let live_balance = fuzz.token.balance(&fuzz.env.current_contract_address());
    assert_eq!(
        agg.paid_total + live_balance + fuzz.state.clawback_total_to_admin,
        fuzz.state.funded,
        "Conservation broken mid-run: paid({}) + contract({}) + clawback({}) != funded({})",
        agg.paid_total, live_balance, fuzz.state.clawback_total_to_admin, fuzz.state.funded,
    );
}

// ----------------------------------------------------------------------------
// Main fuzz routine — 10,000 bounded scenarios, 12 actions per scenario.
// ----------------------------------------------------------------------------
#[test]
fn fuzz_grant_round_invariants_10k_runs() {
    for run in 0..RUNS {
        let seed = BASE_SEED ^ (run as u64);
        let mut fuzz = setup_fuzz(seed);
        // Verify the harness itself is consistent before fuzzing starts.
        assert_invariants(&fuzz);
        let mut rng = Prng::from_seed(seed.rotate_left(17));
        for _ in 0..ACTIONS_PER_RUN {
            let action = pick_action(&fuzz, &mut rng);
            apply_action(&mut fuzz, action, &mut rng);
            // Conservation must hold after every single call. If it
            // doesn't, the violation is attributable to that exact call.
            assert_conservation_after_step(&fuzz);
        }
        assert_invariants(&fuzz);
    }
}

// ----------------------------------------------------------------------------
// Secondary fuzz: 1,000 scenarios at 32 actions each. Total across both
// fuzz tests: 10,000 * 12 + 1,000 * 32 == 152,000 contract calls; both
// individual tests each clear the 10,000-call bar.
// ----------------------------------------------------------------------------
#[test]
fn fuzz_grant_round_invariants_long_sequences() {
    for run in 0..LONG_RUNS {
        let seed = BASE_SEED.rotate_left(7) ^ (run as u64);
        let mut fuzz = setup_fuzz(seed);
        assert_invariants(&fuzz);
        let mut rng = Prng::from_seed(seed.rotate_left(29));
        for _ in 0..LONG_ACTIONS_PER_RUN {
            let action = pick_action(&fuzz, &mut rng);
            apply_action(&mut fuzz, action, &mut rng);
            assert_conservation_after_step(&fuzz);
        }
        assert_invariants(&fuzz);
    }
}

// ============================================================================
// Access-control invariants (negative tests).
//
// These don't use `env.mock_all_auths()`; instead they leave it unset so
// that any `require_auth()` call inside the contract panics. Each one
// proves that the named entrypoint refuses to operate without proper auth.
// ============================================================================

#[test]
#[should_panic]
fn ac_submit_application_panics_without_applicant_auth() {
    let env = Env::default(); // no mock_all_auths, no mock_auths
    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "AC"),
        &String::from_str(&env, "ipfs://ac"),
        &1_000_000,
        &token_id,
    );

    let applicant = Address::generate(&env);
    // submit_application calls applicant.require_auth() -> panic.
    let _ = client.submit_application(&applicant, &String::from_str(&env, "ipfs://app"));
}

#[test]
#[should_panic]
fn ac_approve_application_panics_without_admin_auth() {
    let env = Env::default();
    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "AC"),
        &String::from_str(&env, "ipfs://ac"),
        &1_000_000,
        &token_id,
    );

    // approve_application calls admin.require_auth() -> panic.
    let _ = client.approve_application(&1);
}

#[test]
#[should_panic]
fn ac_clawback_panics_without_admin_auth() {
    let env = Env::default();
    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "AC"),
        &String::from_str(&env, "ipfs://ac"),
        &1_000_000,
        &token_id,
    );

    let _ = client.clawback_unspent_funds(&admin);
}

#[test]
#[should_panic]
fn ac_cannot_double_initialize() {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "AC"),
        &String::from_str(&env, "ipfs://ac"),
        &1_000_000,
        &token_id,
    );
    // initialize asserts "Already initialized" on the second call -> panic.
    client.initialize(
        &admin,
        &String::from_str(&env, "AC2"),
        &String::from_str(&env, "ipfs://ac2"),
        &1_000_000,
        &token_id,
    );
}

#[test]
#[should_panic]
fn ac_cannot_pay_unapproved_milestone() {
    let env = Env::default();
    env.mock_all_auths();
    let admin = Address::generate(&env);
    let token_id = env.register_stellar_asset_contract(admin.clone());
    let token_admin = StellarAssetClient::new(&env, &token_id);
    let contract_id = env.register_contract(None, GrantRoundContract);
    let client = GrantRoundContractClient::new(&env, &contract_id);

    client.initialize(
        &admin,
        &String::from_str(&env, "AC"),
        &String::from_str(&env, "ipfs://ac"),
        &1_000_000,
        &token_id,
    );

    let applicant = Address::generate(&env);
    let app_id = client.submit_application(&applicant, &String::from_str(&env, "ipfs://app"));
    client.approve_application(&app_id);

    let mut amounts: Vec<i128> = vec![&env];
    amounts.push_back(100);
    client.create_milestones(&app_id, &amounts);

    // Mint so balance is non-zero, but skip submit/approve. Contract
    // asserts "!approved" on release_payout -> panic.
    token_admin.mint(&contract_id, &1_000);

    let _ = client.release_payout(&app_id, &0);
}
