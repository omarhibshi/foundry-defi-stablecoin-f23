// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

pragma solidity ^0.8.18;

/**
 * @title Decentralized Stable Coin
 * @author Patrick Collins (Co. author Omar ALHABSHI)
 *  *
 * Collateral: Exogenous (ETH & BTC)    =====> DSCEngine
 * Miniting: Algorithmic    =====> DSCEngine
 * Relative Stability: Anchored (pegged) to USD =====> DSCEngine
 *
 * @dev This is the stable coin's main contract file
 * This is the contract meant to be governed by the DSCEngine.
 * This contract is just the ERC20 implementation of our stablecoin system (protocol)
 * The actual logic of the stablecoin system is in the DSCEngine contract, this contract will have the miniting and burtning functions
 *
 *
 */

// // // // // //
//  imports  //
// // // // // //

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // // // // // //
    //  errors     //
    // // // // // //

    error DecentralizedStableCoin__Amount_MustBe_MoreThan_Zero();
    error DecentralizedStableCoin__Burn_Amount_Exceeeds_Balance();
    error DecentralizedStableCoin__Mint_Must_NotBe_Zero_Address();

    constructor() ERC20("Decenttralized Stable Coin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralizedStableCoin__Amount_MustBe_MoreThan_Zero();
        }
        if (_amount > balance) {
            revert DecentralizedStableCoin__Burn_Amount_Exceeeds_Balance();
        }

        super.burn(_amount); // call the burn function from the ERC20Burnable contract (super class)
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__Mint_Must_NotBe_Zero_Address();
        }

        if (_amount <= 0) {
            revert DecentralizedStableCoin__Amount_MustBe_MoreThan_Zero();
        }
        _mint(_to, _amount);
        return true;
    }
}
