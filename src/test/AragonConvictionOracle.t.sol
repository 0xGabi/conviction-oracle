// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "hardhat/console.sol";

import {DSTest} from "../../dapp_test/test.sol";
import {AragonConvictionOracle} from "../AragonConvictionOracle.sol";

contract AragonConvictionOracleTest is DSTest {

    AragonConvictionOracle wrappedAragonConvictionOracle;
    ERC20 stackedToken;
    function setUp() public {
        stackedToken = new ERC20("Name", "SYM");
        address[] memory triggers = new address[](2);
        triggers[0] = address(0x50);
        triggers[1] = address(0x100);
        wrappedAragonConvictionOracle = new AragonConvictionOracle(stackedToken, 1, 1, triggers);
    }

    /// -------------------------------------------------------------------
    /// Gas benchmarking
    /// -------------------------------------------------------------------


    function testGas_decay() public view {
        wrappedAragonConvictionOracle.decay();
    }

    function testGas_minStakeRatio() public view {
        wrappedAragonConvictionOracle.minStakeRatio();
    }

    function testGas_calculateConviction() public view {
        wrappedAragonConvictionOracle.calculateConviction(0,0,0);
    }

    function testGas_getProposal() public view {
        wrappedAragonConvictionOracle.getProposal(0);
    }

}
