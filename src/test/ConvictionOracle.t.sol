// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "hardhat/console.sol";

import {DSTest} from "../../dapp_test/test.sol";
import {ConvictionOracle} from "../ConvictionOracle.sol";

contract ConvictionOracleTest is DSTest {

    ConvictionOracle wrappedConvictionOracle;
    ERC20 stackedToken;
    function setUp() public {
        stackedToken = new ERC20("Name", "SYM");
        address[] memory triggers = new address[](2);
        triggers[0] = address(0x50);
        triggers[1] = address(0x100);
        wrappedConvictionOracle = new ConvictionOracle(stackedToken, 1, 1, triggers);
    }

    /// -------------------------------------------------------------------
    /// Gas benchmarking
    /// -------------------------------------------------------------------


    function testGas_decay() public view {
        wrappedConvictionOracle.decay();
    }

    function testGas_minStakeRatio() public view {
        wrappedConvictionOracle.minStakeRatio();
    }

    /* //TODO add this tests
    function testGas_addProposal() public {
        wrappedConvictionOracle.addProposal();
    }*/

    function testGas_calculateConviction() public view {
        wrappedConvictionOracle.calculateConviction(0,0,0);
    }

    function testGas_getProposal() public view {
        wrappedConvictionOracle.getProposal(0);
    }

    /* //TODO add this tests
    function testGas_cancelProposal() public {
        wrappedConvictionOracle.cancelProposal(0);
    }*/


}
