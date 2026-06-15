// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 流动性数学库
library LiquidityMath {
    /// @notice 将有符号流动性变化量加到当前流动性，发生上溢或下溢时回滚。
    /// @param x 修改前的流动性。
    /// @param y 流动性变化量；正数增加，负数减少。
    /// @return z 修改后的流动性。
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        assembly ("memory-safe") {
            z := add(and(x, 0xffffffffffffffffffffffffffffffff), signextend(15, y))
            if shr(128, z) {
                // 回滚 SafeCastOverflow()。
                mstore(0, 0x93dafdf1)
                revert(0x1c, 0x04)
            }
        }
    }
}
