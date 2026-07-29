// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract OptimisticOracle {
    error ZeroBondToken();
    error ZeroArbitrator();
    error ZeroAsset();
    error ZeroPrice();
    error ProposalDoesNotExist();
    error AssetMismatch();
    error AlreadyDisputed();
    error AlreadyResolved();
    error ChallengeWindowPassed();
    error ProposalIsDisputed();
    error ChallengeWindowNotClosed();
    error OnlyArbitratorCanResolve();
    error ProposalNotDisputed();
    error OnlyArbitratorCanChangeArbitrator();

    using SafeERC20 for IERC20;

    // ─── Structs ────────────────────────────────────────────────────────────

    struct Proposal {
        address proposer;
        address asset;
        uint256 price;
        uint256 timestamp;
        bool disputed;
        address disputer;
        bool resolved;
        bool proposalValid;
    }

    // ─── State ──────────────────────────────────────────────────────────────

    IERC20 public immutable bondToken;
    uint256 public immutable bondAmount;
    uint256 public immutable challengeWindow;
    address public arbitrator;

    uint256 public nextProposalId;
    mapping(uint256 => Proposal) public proposals;

    // asset => price
    mapping(address => uint256) public prices;
    // asset => timestamp of the price source proposal
    mapping(address => uint256) public priceTimestamps;

    // ─── Events ─────────────────────────────────────────────────────────────

    event PriceProposed(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed asset,
        uint256 price,
        uint256 timestamp
    );
    event PriceDisputed(
        uint256 indexed proposalId, address indexed disputer, address indexed asset
    );
    event PriceSettled(uint256 indexed proposalId, address indexed asset, uint256 price);
    event DisputeResolved(uint256 indexed proposalId, bool proposalValid);
    event ArbitratorSet(address indexed newArbitrator);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        IERC20 _bondToken,
        uint256 _bondAmount,
        uint256 _challengeWindow,
        address _arbitrator
    ) {
        if (!(address(_bondToken) != address(0))) revert ZeroBondToken();
        if (!(_arbitrator != address(0))) revert ZeroArbitrator();
        bondToken = _bondToken;
        bondAmount = _bondAmount;
        challengeWindow = _challengeWindow;
        arbitrator = _arbitrator;
    }

    // ─── Proposal ───────────────────────────────────────────────────────────

    function proposePrice(address asset, uint256 price) external returns (uint256 proposalId) {
        if (!(asset != address(0))) revert ZeroAsset();
        if (!(price > 0)) revert ZeroPrice();

        proposalId = nextProposalId++;

        // Pull bond from proposer
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            asset: asset,
            price: price,
            timestamp: block.timestamp,
            disputed: false,
            disputer: address(0),
            resolved: false,
            proposalValid: false
        });

        emit PriceProposed(proposalId, msg.sender, asset, price, block.timestamp);
    }

    // ─── Dispute ────────────────────────────────────────────────────────────

    function disputePrice(address asset, uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (!(proposal.proposer != address(0))) revert ProposalDoesNotExist();
        if (!(proposal.asset == asset)) revert AssetMismatch();
        if (!(!proposal.disputed)) revert AlreadyDisputed();
        if (!(!proposal.resolved)) revert AlreadyResolved();
        if (!(block.timestamp <= proposal.timestamp + challengeWindow)) revert ChallengeWindowPassed();

        // CEI: mark disputed before pulling the disputer bond.
        proposal.disputed = true;
        proposal.disputer = msg.sender;

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        emit PriceDisputed(proposalId, msg.sender, asset);
    }

    // ─── Settlement ─────────────────────────────────────────────────────────

    function settle(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        if (!(proposal.proposer != address(0))) revert ProposalDoesNotExist();
        if (!(!proposal.resolved)) revert AlreadyResolved();
        if (!(!proposal.disputed)) revert ProposalIsDisputed();
        if (!(block.timestamp > proposal.timestamp + challengeWindow)) revert ChallengeWindowNotClosed();

        proposal.resolved = true;
        proposal.proposalValid = true;

        // Save price if it's newer than the currently stored one
        if (proposal.timestamp > priceTimestamps[proposal.asset]) {
            prices[proposal.asset] = proposal.price;
            priceTimestamps[proposal.asset] = proposal.timestamp;
        }

        // Return bond to proposer
        bondToken.safeTransfer(proposal.proposer, bondAmount);

        emit PriceSettled(proposalId, proposal.asset, proposal.price);
    }

    // ─── Arbitration ────────────────────────────────────────────────────────

    function resolveDispute(uint256 proposalId, bool proposalValid) external {
        if (!(msg.sender == arbitrator)) revert OnlyArbitratorCanResolve();
        Proposal storage proposal = proposals[proposalId];
        if (!(proposal.proposer != address(0))) revert ProposalDoesNotExist();
        if (!(proposal.disputed)) revert ProposalNotDisputed();
        if (!(!proposal.resolved)) revert AlreadyResolved();

        proposal.resolved = true;
        proposal.proposalValid = proposalValid;

        if (proposalValid) {
            // Proposer was right. Proposer gets their bond back + disputer's bond
            bondToken.safeTransfer(proposal.proposer, bondAmount * 2);

            // Update price if it's newer
            if (proposal.timestamp > priceTimestamps[proposal.asset]) {
                prices[proposal.asset] = proposal.price;
                priceTimestamps[proposal.asset] = proposal.timestamp;
            }
        } else {
            // Disputer was right. Disputer gets their bond back + proposer's bond
            bondToken.safeTransfer(proposal.disputer, bondAmount * 2);
        }

        emit DisputeResolved(proposalId, proposalValid);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────

    function setArbitrator(address _arbitrator) external {
        if (!(msg.sender == arbitrator)) revert OnlyArbitratorCanChangeArbitrator();
        if (!(_arbitrator != address(0))) revert ZeroArbitrator();
        arbitrator = _arbitrator;
        emit ArbitratorSet(_arbitrator);
    }
}
