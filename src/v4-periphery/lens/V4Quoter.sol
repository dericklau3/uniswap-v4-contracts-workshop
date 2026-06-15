// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Quoter} from "../interfaces/IV4Quoter.sol";
import {PathKey} from "../libraries/PathKey.sol";
import {QuoterRevert} from "../libraries/QuoterRevert.sol";
import {BaseV4Quoter} from "../base/BaseV4Quoter.sol";
import {Locker} from "../libraries/Locker.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @title V4 兑换报价器
/// @notice 模拟单跳或多跳的精确输入、精确输出兑换，并返回预计输出/输入数量与 gas 消耗。
/// @dev 报价会实际进入 `PoolManager.unlock` 和 `swap` 非 view 路径，再通过主动 revert 携带结果，
/// 从而回滚所有模拟状态。因此这些函数不能标记为 view，gas 也不适合链上合约直接调用，主要供 `eth_call` 使用。
contract V4Quoter is IV4Quoter, BaseV4Quoter {
    using QuoterRevert for *;

    constructor(IPoolManager _poolManager) BaseV4Quoter(_poolManager) {}

    modifier setMsgSender() {
        Locker.set(msg.sender);
        _; // 执行报价函数。
        Locker.set(address(0)); // 清除临时调用者，避免后续报价读取到旧上下文。
    }

    /// @notice 报价单池精确输入兑换：输入数量固定，计算预计可得输出。
    /// @param params 报价参数，包括 PoolKey、方向、精确输入数量和传给 hook 的数据。
    /// @return amountOut 预计输出数量。
    /// @return gasEstimate 模拟兑换路径消耗的 gas 估算值。
    /// @dev 通过 `unlock` 执行模拟；成功报价也会以 `QuoteSwap` 错误回退，再由本函数解析金额。
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        setMsgSender
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap revert 数据提取报价；若是其他错误则继续向外抛出。
            amountOut = reason.parseQuoteAmount();
        }
    }

    /// @notice 报价多跳精确输入兑换：沿 `path` 正向传递每一跳输出，得到最终输出。
    /// @param params 包含输入货币、PathKey 路径和精确输入数量的报价参数。
    /// @return amountOut 最后一跳预计输出数量。
    /// @return gasEstimate 整条模拟路径消耗的 gas 估算值。
    function quoteExactInput(QuoteExactParams memory params)
        external
        setMsgSender
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap revert 数据提取报价；模拟失败时保留原始错误。
            amountOut = reason.parseQuoteAmount();
        }
    }

    /// @notice 报价单池精确输出兑换：输出数量固定，计算预计所需输入。
    /// @param params 报价参数，包括 PoolKey、方向、精确输出数量和 hookData。
    /// @return amountIn 预计输入数量。
    /// @return gasEstimate 模拟兑换路径消耗的 gas 估算值。
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        setMsgSender
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap revert 数据提取报价；模拟失败时保留原始错误。
            amountIn = reason.parseQuoteAmount();
        }
    }

    /// @notice 报价多跳精确输出兑换：从目标输出沿 `path` 反向推算首跳所需输入。
    /// @param params 包含输出货币、反向求解所需 PathKey 路径和精确输出数量的报价参数。
    /// @return amountIn 完成目标输出预计需要的首种货币输入数量。
    /// @return gasEstimate 整条模拟路径消耗的 gas 估算值。
    function quoteExactOutput(QuoteExactParams memory params)
        external
        setMsgSender
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // 从 QuoteSwap revert 数据提取报价；模拟失败时保留原始错误。
            amountIn = reason.parseQuoteAmount();
        }
    }

    /// @dev 仅由 `_unlockCallback` 通过本合约外部自调用，用于逐跳模拟精确输入兑换并以 revert 返回结果。
    function _quoteExactInput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountIn = params.exactAmount;
        Currency inputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = 0; i < pathLength; i++) {
            pathKey = params.path[i];
            (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(inputCurrency);

            swapDelta = _swap(poolKey, zeroForOne, -int256(int128(amountIn)), pathKey.hookData);

            amountIn = zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
            inputCurrency = pathKey.intermediateCurrency;
        }
        // 每跳都会把输出赋给 amountIn 供下一跳使用；循环结束后该变量实际保存最终 amountOut。
        amountIn.revertQuote();
    }

    /// @dev 仅由 `_unlockCallback` 外部自调用，模拟单跳精确输入兑换并以 revert 返回输出数量。
    function _quoteExactInputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, -int256(int128(params.exactAmount)), params.hookData);

        // 常规兑换的输出侧 delta 为正，方向决定读取 amount0 还是 amount1。
        uint256 amountOut = params.zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
        amountOut.revertQuote();
    }

    /// @dev 仅由 `_unlockCallback` 外部自调用，从路径末端向前模拟精确输出兑换并以 revert 返回所需输入。
    function _quoteExactOutput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountOut = params.exactAmount;
        Currency outputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = pathLength; i > 0; i--) {
            pathKey = params.path[i - 1];
            (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(outputCurrency);

            swapDelta = _swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);

            amountOut = oneForZero ? uint128(-swapDelta.amount1()) : uint128(-swapDelta.amount0());

            outputCurrency = pathKey.intermediateCurrency;
        }
        // 每跳都会把所需输入赋给 amountOut 继续反推；循环结束后该变量实际保存首跳 amountIn。
        amountOut.revertQuote();
    }

    /// @dev 仅由 `_unlockCallback` 外部自调用，模拟单跳精确输出兑换并以 revert 返回所需输入。
    function _quoteExactOutputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, int256(uint256(params.exactAmount)), params.hookData);

        // 输入侧 delta 为负，取相反数后才是用户需要支付的正数数量。
        uint256 amountIn = params.zeroForOne ? uint128(-swapDelta.amount0()) : uint128(-swapDelta.amount1());
        amountIn.revertQuote();
    }

    /// @notice 返回发起当前报价的原始外部调用者。
    /// @dev V4 回调会丢失原始 `msg.sender`，因此报价入口先把调用者写入 `Locker`，供 hook 等集成读取。
    /// @return 原始报价调用者地址。
    function msgSender() external view returns (address) {
        // 此处只借用 Locker 保存上下文；V4Quoter 本身没有启用重入锁语义。
        return Locker.get();
    }
}
