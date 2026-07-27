// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GrantRound - Minimal MVP grant round contract for GrantChain
/// @notice Holds basic round config, application approvals, milestones, and ETH payouts
/// @dev Intentionally simple: single admin, ETH-only escrow, URI-based metadata
contract GrantRound {
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

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrancy");
        _locked = true;
        _;
        _locked = false;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
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
    /// @param _metadataURI metadata URI for the round
    /// @param _budget declarative budget for UI display
    /// @param _admin admin address for access control
    constructor(string memory _title, string memory _metadataURI, uint256 _budget, address _admin) {
        require(_admin != address(0), "admin=0");
        roundTitle = _title;
        metadataURI = _metadataURI;
        budget = _budget;
        admin = _admin;
    }

    /// @notice Accept ETH funding for this round
    receive() external payable {
        emit DepositReceived(msg.sender, msg.value);
    }

    /// @notice Deposit ETH explicitly
    function deposit() external payable onlyAdmin whenNotPaused {
        emit DepositReceived(msg.sender, msg.value);
    }

    /// @notice Emergency stop: halts deposit() until unpaused (#1)
    function pause() external onlyAdmin {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resume deposit() after a pause (#1)
    function unpause() external onlyAdmin {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Submit a grant application by metadata URI
    /// @param uri metadata URI describing the proposal
    /// @return appId id of the created application
    function submitApplication(string calldata uri) external returns (uint256 appId) {
        require(bytes(uri).length > 0, "uri empty");
        appId = ++applicationCount;
        applications[appId] =
            Application({applicant: msg.sender, uri: uri, status: AppStatus.Pending});
        emit ApplicationSubmitted(appId, msg.sender, uri);
    }

    /// @notice Approve a pending application
    function approveApplication(uint256 appId) external onlyAdmin {
        Application storage app = applications[appId];
        require(app.applicant != address(0), "app !exists");
        require(app.status == AppStatus.Pending, "not pending");
        app.status = AppStatus.Approved;
        emit ApplicationApproved(appId, msg.sender);
    }

    /// @notice Reject a pending application
    function rejectApplication(uint256 appId) external onlyAdmin {
        Application storage app = applications[appId];
        require(app.applicant != address(0), "app !exists");
        require(app.status == AppStatus.Pending, "not pending");
        app.status = AppStatus.Rejected;
        emit ApplicationRejected(appId, msg.sender);
    }

    /// @notice Create milestones for an approved application. One-time definition.
    /// @param appId target approved application
    /// @param amounts milestone amounts denominated in wei
    function createMilestones(uint256 appId, uint256[] calldata amounts) external onlyAdmin {
        Application storage app = applications[appId];
        require(app.applicant != address(0), "app !exists");
        require(app.status == AppStatus.Approved, "app !approved");
        require(_milestones[appId].length == 0, "already set");
        require(amounts.length > 0, "no milestones");

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] > 0, "amount 0");
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
        require(app.applicant != address(0), "app !exists");
        require(app.status == AppStatus.Approved, "app !approved");
        require(msg.sender == app.applicant, "not grantee");
        require(index < _milestones[appId].length, "bad index");

        Milestone storage m = _milestones[appId][index];
        require(!m.submitted, "already submitted");
        require(bytes(evidenceURI).length > 0, "evidence empty");
        m.evidenceURI = evidenceURI;
        m.submitted = true;
        emit MilestoneEvidenceSubmitted(appId, index, evidenceURI);
    }

    /// @notice Admin approves submitted milestone evidence
    function approveMilestone(uint256 appId, uint256 index) external onlyAdmin {
        require(index < _milestones[appId].length, "bad index");
        Milestone storage m = _milestones[appId][index];
        require(m.submitted, "not submitted");
        require(!m.approved, "already approved");
        m.approved = true;
        emit MilestoneApproved(appId, index, msg.sender);
    }

    /// @notice Release payout for an approved milestone to the grantee
    function releasePayout(uint256 appId, uint256 index) external onlyAdmin nonReentrant {
        Application storage app = applications[appId];
        require(app.applicant != address(0), "app !exists");
        require(index < _milestones[appId].length, "bad index");
        Milestone storage m = _milestones[appId][index];
        require(m.approved, "!approved");
        require(!m.paid, "paid");
        require(address(this).balance >= m.amount, "insufficient funds");

        m.paid = true;
        (bool ok,) = app.applicant.call{value: m.amount}("");
        require(ok, "transfer failed");
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
        require(ok, "clawback failed");
        emit FundsClawedBack(recipient, amt);
    }
}

