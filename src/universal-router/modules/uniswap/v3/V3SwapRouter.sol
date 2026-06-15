// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {V3Path} from './V3Path.sol';
import {BytesLib} from './BytesLib.sol';
import {SafeCast} from '@uniswap/v3-core/contracts/libraries/SafeCast.sol';
import {IUniswapV3Pool} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import {IUniswapV3SwapCallback} from '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';
import {ActionConstants} from '@uniswap/v4-periphery/src/libraries/ActionConstants.sol';
import {Constants} from '../../../libraries/Constants.sol';
import {CalldataDecoder} from '@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol';
import {Permit2Payments} from '../../Permit2Payments.sol';
import {UniswapImmutables} from '../UniswapImmutables.sol';
import {MaxInputAmount} from '../../../libraries/MaxInputAmount.sol';
import {ERC20} from 'solmate/src/tokens/ERC20.sol';

/// @title Uniswap V3 交易路由模块
/// @notice 执行 V3 精确输入/输出 swap，并在 pool callback 中完成 Permit2 付款、反向多 hop 与逐 hop 价格校验。
abstract contract V3SwapRouter is UniswapImmutables, Permit2Payments, IUniswapV3SwapCallback {
    using V3Path for bytes;
    using BytesLib for bytes;
    using CalldataDecoder for bytes;
    using SafeCast for uint256;

    error V3InvalidSwap();
    error V3TooLittleReceived();
    error V3TooMuchRequested();
    error V3InvalidAmountOut();
    error V3InvalidCaller();
    error V3TooLittleReceivedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    error V3TooMuchRequestedPerHop(uint256 hopIndex, uint256 minPrice, uint256 price);
    error V3HopPriceAndPathLengthMismatch();

    /// @dev `getSqrtRatioAtTick(MIN_TICK)` 可返回的最小 sqrt price；swap 时加 1 作为可达价格边界。
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @dev `getSqrtRatioAtTick(MAX_TICK)` 可返回的最大 sqrt price；swap 时减 1 作为可达价格边界。
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta <= 0 && amount1Delta <= 0) revert V3InvalidSwap(); // 不支持完全发生在零流动性区域内的 swap。
        (, address payer, uint256[] memory minHopPriceX36, uint256 hopIndex) =
            abi.decode(data, (bytes, address, uint256[], uint256));
        bytes calldata path = data.toBytes(0);

        // 精确输出按反向 path 执行；进入 callback 时，编码中的 tokenOut 在最终付款分支中实际是正向交易的输入 token。
        (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();

        if (computePoolAddress(tokenIn, tokenOut, fee) != msg.sender) revert V3InvalidCaller();

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));

        if (isExactInput) {
            // 精确输入：当前 hop 的输入量已经确定，直接向发起 callback 的 Pool 付款。
            payOrPermit2Transfer(tokenIn, payer, msg.sender, amountToPay);
        } else {
            // 精确输出：Pool 先给出目标输出，再通过 callback 索要输入；多 hop 时继续反向触发前一个 Pool。
            if (path.hasMultiplePools()) {
                // 对精确输出的中间 hop 检查实际输出/输入价格，防止某一池单独遭受过大滑点。
                if (minHopPriceX36.length != 0) {
                    uint256 amountOut = uint256(-(amount0Delta > 0 ? amount1Delta : amount0Delta));
                    uint256 price = amountOut * Constants.PRICE_PRECISION / amountToPay;
                    uint256 minPrice = minHopPriceX36[hopIndex];
                    if (price < minPrice) revert V3TooMuchRequestedPerHop(hopIndex, minPrice, price);
                }
                // 当前 Pool 所需的输入由前一个反向 swap 产出并直接发给当前 Pool；
                // 这是中间结算步骤，但最早一跳最终仍会向原始 payer 收款。
                path = path.skipToken();
                _swap(
                    -amountToPay.toInt256(),
                    msg.sender,
                    path,
                    payer,
                    false,
                    minHopPriceX36,
                    hopIndex > 0 ? hopIndex - 1 : 0
                );
            } else {
                if (amountToPay > MaxInputAmount.get()) revert V3TooMuchRequested();
                // 反向执行到最后一个 callback 时，实际对应正向交易的第一 hop，检查其最低价格。
                if (minHopPriceX36.length != 0) {
                    uint256 amountOut = uint256(-(amount0Delta > 0 ? amount1Delta : amount0Delta));
                    uint256 price = amountOut * Constants.PRICE_PRECISION / amountToPay;
                    uint256 minPrice = minHopPriceX36[hopIndex];
                    if (price < minPrice) revert V3TooMuchRequestedPerHop(hopIndex, minPrice, price);
                }
                // 精确输出 path 反向编码，因此此处的 `tokenOut` 就是用户正向交易要支付的首个输入 token。
                payOrPermit2Transfer(tokenOut, payer, msg.sender, amountToPay);
            }
        }
    }

    /// @notice 执行 Uniswap V3 精确输入交易：固定首币投入，并要求最终输出不少于下限。
    /// @dev path 按正向交易顺序编码为 `tokenIn | fee | tokenOut | fee | ...`。每一 hop 的输出由路由器
    /// 暂存并作为下一 hop 输入；首 hop 通过 callback 从 `payer` 付款，后续 hop 使用路由器余额付款。
    /// @param recipient 最终输出 token 接收者。
    /// @param amountIn 首个输入 token 数量；可使用 `CONTRACT_BALANCE` 表示路由器全部该 token 余额。
    /// @param amountOutMinimum 可接受的最终最小输出量。
    /// @param path 按正向交易顺序紧凑编码的 V3 path。
    /// @param payer 首 hop 付款地址；可为用户或 Universal Router。
    /// @param minHopPriceX36 每个 hop 的最低兑换价格，精度为 1e36；空数组表示关闭逐 hop 检查。
    function v3SwapExactInput(
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        bytes calldata path,
        address payer,
        uint256[] calldata minHopPriceX36
    ) internal {
        // 校验价格数组与 hop 数一致。
        // V3 path: token(20) + [fee(3) + token(20)] * numHops => path.length = (minHopPriceX36.length * 23) + 20
        if (
            minHopPriceX36.length != 0
                && path.length != (minHopPriceX36.length * Constants.NEXT_V3_POOL_OFFSET) + Constants.ADDR_SIZE
        ) revert V3HopPriceAndPathLengthMismatch();

        // `CONTRACT_BALANCE` 表示把路由器当前持有的全部首币作为精确输入，便于承接前序命令产出。
        if (amountIn == ActionConstants.CONTRACT_BALANCE) {
            address tokenIn = path.decodeFirstToken();
            amountIn = ERC20(tokenIn).balanceOf(address(this));
        }

        uint256 amountOut;
        uint256 hopIndex;
        uint256 previousAmountIn = amountIn;
        uint256[] memory emptyHopPrice = new uint256[](0);
        while (true) {
            bool hasMultiplePools = path.hasMultiplePools();

            // 前一 hop 的输出成为后一 hop 的输入；中间输出先由 Universal Router 托管。
            (int256 amount0Delta, int256 amount1Delta, bool zeroForOne) = _swap(
                amountIn.toInt256(),
                hasMultiplePools ? address(this) : recipient, // 中间 hop 由路由器托管输出。
                path.getFirstPool(), // 每次只执行 path 最前面的一个 pool。
                payer, // 首 hop 可由用户付款，后续 hop 改为路由器付款。
                true,
                emptyHopPrice, // 精确输入在每次 swap 返回后检查价格，callback 无需重复检查。
                0
            );

            amountIn = uint256(-(zeroForOne ? amount1Delta : amount0Delta));

            // 用该 hop 的实际输出/实际输入计算价格，逐池执行最低价格保护。
            if (minHopPriceX36.length != 0) {
                uint256 price = amountIn * Constants.PRICE_PRECISION / previousAmountIn;
                uint256 minPrice = minHopPriceX36[hopIndex];
                if (price < minPrice) revert V3TooLittleReceivedPerHop(hopIndex, minPrice, price);
            }

            // 仍有 pool 时跳过已执行的 `token + fee` 并继续；最后一 hop 则确定最终输出。
            if (hasMultiplePools) {
                payer = address(this);
                path = path.skipToken();
                previousAmountIn = amountIn;
                hopIndex++;
            } else {
                amountOut = amountIn;
                break;
            }
        }

        if (amountOut < amountOutMinimum) revert V3TooLittleReceived();
    }

    /// @notice 执行 Uniswap V3 精确输出交易：固定最终输出，并限制用户首币最大投入。
    /// @dev V3 精确输出 path 必须按反向顺序编码。路由器先调用正向交易的最后一个 Pool，callback 再逐级
    /// 触发更早的 hop，直到第一 hop 通过 Permit2 或路由器余额完成最终付款。
    /// @param recipient 最终输出 token 接收者。
    /// @param amountOut 要获得的精确输出数量。
    /// @param amountInMaximum 允许消耗的最大首币输入量，写入 transient storage 供最深层 callback 检查。
    /// @param path 按精确输出反向执行顺序紧凑编码的 V3 path。
    /// @param payer 最终承担首币输入的地址。
    /// @param minHopPriceX36 按正向 hop 索引排列的最低兑换价格，精度为 1e36；空数组表示关闭检查。
    function v3SwapExactOutput(
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        bytes calldata path,
        address payer,
        uint256[] calldata minHopPriceX36
    ) internal {
        // 校验价格数组与 hop 数一致。
        // V3 path: token(20) + [fee(3) + token(20)] * numHops => path.length = (minHopPriceX36.length * 23) + 20
        if (
            minHopPriceX36.length != 0
                && path.length != (minHopPriceX36.length * Constants.NEXT_V3_POOL_OFFSET) + Constants.ADDR_SIZE
        ) revert V3HopPriceAndPathLengthMismatch();

        // `_swap` 要把价格数组编码进 callback data，因此先从 calldata 复制到 memory。
        uint256[] memory minHopPriceX36Memory = minHopPriceX36;

        MaxInputAmount.set(amountInMaximum);

        // 精确输出的第一次 `_swap` 处理正向交易的最后一 hop。
        // 交易方向：hop 0 (A->B), hop 1 (B->C), ...
        // 执行顺序：先执行最后一 hop，再由 callback 逐级处理更早的 hop。
        // 因此 hopIndex 从 `length - 1` 开始，并在 callback 中递减。
        uint256 startHopIndex = minHopPriceX36Memory.length > 0 ? minHopPriceX36Memory.length - 1 : 0;

        (int256 amount0Delta, int256 amount1Delta, bool zeroForOne) =
            _swap(-amountOut.toInt256(), recipient, path, payer, false, minHopPriceX36Memory, startHopIndex);

        uint256 amountOutReceived = zeroForOne ? uint256(-amount1Delta) : uint256(-amount0Delta);

        if (amountOutReceived != amountOut) revert V3InvalidAmountOut();

        MaxInputAmount.set(0);
    }

    /// @dev 执行单个 V3 Pool swap，同时服务 exactIn 与 exactOut。
    /// exactIn 时 `amount` 为正的 `amountIn`；exactOut 时为负的 `-amountOut`。
    /// path 及 payer 会编码进 callback data，使 Pool 回调时能够验证调用者、继续多 hop 并完成结算。
    function _swap(
        int256 amount,
        address recipient,
        bytes calldata path,
        address payer,
        bool isExactIn,
        uint256[] memory minHopPriceX36,
        uint256 hopIndex
    ) private returns (int256 amount0Delta, int256 amount1Delta, bool zeroForOne) {
        (address tokenIn, uint24 fee, address tokenOut) = path.decodeFirstPool();

        zeroForOne = isExactIn ? tokenIn < tokenOut : tokenOut < tokenIn;

        (amount0Delta, amount1Delta) = IUniswapV3Pool(computePoolAddress(tokenIn, tokenOut, fee))
            .swap(
                recipient,
                zeroForOne,
                amount,
                (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1),
                abi.encode(path, payer, minHopPriceX36, hopIndex)
            );
    }

    function computePoolAddress(address tokenA, address tokenB, uint24 fee) private view returns (address pool) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            UNISWAP_V3_FACTORY,
                            keccak256(abi.encode(tokenA, tokenB, fee)),
                            UNISWAP_V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
}
