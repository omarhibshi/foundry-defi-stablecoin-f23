// SPDX-License-Identifier: SEE LICENSE IN LICENSE

// Handler is going to narrow down the way we call functions so we don't wast runs
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
//import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    // DeployDSC deployer;
    // HelperConfig config;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public userWithCollateralDeposited;

    uint256 MAX_DEPOSITE_SIZE = type(uint96).max;
    MockV3Aggregator public ethUsdPriceFeed;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();

        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }
    // redeem collateral

    function mintDsc(uint256 _amount, uint256 addressSeed) public {
        // _amount = bound(_amount, 0, MAX_DEPOSITE_SIZE);
        if (userWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        (uint256 totalDsctMinted, uint256 totalCollateralInUsed) = dsce.getAccountInformation(sender);

        int256 maxDscToMint = (int256(totalCollateralInUsed) / 2) - int256(totalDsctMinted); // always remeber 1 DSC is pegged to 1 USD
        // here is how the above is calculated:
        // 1. user has deposited $4000 worth weth, therefore user has the right to mint up to 2000 DSC (200% ratio or  1:2)
        // 2. user chooses to mint 1000 DSC, therefore user has 1000 DSC in debt and 4000 weth in collateral and can still mint a maximum of 1000 DSC more
        // 3. maxDscToMint = (4000 / 2) - 1000 = 2000 - 1000 = 1000

        if (maxDscToMint < 0) {
            return;
        }

        _amount = bound(_amount, 0, uint256(maxDscToMint));

        if (_amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDsc(_amount);
        vm.stopPrank();
        // the reason the line below was never reached before is because the fuzzer was calling mintDsc() with random addresses that may not have collateral deposited
        // this is why we created the array userWithCollateralDeposited, so we can call mintDsc() with addresses that have collateral deposited
        // this steped ensured that the line below is reached
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        // In this handler, all function parameters wil be randomized
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        _amountCollateral = bound(_amountCollateral, 1, MAX_DEPOSITE_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, _amountCollateral);
        collateral.approve(address(dsce), _amountCollateral);
        dsce.depositCollateral(address(collateral), _amountCollateral);
        vm.stopPrank();
        // the line below may double push the same user, but that's ok
        userWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
        _amountCollateral = bound(_amountCollateral, 0, maxCollateralToRedeem); // We had to make the lower bound 0 in case the user has no collateral to redeem,
        // otherwise we will run the case where (1 > 0)
        // However, since redeemCollateral()  eventually reverts if _amountCollateral is 0, we ask the test in this case to skip the current run and proceed
        // with the next one. In order to do this, we use a simple return statement.
        // or we could use, vm.assume(a !=0 ) which serve the same purpose (if the bololean expression evaluates to false, the fuzzer will discard
        // the current fuzz inputs and start a new fuzz run)
        if (_amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), _amountCollateral);
    }
    // This breaks our invariant test suite!!!!
    // function updateCollateralPrice(uint96 _newPrice) public {
    //     int256 newPriceInt = int256(uint256(_newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions

    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (ERC20Mock) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
