// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {ERC2771Context} from "./ERC2771Context.sol";

/// @title GrantRound - Minimal MVP grant round contract for GrantChain
/// @notice Holds basic round config, application approvals, milestones, and ETH payouts.
///         Supports EIP-712 meta-transactions via ERC-2771: a trusted forwarder can
///         relay calls on behalf of users, and `_msgSender()` correctly resolves to the
///         original signer rather than the forwarder address.
/// @dev Intentionally simple: single admin, ETH-only escrow, URI-based metadata.
contract GrantRound is ERC2771Context {
    error NotAdmin();
    error Reentrancy();
    error ContractPaused();
    error ZeroAdminAddress();
    error AlreadyPaused();
    error NotPaused();
    error UriEmpty();
    error ApplicationDoesNotExist();
    error NotPending();
    error ApplicationNotApproved();
    error AlreadySet();
    error NoMilestones();
    error ZeroMilestoneAmount();
    error NotGrantee();
    error InvalidMilestoneIndex();
    error AlreadySubmitted();
    error EvidenceEmpty();
    error NotSubmitted();
    error AlreadyApproved();
    error MilestoneNotApproved();
    error MilestoneAlreadyPaid();
    error InsufficientFunds();
    error TransferFailed();
    error ClawbackFailed();

    /// @dev Single admin for this round. TODO: future governance adapter/roles
    address public immutable admin;

    /// @dev Human-readable title for the round (short). Off-chain may mirror/extend.
    string public roundTitle;

    /// @dev Metadata URI describing the round config/details
    string public metadataURI;

    /// @dev Declarative budget for UI purposes; not strictly enforced on-chain
    uint256 public budget;

    /// @dev Basic reentrancy guard for payout
    bool private _locked;

    /// @dev Emergency stop switch (#1). When set, fund-in operations revert.
    bool public paused;

    function _checkAdmin() internal view {
        if (!(_msgSender() == admin)) revert NotAdmin();
    }

    function _checkWhenNotPaused() internal view {
        if (!(!paused)) revert ContractPaused();
    }

    modifier onlyAdmin() {
        _checkAdmin();
        _;
    }

    modifier nonReentrant() {
        if (!(!_locked)) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier whenNotPaused() {
        _checkWhenNotPaused();
        _;
    }

    enum AppStatus {
        Pending,
        Approved,
        Rejected
    }

    struct Application {
        address applicant;
        string uri;
        AppStatus status;
    }

    struct Milestone {
        uint256 amount;
        string evidenceURI;
        bool submitted;
        bool approved;
        bool paid;
    }

    /// @dev incremental app id
    uint256 public applicationCount;

    mapping(uint256 => Application) public applications; // appId => Application
    mapping(uint256 => Milestone[]) private _milestones; // appId => milestones

    /// @dev Emitted when round receives funding
    event DepositReceived(address indexed from, uint256 amount);
    /// @dev Emitted when a new application is submitted
    event ApplicationSubmitted(uint256 indexed appId, address indexed applicant, string uri);
    /// @dev Emitted when an application is approved
    event ApplicationApproved(uint256 indexed appId, address indexed admin);
    /// @dev Emitted when an application is rejected
    event ApplicationRejected(uint256 indexed appId, address indexed admin);
    /// @dev Emitted when milestones created for an application
    event MilestonesCreated(uint256 indexed appId, uint256 count, uint256 totalAmount);
    /// @dev Emitted when milestone evidence is submitted by grantee
    event MilestoneEvidenceSubmitted(
        uint256 indexed appId, uint256 indexed index, string evidenceURI
    );
    /// @dev Emitted when admin approves milestone evidence
    event MilestoneApproved(uint256 indexed appId, uint256 indexed index, address indexed admin);
    /// @dev Emitted when payout released to grantee
    event PayoutReleased(uint256 indexed appId, uint256 indexed index, address to, uint256 amount);
    /// @dev Emitted when unspent funds are withdrawn by admin (#5)
    event FundsClawedBack(address indexed to, uint256 amount);
    /// @dev Emitted when the round is paused/unpaused (#1)
    event Paused(address indexed admin);
    event Unpaused(address indexed admin);

    /// @param _title round title
    /// @param _metadataURI metadata URI for the round details
    /// @param _budget declarative budget for UI display
    /// @param _admin admin address for access control
    /// @param _trustedForwarder ERC-2771 forwarder address (set to address(0) to disable
    ///        meta-transaction support — the zero address is rejected by ERC2771Context,
    ///        so pass a dedicated no-op address if you truly want no forwarding)
    constructor(
        string memory _title,
        string memory _metadataURI,
        uint256 _budget,
        address _admin,
        address _trustedForwarder
    ) ERC2771Context(_trustedForwarder) {
        if (!(_admin != address(0))) revert ZeroAdminAddress();
        roundTitle = _title;
        metadataURI = _metadataURI;
        budget = _budget;
        admin = _admin;
    }

    /// @notice Accept ETH funding for this round.
    /// @dev Respects the pause switch so the documented "fund-in operations revert"
    ///      guarantee (#1) holds for every funding path, not just deposit().
    receive() external payable whenNotPaused {
        emit DepositReceived(msg.sender, msg.value);
    }

    /// @notice Deposit ETH explicitly
    function deposit() external payable onlyAdmin whenNotPaused {
        emit DepositReceived(_msgSender(), msg.value);
    }

    /// @notice Emergency stop: halts deposit() until unpaused (#1)
    function pause() external onlyAdmin {
        if (!(!paused)) revert AlreadyPaused();
        paused = true;
        emit Paused(_msgSender());
    }

    /// @notice Resume deposit() after a pause (#1)
    function unpause() external onlyAdmin {
        if (!(paused)) revert NotPaused();
        paused = false;
        emit Unpaused(_msgSender());
    }

    /// @notice Submit a grant application by metadata URI
    /// @param uri metadata URI describing the proposal
    /// @return appId id of the created application
    function submitApplication(string calldata uri) external returns (uint256 appId) {
        if (!(bytes(uri).length > 0)) revert UriEmpty();
        address sender = _msgSender();
        appId = ++applicationCount;
        applications[appId] =
            Application({applicant: sender, uri: uri, status: AppStatus.Pending});
        emit ApplicationSubmitted(appId, sender, uri);
    }

    /// @notice Approve a pending application
    function approveApplication(uint256 appId) external onlyAdmin {
        Application storage app = applications[appId];
        if (!(app.applicant != address(0))) revert ApplicationDoesNotExist();
        if (!(app.status == AppStatus.Pending)) revert NotPending();
        app.status = AppStatus.Approved;
        emit ApplicationApproved(appId, _msgSender());
    }

    /// @notice Reject a pending application
    function rejectApplication(uint256 appId) external onlyAdmin {
        Application storage app = applications[appId];
        if (!(app.applicant != address(0))) revert ApplicationDoesNotExist();
        if (!(app.status == AppStatus.Pending)) revert NotPending();
        app.status = AppStatus.Rejected;
        emit ApplicationRejected(appId, _msgSender());
    }

    /// @notice Create milestones for an approved application. One-time definition.
    /// @param appId target approved application
    /// @param amounts milestone amounts denominated in wei
    function createMilestones(uint256 appId, uint256[] calldata amounts) external onlyAdmin {
        Application storage app = applications[appId];
        if (!(app.applicant != address(0))) revert ApplicationDoesNotExist();
        if (!(app.status == AppStatus.Approved)) revert ApplicationNotApproved();
        if (!(_milestones[appId].length == 0)) revert AlreadySet();
        if (!(amounts.length > 0)) revert NoMilestones();

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            if (!(amounts[i] > 0)) revert ZeroMilestoneAmount();
            _milestones[appId].push(
                Milestone({
                    amount: amounts[i],
                    evidenceURI: "",
                    submitted: false,
                    approved: false,
                    paid: false
                })
            );
            total += amounts[i];
        }
        // NOTE: We do NOT strictly enforce budget; payout will check balance sufficiency.
        emit MilestonesCreated(appId, amounts.length, total);
    }

    /// @notice Submit evidence URI for a milestone by the grantee (applicant)
    function submitMilestoneEvidence(uint256 appId, uint256 index, string calldata evidenceURI)
        external
    {
        Application storage app = applications[appId];
        if (!(app.applicant != address(0))) revert ApplicationDoesNotExist();
        if (!(app.status == AppStatus.Approved)) revert ApplicationNotApproved();
        if (!(_msgSender() == app.applicant)) revert NotGrantee();
        if (!(index < _milestones[appId].length)) revert InvalidMilestoneIndex();

        Milestone storage m = _milestones[appId][index];
        if (!(!m.submitted)) revert AlreadySubmitted();
        if (!(bytes(evidenceURI).length > 0)) revert EvidenceEmpty();
        m.evidenceURI = evidenceURI;
        m.submitted = true;
        emit MilestoneEvidenceSubmitted(appId, index, evidenceURI);
    }

    /// @notice Admin approves submitted milestone evidence
    function approveMilestone(uint256 appId, uint256 index) external onlyAdmin {
        if (!(index < _milestones[appId].length)) revert InvalidMilestoneIndex();
        Milestone storage m = _milestones[appId][index];
        if (!(m.submitted)) revert NotSubmitted();
        if (!(!m.approved)) revert AlreadyApproved();
        m.approved = true;
        emit MilestoneApproved(appId, index, _msgSender());
    }

    /// @notice Release payout for an approved milestone to the grantee
    function releasePayout(uint256 appId, uint256 index) external onlyAdmin nonReentrant {
        Application storage app = applications[appId];
        if (!(app.applicant != address(0))) revert ApplicationDoesNotExist();
        if (!(index < _milestones[appId].length)) revert InvalidMilestoneIndex();
        Milestone storage m = _milestones[appId][index];
        if (!(m.approved)) revert MilestoneNotApproved();
        if (!(!m.paid)) revert MilestoneAlreadyPaid();
        if (!(address(this).balance >= m.amount)) revert InsufficientFunds();

        m.paid = true;
        (bool ok,) = app.applicant.call{value: m.amount}("");
        if (!(ok)) revert TransferFailed();
        emit PayoutReleased(appId, index, app.applicant, m.amount);
    }

    /// @notice Read milestones for an application
    function getMilestones(uint256 appId) external view returns (Milestone[] memory) {
        return _milestones[appId];
    }

    /// @notice Withdraw unspent funds to admin or specified address
    /// @dev TODO: extend to richer clawback policies and timelocks
    function clawbackUnspentFunds(address to) external onlyAdmin nonReentrant {
        address recipient = to == address(0) ? admin : to;
        uint256 amt = address(this).balance;
        (bool ok,) = recipient.call{value: amt}("");
        if (!(ok)) revert ClawbackFailed();
        emit FundsClawedBack(recipient, amt);
    }
}
