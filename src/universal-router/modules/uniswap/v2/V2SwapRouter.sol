// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import {UniswapV2Library} from './UniswapV2Library.sol';
import {UniswapImmutables} from '../UniswapImmutables.sol';
import {Permit2Payments} from '../../Permit2Payments.sol';
import {Constants} from '../../../libraries/Constants.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @title Uniswap V2 交易路由模块
abstract contract V2SwapRouter is UniswapImmutables, Permit2Payments {
    error V2TooLittleReceived();
    error V2TooMuchRequested();
    error V2InvalidPath();
    error V2TooLittleReceivedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    error V2InvalidHopPriceLength();

    function _v2Swap(address[] calldata path, address recipient, address pair, uint256[] calldata minHopPriceX36)
        private
    {
        unchecked {
            // 缓存首个 Pair 的 token0，后续每 hop 同时计算下一个 Pair 的 token0，减少重复排序。
            (address token0,) = UniswapV2Library.sortTokens(path[0], path[1]);
            uint256 finalPairIndex = path.length - 1;
            uint256 penultimatePairIndex = finalPairIndex - 1;
            bool minHopPriceEnabled = minHopPriceX36.length != 0;
            for (uint256 i; i < finalPairIndex; i++) {
                (address input, address output) = (path[i], path[i + 1]);
                (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
                (uint256 reserveInput, uint256 reserveOutput) =
                    input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                uint256 amountInput = ERC20(input).balanceOf(pair) - reserveInput;
                uint256 amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
                (uint256 amount0Out, uint256 amount1Out) =
                    input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
                address nextPair;
                (nextPair, token0) = i < penultimatePairIndex
                    ? UniswapV2Library.pairAndToken0For(
                        UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, output, path[i + 2]
                    )
                    : (recipient, address(0));

                // 开启逐 hop 最低价格保护时，用下一个接收地址的实际余额增量衡量输出，
                // 因而也能覆盖 fee-on-transfer token 导致的实际到账差异。
                if (minHopPriceEnabled && minHopPriceX36[i] != 0) {
                    uint256 recipientBalance = ERC20(output).balanceOf(nextPair);
                    IUniswapV2Pair(pair).swap(amount0Out, amount1Out, nextPair, new bytes(0));
                    amountOutput = ERC20(output).balanceOf(nextPair) - recipientBalance;
                    uint256 price = amountOutput * Constants.PRICE_PRECISION / amountInput;
                    uint256 minPrice = minHopPriceX36[i];
                    if (price < minPrice) revert V2TooLittleReceivedPerHop(i, minPrice, price);
                } else {
                    IUniswapV2Pair(pair).swap(amount0Out, amount1Out, nextPair, new bytes(0));
                }
                pair = nextPair;
            }
        }
    }

    /// @notice 执行 Uniswap V2 精确输入交易：固定首币投入，并要求最终输出不少于下限。
    /// @dev 首跳输入通过路由器余额或 Permit2 直接发送给第一个 Pair；每个中间 Pair 将输出直接发送给
    /// 下一个 Pair，最后一跳才发送给 `recipient`。最终使用接收者余额差检查整体滑点。
    /// @param recipient 最终输出 token 接收者。
    /// @param amountIn 首个输入 token 数量。
    /// @param amountOutMinimum 可接受的最终最小输出量。
    /// @param path 按交易方向排列的 token 地址数组。
    /// @param payer 首跳付款地址；可为用户或 Universal Router。
    /// @param minHopPriceX36 每个 hop 的最低兑换价格，精度为 1e36；空数组表示关闭逐 hop 检查。
    function v2SwapExactInput(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address[] calldata path,
        address payer,
        uint256[] calldata minHopPriceX36
    ) internal {
        if (path.length < 2) revert V2InvalidPath();
        if (minHopPriceX36.length != 0 && minHopPriceX36.length != path.length - 1) {
            revert V2InvalidHopPriceLength();
        }

        address firstPair =
            UniswapV2Library.pairFor(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, path[0], path[1]);
        if (
            amountIn != Constants.ALREADY_PAID // amountIn 为 0 表示 Pair 已提前收到输入 token。
        ) {
            payOrPermit2Transfer(path[0], payer, firstPair, amountIn);
        }

        ERC20 tokenOut = ERC20(path[path.length - 1]);
        uint256 balanceBefore = tokenOut.balanceOf(recipient);

        _v2Swap(path, recipient, firstPair, minHopPriceX36);

        uint256 amountOut = tokenOut.balanceOf(recipient) - balanceBefore;
        if (amountOut < amountOutMinimum) revert V2TooLittleReceived();
    }

    /// @notice 执行 Uniswap V2 精确输出交易：固定最终输出，并限制首币最大投入。
    /// @dev 先从末 hop 向前读取储备并反算总输入，再把准确输入发送给首个 Pair，随后按正向路径逐池交换。
    /// @param recipient 最终输出 token 接收者。
    /// @param amountOut 要获得的精确输出数量。
    /// @param amountInMaximum 允许消耗的最大首币输入量。
    /// @param path 按交易方向排列的 token 地址数组。
    /// @param payer 首跳付款地址；可为用户或 Universal Router。
    /// @param minHopPriceX36 每个 hop 的最低兑换价格，精度为 1e36；空数组表示关闭逐 hop 检查。
    function v2SwapExactOutput(
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        address[] calldata path,
        address payer,
        uint256[] calldata minHopPriceX36
    ) internal {
        if (path.length < 2) revert V2InvalidPath();
        if (minHopPriceX36.length != 0 && minHopPriceX36.length != path.length - 1) {
            revert V2InvalidHopPriceLength();
        }

        (uint256 amountIn, address firstPair) =
            UniswapV2Library.getAmountInMultihop(UNISWAP_V2_FACTORY, UNISWAP_V2_PAIR_INIT_CODE_HASH, amountOut, path);
        if (amountIn > amountInMaximum) revert V2TooMuchRequested();

        payOrPermit2Transfer(path[0], payer, firstPair, amountIn);
        _v2Swap(path, recipient, firstPair, minHopPriceX36);
    }
}
