// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title FixedPoint96
/// @notice 处理二进制定点数的常量库，参见 https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev 在 SqrtPriceMath.sol 中使用；Q96 为价格计算保留 96 bit 小数精度。
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}
