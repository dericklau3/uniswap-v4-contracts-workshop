// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Calldata ABI 解码库
/// @notice 直接在 calldata 上返回结构体和动态字节切片，减少 `abi.decode` 产生的内存复制和 gas。
/// @dev 汇编解码依赖严格 ABI 编码，并在所有动态偏移和长度处执行边界检查。
library CalldataDecoder {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice 用于约束动态偏移和长度的掩码，避免加法溢出。
    /// @dev 正常 ABI 数据不会使用超过 `type(uint32).max` 的偏移或长度。
    /// 这与 Solidity 标准解码略有差异：超大值会按 uint32 截断，只会影响恶意或错误调用者。
    uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
    uint256 constant OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN = 0xffffffe0;

    /// @notice 等于 `SliceOutOfBounds.selector`，并放在最低有效位以便汇编直接写入。
    uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @dev 等价于在 calldata 中执行 `abi.decode(params, (bytes, bytes[]))`，但要求严格 ABI 编码。
    function decodeActionsRouterParams(bytes calldata _bytes)
        internal
        pure
        returns (bytes calldata actions, bytes[] calldata params)
    {
        assembly ("memory-safe") {
            // 严格编码要求数据头如下：
            // 0x00: 0x40（指向 actions.length）
            // 0x20: 0x60 + actions 对齐后长度（指向 params.length）
            // 0x40: actions.length
            // 0x60: actions 数据起点

            // 验证 actions 偏移符合严格编码。
            let invalidData := xor(calldataload(_bytes.offset), 0x40)
            actions.offset := add(_bytes.offset, 0x60)
            actions.length := and(calldataload(add(_bytes.offset, 0x40)), OFFSET_OR_LENGTH_MASK)

            // 将 actions 长度向上按 32 字节对齐，再加前三个编码字的 0x60。
            let paramsLengthOffset := add(and(add(actions.length, 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x60)
            // 验证 params 偏移紧跟 actions 对齐区。
            invalidData := or(invalidData, xor(calldataload(add(_bytes.offset, 0x20)), paramsLengthOffset))
            let paramsLengthPointer := add(_bytes.offset, paramsLengthOffset)
            params.length := and(calldataload(paramsLengthPointer), OFFSET_OR_LENGTH_MASK)
            params.offset := add(paramsLengthPointer, 0x20)

            // params[0] 的预期相对偏移是 params.length * 32，
            // 因为数组开头 params.length 个槽位分别保存各元素长度位置的指针。
            let tailOffset := shl(5, params.length)
            let expectedOffset := tailOffset

            for { let offset := 0 } lt(offset, tailOffset) { offset := add(offset, 32) } {
                let itemLengthOffset := calldataload(add(params.offset, offset))
                // 验证每个元素偏移与严格连续编码的预期值一致。
                invalidData := or(invalidData, xor(itemLengthOffset, expectedOffset))
                let itemLengthPointer := add(params.offset, itemLengthOffset)
                let length :=
                    add(and(add(calldataload(itemLengthPointer), 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x20)
                expectedOffset := add(expectedOffset, length)
            }

            // 编码无效或实际 calldata 短于声明长度时回退。
            if or(invalidData, lt(add(_bytes.length, _bytes.offset), add(params.offset, expectedOffset))) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }

    /// @dev 等价于在 calldata 中解码 `(uint256, uint256, uint128, uint128, bytes)`。
    function decodeModifyLiquidityParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes calldata hookData)
    {
        // 动态 bytes 的 `toBytes` 已覆盖整体边界检查，此处不重复检查固定头长度。
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            liquidity := calldataload(add(params.offset, 0x20))
            amount0 := calldataload(add(params.offset, 0x40))
            amount1 := calldataload(add(params.offset, 0x60))
        }

        hookData = params.toBytes(4);
    }

    /// @dev 等价于在 calldata 中解码 `(uint256, uint128, uint128, bytes)`。
    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
    {
        // 动态 bytes 的 `toBytes` 已执行边界检查。
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Max := calldataload(add(params.offset, 0x20))
            amount1Max := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev 等价于在 calldata 中解码 `(PoolKey, int24, int24, uint256, uint128, uint128, address, bytes)`。
    function decodeMintParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // hookData 的 `toBytes` 已执行整体边界检查。
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            liquidity := calldataload(add(params.offset, 0xe0))
            amount0Max := calldataload(add(params.offset, 0x100))
            amount1Max := calldataload(add(params.offset, 0x120))
            owner := calldataload(add(params.offset, 0x140))
        }
        hookData = params.toBytes(11);
    }

    /// @dev 等价于在 calldata 中解码 `(PoolKey, int24, int24, uint128, uint128, address, bytes)`。
    function decodeMintFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // hookData 的 `toBytes` 已执行整体边界检查。
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            amount0Max := calldataload(add(params.offset, 0xe0))
            amount1Max := calldataload(add(params.offset, 0x100))
            owner := calldataload(add(params.offset, 0x120))
        }

        hookData = params.toBytes(10);
    }

    /// @dev 等价于在 calldata 中解码 `(uint256, uint128, uint128, bytes)`。
    function decodeBurnParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
    {
        // hookData 的 `toBytes` 已执行整体边界检查。
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Min := calldataload(add(params.offset, 0x20))
            amount1Min := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev 等价于 `abi.decode(params, (IV4Router.ExactInputParams))`。
    function decodeSwapExactInParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputParams calldata swapParams)
    {
        // ExactInputParams 含动态字段，返回值只需指向 calldata 中结构体起点。
        assembly ("memory-safe") {
            // 只检查 path 和 minHopPriceX36 均为空时的最小合法长度。
            // 0xe0 = 7 * 0x20：3 个静态元素、两个动态偏移，以及两个长度 0。
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于 `abi.decode(params, (IV4Router.ExactInputSingleParams))`。
    function decodeSwapExactInSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputSingleParams calldata swapParams)
    {
        // ExactInputSingleParams 含动态 hookData，只需定位结构体起点。
        assembly ("memory-safe") {
            // 只检查 hookData 为空时的最小合法长度。
            // 0x160 = 11 * 0x20：9 个元素、bytes 偏移和长度 0。
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于 `abi.decode(params, (IV4Router.ExactOutputParams))`。
    function decodeSwapExactOutParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputParams calldata swapParams)
    {
        // ExactOutputParams 含动态字段，只需定位结构体起点。
        assembly ("memory-safe") {
            // 只检查 path 和 minHopPriceX36 均为空时的最小合法长度。
            // 0xe0 = 7 * 0x20：3 个静态元素、两个动态偏移，以及两个长度 0。
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于 `abi.decode(params, (IV4Router.ExactOutputSingleParams))`。
    function decodeSwapExactOutSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputSingleParams calldata swapParams)
    {
        // ExactOutputSingleParams 含动态 hookData，只需定位结构体起点。
        assembly ("memory-safe") {
            // 只检查 hookData 为空时的最小合法长度。
            // 0x160 = 11 * 0x20：9 个元素、bytes 偏移和长度 0。
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency)`。
    function decodeCurrency(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, Currency)`。
    function decodeCurrencyPair(bytes calldata params) internal pure returns (Currency currency0, Currency currency1) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, Currency, address)`。
    function decodeCurrencyPairAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency0, Currency currency1, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
            _address := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, address)`。
    function decodeCurrencyAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, address, uint256)`。
    function decodeCurrencyAddressAndUint256(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address, uint256 amount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
            amount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, uint256)`。
    function decodeCurrencyAndUint256(bytes calldata params) internal pure returns (Currency currency, uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中解码 `(uint256)`。
    function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            amount := calldataload(params.offset)
        }
    }

    /// @dev 等价于在 calldata 中解码 `(Currency, uint256, bool)`。
    function decodeCurrencyUint256AndBool(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, bool boolean)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
            boolean := calldataload(add(params.offset, 0x40))
        }
    }

    /// @notice 把 `_bytes` 中第 `_arg` 个 ABI 参数作为动态 `bytes` calldata 切片返回。
    /// @param _bytes 包含 ABI 参数的输入字节串。
    /// @param _arg 要提取的参数索引。
    function toBytes(bytes calldata _bytes, uint256 _arg) internal pure returns (bytes calldata res) {
        uint256 length;
        assembly ("memory-safe") {
            // 第 `_arg` 个头槽位于 `32 * arg`，其中保存指向动态长度字的相对偏移。
            // shl(5, x) 等价于 mul(32, x)。
            let lengthPtr :=
                add(_bytes.offset, and(calldataload(add(_bytes.offset, shl(5, _arg))), OFFSET_OR_LENGTH_MASK))
            // 动态 bytes 声明的字节长度。
            length := and(calldataload(lengthPtr), OFFSET_OR_LENGTH_MASK)
            // bytes 实际内容开始位置，跳过长度字。
            let offset := add(lengthPtr, 0x20)
            // 直接设置返回 calldata 切片的 offset 和 length。
            res.length := length
            res.offset := offset

            // 实际 calldata 长度不足以覆盖声明区间时回退。
            if lt(add(_bytes.length, _bytes.offset), add(length, offset)) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }
}
