# Contributing to WhiteLotus Contracts

Thank you for your interest in contributing to WhiteLotus Contracts! This document guides you through the contribution process.

## GrantFox Contribution Workflow

This repository participates in GrantFox for open-source collaboration. Here's how to contribute:

1. **Browse Issues**: Visit the [GrantFox Contributor App](https://contribute.grantfox.xyz/) to find available issues tagged for this repository.
2. **Claim an Issue**: Apply for an issue through GrantFox. Wait for maintainer approval before starting work.
3. **Fork and Branch**: Fork the repository and create a feature branch from `main`.
4. **Develop**: Make your changes following the guidelines below.
5. **Test**: Run tests and ensure your changes pass all checks.
6. **Submit PR**: Create a pull request with the GrantFox issue link in the description.
7. **Review**: Maintainers will review your PR via GrantFox. Address feedback promptly.

## Development Setup

### Prerequisites

- Foundry installed: https://book.getfoundry.sh/getting-started/installation
- Git

### Installation

```bash
git clone https://github.com/your-org/whitelotus-contracts.git
cd whitelotus-contracts
forge install foundry-rs/forge-std
```

### Building

```bash
forge build
```

### Testing

```bash
forge test -vv
```

### Formatting

```bash
forge fmt
```

## Code Style Guidelines

- Follow Solidity best practices and security patterns
- Use NatSpec comments for all public functions
- Keep functions focused and modular
- Add events for state changes
- Follow the existing code structure in `src/`
- Use the Foundry formatting style defined in `foundry.toml`

## Smart Contract Security

- All contract changes must include tests
- Review access control patterns carefully
- Check for reentrancy vulnerabilities
- Validate all external inputs
- Use OpenZeppelin patterns where applicable
- Document security assumptions in code comments

## Pull Request Process

1. **Link Issue**: Include the GrantFox issue number in your PR description.
2. **Summary**: Provide a clear summary of changes.
3. **Test Evidence**: Describe how you tested the changes.
4. **Checklist**: Ensure your PR meets the checklist in the PR template.
5. **Communication**: Respond to review comments within 48 hours.

## Expected PR Quality

- **Scope**: Changes should be focused on the linked issue.
- **Tests**: Include comprehensive tests for new functionality or bug fixes.
- **Documentation**: Update README and NatSpec comments as needed.
- **Security**: Consider security implications of all changes.
- **Gas**: Optimize gas usage where reasonable without sacrificing readability.
- **Backwards Compatibility**: Avoid breaking changes without justification.

## Review Process

- Maintainers review PRs through GrantFox workflow.
- Reviews focus on correctness, security, gas efficiency, and alignment with project goals.
- Address all review comments before requesting re-review.
- PRs may be rejected if they don't meet quality standards.

## Communication

- Use GitHub issues for bug reports and feature requests.
- Use GitHub discussions for questions and ideas.
- Be respectful and constructive in all communications.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Help

- Check existing issues and discussions.
- Read the [README](README.md) for architecture and usage.
- Review test files for usage examples.
- Ask questions in GitHub discussions.

## Campaign-Ready Tasks

Maintainers mark issues as campaign-ready when they:
- Are small and well-scoped
- Have clear acceptance criteria
- Specify expected contracts to change
- Include estimated difficulty
- Define testing requirements
- Note reviewer expectations

Look for issues tagged with `good first issue` or `help wanted` on GrantFox.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
