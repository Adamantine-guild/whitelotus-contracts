// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {LZAdapter} from "./LZAdapter.sol";

contract WhiteLotusOFT is ERC20, LZAdapter {
    error InvalidRecipient();
    error InvalidAmount();

    event TransferSent(
        address indexed sender, uint32 indexed dstEid, bytes32 indexed guid, uint256 amount
    );
    event TransferReceived(address indexed recipient, uint32 indexed srcEid, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address endpoint_,
        address owner_,
        uint256 initialSupply
    ) ERC20(name_, symbol_) LZAdapter(endpoint_, owner_) {
        _mint(owner_, initialSupply);
    }

    function send(uint32 dstEid, bytes32 recipient, uint256 amount, uint256 nativeFee)
        external
        payable
        returns (bytes32 guid)
    {
        if (recipient == bytes32(0)) revert InvalidRecipient();
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, amount);
        guid = _send(dstEid, abi.encode(uint8(0), recipient, amount), nativeFee);
        emit TransferSent(msg.sender, dstEid, guid, amount);
    }

    function _handleMessage(uint32 srcEid, bytes calldata message) internal override {
        (uint8 kind, bytes32 recipient, uint256 amount) =
            abi.decode(message, (uint8, bytes32, uint256));
        if (kind == 0) {
            if (uint256(recipient) > type(uint160).max) revert InvalidRecipient();
            address account = address(uint160(uint256(recipient)));
            if (account == address(0)) revert InvalidRecipient();
            if (amount == 0) revert InvalidAmount();
            _mint(account, amount);
            emit TransferReceived(account, srcEid, amount);
            return;
        }
        super._handleMessage(srcEid, message);
    }
}
