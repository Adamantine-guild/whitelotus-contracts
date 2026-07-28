// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

// Simulates BaseLogic before any variables are added
abstract contract MockBaseLogicV1 is Initializable {
    uint256[50] private __gap;
}

// Simulates a child contract using BaseLogic V1
contract MockContractV1 is MockBaseLogicV1 {
    uint256 public childVar;
}

// Simulates BaseLogic after a variable is added correctly (gap reduced)
abstract contract MockBaseLogicV2_Correct is Initializable {
    uint256 public newVar;
    uint256[49] private __gap;
}

// Simulates a child contract using the Correct BaseLogic V2
contract MockContractV2_Correct is MockBaseLogicV2_Correct {
    uint256 public childVar;
}

// Simulates BaseLogic after a variable is added INCORRECTLY (gap NOT reduced)
abstract contract MockBaseLogicV2_Bad is Initializable {
    uint256 public newVar;
    uint256[50] private __gap;
}

// Simulates a child contract using the Bad BaseLogic V2
contract MockContractV2_Bad is MockBaseLogicV2_Bad {
    uint256 public childVar;
}
