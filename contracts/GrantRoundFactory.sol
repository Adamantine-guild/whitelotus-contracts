// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {GrantRound} from "./GrantRound.sol";

/// @title GrantRoundFactory - Minimal factory to deploy simple grant rounds
/// @notice Deploys GrantRound contracts pre-configured with an ERC-2771 trusted forwarder
///         so that every round created through this factory can participate in
///         sponsored / gasless meta-transactions out of the box.
contract GrantRoundFactory {
    error ZeroForwarder();
    error FundingFailed();

    event RoundCreated(
        address indexed round,
        address indexed admin,
        string title,
        string metadataURI,
        uint256 budget
    );

    address[] public allRounds;

    /// @dev ERC-2771 forwarder address wired into every deployed GrantRound.
    address public immutable trustedForwarder;

    /// @param _trustedForwarder Address of the EIP-712 MinimalForwarder (or any ERC-2771
    ///        compatible forwarder).  Must be non-zero.
    constructor(address _trustedForwarder) {
        if (!(_trustedForwarder != address(0))) revert ZeroForwarder();
        trustedForwarder = _trustedForwarder;
    }

    /// @notice Create a new grant round with basic config
    /// @param title short title
    /// @param metadataURI metadata URI for the round details
    /// @param budget declarative budget for UI
    /// @param admin admin address controlling the round
    /// @return round address of the deployed GrantRound
    function createRound(
        string calldata title,
        string calldata metadataURI,
        uint256 budget,
        address admin
    ) external payable returns (address round) {
        address _admin = admin == address(0) ? msg.sender : admin;
        GrantRound r = new GrantRound(title, metadataURI, budget, _admin, trustedForwarder);
        round = address(r);
        allRounds.push(round);

        if (msg.value > 0) {
            // optional initial funding
            (bool ok,) = round.call{value: msg.value}("");
            if (!(ok)) revert FundingFailed();
        }

        emit RoundCreated(round, _admin, title, metadataURI, budget);
    }

    /// @notice Number of rounds created
    function roundsCount() external view returns (uint256) {
        return allRounds.length;
    }
}
