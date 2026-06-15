// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title 滑点检查库
/// @notice 校验增仓本金支出不超过上限，或减仓本金收入不低于下限。
library SlippageCheck {
    using SafeCast for int128;

    error MaximumAmountExceeded(uint128 maximumAmount, uint128 amountRequested);
    error MinimumAmountInsufficient(uint128 minimumAmount, uint128 amountReceived);

    /// @notice 任一货币的正向本金 delta 低于用户最低收款时回退。
    /// @param delta 移除流动性返还的本金，不包含已累积手续费。
    /// @param amount0Min token0 最低接收数量。
    /// @param amount1Min token1 最低接收数量。
    /// @dev 用于 burn 或 decrease。常规情况下返回 delta 为正；
    /// 若 hook 在减仓时返回负 delta，SafeCast 会回退，因此本库不支持这类要求用户反向付款的 hook 池。
    function validateMinOut(BalanceDelta delta, uint128 amount0Min, uint128 amount1Min) internal pure {
        // burn/decrease 通常返回正 delta；若自定义 hook 改成负值，toUint128 会回退并拒绝该池语义。
        if (delta.amount0().toUint128() < amount0Min) {
            revert MinimumAmountInsufficient(amount0Min, delta.amount0().toUint128());
        }
        if (delta.amount1().toUint128() < amount1Min) {
            revert MinimumAmountInsufficient(amount1Min, delta.amount1().toUint128());
        }
    }

    /// @notice 任一货币的负向本金 delta 绝对值超过用户最大支出时回退。
    /// @param delta 增加流动性产生的本金 delta，不包含 increase 时可能同步到的手续费。
    /// @param amount0Max token0 最大支出数量。
    /// @param amount1Max token1 最大支出数量。
    /// @dev 用于 mint 或 increase。若 hook 反而给用户正 delta，代表用户获得货币，本函数不做最低收入检查。
    function validateMaxIn(BalanceDelta delta, uint128 amount0Max, uint128 amount1Max) internal pure {
        // mint/increase 通常产生负 delta。自定义 hook 可能在扣除手续费后仍给出正 delta，
        // 所以只对确定为负的支出取绝对值并检查上限；正 delta 不做 minAmountOut 型正向滑点保护。
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        if (amount0 < 0 && amount0Max < uint128(uint256(-amount0))) {
            revert MaximumAmountExceeded(amount0Max, uint128(uint256(-amount0)));
        }
        if (amount1 < 0 && amount1Max < uint128(uint256(-amount1))) {
            revert MaximumAmountExceeded(amount1Max, uint128(uint256(-amount1)));
        }
    }
}
