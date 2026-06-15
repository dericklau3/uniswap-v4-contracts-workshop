// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice 根据代币数量、当前价格和仓位价格区间计算可获得的集中流动性。
library LiquidityAmounts {
    using SafeCast for uint256;

    /// @notice 计算给定 token0 数量在指定价格区间可支持的流动性。
    /// @dev 公式：amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))。
    /// @param sqrtPriceAX96 第一个 tick 边界的平方根价格。
    /// @param sqrtPriceBX96 第二个 tick 边界的平方根价格；函数会自动排序两个边界。
    /// @param amount0 投入的 token0 数量。
    /// @return liquidity 可获得的流动性。
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
            return FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
        }
    }

    /// @notice 计算给定 token1 数量在指定价格区间可支持的流动性。
    /// @dev 公式：amount1 / (sqrt(upper) - sqrt(lower))，并按 Q96 精度缩放。
    /// @param sqrtPriceAX96 第一个 tick 边界的平方根价格。
    /// @param sqrtPriceBX96 第二个 tick 边界的平方根价格；函数会自动排序两个边界。
    /// @param amount1 投入的 token1 数量。
    /// @return liquidity 可获得的流动性。
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        unchecked {
            if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
            return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
        }
    }

    /// @notice 根据两种代币预算、当前池价格和区间边界计算最多可铸造的流动性。
    /// @dev 当前价低于区间时仓位只需要 token0，高于区间时只需要 token1；
    /// 当前价位于区间内时两种代币都需要，最终取两侧预算可支持流动性的较小值。
    /// @param sqrtPriceX96 当前池平方根价格。
    /// @param sqrtPriceAX96 第一个 tick 边界的平方根价格。
    /// @param sqrtPriceBX96 第二个 tick 边界的平方根价格。
    /// @param amount0 可投入的 token0 数量。
    /// @param amount1 可投入的 token1 数量。
    /// @return liquidity 两种预算共同约束下的最大流动性。
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }
}
