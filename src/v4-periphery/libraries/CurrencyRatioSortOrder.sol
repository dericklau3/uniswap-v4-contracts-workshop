// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 货币价格比率排序优先级
/// @notice 定义 NFT 展示价格时货币应位于分子还是分母的优先级；数值越大越倾向位于分子。
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/TokenRatioSortOrder.sol
library CurrencyRatioSortOrder {
    int256 constant NUMERATOR_MOST = 300;
    int256 constant NUMERATOR_MORE = 200;
    int256 constant NUMERATOR = 100;

    int256 constant DENOMINATOR_MOST = -300;
    int256 constant DENOMINATOR_MORE = -200;
    int256 constant DENOMINATOR = -100;
}
