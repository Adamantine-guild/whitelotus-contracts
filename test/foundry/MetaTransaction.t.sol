// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinimalForwarder} from "../../contracts/MinimalForwarder.sol";
import {GrantRound} from "../../contracts/GrantRound.sol";
import {Governance} from "../../contracts/Governance.sol";

// ─── Minimal ERC-20 token for voting-power tests ─────────────────────────────

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// ─── Main test contract ───────────────────────────────────────────────────────

/// @title MetaTransactionTest
/// @notice End-to-end tests for the EIP-712 meta-transaction pipeline.
///
/// Coverage:
///   1.  Basic relay: relayer executes on behalf of signer; applicant is signer
///   2.  Replay attack: same signature cannot be reused
///   3.  Deadline expiry: expired requests revert
///   4.  Wrong signer: forged signatures revert
///   5.  Nonce mismatch: out-of-order nonces revert
///   6.  Non-forwarder caller cannot fake appended sender
///   7.  verify() matches execute() outcome
///   8.  Sequential nonces across multiple requests
///   9.  Relayed milestone evidence respects grantee identity
///  10.  Stranger cannot submit evidence via relay
///  11.  Governance – relayed commitVote / revealVote end-to-end
///  12.  Governance – reveal with wrong vote reverts (commit mismatch)
///  13.  isTrustedForwarder / trustedForwarder view helpers
///  14.  Admin-only function from non-admin signer reverts via relay
///  15.  Admin-only function from admin signer succeeds via relay
///  16.  Cross-chain replay: sig signed on different chainId reverts
contract MetaTransactionTest is Test {
    // ─── Actors ─────────────────────────────────────────────────────────────

    uint256 internal signerKey = 0xA11CE0001;
    address internal signer;

    uint256 internal adminKey = 0xAD0001;
    address internal adminAddr;

    address internal relayer = address(0xDEAD);

    // ─── Contracts ──────────────────────────────────────────────────────────

    MinimalForwarder internal forwarder;
    GrantRound internal round;
    MockERC20 internal token;
    Governance internal gov;

    // ─── Setup ──────────────────────────────────────────────────────────────

    function setUp() public {
        signer = vm.addr(signerKey);
        adminAddr = vm.addr(adminKey);

        vm.deal(signer, 10 ether);
        vm.deal(adminAddr, 10 ether);
        vm.deal(relayer, 10 ether);

        // Deploy forwarder.
        forwarder = new MinimalForwarder();

        // Deploy GrantRound (admin = adminAddr, forwarder wired in).
        vm.prank(adminAddr);
        round = new GrantRound("Meta Round", "ipfs://meta", 5 ether, adminAddr, address(forwarder));

        // Fund the round.
        vm.prank(adminAddr);
        round.deposit{value: 5 ether}();

        // Deploy token + Governance (admin = msg.sender = address(this) of test setup).
        token = new MockERC20();
        vm.prank(adminAddr);
        gov = new Governance(address(token), address(forwarder));
    }

    // ─── EIP-712 signing helpers ─────────────────────────────────────────────

    bytes32 private constant FORWARD_REQUEST_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint256 deadline,bytes data)"
    );

    /// @dev Build the EIP-712 digest for a ForwardRequest.
    function _digest(MinimalForwarder.ForwardRequest memory req)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                forwarder.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        FORWARD_REQUEST_TYPEHASH,
                        req.from,
                        req.to,
                        req.value,
                        req.gas,
                        req.nonce,
                        req.deadline,
                        keccak256(req.data)
                    )
                )
            )
        );
    }

    /// @dev Sign a digest with privateKey; returns compact 65-byte sig (r, s, v).
    function _sign(uint256 privateKey, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, d);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build + sign a ForwardRequest for `data` targeting `to`.
    function _buildAndSign(
        uint256 privateKey,
        address to,
        bytes memory data
    )
        internal
        view
        returns (MinimalForwarder.ForwardRequest memory req, bytes memory sig)
    {
        address from = vm.addr(privateKey);
        req = MinimalForwarder.ForwardRequest({
            from: from,
            to: to,
            value: 0,
            gas: 300_000,
            nonce: forwarder.nonces(from),
            deadline: block.timestamp + 1 hours,
            data: data
        });
        sig = _sign(privateKey, _digest(req));
    }

    // ─── 1. Basic relay: signer identity is correct ──────────────────────────

    function testRelayedSubmitApplicationCreditsSigner() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://relayed-app");
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(signerKey, address(round), data);

        // Relayer executes.
        vm.prank(relayer);
        (bool ok,) = forwarder.execute(req, sig);
        assertTrue(ok, "execute should succeed");

        // Application must be attributed to `signer`, not `relayer`.
        (address applicant,,) = round.applications(1);
        assertEq(applicant, signer, "applicant must be original signer");
    }

    // ─── 2. Replay attack: second use of same signature reverts ─────────────

    function testReplayAttackReverts() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://replay");
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(signerKey, address(round), data);

        // First execution succeeds.
        vm.prank(relayer);
        (bool ok,) = forwarder.execute(req, sig);
        assertTrue(ok);

        // Second attempt with the same nonce must revert.
        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.NonceMismatch.selector);
        forwarder.execute(req, sig);
    }

    // ─── 3. Deadline expiry ──────────────────────────────────────────────────

    function testExpiredRequestReverts() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://expired");
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(signerKey, address(round), data);

        // Warp past deadline.
        vm.warp(req.deadline + 1);

        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.Expired.selector);
        forwarder.execute(req, sig);
    }

    // ─── 4. Invalid signature (wrong key) ────────────────────────────────────

    function testInvalidSignatureReverts() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://bad-sig");
        (MinimalForwarder.ForwardRequest memory req,) =
            _buildAndSign(signerKey, address(round), data);

        // Sign the same digest with a DIFFERENT private key.
        uint256 attackerKey = 0xBAD0BAD0;
        bytes memory badSig = _sign(attackerKey, _digest(req));

        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.InvalidSignature.selector);
        forwarder.execute(req, badSig);
    }

    // ─── 5. Nonce out of order ────────────────────────────────────────────────

    function testNonceMismatchReverts() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://nonce");
        (MinimalForwarder.ForwardRequest memory req,) =
            _buildAndSign(signerKey, address(round), data);

        // Tamper nonce and re-sign.
        req.nonce = 999;
        bytes memory sig = _sign(signerKey, _digest(req));

        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.NonceMismatch.selector);
        forwarder.execute(req, sig);
    }

    // ─── 6. Non-forwarder cannot fake appended sender ─────────────────────────

    function testNonForwarderCannotFakeSender() public {
        // `relayer` is NOT the trusted forwarder; its direct calls fall back to msg.sender.
        vm.prank(relayer);
        round.submitApplication("ipfs://direct");

        (address applicant,,) = round.applications(1);
        assertEq(applicant, relayer, "direct caller must be attributed to msg.sender");
        assertTrue(applicant != signer, "fake appended address must not be parsed");
    }

    // ─── 7. verify() matches execute() ───────────────────────────────────────

    function testVerifyMatchesExecute() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://verify");
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(signerKey, address(round), data);

        assertTrue(forwarder.verify(req, sig), "verify must return true before execute");

        vm.prank(relayer);
        forwarder.execute(req, sig);

        assertFalse(forwarder.verify(req, sig), "verify must return false after nonce consumed");
    }

    // ─── 8. Sequential nonces ────────────────────────────────────────────────

    function testSequentialNonces() public {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(forwarder.nonces(signer), i, "nonce pre-tx");

            bytes memory data = abi.encodeWithSelector(
                GrantRound.submitApplication.selector,
                string(abi.encodePacked("ipfs://seq-", vm.toString(i)))
            );
            (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
                _buildAndSign(signerKey, address(round), data);

            vm.prank(relayer);
            (bool ok,) = forwarder.execute(req, sig);
            assertTrue(ok);
        }
        assertEq(forwarder.nonces(signer), 3, "nonce should be 3 after 3 relayed txs");
    }

    // ─── 9. Relayed milestone evidence respects grantee identity ─────────────

    function testRelayedMilestoneEvidenceGranteeCheck() public {
        // Signer submits application via relay.
        bytes memory appData =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://ms-app");
        (MinimalForwarder.ForwardRequest memory req1, bytes memory sig1) =
            _buildAndSign(signerKey, address(round), appData);
        vm.prank(relayer);
        forwarder.execute(req1, sig1);
        uint256 appId = round.applicationCount();

        // Admin approves and creates milestones.
        vm.prank(adminAddr);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(adminAddr);
        round.createMilestones(appId, amounts);

        // Signer (grantee) submits evidence via relay.
        bytes memory evidData = abi.encodeWithSelector(
            GrantRound.submitMilestoneEvidence.selector, appId, uint256(0), "ipfs://evid0"
        );
        (MinimalForwarder.ForwardRequest memory req2, bytes memory sig2) =
            _buildAndSign(signerKey, address(round), evidData);
        vm.prank(relayer);
        (bool ok,) = forwarder.execute(req2, sig2);
        assertTrue(ok, "evidence submission should succeed");

        GrantRound.Milestone[] memory milestones = round.getMilestones(appId);
        assertTrue(milestones[0].submitted, "milestone must be marked submitted");
    }

    // ─── 10. Stranger cannot submit evidence via relay ────────────────────────

    function testRelayedEvidenceStrangerReverts() public {
        // Signer submits application.
        bytes memory appData =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://stranger-app");
        (MinimalForwarder.ForwardRequest memory req1, bytes memory sig1) =
            _buildAndSign(signerKey, address(round), appData);
        vm.prank(relayer);
        forwarder.execute(req1, sig1);
        uint256 appId = round.applicationCount();

        vm.prank(adminAddr);
        round.approveApplication(appId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(adminAddr);
        round.createMilestones(appId, amounts);

        // A DIFFERENT key tries to submit evidence for signer's application.
        uint256 strangerKey = 0x5738A9E8;
        bytes memory evidData = abi.encodeWithSelector(
            GrantRound.submitMilestoneEvidence.selector, appId, uint256(0), "ipfs://evil"
        );
        (MinimalForwarder.ForwardRequest memory req2, bytes memory sig2) =
            _buildAndSign(strangerKey, address(round), evidData);

        vm.prank(relayer);
        vm.expectRevert(GrantRound.NotGrantee.selector);
        forwarder.execute(req2, sig2);
    }

    // ─── 11. Governance – relayed commitVote / revealVote end-to-end ─────────

    function testGovernanceRelayedCommitAndReveal() public {
        token.mint(signer, 100 ether);

        vm.prank(adminAddr);
        uint256 proposalId = gov.createProposal("Test Proposal", 1 days, 1 days);

        uint256 salt = 0xDEADBEEF;
        bytes32 commitHash = keccak256(abi.encodePacked(Governance.Vote.For, salt));

        // Commit via relay.
        bytes memory commitData =
            abi.encodeWithSelector(Governance.commitVote.selector, proposalId, commitHash);
        (MinimalForwarder.ForwardRequest memory req1, bytes memory sig1) =
            _buildAndSign(signerKey, address(gov), commitData);
        vm.prank(relayer);
        (bool ok1,) = forwarder.execute(req1, sig1);
        assertTrue(ok1, "commitVote relay should succeed");

        // Receipt must be attributed to the original signer.
        (uint256 weight,,,bool committed,) = gov.receipts(proposalId, signer);
        assertTrue(committed, "signer should be committed");
        assertEq(weight, 100 ether);

        // Advance to reveal phase.
        vm.warp(block.timestamp + 1 days + 1);

        // Reveal via relay.
        bytes memory revealData = abi.encodeWithSelector(
            Governance.revealVote.selector, proposalId, Governance.Vote.For, salt
        );
        (MinimalForwarder.ForwardRequest memory req2, bytes memory sig2) =
            _buildAndSign(signerKey, address(gov), revealData);
        vm.prank(relayer);
        (bool ok2,) = forwarder.execute(req2, sig2);
        assertTrue(ok2, "revealVote relay should succeed");

        (,,,,bool revealed) = gov.receipts(proposalId, signer);
        assertTrue(revealed, "vote should be revealed");
    }

    // ─── 12. Governance – wrong vote in reveal reverts ────────────────────────

    function testGovernanceRelayedRevealMismatchReverts() public {
        token.mint(signer, 100 ether);

        vm.prank(adminAddr);
        uint256 proposalId = gov.createProposal("Mismatch Proposal", 1 days, 1 days);

        uint256 salt = 0xCAFEBABE;
        bytes32 commitHash = keccak256(abi.encodePacked(Governance.Vote.For, salt));

        bytes memory commitData =
            abi.encodeWithSelector(Governance.commitVote.selector, proposalId, commitHash);
        (MinimalForwarder.ForwardRequest memory req1, bytes memory sig1) =
            _buildAndSign(signerKey, address(gov), commitData);
        vm.prank(relayer);
        forwarder.execute(req1, sig1);

        vm.warp(block.timestamp + 1 days + 1);

        // Reveal with WRONG vote option.
        bytes memory revealData = abi.encodeWithSelector(
            Governance.revealVote.selector, proposalId, Governance.Vote.Against, salt
        );
        (MinimalForwarder.ForwardRequest memory req2, bytes memory sig2) =
            _buildAndSign(signerKey, address(gov), revealData);

        vm.prank(relayer);
        vm.expectRevert(Governance.CommitMismatch.selector);
        forwarder.execute(req2, sig2);
    }

    // ─── 13. isTrustedForwarder / trustedForwarder view helpers ──────────────

    function testIsTrustedForwarder() public view {
        assertTrue(round.isTrustedForwarder(address(forwarder)));
        assertFalse(round.isTrustedForwarder(address(0xDEAD)));
        assertEq(round.trustedForwarder(), address(forwarder));
    }

    // ─── 14. Admin-only function from non-admin signer reverts via relay ──────

    function testRelayedAdminCallFromNonAdminReverts() public {
        bytes memory data = abi.encodeWithSelector(GrantRound.pause.selector);
        // signerKey is NOT the admin.
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(signerKey, address(round), data);

        vm.prank(relayer);
        vm.expectRevert(GrantRound.NotAdmin.selector);
        forwarder.execute(req, sig);
    }

    // ─── 15. Admin-only function from admin signer succeeds via relay ─────────

    function testRelayedAdminCallFromAdminSucceeds() public {
        bytes memory data = abi.encodeWithSelector(GrantRound.pause.selector);
        (MinimalForwarder.ForwardRequest memory req, bytes memory sig) =
            _buildAndSign(adminKey, address(round), data);

        vm.prank(relayer);
        (bool ok,) = forwarder.execute(req, sig);
        assertTrue(ok, "admin relay should succeed");
        assertTrue(round.paused(), "round should be paused");
    }

    // ─── 16. Cross-chain replay: sig signed under different chainId reverts ───

    function testCrossChainReplayReverts() public {
        bytes memory data =
            abi.encodeWithSelector(GrantRound.submitApplication.selector, "ipfs://xchain");
        (MinimalForwarder.ForwardRequest memory req,) =
            _buildAndSign(signerKey, address(round), data);

        uint256 originalChain = block.chainid;

        // Switch to a different chainId so the domain separator changes.
        vm.chainId(originalChain + 1);
        bytes32 crossChainDigest = _digest(req); // built under chainId N+1
        bytes memory crossSig = _sign(signerKey, crossChainDigest);

        // Restore original chainId and try to execute with the cross-chain signature.
        vm.chainId(originalChain);

        vm.prank(relayer);
        vm.expectRevert(MinimalForwarder.InvalidSignature.selector);
        forwarder.execute(req, crossSig);
    }
}
