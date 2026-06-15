// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title FixedPoint128
/// @notice 处理二进制定点数的常量库，参见 https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Q128 用于把累计手续费增长表示为“每单位流动性的手续费”，保留 128 bit 小数精度。
library FixedPoint128 {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}
