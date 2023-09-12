// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
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

pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author Patrick Collins (Co. author Omar ALHABSHI)
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 *
 * This stablecoin has the following properties:
 * - Exogenos Collateral
 * - Dollar Pegged
 * - Algoritmicallly stable
 *
 * It is similar to DAI if DAI had no governance, no fee and was only backed by WETH and WBTC.
 *
 * @notice Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minitng and redeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

// // // // //
// Imports  //
// // // // //
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

// // // // // // // // // // // // //
// interfaces, libraries, contracts //
// // // // // // // // // // // // //

contract DSCEngine is ReentrancyGuard {
    // // // // // //
    //  Errors     //
    // // // // // //

    error DSCEngine__Need_MoreThan_zero();
    error DSCEngine__TokenAddresses_And_PriceFeedAddresses_MustBe_Same_Length();
    error DSCEngine__Not_Allowed_Token();
    error DSCEngine__Transfer_Failed();
    error DSCEngine__Breaks_Health_Factor(uint256 healthFactor);
    error DSCEngine__Mint_Failed();
    error DSCEngine__Health_Factor_OK();
    error DSCEngine__Health_Factor_Not_Improved();

    // // // // // // // //
    //  Types            //
    // // // // // // // //

    using OracleLib for AggregatorV3Interface;

    // // // // // // // //
    //  State variables  //
    // // // // // // // //
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // 1e8;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; // 0.1
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus
    // Depoiste:
    // 200% <-> 110%  the system is safe
    // 50% this violates the collateral to debt ratio, thus breaks our entire system

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userTokenBalances
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // userDSCBalances
    address[] private s_collateralTokens; // tokensAllowed
    //
    DecentralizedStableCoin private immutable i_dsc;

    // // // // //
    //  Events  //
    // // // // //

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address token, uint256 amount);

    // // // // // //
    //  Modifiers  //
    // // // // // //
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DSCEngine__Need_MoreThan_zero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeeds[_tokenAddress] == address(0)) {
            revert DSCEngine__Not_Allowed_Token();
        }
        _;
    }

    // // // // // //
    //  Functions  //
    // // // // // //
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        // USD is our Price Feed, Ex. ETH/USD, BTC/USD, MKR/USD
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddresses_And_PriceFeedAddresses_MustBe_Same_Length();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            // populate the mapping with real token addresses and their corresponding price feed addresses
            // A token is allowed if it has a price feed address associated with it
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    // // // // // // // // //
    //  External Functions  //
    // // // // // // // // //

    /**
     * @param _tokenCollateralAddress the address of the token to deposit as collateral
     * @param _amountCollateral the amount of the token to deposit as collateral
     * @param _amountDscToMint  the amount of DSC to mint
     * @notice this function will deposite your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    } // I want to deposit their DAI or wBTC to mint DSC

    /**
     * @notice follow CEI pattern (check, effects, interactions)
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of the token to deposit as collateral
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool successs = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);

        if (!successs) {
            revert DSCEngine__Transfer_Failed();
        }
    }

    /**
     * @notice Once done with DSC, I want to redeem my DAI or wBTC (and burn DSC )
     * @param _tokenCollateralAddress  The address of the token to redeem
     * @param _amountCollateral The amount of the token to redeem
     * @param _amountDscToBurn The amount of DSC to burn
     */
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn); // Once done with DSC, I want to redeem my DAI or wBTC (and burn DSC )
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // redeemColateral() already have health factor check, it will revert if health factor is broken
    }

    /**
     * @notice I want to redeem my DAI or wBTC (no DSC was minted yet)
     * @notice follow CEI pattern (check, effects, interactions)
     * @param _tokenCollateralAddress The address of the token to redeem
     * @param _amountCollateral The amount of the token to redeem
     * @notice DRY: DON'T REPEATE YOURESEFL
     */
    // in order to redeem collateral,
    // 1. Health factor must be over 1 after collateral pulled
    // dry: DON'T REPEATE YOURESEFL
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZero(_amountCollateral)
        nonReentrant
    {
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
        bool successs = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);
        if (!successs) {
            revert DSCEngine__Transfer_Failed();
        }
    }
    /**
     * @notice follow CEI pattern (check, effects, interactions)
     * @param _amountDscToMint The amount of DSC to mint
     * @notice they must have more colletaral value than the amount of DSC they want to mint
     */

    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__Mint_Failed();
        }
    } // I want to mint DSC with my deposited DAI or wBTC

    /**
     * @notice I want to burn my DSC to maintain a balanced collateralization
     * @notice follow CEI pattern (check, effects, interactions)
     * @param _amountDscToBurn  The amount of DSC to burn
     */
    function burnDsc(uint256 _amountDscToBurn) public moreThanZero(_amountDscToBurn) {
        _burnDsc(_amountDscToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This might neve be hit ...
    }

    //Example of why we need to liquidate
    // $100 ETH Collateral baking $50 DSC minted
    // ETH tanks to $20 ETH <=> $20 ETH Collateral baking $50 DSC minted (DSC is now not worth $1)
    // no one will pay $50 to close the DSC position to get £20 worh of ETH

    // What do we do? To help incentivise the user, the system has to be overcollateralized.
    // so, as the price is going,
    // at $75 backing £50 DSC
    // liquiditor takes $75 backing and burns off the $50 DSC
    // if someone is almost undercollateralized, we will pay to liquidate them
    /**
     *
     * @notice follow CEI pattern (check, effects, interactions)
     *
     * @param _tokenCollateralAddress The erc20 collateral to liquidate them!
     * @param _user The user who has broken the health factor, Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param _debtToCover The amount of DSC to burn to improve the user health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less overcollateralized, then we wouldn't be able to incentivise liquidators
     * for example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address _tokenCollateralAddress, address _user, uint256 _debtToCover)
        external
        moreThanZero(_debtToCover)
        nonReentrant
    {
        // need to the the user health factor (is he liquidatable?)
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__Health_Factor_OK();
        }
        // we want to burn their DSC "debt"
        // And take their collateral (remove them from the system basiclly ... )
        // Bad user: $140 ETH, $100 DSC
        // _debtToCover = $100 DSC
        // The question is: $100 DSC = ??? ETH (tokenCollateralAmountEqualDebtCovered)
        // 0.05 ETH is the price of $100 DSC in ETH
        uint256 tokenCollateralAmountEqualDebtCovered = getTokenAmountFromUsd(_tokenCollateralAddress, _debtToCover);
        // And give them a 10% bonusr
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts onto a treasury

        // 0.05 * 0.1 = 0.005 getting 0.055 ETH (10% bonus)
        uint256 bounsCollateral = (tokenCollateralAmountEqualDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // below is the amount to redeem for whoever call the liquidate function
        uint256 totalCollateralToRedeem = tokenCollateralAmountEqualDebtCovered + bounsCollateral;
        _redeemCollateral(_tokenCollateralAddress, totalCollateralToRedeem, _user, msg.sender);
        _burnDsc(_debtToCover, _user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__Health_Factor_Not_Improved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Threshold to let's say 150%
    // $100 ETH Collateral --> $75
    //
    // Person 1 borrows $50 DSC (= 50 * 150% = $75 ETH that's how much collateral he needs to have)
    // ETH price drops ==> collateral = $50 & borrowed DSC = $50 (collateralization ratio = 100%)
    //
    // Person 2  pays $50 DSC and gets the $50 ETH collateral
    // Person 1 : DSC debt = 0 & collateral = $0

    // // // // // // // // // // // //
    // Private & Internal Functions  //
    // // // // // // // // // // // //

    /**
     *
     * @dev low level internal function , do not call unless the function calling it is
     * checking for health factors being broken
     */

    // The caller "_dscFrom" of this burnDsc() will have to fork out the amount of DSC burned from his bag, in rteun he will get rewarded with the collateral
    // The _onBehalfOf who is liquidated will have the DSC deducted from his bag,
    // USER gets to keep his DSC but he wont have the loan anymore (neithe some or all of his collateral)

    // To simplify Liquidation:
    // 1. USER enters with collateral and DSC
    // 2. Liquidator enters with DSC (just about enough to cover the ammount USER owns), he may also have some collateral (but thats not important here)
    // 3. USER gets liquidated, his DSC remains intact and his collateral is taken
    // 4. Liquidator gets the collateral (taken from USER) and his DSC is burned (taken from his bag)
    function _burnDsc(uint256 _amountDscToBurn, address _onBehalfOf, address _dscFrom) private {
        s_DSCMinted[_onBehalfOf] -= _amountDscToBurn;
        // instead of sending the DSCs to a burn address, below DSCEngine takes those DSCs from user ( msg.sender).
        // then  DSCEngine calls the function _burn(_msgSender(), amount) of parent class of "DecentralizedStableCoin" to burn the DSCs once and for all.
        bool success = i_dsc.transferFrom(_dscFrom, address(this), _amountDscToBurn);
        if (!success) {
            revert DSCEngine__Transfer_Failed();
        }
        i_dsc.burn(_amountDscToBurn);
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 _totalDscMinted, uint256 _totalCollateralValueInUsd)
    {
        _totalDscMinted = s_DSCMinted[_user];
        _totalCollateralValueInUsd = getAccountCollateralValue(_user);
    }

    // 1. Chack health factor (do they have enouhg collateral to mint DSC)
    // 2. If not, revert

    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__Breaks_Health_Factor(userHealthFactor);
        }
    }

    /**
     * Returns how close to liquidation the user is
     * If a user hoes below 1, then thay can get liquidated
     */

    function _healthFactor(address _user) private view returns (uint256) {
        // we need
        // 1. the value of all collateral
        // 2. the value of all DSC
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max; // This was added to avoid devision by zero when the user has no DSC minted
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // // // // // // // //  // // // / // // //
    // Public & External view functions // // //
    // // // // // // // // // // // / // // //

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address _tokenCollateral, uint256 _usdAmountInWei) public view returns (uint256) {
        // What we need:
        // price of ETH (token)
        // $/ETH ETH ??
        // exapmle: price $2000/ETH and we have $1000 => we have 0.5 ETH (1000/2000)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_tokenCollateral]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (_usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    //  Return the value of all collateral
    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFees = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFees.staleCheckLatestRoundData();
        // 1ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * _amount) / PRECISION;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountInformation(address _user)
        external
        view
        returns (uint256 _totalDscMinted, uint256 _totalCollateralValueInUsd)
    {
        (_totalDscMinted, _totalCollateralValueInUsd) = _getAccountInformation(_user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
