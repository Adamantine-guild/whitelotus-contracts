// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Context} from "./ERC2771Context.sol";

/// @title IERC20 - Minimal ERC20 interface for voting-power queries
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Governance - Commit-reveal voting to prevent front-running and bandwagon manipulation
/// @notice Two-phase scheme: voters first submit keccak256(vote, salt), then reveal during the
///         reveal window.  Votes stay hidden until tally, neutralising MEV / social-signal attacks.
/// @dev Lifecycle per proposal:
///      1. Admin calls createProposal() – token balances are snapshotted per-voter at commit time.
///      2. Commit phase – voters submit a commitment hash. Observers see only opaque hashes.
///      3. Reveal phase – voters reveal (vote, salt); the hash is verified on-chain.
///      4. Tally – anyone finalises the result; committed-but-unrevealed voters are penalised
///         (their weight is forfeited entirely and counts for no option).
///
///      ERC-2771 meta-transaction support: the trusted forwarder can relay commitVote and
///      revealVote calls on behalf of voters.  `_msgSender()` correctly resolves to the
///      original signer, so voting power and receipt tracking are tied to the voter, not
///      the relayer.
contract Governance is ERC2771Context {
    // ─── Types ──────────────────────────────────────────────────────────────

    /// @dev Vote options.  Against defaults to 0, matching the enum's default value.
    enum Vote {
        Against,
        For,
        Abstain
    }

    // ─── State ──────────────────────────────────────────────────────────────

    /// @dev Admin who creates proposals. Can be transferred (e.g. to a TimelockController)
    ///      to enforce a delay before proposal creation.
    address public admin;

    /// @dev ERC-20 token whose balanceOf() determines each voter's weight at commit time.
    IERC20 public immutable votingToken;

    /// @dev Auto-incrementing proposal counter.
    uint256 public proposalCount;

    struct Proposal {
        string description;
        uint256 snapshotBlock;
        uint256 commitDeadline;
        uint256 revealDeadline;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool tallied;
    }

    struct VoterReceipt {
        uint256 weight; // token balance snapshotted at commit
        bytes32 commitHash; // keccak256(abi.encodePacked(vote, salt))
        Vote vote; // revealed vote (defaults to Against = 0)
        bool committed;
        bool revealed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => VoterReceipt)) public receipts;
    mapping(uint256 => address[]) private _voterList;

    // ─── Events ─────────────────────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed proposalId,
        string description,
        uint256 commitDeadline,
        uint256 revealDeadline
    );
    event VoteCommitted(uint256 indexed proposalId, address indexed voter);
    event VoteRevealed(uint256 indexed proposalId, address indexed voter, Vote vote);
    event VotePenalized(uint256 indexed proposalId, address indexed voter, uint256 forfeitedWeight);
    event ProposalTallied(
        uint256 indexed proposalId, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes
    );
    event AdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    // ─── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(_msgSender() == admin, "Not admin");
        _;
    }

    modifier validProposal(uint256 proposalId) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        _;
    }

    // ─── Constructor ────────────────────────────────────────────────────────

    /// @param _votingToken ERC-20 token used to derive each voter's weight via balanceOf()
    /// @param _trustedForwarder ERC-2771 forwarder address; enables gasless voting via relayers.
    constructor(address _votingToken, address _trustedForwarder) ERC2771Context(_trustedForwarder) {
        require(_votingToken != address(0), "Zero token");
        admin = msg.sender;
        votingToken = IERC20(_votingToken);
    }

    // ─── Admin management ───────────────────────────────────────────────────

    /// @notice Transfer the admin role to a new address.
    /// @dev Only callable by the current admin. Intended to hand authority to a
    ///      TimelockController so that proposal creation enforces a mandatory delay.
    /// @param newAdmin Address that will be able to call createProposal()
    function updateAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero admin");
        require(newAdmin != admin, "Same admin");
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    // ─── Phase 0: Proposal creation ─────────────────────────────────────────

    /// @notice Admin creates a new proposal.
    /// @dev Voting power is determined per-voter when they commit (balanceOf at that block).
    /// @param description Human-readable proposal text
    /// @param commitDuration Seconds the commit phase lasts
    /// @param revealDuration Seconds the reveal phase lasts (starts after commit ends)
    /// @return proposalId ID of the created proposal
    function createProposal(
        string calldata description,
        uint256 commitDuration,
        uint256 revealDuration
    ) external onlyAdmin returns (uint256 proposalId) {
        require(bytes(description).length > 0, "Empty description");
        require(commitDuration > 0 && revealDuration > 0, "Zero duration");

        proposalId = ++proposalCount;
        uint256 commitEnd = block.timestamp + commitDuration;

        Proposal storage p = proposals[proposalId];
        p.description = description;
        p.snapshotBlock = block.number;
        p.commitDeadline = commitEnd;
        p.revealDeadline = commitEnd + revealDuration;

        emit ProposalCreated(proposalId, description, commitEnd, p.revealDeadline);
    }

    // ─── Phase 1: Commit ────────────────────────────────────────────────────

    /// @notice Submit a vote commitment hash.
    /// @dev hash must be computed as keccak256(abi.encodePacked(vote, salt)) off-chain.
    ///      The voter's token balance is snapshotted as their weight for this proposal.
    ///      Can be relayed via the trusted forwarder; `_msgSender()` resolves to the voter.
    /// @param proposalId Target proposal
    /// @param voteHash The commitment hash
    function commitVote(uint256 proposalId, bytes32 voteHash) external validProposal(proposalId) {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp <= p.commitDeadline, "Commit phase ended");
        require(voteHash != bytes32(0), "Zero hash");

        address voter = _msgSender();
        VoterReceipt storage r = receipts[proposalId][voter];
        require(!r.committed, "Already committed");

        r.commitHash = voteHash;
        r.weight = votingToken.balanceOf(voter);
        require(r.weight > 0, "No voting power");
        r.committed = true;

        _voterList[proposalId].push(voter);

        emit VoteCommitted(proposalId, voter);
    }

    // ─── Phase 2: Reveal ────────────────────────────────────────────────────

    /// @notice Reveal your vote and salt; the contract verifies against the stored commitment.
    /// @dev Can be relayed via the trusted forwarder; `_msgSender()` resolves to the voter.
    /// @param proposalId Target proposal
    /// @param vote The actual vote value
    /// @param salt The random salt used during commit
    function revealVote(uint256 proposalId, Vote vote, uint256 salt)
        external
        validProposal(proposalId)
    {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.commitDeadline, "Commit phase active");
        require(block.timestamp <= p.revealDeadline, "Reveal phase ended");

        address voter = _msgSender();
        VoterReceipt storage r = receipts[proposalId][voter];
        require(r.committed, "No commitment");
        require(!r.revealed, "Already revealed");

        require(keccak256(abi.encodePacked(vote, salt)) == r.commitHash, "Commit mismatch");

        r.vote = vote;
        r.revealed = true;

        if (vote == Vote.For) {
            p.forVotes += r.weight;
        } else if (vote == Vote.Abstain) {
            p.abstainVotes += r.weight;
        } else {
            p.againstVotes += r.weight;
        }

        emit VoteRevealed(proposalId, voter, vote);
    }

    // ─── Phase 3: Tally ─────────────────────────────────────────────────────

    /// @notice Finalise the proposal after the reveal window closes.
    /// @dev Callable by anyone.  Iterates the voter list and penalises every address that
    ///      committed but failed to reveal – their weight is forfeited entirely (does not
    ///      count toward any option).
    /// @param proposalId Target proposal
    function tallyVotes(uint256 proposalId) external validProposal(proposalId) {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp > p.revealDeadline, "Reveal phase active");
        require(!p.tallied, "Already tallied");

        p.tallied = true;

        address[] storage voters = _voterList[proposalId];
        for (uint256 i = 0; i < voters.length; ++i) {
            VoterReceipt storage r = receipts[proposalId][voters[i]];
            if (r.committed && !r.revealed) {
                emit VotePenalized(proposalId, voters[i], r.weight);
            }
        }

        emit ProposalTallied(proposalId, p.forVotes, p.againstVotes, p.abstainVotes);
    }

    // ─── View helpers ───────────────────────────────────────────────────────

    /// @notice Read the full result of a tallied proposal.
    function getProposalResult(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (
            string memory description,
            bool tallied,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.description, p.tallied, p.forVotes, p.againstVotes, p.abstainVotes);
    }

    /// @notice Seconds remaining in the commit phase (0 if ended).
    function commitTimeRemaining(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (uint256)
    {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.commitDeadline) return 0;
        return p.commitDeadline - block.timestamp;
    }

    /// @notice Seconds remaining in the reveal phase (0 if ended).
    function revealTimeRemaining(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (uint256)
    {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.revealDeadline) return 0;
        return p.revealDeadline - block.timestamp;
    }

    /// @notice Number of voters who committed to a proposal.
    function voterCount(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (uint256)
    {
        return _voterList[proposalId].length;
    }
}
