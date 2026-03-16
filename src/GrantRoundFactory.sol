// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./GrantRound.sol";

/// @title GrantRoundFactory - Minimal factory to deploy simple grant rounds
contract GrantRoundFactory {
    event RoundCreated(
        address indexed round,
        address indexed admin,
        string title,
        string metadataURI,
        uint256 budget
    );

    address[] public allRounds;

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
        GrantRound r = new GrantRound(title, metadataURI, budget, _admin);
        round = address(r);
        allRounds.push(round);

        if (msg.value > 0) {
            // optional initial funding
            (bool ok, ) = round.call{value: msg.value}("");
            require(ok, "funding failed");
        }

        emit RoundCreated(round, _admin, title, metadataURI, budget);
    }

    /// @notice Number of rounds created
    function roundsCount() external view returns (uint256) {
        return allRounds.length;
    }
}
