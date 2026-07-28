// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract OptimisticOracle {
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
        require(address(_bondToken) != address(0), "OptimisticOracle: Zero bond token");
        require(_arbitrator != address(0), "OptimisticOracle: Zero arbitrator");
        bondToken = _bondToken;
        bondAmount = _bondAmount;
        challengeWindow = _challengeWindow;
        arbitrator = _arbitrator;
    }

    // ─── Proposal ───────────────────────────────────────────────────────────

    function proposePrice(address asset, uint256 price) external returns (uint256 proposalId) {
        require(asset != address(0), "OptimisticOracle: Zero asset");
        require(price > 0, "OptimisticOracle: Zero price");

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
        require(proposal.proposer != address(0), "OptimisticOracle: Proposal does not exist");
        require(proposal.asset == asset, "OptimisticOracle: Asset mismatch");
        require(!proposal.disputed, "OptimisticOracle: Already disputed");
        require(!proposal.resolved, "OptimisticOracle: Already resolved");
        require(
            block.timestamp <= proposal.timestamp + challengeWindow,
            "OptimisticOracle: Challenge window passed"
        );

        // Pull bond from disputer
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        proposal.disputed = true;
        proposal.disputer = msg.sender;

        emit PriceDisputed(proposalId, msg.sender, asset);
    }

    // ─── Settlement ─────────────────────────────────────────────────────────

    function settle(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposer != address(0), "OptimisticOracle: Proposal does not exist");
        require(!proposal.resolved, "OptimisticOracle: Already resolved");
        require(!proposal.disputed, "OptimisticOracle: Proposal is disputed");
        require(
            block.timestamp > proposal.timestamp + challengeWindow,
            "OptimisticOracle: Challenge window not closed"
        );

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
        require(msg.sender == arbitrator, "OptimisticOracle: Only arbitrator can resolve");
        Proposal storage proposal = proposals[proposalId];
        require(proposal.proposer != address(0), "OptimisticOracle: Proposal does not exist");
        require(proposal.disputed, "OptimisticOracle: Proposal not disputed");
        require(!proposal.resolved, "OptimisticOracle: Already resolved");

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
        require(msg.sender == arbitrator, "OptimisticOracle: Only arbitrator can change arbitrator");
        require(_arbitrator != address(0), "OptimisticOracle: Zero arbitrator");
        arbitrator = _arbitrator;
        emit ArbitratorSet(_arbitrator);
    }
}
