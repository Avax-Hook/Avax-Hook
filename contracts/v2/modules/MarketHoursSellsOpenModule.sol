// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketHoursBase} from "./MarketHoursModule.sol";

/// @title MarketHoursSellsOpenModule
/// @notice Market hours for buys only: buys are refused outside the US stock-market session, sells stay
///         open around the clock. Same calendar and config as MarketHoursModule (see MarketHoursBase); it
///         does not declare BLOCKS_SELLS, so it can never stop a sell.
contract MarketHoursSellsOpenModule is MarketHoursBase {
    constructor(address _hook) MarketHoursBase(_hook) {}

    function sellsAlwaysOpen() public pure override returns (bool) {
        return true;
    }
}
