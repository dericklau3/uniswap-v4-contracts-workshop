// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {PathKey} from "./libraries/PathKey.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IV4Router} from "./interfaces/IV4Router.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {BipsLibrary} from "./libraries/BipsLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Uniswap V4 路由核心
/// @notice 封装单跳、多跳、精确输入和精确输出兑换，以及兑换后资金结算所需的内部逻辑。
/// @dev 继承合约应在自己的外部入口调用 `BaseActionsRouter._executeActions`。兑换会先在 `PoolManager`
/// 中形成瞬时正负 delta，再由后续 `SETTLE`、`TAKE` 等动作完成付款和收款，因此整个批次必须原子执行。
abstract contract V4Router is IV4Router, BaseActionsRouter, DeltaResolver {
    using SafeCast for *;
    using CalldataDecoder for bytes;
    using BipsLibrary for uint256;

    uint256 private constant PRECISION = 1e36;

    constructor(IPoolManager _poolManager) BaseActionsRouter(_poolManager) {}

    function _handleAction(uint256 action, bytes calldata params) internal override {
        // 动作编号按兑换类和支付类分区，先比较区间再分派可减少重复判断和 gas。
        if (action < Actions.SETTLE) {
            if (action == Actions.SWAP_EXACT_IN) {
                IV4Router.ExactInputParams calldata swapParams = params.decodeSwapExactInParams();
                _swapExactInput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_IN_SINGLE) {
                IV4Router.ExactInputSingleParams calldata swapParams = params.decodeSwapExactInSingleParams();
                _swapExactInputSingle(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT) {
                IV4Router.ExactOutputParams calldata swapParams = params.decodeSwapExactOutParams();
                _swapExactOutput(swapParams);
                return;
            } else if (action == Actions.SWAP_EXACT_OUT_SINGLE) {
                IV4Router.ExactOutputSingleParams calldata swapParams = params.decodeSwapExactOutSingleParams();
                _swapExactOutputSingle(swapParams);
                return;
            }
        } else {
            if (action == Actions.SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullDebt(currency);
                if (amount > maxAmount) revert V4TooMuchRequested(maxAmount, amount);
                _settle(currency, msgSender(), amount);
                return;
            } else if (action == Actions.TAKE_ALL) {
                (Currency currency, uint256 minAmount) = params.decodeCurrencyAndUint256();
                uint256 amount = _getFullCredit(currency);
                if (amount < minAmount) revert V4TooLittleReceived(minAmount, amount);
                _take(currency, msgSender(), amount);
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE_PORTION) {
                (Currency currency, address recipient, uint256 bips) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _getFullCredit(currency).calculatePortion(bips));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    function _swapExactInputSingle(IV4Router.ExactInputSingleParams calldata params) private {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut =
            _swap(params.poolKey, params.zeroForOne, -int256(uint256(amountIn)), params.hookData).toUint128();
        if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOut) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooLittleReceivedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactInput(IV4Router.ExactInputParams calldata params) private {
        unchecked {
            // 缓存路径长度及中间变量，避免循环内重复读取 calldata。
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // 常规池的输出侧 delta 为正；某些会返回自定义 delta 的 hook 池可能改变这一符号约定。
                amountOut = _swap(poolKey, zeroForOne, -int256(uint256(amountIn)), pathKey.hookData).toUint128();

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = amountOut * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i];
                    if (priceX36 < minPrice) revert V4TooLittleReceivedPerHop(i, minPrice, priceX36);
                }

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) revert V4TooLittleReceived(params.amountOutMinimum, amountOut);
        }
    }

    function _swapExactOutputSingle(IV4Router.ExactOutputSingleParams calldata params) private {
        uint128 amountOut = params.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut =
                _getFullDebt(params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0).toUint128();
        }
        uint128 amountIn = (uint256(
                -int256(_swap(params.poolKey, params.zeroForOne, int256(uint256(amountOut)), params.hookData))
            ))
        .toUint128();
        if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        if (params.minHopPriceX36 != 0) {
            uint256 priceX36 = uint256(amountOut) * PRECISION / amountIn;
            if (priceX36 < params.minHopPriceX36) {
                revert V4TooMuchRequestedPerHopSingle(params.minHopPriceX36, priceX36);
            }
        }
    }

    function _swapExactOutput(IV4Router.ExactOutputParams calldata params) private {
        unchecked {
            // 缓存路径长度及中间变量，精确输出需要从最终输出币沿路径反向推算输入。
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            if (amountOut == ActionConstants.OPEN_DELTA) {
                amountOut = _getFullDebt(currencyOut).toUint128();
            }

            uint256 perHopPriceLength = params.minHopPriceX36.length;
            if (perHopPriceLength != 0 && perHopPriceLength != pathLength) revert InvalidHopPriceLength();

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // 反向推算时该中间量代表下一跳所需输入，常规池对应负 delta；自定义 delta hook 可能例外。
                amountIn = (uint256(-int256(_swap(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData))))
                .toUint128();

                if (perHopPriceLength != 0) {
                    uint256 priceX36 = amountOut * PRECISION / amountIn;
                    uint256 minPrice = params.minHopPriceX36[i - 1];
                    if (priceX36 < minPrice) revert V4TooMuchRequestedPerHop(i - 1, minPrice, priceX36);
                }
                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) revert V4TooMuchRequested(params.amountInMaximum, amountIn);
        }
    }

    function _swap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (int128 reciprocalAmount)
    {
        // 路由不向调用者开放任意 sqrtPriceLimit：精确输出必须允许价格在协议边界内继续移动，
        // 最终由 amountInMaximum 和逐跳 minHopPriceX36 约束成本，避免半途触价后只成交部分输出。
        unchecked {
            BalanceDelta delta = poolManager.swap(
                poolKey,
                SwapParams(
                    zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                hookData
            );

            reciprocalAmount = (zeroForOne == amountSpecified < 0) ? delta.amount1() : delta.amount0();
        }
    }
}
