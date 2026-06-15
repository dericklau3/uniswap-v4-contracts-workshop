// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "./FullMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";

/// @title 计算单个 tick 区间内的一步兑换结果
/// @notice 在当前有效流动性保持不变的价格区间内，计算本步兑换后的价格、输入、输出与手续费。
/// @dev 一次完整 swap 可能跨越多个已初始化 tick；Pool.swap 会循环调用本库，每跨过边界后更新流动性再继续。
library SwapMath {
    /// @notice swap fee 以百分之一 bip 表示，因此最大值 1e6 对应 100%。
    /// @dev swap fee 是本次兑换的总费率，包含 LP fee 与 Protocol fee 的组合效果。
    uint256 internal constant MAX_SWAP_FEE = 1e6;

    /// @notice 根据下一初始化 tick 与用户价格限制，计算本步实际可到达的平方根价格目标。
    /// @param zeroForOne 兑换方向；true 为 currency0 换 currency1，false 为 currency1 换 currency0。
    /// @param sqrtPriceNextX96 下一条已初始化 tick 对应的 Q64.96 平方根价格。
    /// @param sqrtPriceLimitX96 用户设置的 Q64.96 平方根价格限制。zeroForOne 时成交后价格不能低于该值；
    ///        oneForZero 时成交后价格不能高于该值。
    /// @return sqrtPriceTargetX96 本步兑换应使用的价格目标。
    function getSqrtPriceTarget(bool zeroForOne, uint160 sqrtPriceNextX96, uint160 sqrtPriceLimitX96)
        internal
        pure
        returns (uint160 sqrtPriceTargetX96)
    {
        assembly ("memory-safe") {
            // 使用标志在 sqrtPriceNextX96 与 sqrtPriceLimitX96 之间选择。
            // zeroForOne == true 时，nextOrLimit 等价于 sqrtPriceNextX96 >= sqrtPriceLimitX96，
            // sqrtPriceTargetX96 = max(sqrtPriceNextX96, sqrtPriceLimitX96)
            // zeroForOne == false 时，nextOrLimit 等价于 sqrtPriceNextX96 < sqrtPriceLimitX96，
            // sqrtPriceTargetX96 = min(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceNextX96 := and(sqrtPriceNextX96, 0xffffffffffffffffffffffffffffffffffffffff)
            sqrtPriceLimitX96 := and(sqrtPriceLimitX96, 0xffffffffffffffffffffffffffffffffffffffff)
            let nextOrLimit := xor(lt(sqrtPriceNextX96, sqrtPriceLimitX96), and(zeroForOne, 0x1))
            let symDiff := xor(sqrtPriceNextX96, sqrtPriceLimitX96)
            sqrtPriceTargetX96 := xor(sqrtPriceLimitX96, mul(symDiff, nextOrLimit))
        }
    }

    /// @notice 根据兑换参数，计算本步消耗多少输入、产生多少输出以及价格移动到哪里。
    /// @dev amountRemaining < 0 表示 exactIn；输入与手续费之和绝不会超过剩余输入的绝对值。
    ///      amountRemaining > 0 表示 exactOut；为保证池不会少收，所需输入与手续费采用向上取整。
    /// @param sqrtPriceCurrentX96 池当前平方根价格。
    /// @param sqrtPriceTargetX96 本步不能越过的目标价格，兑换方向也由当前价与目标价的大小关系推导。
    /// @param liquidity 当前 tick 区间内可用的活跃流动性。
    /// @param amountRemaining 尚待兑换的输入量或尚待获得的输出量。
    /// @param feePips 从输入中收取的费率，以百分之一 bip 表示。
    /// @return sqrtPriceNextX96 本步后的价格，不会越过目标价格。
    /// @return amountIn 本步实际投入的 currency0 或 currency1 数量。
    /// @return amountOut 本步实际获得的 currency0 或 currency1 数量。
    /// @return feeAmount 本步从输入中收取的手续费数量。
    /// @dev feePips 不得大于 MAX_SWAP_FEE；设置费率前由 LPFeeLibrary.isValid 保证该条件。
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtPriceNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        unchecked {
            uint256 _feePips = feePips; // 只做一次向上类型转换并缓存。
            bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
            bool exactIn = amountRemaining < 0;

            if (exactIn) {
                uint256 amountRemainingLessFee =
                    FullMath.mulDiv(uint256(-amountRemaining), MAX_SWAP_FEE - _feePips, MAX_SWAP_FEE);
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true);
                if (amountRemainingLessFee >= amountIn) {
                    // 剩余净输入足够到达目标价，因此 amountIn 由目标价格限制。
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                    feeAmount = _feePips == MAX_SWAP_FEE
                        ? amountIn // 此处 amountIn 必为 0，因为 amountRemainingLessFee == 0 且仍需 >= amountIn。
                        : FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
                } else {
                    // 净输入不足以到达目标价，耗尽本步剩余输入。
                    amountIn = amountRemainingLessFee;
                    sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                        sqrtPriceCurrentX96, liquidity, amountRemainingLessFee, zeroForOne
                    );
                    // 未到达目标价，最大输入中扣除实际净输入后的全部余量都作为手续费。
                    feeAmount = uint256(-amountRemaining) - amountIn;
                }
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false);
            } else {
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceTargetX96, sqrtPriceCurrentX96, liquidity, false)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, false);
                if (uint256(amountRemaining) >= amountOut) {
                    // 期望输出足够跨到目标价，因此 amountOut 由目标价格限制。
                    sqrtPriceNextX96 = sqrtPriceTargetX96;
                } else {
                    // 期望输出不足以到达目标价，将输出限制为尚需获得的数量，避免超额输出。
                    amountOut = uint256(amountRemaining);
                    sqrtPriceNextX96 =
                        SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPriceCurrentX96, liquidity, amountOut, zeroForOne);
                }
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
                // exactOut 下 feePips 不能等于 MAX_SWAP_FEE，否则全部输入都成为手续费，无法产生指定输出。
                feeAmount = FullMath.mulDivRoundingUp(amountIn, _feePips, MAX_SWAP_FEE - _feePips);
            }
        }
    }
}
