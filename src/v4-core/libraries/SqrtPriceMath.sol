// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {SafeCast} from "./SafeCast.sol";

import {FullMath} from "./FullMath.sol";
import {UnsafeMath} from "./UnsafeMath.sol";
import {FixedPoint96} from "./FixedPoint96.sol";

/// @title 基于 Q64.96 平方根价格与流动性的数学函数
/// @notice 使用 Q64.96 形式的平方根价格和流动性，计算兑换后的新价格以及 currency0/currency1 数量差额。
library SqrtPriceMath {
    using SafeCast for uint256;

    error InvalidPriceOrLiquidity();
    error InvalidPrice();
    error NotEnoughLiquidity();
    error PriceOverflow();

    /// @notice 根据 currency0 的变化量计算下一平方根价格。
    /// @dev 始终向上取整。exact output 且价格上升时，价格必须至少移动到足以给出目标输出；
    ///      exact input 且价格下降时，则应让价格少移动一点，避免池多发送输出。
    ///      最精确公式为 liquidity * sqrtPX96 / (liquidity +- amount * sqrtPX96)；
    ///      若中间乘积溢出，则改算 liquidity / (liquidity / sqrtPX96 +- amount)。
    /// @param sqrtPX96 起始价格，即计入 currency0 变化前的价格。
    /// @param liquidity 当前可用流动性。
    /// @param amount 要加入或移出虚拟储备的 currency0 数量。
    /// @param add true 表示加入 currency0，false 表示移除。
    /// @return 根据 add 加入或移除 amount 后的价格。
    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // amount == 0 时直接返回；否则通用公式因舍入不保证结果严格等于输入价格。
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            unchecked {
                uint256 product = amount * sqrtPX96;
                if (product / amount == sqrtPX96) {
                    uint256 denominator = numerator1 + product;
                    if (denominator >= numerator1) {
                        // 结果始终可放入 160 bit。
                        return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                    }
                }
            }
            // 上述路径已检查 denominator 加法溢出；失败时使用代数等价的备用公式。
            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        } else {
            unchecked {
                uint256 product = amount * sqrtPX96;
                // product 溢出时 denominator 必然下溢；此外还必须直接检查 denominator 不会下溢。
                // 等价于：if (product / amount != sqrtPX96 || numerator1 <= product) revert PriceOverflow();
                assembly ("memory-safe") {
                    if iszero(
                        and(
                            eq(div(product, amount), and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                            gt(numerator1, product)
                        )
                    ) {
                        mstore(0, 0xf5c787f1) // PriceOverflow() 的 selector。
                        revert(0x1c, 0x04)
                    }
                }
                uint256 denominator = numerator1 - product;
                return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
            }
        }
    }

    /// @notice 根据 currency1 的变化量计算下一平方根价格。
    /// @dev 始终向下取整。exact output 且价格下降时，价格必须至少移动到足以给出目标输出；
    ///      exact input 且价格上升时，则应让价格少移动一点，避免池多发送输出。
    ///      本公式与无损版本 sqrtPX96 +- amount / liquidity 的误差小于 1 wei。
    /// @param sqrtPX96 起始价格，即计入 currency1 变化前的价格。
    /// @param liquidity 当前可用流动性。
    /// @param amount 要加入或移出虚拟储备的 currency1 数量。
    /// @param add true 表示加入 currency1，false 表示移除。
    /// @return 加入或移除 `amount` 后的价格。
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // 加入时要让最终值向下取整，商也向下取整；移除时减去的商需向上取整。
        // 两种情况下都尽量对常见输入避免使用 mulDiv。
        if (add) {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? (amount << FixedPoint96.RESOLUTION) / liquidity
                    : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity)
            );

            return (uint256(sqrtPX96) + quotient).toUint160();
        } else {
            uint256 quotient = (
                amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity)
            );

            // 等价于：if (sqrtPX96 <= quotient) revert NotEnoughLiquidity();
            assembly ("memory-safe") {
                if iszero(gt(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff), quotient)) {
                    mstore(0, 0x4323a555) // NotEnoughLiquidity() 的 selector。
                    revert(0x1c, 0x04)
                }
            }
            // 结果始终可放入 160 bit。
            unchecked {
                return uint160(sqrtPX96 - quotient);
            }
        }
    }

    /// @notice 根据输入的 currency0 或 currency1 数量计算下一平方根价格。
    /// @dev 价格或流动性为 0、或下一价格越界时回滚。
    /// @param sqrtPX96 计入输入前的起始价格。
    /// @param liquidity 当前可用流动性。
    /// @param amountIn 本次投入的 currency0 或 currency1 数量。
    /// @param zeroForOne true 表示输入 currency0，false 表示输入 currency1。
    /// @return uint160 把输入加入相应虚拟储备后的价格。
    function getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        // 等价于：if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // InvalidPriceOrLiquidity() 的 selector。
                revert(0x1c, 0x04)
            }
        }

        // 按保护池的方向舍入，确保不会越过目标价格。
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice 根据输出的 currency0 或 currency1 数量计算下一平方根价格。
    /// @dev 价格或流动性为 0、或下一价格越界时回滚。
    /// @param sqrtPX96 扣除输出前的起始价格。
    /// @param liquidity 当前可用流动性。
    /// @param amountOut 本次从虚拟储备中取出的 currency0 或 currency1 数量。
    /// @param zeroForOne true 表示输出 currency1，false 表示输出 currency0。
    /// @return uint160 移除相应输出数量后的价格。
    function getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint160)
    {
        // 等价于：if (sqrtPX96 == 0 || liquidity == 0) revert InvalidPriceOrLiquidity();
        assembly ("memory-safe") {
            if or(
                iszero(and(sqrtPX96, 0xffffffffffffffffffffffffffffffffffffffff)),
                iszero(and(liquidity, 0xffffffffffffffffffffffffffffffff))
            ) {
                mstore(0, 0x4f2461b8) // InvalidPriceOrLiquidity() 的 selector。
                revert(0x1c, 0x04)
            }
        }

        // 按保护池的方向舍入，确保价格至少移动到可提供目标输出的位置。
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice 计算两个价格之间的 amount0 差额。
    /// @dev 计算 liquidity / sqrt(lower) - liquidity / sqrt(upper)，即
    ///      liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))。
    /// @param sqrtPriceAX96 一个平方根价格。
    /// @param sqrtPriceBX96 另一个平方根价格。
    /// @param liquidity 当前可用流动性。
    /// @param roundUp 是否向上取整。
    /// @return uint256 在两个价格之间覆盖指定 liquidity 仓位所需的 currency0 数量。
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

            // 等价于：if (sqrtPriceAX96 == 0) revert InvalidPrice();
            assembly ("memory-safe") {
                if iszero(and(sqrtPriceAX96, 0xffffffffffffffffffffffffffffffffffffffff)) {
                    mstore(0, 0x00bfc921) // InvalidPrice() 的 selector。
                    revert(0x1c, 0x04)
                }
            }

            uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
            uint256 numerator2 = sqrtPriceBX96 - sqrtPriceAX96;

            return roundUp
                ? UnsafeMath.divRoundingUp(FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtPriceBX96), sqrtPriceAX96)
                : FullMath.mulDiv(numerator1, numerator2, sqrtPriceBX96) / sqrtPriceAX96;
        }
    }

    /// @notice 返回 a 与 b 的绝对差，等价于 `a >= b ? a - b : b - a`。
    function absDiff(uint160 a, uint160 b) internal pure returns (uint256 res) {
        assembly ("memory-safe") {
            let diff :=
                sub(and(a, 0xffffffffffffffffffffffffffffffffffffffff), and(b, 0xffffffffffffffffffffffffffffffffffffffff))
            // a >= b 时 mask = 0，否则 mask = -1（全部 bit 为 1）。
            let mask := sar(255, diff)
            // a >= b 时，res = a - b = 0 ^ (a - b)。
            // a < b 时，res = b - a = ~~(b - a) = ~(-(b - a) - 1) = ~(a - b - 1) = (-1) ^ (a - b - 1)。
            // 两种情况都可统一为 res = mask ^ (a - b + mask)。
            res := xor(mask, add(mask, diff))
        }
    }

    /// @notice 计算两个价格之间的 amount1 差额。
    /// @dev 计算 liquidity * (sqrt(upper) - sqrt(lower))。
    /// @param sqrtPriceAX96 一个平方根价格。
    /// @param sqrtPriceBX96 另一个平方根价格。
    /// @param liquidity 当前可用流动性。
    /// @param roundUp 是否向上取整。
    /// @return amount1 在两个价格之间覆盖指定 liquidity 仓位所需的 currency1 数量。
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity, bool roundUp)
        internal
        pure
        returns (uint256 amount1)
    {
        uint256 numerator = absDiff(sqrtPriceAX96, sqrtPriceBX96);
        uint256 denominator = FixedPoint96.Q96;
        uint256 _liquidity = uint256(liquidity);

        /**
         * 等价于：
         *   amount1 = roundUp
         *       ? FullMath.mulDivRoundingUp(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96)
         *       : FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
         * 不会溢出，因为 `type(uint128).max * type(uint160).max >> 96 < (1 << 192)`。
         */
        amount1 = FullMath.mulDiv(_liquidity, numerator, denominator);
        assembly ("memory-safe") {
            amount1 := add(amount1, and(gt(mulmod(_liquidity, numerator, denominator), 0), roundUp))
        }
    }

    /// @notice 计算带符号的 currency0 差额。
    /// @dev 增加流动性时返回负数，表示调用方需要向池支付；移除流动性时返回正数，表示池向调用方支付。
    /// @param sqrtPriceAX96 一个平方根价格。
    /// @param sqrtPriceBX96 另一个平方根价格。
    /// @param liquidity 用于计算 amount0 的流动性变化量。
    /// @return int256 两个价格之间该 liquidityDelta 对应的 currency0 差额。
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }

    /// @notice 计算带符号的 currency1 差额。
    /// @dev 增加流动性时返回负数，表示调用方需要向池支付；移除流动性时返回正数，表示池向调用方支付。
    /// @param sqrtPriceAX96 一个平方根价格。
    /// @param sqrtPriceBX96 另一个平方根价格。
    /// @param liquidity 用于计算 amount1 的流动性变化量。
    /// @return int256 两个价格之间该 liquidityDelta 对应的 currency1 差额。
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, int128 liquidity)
        internal
        pure
        returns (int256)
    {
        unchecked {
            return liquidity < 0
                ? getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(-liquidity), false).toInt256()
                : -getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, uint128(liquidity), true).toInt256();
        }
    }
}
