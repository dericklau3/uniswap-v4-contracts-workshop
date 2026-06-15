// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {QuoterRevert} from "../libraries/QuoterRevert.sol";
import {SafeCallback} from "../base/SafeCallback.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

abstract contract BaseV4Quoter is SafeCallback {
    using QuoterRevert for *;

    error NotEnoughLiquidity(PoolId poolId);
    error NotSelf();
    error UnexpectedCallSuccess();

    constructor(IPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @dev 仅允许本合约通过外部自调用进入。这样既能模拟内部报价步骤，又能在上层 `try/catch`
    /// 中捕获并解析报价函数主动抛出的 revert 数据，防止任意外部账户伪造报价执行路径。
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        // 每条报价路径最终都应回退：成功报价抛出 QuoteSwap(quoteAmount)，失败则抛出具体错误。
        if (success) revert UnexpectedCallSuccess();
        // 无论是合法报价还是其他错误，都把原始 revert 数据交给上层解析。
        returnData.bubbleReason();
    }

    /// @notice 模拟一次兑换并返回货币余额变化；`amountSpecified < 0` 表示精确输入，否则表示精确输出。
    /// @dev 报价不结算资金，而是在 `PoolManager` 的解锁上下文中执行真实换算，随后通过 revert 回滚全部状态。
    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        internal
        returns (BalanceDelta swapDelta)
    {
        swapDelta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );

        // 确认指定侧数量被完整成交；若到达价格边界仍未完成，说明池中可用流动性不足。
        int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? swapDelta.amount0() : swapDelta.amount1();
        if (amountSpecifiedActual != amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }
}
