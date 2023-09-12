// SPDX-License-Identifier: MITj
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    DSCEngine public dscE;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;
    DeployDSC public deployer;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    uint256 amountToMint = 100 ether;
    address public USER = address(1);

    //address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether; //
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    // 1.0 health factor
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether; // 1000 DSC
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // 50% liquidation threshold
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_PRECISION = 100; // 0.1
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    // Lists
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscE, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(USER, 30 ether);
        }
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE); // here USER is gaven a balance of ERC20Mock(weth)
        // in subsequent tests, USER will have to grant the Engine contract some allowance from its ERC20Mock(weth) tokens
        // Engine contract can then use that allowance to put down as collateral some amount of ERC20Mock(weth) tokens on behalf of USER
        // USER will then be able to mint some DSC tokens becaus it has some collateral in DSC token contract
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    function testWahtever() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        mockDsc.mint(USER, AMOUNT_COLLATERAL);
        // (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        console.log("AMOUNT_COLLATERAL              ", AMOUNT_COLLATERAL);
        console.log("MIN_HEALTH_FACTOR              ", MIN_HEALTH_FACTOR);
        console.log("STARTING_ERC20_BALANCE         ", STARTING_ERC20_BALANCE);
        console.log("LIQUIDATION_THRESHOLD          ", LIQUIDATION_THRESHOLD);
        console.log("amountToMint                   ", amountToMint);
        console.log("collateralToCover              ", collateralToCover);
        console.log("USER.balance                   ", USER.balance);
        console.log("ERC20Mock(weth).balanceOf(USER)", ERC20Mock(weth).balanceOf(USER));
    }
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    /////////////////////////
    /// Constructor Tests   //
    //////////////////////////

    function testRevertsTokenLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddresses_And_PriceFeedAddresses_MustBe_Same_Length.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses,address(dsc));
    }

    /////////////////////
    /// Price Tests   //
    /////////////////////

    function testgetTokenAmountFromUsd() public {
        uint256 usdAmount = 100e18; //  100 USD
        // 30000 USD / 2000 USD/ETH = 15 ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualweth = dscE.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualweth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15 ETH
        // 15 ETH * 2000 USD/ETH = 30000 USD
        uint256 expectedEthUsdValue = 30000e18;
        uint256 ethUsdValue = dscE.getUsdValue(weth, ethAmount);
        assertEq(ethUsdValue, expectedEthUsdValue);
    }

    /////////////////////////////////
    /// depositeCollateral Tests   //
    /////////////////////////////////

    //this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__Transfer_Failed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__Need_MoreThan_zero.selector);
        dscE.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfCollateralNotApproved() public {
        ERC20Mock ranToken = new ERC20Mock("RAN","RAN",USER,AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__Not_Allowed_Token.selector);
        dscE.depositCollateral(address(ranToken), 100);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        // Remember we did this in SsetUp(): ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE); // it means that USER has 10 weth
        // next USER has to grant the Engine contract some allowance from its ERC20Mock(weth) tokens

        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositeCollateralAndGetAccountInformation() public depositedCollateral {
        (uint256 totalDscMinted, uint256 CollateralValueInUsd) = dscE.getAccountInformation(USER);

        uint256 expectedCollateralAmount = dscE.getTokenAmountFromUsd(weth, CollateralValueInUsd);
        uint256 expectedTotalDscMinted = 0;

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedCollateralAmount);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscE.getAdditionalFeedPrecision())) / dscE.getPrecision();
        vm.startPrank(USER); //in wei
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscE.calculateHealthFactor(amountToMint, dscE.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__Breaks_Health_Factor.selector, expectedHealthFactor)
        );
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__Mint_Failed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__Need_MoreThan_zero.selector);
        dscE.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscE.getAdditionalFeedPrecision())) / dscE.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dscE.calculateHealthFactor(amountToMint, dscE.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__Breaks_Health_Factor.selector, expectedHealthFactor)
        );
        dscE.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dscE.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////
    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__Need_MoreThan_zero.selector);
        dscE.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscE.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscE), amountToMint);
        dscE.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__Transfer_Failed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__Need_MoreThan_zero.selector);
        dscE.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dscE.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscE));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscE.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscE), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__Need_MoreThan_zero.selector);
        dscE.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dscE), amountToMint);
        dscE.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscE.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $150 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscE.getHealthFactor(USER);
        // $180 collateral / 200 debt = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__Health_Factor_Not_Improved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscE), collateralToCover);
        dscE.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscE), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__Health_Factor_OK.selector);
        dscE.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        //********************************************************************************************* */
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscE.getAccountInformation(USER);
        uint256 userCollateralValueInUsd = totalCollateralValueInUsd;
        uint256 userHealthFactor = dscE.getHealthFactor(USER);
        console.log("Prior to collateral token price crash ");
        console.log("----------------------------------------------------");
        console.log("USER DSC balance                   ", ERC20Mock(address(dsc)).balanceOf(USER));
        console.log("USER weth balance                  ", ERC20Mock(weth).balanceOf(USER));
        console.log("USER's TotalDscMinted              ", totalDscMinted);
        console.log("USER's TotalCollateralValueInUsd   ", totalCollateralValueInUsd);
        console.log("MIN_HEALTH_FACTOR                  ", MIN_HEALTH_FACTOR);
        console.log("USER's HealtheFactor               ", userHealthFactor);
        console.log("");
        //********************************************************************************************* */

        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice); // crash the price

        //********************************************************************************************* */
        (totalDscMinted, totalCollateralValueInUsd) = dscE.getAccountInformation(USER);
        userCollateralValueInUsd = totalCollateralValueInUsd;
        userHealthFactor = dscE.getHealthFactor(USER);
        uint256 userCollateralValueInUsdAftercrash = totalCollateralValueInUsd;
        console.log("Post collateral token price crash ");
        console.log("-----------------------------------------------");
        console.log("USER DSC balance                   ", ERC20Mock(address(dsc)).balanceOf(USER));
        console.log("USER weth balance                  ", ERC20Mock(weth).balanceOf(USER));
        console.log("USER's TotalDscMinted              ", totalDscMinted);
        console.log("USER's TotalCollateralValueInUsd   ", totalCollateralValueInUsd);
        console.log("MIN_HEALTH_FACTOR                  ", MIN_HEALTH_FACTOR);
        console.log("USER's HealtheFactor               ", userHealthFactor);
        console.log("");
        //********************************************************************************************* */
        console.log("----------------------------------------------------");
        console.log("liquidator enters, deposits collateral and mints DSC");
        console.log("----------------------------------------------------");
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        console.log("liquidator's weth initial balance  ", ERC20Mock(weth).balanceOf(liquidator));
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscE), collateralToCover);
        dscE.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        console.log("");
        console.log("Pre Liquidation");
        console.log("----------------------------------------------------");
        console.log("LIQUIDATOR DSC balance                   ", ERC20Mock(address(dsc)).balanceOf(liquidator));
        console.log("liquidator's weth balance                ", ERC20Mock(weth).balanceOf(liquidator));
        (totalDscMinted, totalCollateralValueInUsd) = dscE.getAccountInformation(liquidator);
        console.log("liquidator's TotalDscMinted              ", totalDscMinted);
        console.log("liquidator's TotalCollateralValueInUsd   ", totalCollateralValueInUsd);
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        console.log("priceFeed after price crash              ", uint256(price));
        uint256 collateralEqualDebtCovered = dscE.getTokenAmountFromUsd(address(weth), amountToMint);
        console.log("Debt 100e18 DSC = ?? weth                ", collateralEqualDebtCovered);
        uint256 bounsCollateral = (collateralEqualDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = collateralEqualDebtCovered + bounsCollateral;
        console.log("Total Collateral To Redeem               ", totalCollateralToRedeem);
        console.log(
            "USER remaining collatreral               ",
            userCollateralValueInUsdAftercrash - (userCollateralValueInUsdAftercrash - totalCollateralToRedeem) // ?????
        );

        dsc.approve(address(dscE), amountToMint);
        dscE.liquidate(weth, USER, amountToMint); // 100e18 DSC = ?? weth
        vm.stopPrank();

        //********************************************************************************************* */
        (totalDscMinted, totalCollateralValueInUsd) = dscE.getAccountInformation(USER);
        userCollateralValueInUsd = totalCollateralValueInUsd;
        userHealthFactor = dscE.getHealthFactor(USER);
        console.log("");

        console.log("Post liquidation ");
        console.log("-----------------------------------------------");
        console.log("USER .....");
        console.log("USER DSC balance                   ", ERC20Mock(address(dsc)).balanceOf(USER));
        console.log("USER weth balance                  ", ERC20Mock(weth).balanceOf(USER));
        console.log("USER's TotalDscMinted              ", totalDscMinted);
        console.log("USER's TotalCollateralValueInUsd   ", totalCollateralValueInUsd);
        console.log("MIN_HEALTH_FACTOR                  ", MIN_HEALTH_FACTOR);
        console.log("USER's HealtheFactor               ", userHealthFactor);
        console.log("");
        (totalDscMinted, totalCollateralValueInUsd) = dscE.getAccountInformation(liquidator);
        userCollateralValueInUsd = totalCollateralValueInUsd;
        userHealthFactor = dscE.getHealthFactor(liquidator);
        console.log("LIQUIDATOR .....");
        console.log("LIQUIDATOR DSC balance                   ", ERC20Mock(address(dsc)).balanceOf(liquidator));
        console.log("LIQUIDATOR weth balance                  ", ERC20Mock(weth).balanceOf(liquidator));
        console.log("LIQUIDATOR's TotalDscMinted              ", totalDscMinted);
        console.log("LIQUIDATOR's TotalCollateralValueInUsd   ", totalCollateralValueInUsd);
        console.log("MIN_HEALTH_FACTOR                        ", MIN_HEALTH_FACTOR);
        console.log("LIQUIDATOR's HealtheFactor               ", userHealthFactor);
        console.log("");
        //********************************************************************************************* */

        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        vm.startPrank(USER);
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = dscE.getAccountInformation(USER);
        uint256 userHealthFactor = dscE.getHealthFactor(USER);
        vm.stopPrank();
        console.log("");
        console.log("After liquidation  ");
        console.log("-----------------------------------------------");
        console.log("USER weth balance                        ", ERC20Mock(weth).balanceOf(USER));
        console.log("USER's TotalDscMinted                    ", totalDscMinted);
        console.log("USER's TotalCollateralValueInUsd         ", totalCollateralValueInUsd);
        console.log("MIN_HEALTH_FACTOR                        ", MIN_HEALTH_FACTOR);
        console.log("USER's HealtheFactor                     ", userHealthFactor);

        vm.startPrank(liquidator);
        userHealthFactor = dscE.getHealthFactor(liquidator);
        vm.stopPrank();

        console.log("");

        console.log("-----------------------------------------------");
        console.log("liquidator's weth balance                ", ERC20Mock(weth).balanceOf(liquidator));
        console.log("MIN_HEALTH_FACTOR                        ", MIN_HEALTH_FACTOR);
        console.log("USER's HealtheFactor                     ", userHealthFactor);

        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscE.getTokenAmountFromUsd(weth, amountToMint)
            + (dscE.getTokenAmountFromUsd(weth, amountToMint) / dscE.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscE.getTokenAmountFromUsd(weth, amountToMint)
            + (dscE.getTokenAmountFromUsd(weth, amountToMint) / dscE.getLiquidationBonus());

        uint256 usdAmountLiquidated = dscE.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dscE.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscE.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscE.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscE.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscE.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dscE.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dscE.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dscE.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscE.getAccountInformation(USER);
        uint256 expectedCollateralValue = dscE.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralBalance = dscE.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscE), AMOUNT_COLLATERAL);
        dscE.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dscE.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dscE.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dscE.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dsce));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
