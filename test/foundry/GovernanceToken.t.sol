// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GovernanceToken} from "../../contracts/GovernanceToken.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken internal token;
    uint256 internal ownerPk = 0xB0B;
    address internal owner = vm.addr(ownerPk);
    address internal spender = address(0xCAD);

    uint256 internal constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        token = new GovernanceToken("White Lotus", "WLT", owner, INITIAL_SUPPLY);
    }

    function testPermitUpdatesAllowance() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.prank(spender);
        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
    }

    function testRejectsReusedNonce() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);

        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function testRejectsExpiredDeadline() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp - 1;

        uint256 nonce = token.nonces(owner);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function testRejectsInvalidSignature() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            0xDEAD,
            keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), bytes32(0)))
        );

        vm.expectRevert();
        token.permit(owner, spender, value, deadline, v, r, s);
    }

    function testUsesPermittedAllowanceForTransfer() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);

        vm.prank(owner);
        token.approve(spender, 0);
        assertEq(token.allowance(owner, spender), 0);
    }

    function testEIP712DomainSeparator() public view {
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(token.name())),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }

    function testNonceIncrementsAfterPermit() public {
        uint256 nonceBefore = token.nonces(owner);

        uint256 value = 50e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(owner);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, owner, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.nonces(owner), nonceBefore + 1);
    }

    function testPermitFromDelegatedAccount() public {
        uint256 alicePk = 0xAb1;
        address alice = vm.addr(alicePk);
        uint256 aliceSupply = 500e18;

        vm.prank(owner);
        token.transfer(alice, aliceSupply);

        uint256 value = 30e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = token.nonces(alice);

        bytes32 permitHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(
            abi.encode(permitHash, alice, spender, value, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        token.permit(alice, spender, value, deadline, v, r, s);

        assertEq(token.allowance(alice, spender), value);
        assertEq(token.balanceOf(alice), aliceSupply);
    }
}
