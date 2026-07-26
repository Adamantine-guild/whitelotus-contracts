# GrantChain MVP Contracts

Minimal, readable smart contracts demonstrating the basic lifecycle of a grant from application approval through milestone payout. This is an intentionally constrained MVP, designed for clarity and future extensibility rather than completeness.

## Implemented

- Create simple grant rounds via a factory
- Store round config (title, metadata URI, budget, admin)
- Submit applications with metadata URIs
- Admin approval/rejection of applications
- Define fixed milestone amounts per approved application
- Grantee submits milestone evidence by URI
- Admin approves milestones
- ETH escrow held by the round; release payout for approved milestones
- Clean events for indexing and UI

## Explicitly Omitted (MVP)

- Token-weighted governance and delegated voting
- Snapshot or off-chain governance integration
- Advanced committee/role hierarchies
- Conflict-of-interest enforcement
- Reputation scoring
- Advanced treasury operations and multi-token routing
- Upgradeability (single, non-upgradeable contracts)
- Sophisticated clawback mechanisms (basic admin withdrawal only)
- Elaborate plugin/modular systems

## Contracts

- `GrantRoundFactory`: Deploys `GrantRound` instances and emits `RoundCreated`.
- `GrantRound`: Holds round config, application approvals, milestone tracking, evidence submission, and ETH payouts.

Notes and assumptions:

- Single `admin` per round with simple access control.
- Budget is declarative for UI; payouts only check actual ETH balance.
- Metadata and evidence are referenced by URIs; large content stays off-chain.
- Reentrancy protection is a minimal mutex around payouts.
- TODOs in code mark extension points for governance/permissions and clawbacks.

## Getting Started

Prerequisites:

- Foundry installed: https://book.getfoundry.sh/getting-started/installation

Install dependencies and build:

```bash
forge install foundry-rs/forge-std
forge build
```

Run tests:

```bash
forge test -vv
```

## Key Flows

1. Admin deploys `GrantRound` via the factory.
2. Admin funds the round with ETH (`deposit()` or send to contract).
3. Applicant submits application with a metadata URI.
4. Admin approves the application.
5. Admin defines milestones with fixed amounts.
6. Grantee submits evidence URI for a milestone.
7. Admin approves the milestone.
8. Admin releases the milestone payout (ETH) to the grantee.

## Deployment

Example script: `script/Deploy.s.sol`

```bash
export PRIVATE_KEY=<hex_private_key>
export ADMIN_ADDRESS=<admin_eth_address> # optional; defaults to deployer
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

## Where to Extend

- Governance/permissions: Replace single-admin with roles or external governance adapters.
- Treasury: Support ERC20 tokens and richer accounting/reservations.
- Clawbacks: Add timeouts, dispute windows, and partial clawbacks.
- Evidence and evaluation: Integrate richer state machines and committees.
- Round lifecycle: Add statuses (scheduled, active, finalized) and constraints.

## Security Notes

- Payouts are protected against reentrancy with a simple mutex.
- Admin functions gate sensitive actions; review carefully when extending.
- Never store secrets on-chain; keep large data in content-addressed storage.

## Events

Emitted for indexing and UI:

- `RoundCreated`
- `DepositReceived`
- `ApplicationSubmitted`, `ApplicationApproved`, `ApplicationRejected`
- `MilestonesCreated`, `MilestoneEvidenceSubmitted`, `MilestoneApproved`
- `PayoutReleased`

## Contributing

We welcome contributions through GrantFox! See [CONTRIBUTING.md](CONTRIBUTING.md) for details on:
- How to claim issues via GrantFox
- Development setup and testing
- Pull request process
- Code style guidelines

## GrantFox

This repository is part of the Adamantine Guild project and participates in GrantFox for open-source collaboration. Contributors can:
- Browse and claim issues via [GrantFox Contributor App](https://contribute.grantfox.xyz/)
- Follow contribution guidelines in [CONTRIBUTING.md](CONTRIBUTING.md)
- Track PR reviews and campaign participation

Maintainers manage campaigns and review contributions via the [GrantFox Maintainer App](https://maintainer.grantfox.xyz/).

## License

MIT - see [LICENSE](LICENSE) file for details.

## Security

For security concerns, please see [SECURITY.md](SECURITY.md).

