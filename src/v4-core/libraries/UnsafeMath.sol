// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 不检查输入与输出边界的数学函数
/// @notice 提供常用数学运算，但不执行溢出、下溢等安全检查；调用方必须自行保证前置条件。
library UnsafeMath {
    /// @notice 返回 ceil(x / y)，即向上取整的商。
    /// @dev 除以 0 会返回 0，调用方必须在外部检查除数。
    /// @param x 被除数。
    /// @param y 除数。
    /// @return z 向上取整后的商 ceil(x / y)。
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly ("memory-safe") {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }

    /// @notice 计算 floor(a×b÷denominator)。
    /// @dev 除以 0 会返回 0，调用方必须在外部检查除数；乘法也不检查 256 bit 溢出。
    /// @param a 被乘数。
    /// @param b 乘数。
    /// @param denominator 除数。
    /// @return result 256 bit 结果 floor(a×b÷denominator)。
    function simpleMulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        assembly ("memory-safe") {
            result := div(mul(a, b), denominator)
        }
    }
}
