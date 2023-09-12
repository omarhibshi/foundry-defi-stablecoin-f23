// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;
/**
 * @title OracleLib
 * @author Patick Collins (Co. Omar AlHABSHI)
 * @notice This library is used to check the Chainlink Oracle for stale data (data that is too old,i.e. price feed is not updated in 3600s)
 * If a price is stale, the function will revert, and render the DSCEngine unusable - This is by design.
 * wW want the DSCEngine to freeze if prices become stale.
 *
 * So if the Chainlink network explodes and you have a lot of money locked in the protocol...too bad.
 *
 */

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface _priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            _priceFeed.latestRoundData();
        uint256 secondsSince = block.timestamp - updatedAt; //seconds since price feed was updated
        // if secondsSince is longer than the "Heartbeat" set by the orcacle for the specific price feed then exist as the price ain't vaild no more
        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
