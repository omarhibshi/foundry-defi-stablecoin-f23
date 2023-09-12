// SPDX-License-Identifier: SEE LICENSE IN LICENSE

// Have our invariant aka properties hold true for all states and all times

// what are our invariants (what are our system properties that should always hold true)

// 1. The total supply of DSC (the debt) should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DeployDSC deployer;
    DSCEngine dsce;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
        //targetContract(address(dsce));
        // We need to make sure we call target contract in synsical order;
        // hey, don't call redeemCollateral() unless there is collateral to redeem
    }

    /////////////////////////////////////////////////////////////////////////
    /// Invariant test calls a ton of different functions on the handler. ///
    /// Parameters of these functions will be populated with randomized  ///
    /// values                                                           ///
    ////////////////////////////////////////////////////////////////////////

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // more deposits than debt
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)

        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethVlaue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethVlaue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);
        console.log("times mint called:", handler.timesMintIsCalled());

        assert(wethVlaue + wbtcValue >= totalSupply);
    }

    ////////////////////////////////////////////////////
    // The getter function shouldn't revert.         //
    // If any of the handler function cominations    //
    // breaks any of the getters, then it means the  //
    // Invariant broke                               //
    ///////////////////////////////////////////////////

    function invariant_getterShouldNotRevert() public view {
        dsce.getLiquidationBonus();
        dsce.getPrecision();
    }
}
