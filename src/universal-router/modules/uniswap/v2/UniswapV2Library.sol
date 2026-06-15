// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import {IUniswapV2Pair} from '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';

/// @title Uniswap V2 路由辅助库
/// @notice 负责 token 排序、Pair 的 CREATE2 地址推导、储备量读取，以及精确输入/输出的恒定乘积报价。
library UniswapV2Library {
    error InvalidReserves();
    error InvalidPath();

    /// @notice 不发起外部调用，直接确定性计算两个 token 对应的 V2 Pair 地址。
    /// @param factory V2 Factory 地址。
    /// @param initCodeHash Pair 初始化代码哈希。
    /// @param tokenA Pair 中的一种 token。
    /// @param tokenB Pair 中的另一种 token。
    /// @return pair 由 Factory、排序后的 token 和 init code hash 推导出的 Pair 地址。
    function pairFor(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        pure
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = pairForPreSorted(factory, initCodeHash, token0, token1);
    }

    /// @notice 计算 V2 Pair 地址，并同时返回按地址值排序后的 token0。
    /// @param factory V2 Factory 地址。
    /// @param initCodeHash Pair 初始化代码哈希。
    /// @param tokenA Pair 中的一种 token。
    /// @param tokenB Pair 中的另一种 token。
    /// @return pair 推导出的 Pair 地址。
    /// @return token0 两个 token 中地址值较小者，用于匹配 reserve0/reserve1 方向。
    function pairAndToken0For(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        internal
        pure
        returns (address pair, address token0)
    {
        address token1;
        (token0, token1) = sortTokens(tokenA, tokenB);
        pair = pairForPreSorted(factory, initCodeHash, token0, token1);
    }

    /// @notice 在 token 已按 `token0 < token1` 排序的前提下，用 CREATE2 公式计算 Pair 地址。
    /// @param factory V2 Factory 地址。
    /// @param initCodeHash Pair 初始化代码哈希。
    /// @param token0 Pair 中地址值较小的 token。
    /// @param token1 Pair 中地址值较大的 token。
    /// @return pair 推导出的 Pair 地址。
    function pairForPreSorted(address factory, bytes32 initCodeHash, address token0, address token1)
        private
        pure
        returns (address pair)
    {
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex'ff', factory, keccak256(abi.encodePacked(token0, token1)), initCodeHash)
                    )
                )
            )
        );
    }

    /// @notice 计算 Pair 地址并读取储备量，再按调用方传入的 tokenA/tokenB 顺序返回。
    /// @dev Pair 原生返回 reserve0/reserve1；这里根据 token0 重新映射，避免报价时弄反输入输出储备。
    /// @param factory V2 Factory 地址。
    /// @param initCodeHash Pair 初始化代码哈希。
    /// @param tokenA 报价方向中的第一种 token。
    /// @param tokenB 报价方向中的第二种 token。
    /// @return pair 推导出的 Pair 地址。
    /// @return reserveA tokenA 对应的储备量。
    /// @return reserveB tokenB 对应的储备量。
    function pairAndReservesFor(address factory, bytes32 initCodeHash, address tokenA, address tokenB)
        private
        view
        returns (address pair, uint256 reserveA, uint256 reserveB)
    {
        address token0;
        (pair, token0) = pairAndToken0For(factory, initCodeHash, tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @notice 按 V2 恒定乘积公式，根据确定输入量计算单 hop 可获得的输出量。
    /// @dev 公式内的 997/1000 表示扣除 0.3% 交易费后再进入 x*y=k 定价。
    /// @param amountIn 输入 token 数量。
    /// @param reserveIn 输入 token 的池内储备。
    /// @param reserveOut 输出 token 的池内储备。
    /// @return amountOut 可从 Pair 获得的输出 token 数量。
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InvalidReserves();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice 按 V2 恒定乘积公式，反算单 hop 获得指定输出量所需的最小输入量。
    /// @dev 整数除法后加 1，确保实际输入不会因向下取整而少于满足目标输出所需的数量。
    /// @param amountOut 期望获得的输出 token 数量。
    /// @param reserveIn 输入 token 的池内储备。
    /// @param reserveOut 输出 token 的池内储备。
    /// @return amountIn 为得到目标输出所需的输入 token 数量。
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InvalidReserves();
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    /// @notice 从最后一个 hop 向前反推多 hop 精确输出交易所需的首币输入量。
    /// @dev 路径按正向交易顺序编码，但精确输出报价必须从最终 `amountOut` 倒推每一池的所需输入。
    /// @param factory V2 Factory 地址。
    /// @param initCodeHash Pair 初始化代码哈希。
    /// @param amountOut 最终期望获得的输出数量。
    /// @param path 多 hop token 地址数组。
    /// @return amount 首个输入 token 所需数量。
    /// @return pair 正向执行交易时的第一个 Pair 地址。
    function getAmountInMultihop(address factory, bytes32 initCodeHash, uint256 amountOut, address[] calldata path)
        internal
        view
        returns (uint256 amount, address pair)
    {
        if (path.length < 2) revert InvalidPath();
        amount = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            uint256 reserveIn;
            uint256 reserveOut;

            (pair, reserveIn, reserveOut) = pairAndReservesFor(factory, initCodeHash, path[i - 1], path[i]);
            amount = getAmountIn(amount, reserveIn, reserveOut);
        }
    }

    /// @notice 按地址数值对两个 token 排序，得到 V2 Pair 使用的 token0/token1 顺序。
    /// @param tokenA 第一个待排序 token。
    /// @param tokenB 第二个待排序 token。
    /// @return token0 地址值较小的 token。
    /// @return token1 地址值较大的 token。
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
