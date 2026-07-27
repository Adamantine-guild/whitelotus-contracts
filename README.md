<div align="center">
  <h1>WhiteLotus Contracts</h1>
  <p>
    <strong>Robust and efficient smart contracts powering the WhiteLotus grant lifecycle.</strong>
  </p>
  
  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
  [![Stellar](https://img.shields.io/badge/Network-Stellar-black)](https://stellar.org/)
  [![Soroban](https://img.shields.io/badge/Platform-Soroban-purple)](https://soroban.stellar.org/)
  [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)
</div>

## 🌟 Overview

WhiteLotus Contracts are engineered on Stellar's Soroban platform using Rust. These smart contracts manage the end-to-end lifecycle of a grant—from application approval through milestone validation and final payouts.

Designed with clarity, security, and future extensibility in mind, these contracts serve as the foundation of the WhiteLotus ecosystem.

## ✨ Features

- **Grant Rounds**: Initialize rounds with comprehensive configurations (title, metadata URI, budget, and administrator).
- **Application Management**: Secure submission of applications via metadata URIs, complete with administrative approval/rejection workflows.
- **Milestone Tracking**: Define fixed milestone tranches for approved applications.
- **Evidence Verification**: Grantees can seamlessly submit evidence URIs for their milestones.
- **Native Payouts**: Secure release of payouts using Soroban's standard Token interface following milestone approval.
- **Events**: Clean and structured contract events designed for easy off-chain indexing and UI integration.

## 🛠️ Getting Started

### Prerequisites

- [Rust](https://www.rust-lang.org/tools/install) installed.
- [Soroban CLI](https://soroban.stellar.org/docs/getting-started/setup) installed.

### Build and Test

Install dependencies and build the WebAssembly target:

```bash
cargo build --target wasm32-unknown-unknown --release
```

Execute the Soroban test suite to verify the logic:

```bash
cargo test
```

### EVM Reference Tests (Foundry)

Solidity reference contracts live in `contracts/` with Forge tests in `test/foundry/`. These provide fast local feedback for core grant lifecycle behavior:

```bash
forge install foundry-rs/forge-std --no-git
forge test -vv
```

## 🔄 Key Workflows

1. **Initialization**: Admin deploys the contract and configures the round.
2. **Funding**: The round is funded via standard Stellar asset transfers to the contract address.
3. **Application**: Applicants submit proposals using off-chain metadata URIs.
4. **Approval**: Admin reviews and approves the application.
5. **Milestone Creation**: Admin establishes milestones and their respective payout amounts.
6. **Evidence Submission**: Grantee submits proof of work for a milestone.
7. **Verification**: Admin reviews and approves the submitted evidence.
8. **Payout**: Admin triggers the release of the milestone payout to the grantee.

## 🤝 Contributing

We strongly believe in open-source and welcome contributions from the community!

1. Fork the repository.
2. Create your feature branch (`git checkout -b feature/amazing-feature`).
3. Commit your changes (`git commit -m 'Add some amazing feature'`).
4. Push to the branch (`git push origin feature/amazing-feature`).
5. Open a Pull Request.

Please review our [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

### GrantFox Platform

This repository participates in **GrantFox** for open-source collaboration. Contributors can:
- Browse and claim issues via the [GrantFox Contributor App](https://contribute.grantfox.xyz/)
- Track PR reviews and campaign participation.

Maintainers manage campaigns and review contributions via the [GrantFox Maintainer App](https://maintainer.grantfox.xyz/).

## 🛡️ Security

For security policies and vulnerability reporting, please refer to [SECURITY.md](SECURITY.md).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
