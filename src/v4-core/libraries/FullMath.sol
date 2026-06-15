// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 512 bit 高精度数学函数
/// @notice 在乘除中间结果可能超过 256 bit 时，仍可无精度损失地计算最终 256 bit 结果。
/// @dev 处理 "phantom overflow"：允许中间乘积溢出 256 bit，只要最终商仍能放入 uint256。
library FullMath {
    /// @notice 全精度计算 floor(a×b÷denominator)；结果溢出 uint256 或 denominator == 0 时回滚。
    /// @param a 被乘数。
    /// @param b 乘数。
    /// @param denominator 除数。
    /// @return result 256 bit 计算结果。
    /// @dev 基于 Remco Bloemen 的 MIT 许可实现：https://xn--2-umb.com/21/muldiv
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 计算 512 bit 乘积 [prod1 prod0] = a * b。
            // 分别计算乘积对 2**256 和 2**256 - 1 的模，再用中国剩余定理重建 512 bit 结果。
            // 结果保存在两个 256 bit 变量中：product = prod1 * 2**256 + prod0。
            uint256 prod0 = a * b; // 乘积的低 256 bit。
            uint256 prod1; // 乘积的高 256 bit。
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // 确保最终结果小于 2**256，同时排除 denominator == 0。
            require(denominator > prod1);

            // 乘积未超过 256 bit 时，直接执行 256/256 除法。
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            ///////////////////////////////////////////////
            // 512/256 除法。
            ///////////////////////////////////////////////

            // 从 [prod1 prod0] 中减去余数，使后续除法可以整除。
            // 使用 mulmod 计算余数。
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // 从 512 bit 数中减去一个 256 bit 数。
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // 从 denominator 中提取 2 的幂因子。
            // 计算 denominator 的最大 2 次幂因子，结果始终 >= 1。
            uint256 twos = (0 - denominator) & denominator;
            // denominator 除以该 2 次幂因子。
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // [prod1 prod0] 同样除以该 2 次幂因子。
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // 把 prod1 中的 bit 移入 prod0。为此需把 `twos` 转换为 2**256 / twos；
            // 若 twos 在 256 bit 算术中变为 0，则此计算会得到 1。
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // 计算 denominator 在模 2**256 下的乘法逆元。
            // 此时 denominator 已是奇数，因此存在 inv，使 denominator * inv = 1 mod 2**256。
            // 从低 4 bit 正确的种子开始，即 denominator * inv = 1 mod 2**4。
            uint256 inv = (3 * denominator) ^ 2;
            // 使用 Newton-Raphson 迭代提高精度。依据 Hensel lifting lemma，
            // 该方法在模算术中同样成立，每轮都会把正确 bit 数翻倍。
            inv *= 2 - denominator * inv; // 模 2**8 的逆元。
            inv *= 2 - denominator * inv; // 模 2**16 的逆元。
            inv *= 2 - denominator * inv; // 模 2**32 的逆元。
            inv *= 2 - denominator * inv; // 模 2**64 的逆元。
            inv *= 2 - denominator * inv; // 模 2**128 的逆元。
            inv *= 2 - denominator * inv; // 模 2**256 的逆元。

            // 当前除法已可整除，因此乘以 denominator 的模逆元即可完成除法，
            // 并得到模 2**256 下的正确结果。前置检查保证结果小于 2**256，
            // 所以这就是最终值，无需再计算高位，prod1 也不再需要。
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice 全精度计算 ceil(a×b÷denominator)；结果溢出 uint256 或 denominator == 0 时回滚。
    /// @dev 先计算向下取整结果；若 mulmod 表明存在余数，则结果加 1，因此舍入方向对接收方所需数量更保守。
    /// @param a 被乘数。
    /// @param b 乘数。
    /// @param denominator 除数。
    /// @return result 256 bit 计算结果。
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) != 0) {
                require(++result > 0);
            }
        }
    }
}
