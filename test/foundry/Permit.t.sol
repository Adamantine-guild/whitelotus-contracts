// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Vault} from "../../contracts/Vault.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockERC20Permit is ERC20, ERC20Permit {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PermitTest is Test {
    Vault internal vaultWithPermit;
    Vault internal vaultWithoutPermit;

    MockERC20Permit internal tokenWithPermit;
    MockERC20 internal tokenWithoutPermit;

    address internal owner = makeAddr("owner");
    uint256 internal userPrivateKey = 0xA11CE;
    address internal user = vm.addr(userPrivateKey);

    uint256 constant INITIAL_BALANCE = 10_000e18;

    function setUp() public {
        // Deploy tokens
        tokenWithPermit = new MockERC20Permit("Permit Token", "PMR", 18);
        tokenWithoutPermit = new MockERC20("No Permit Token", "NPR", 18);

        // Deploy vaults
        vaultWithPermit = new Vault(IERC20(address(tokenWithPermit)), "Vault with Permit", "vPMR", owner);
        vaultWithoutPermit = new Vault(IERC20(address(tokenWithoutPermit)), "Vault without Permit", "vNPR", owner);

        // Mint initial balances
        tokenWithPermit.mint(user, INITIAL_BALANCE);
        tokenWithoutPermit.mint(user, INITIAL_BALANCE);
    }

    // ─── EIP-2612 Permit Happy Path ──────────────────────────────────────────

    function testDepositWithPermitSuccess() public {
        uint256 depositAmount = 1000e18;
        uint256 nonce = tokenWithPermit.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        // Compute EIP-712 permit digest
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(vaultWithPermit),
                depositAmount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenWithPermit.DOMAIN_SEPARATOR(),
                structHash
            )
        );

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        // Perform gasless deposit
        vm.prank(user);
        uint256 shares = vaultWithPermit.deposit(depositAmount, user, deadline, v, r, s);

        assertTrue(shares > 0);
        assertEq(tokenWithPermit.balanceOf(address(vaultWithPermit)), depositAmount);
        assertEq(vaultWithPermit.balanceOf(user), shares);
    }

    function testDepositWithPermitSlippageSuccess() public {
        uint256 depositAmount = 1000e18;
        uint256 nonce = tokenWithPermit.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(vaultWithPermit),
                depositAmount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenWithPermit.DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        uint256 expectedShares = vaultWithPermit.previewDeposit(depositAmount);

        vm.prank(user);
        uint256 shares = vaultWithPermit.deposit(depositAmount, user, expectedShares, deadline, v, r, s);

        assertEq(shares, expectedShares);
    }

    // ─── EIP-2612 Permit Error Paths ──────────────────────────────────────────

    function testDepositWithPermitExpiredSignature() public {
        uint256 depositAmount = 1000e18;
        uint256 nonce = tokenWithPermit.nonces(user);
        uint256 deadline = block.timestamp - 1; // Expired

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(vaultWithPermit),
                depositAmount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenWithPermit.DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline)
        );

        vm.prank(user);
        vaultWithPermit.deposit(depositAmount, user, deadline, v, r, s);
    }

    function testDepositWithPermitInvalidSignature() public {
        uint256 depositAmount = 1000e18;
        uint256 nonce = tokenWithPermit.nonces(user);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(vaultWithPermit),
                depositAmount,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenWithPermit.DOMAIN_SEPARATOR(),
                structHash
            )
        );

        // Sign with a different private key
        uint256 wrongPrivateKey = 0xBAD;
        address wrongSigner = vm.addr(wrongPrivateKey);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, wrongSigner, user)
        );

        vm.prank(user);
        vaultWithPermit.deposit(depositAmount, user, deadline, v, r, s);
    }

    // ─── Fallback Gracefully to Standard Allowance Checks ─────────────────────

    function testDepositFallbackToAllowanceSuccess() public {
        // Here, the token does not support permit, but we provide allowance first
        uint256 depositAmount = 1000e18;
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(user);
        tokenWithoutPermit.approve(address(vaultWithoutPermit), depositAmount);

        // The permit signature parameters (v, r, s) can be dummy values
        vm.prank(user);
        uint256 shares = vaultWithoutPermit.deposit(depositAmount, user, deadline, 0, bytes32(0), bytes32(0));

        assertTrue(shares > 0);
        assertEq(tokenWithoutPermit.balanceOf(address(vaultWithoutPermit)), depositAmount);
    }

    function testDepositFallbackToAllowanceFails() public {
        // No allowance set on the token without permit support
        uint256 depositAmount = 1000e18;
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert("Vault: Permit failed and allowance insufficient");

        vm.prank(user);
        vaultWithoutPermit.deposit(depositAmount, user, deadline, 0, bytes32(0), bytes32(0));
    }
}
