// SPDX-License-Identifier: GPL-3.0-or-later

/// @title Universal Router calldata 字节解码库
pragma solidity ^0.8.0;

import {Constants} from '../../../libraries/Constants.sol';
import {CalldataDecoder} from '@uniswap/v4-periphery/src/libraries/CalldataDecoder.sol';

library BytesLib {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice 读取 bytes 起始 20 字节编码的地址。
    /// @dev 先检查长度，再通过右移 96 位从首个 calldata word 中取出地址。
    /// @param _bytes 待读取的 calldata 字节串。
    /// @return _address 从 byte 0 开始编码的地址。
    function toAddress(bytes calldata _bytes) internal pure returns (address _address) {
        if (_bytes.length < Constants.ADDR_SIZE) revert SliceOutOfBounds();
        assembly {
            _address := shr(96, calldataload(_bytes.offset))
        }
    }

    /// @notice 解码 V3 path 起始处的一个 pool 段：`token0 | fee | token1`。
    /// @dev 紧凑编码长度为 20 + 3 + 20 = 43 字节；读取前必须保证至少包含一个完整 pool。
    /// @param _bytes 待读取的 V3 path 字节串。
    /// @return token0 byte 0 开始的第一个 token 地址。
    /// @return fee byte 20 开始的 uint24 fee。
    /// @return token1 byte 23 开始的第二个 token 地址。
    function toPool(bytes calldata _bytes) internal pure returns (address token0, uint24 fee, address token1) {
        if (_bytes.length < Constants.V3_POP_OFFSET) revert SliceOutOfBounds();
        assembly {
            let firstWord := calldataload(_bytes.offset)
            token0 := shr(96, firstWord)
            fee := and(shr(72, firstWord), 0xffffff)
            token1 := shr(96, calldataload(add(_bytes.offset, 23)))
        }
    }

    /// @notice 将 ABI 参数 `_bytes` 中第 `_arg` 个槽解码为动态数组的长度和数据位置。
    /// @dev `length` 与 `offset` 的 ABI 定位方式对所有动态数组通用；上层函数再通过返回变量类型告诉
    /// 编译器应把该数据解释为 `address[]`、`uint256[]` 等具体数组。
    /// @param _bytes 包含 ABI 编码参数的 calldata 字节串。
    /// @param _arg 待提取参数的槽索引。
    /// @return length 动态数组元素数量。
    /// @return offset 动态数组首个元素在 calldata 中的绝对位置。
    function toLengthOffset(bytes calldata _bytes, uint256 _arg)
        internal
        pure
        returns (uint256 length, uint256 offset)
    {
        assembly {
            // 第 `_arg` 个参数槽位于 `32 * _arg`，槽内保存指向数组 length 的相对偏移。
            // shl(5, x) 等价于 mul(32, x)。
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, shl(5, _arg))))
            length := calldataload(lengthPtr)
            offset := add(lengthPtr, 0x20)
            let relativeOffset := sub(offset, _bytes.offset)
            if lt(_bytes.length, add(shl(5, length), relativeOffset)) {
                mstore(0, 0x3b99b53d) // SliceOutOfBounds()
                revert(0x1c, 0x04)
            }
        }
    }

    /// @notice 将 ABI 参数 `_bytes` 中第 `_arg` 个元素解释为 `address[] calldata`。
    /// @param _bytes 包含地址数组的 ABI 编码参数。
    /// @param _arg 地址数组所在的参数槽索引。
    function toAddressArray(bytes calldata _bytes, uint256 _arg) internal pure returns (address[] calldata res) {
        (uint256 length, uint256 offset) = toLengthOffset(_bytes, _arg);
        assembly {
            res.length := length
            res.offset := offset
        }
    }

    /// @notice 将 ABI 参数 `_bytes` 中第 `_arg` 个元素解释为 `uint256[] calldata`。
    /// @param _bytes 包含 uint256 数组的 ABI 编码参数。
    /// @param _arg uint256 数组所在的参数槽索引。
    function toUint256Array(bytes calldata _bytes, uint256 _arg) internal pure returns (uint256[] calldata res) {
        (uint256 length, uint256 offset) = toLengthOffset(_bytes, _arg);
        assembly {
            res.length := length
            res.offset := offset
        }
    }

    /// @notice 解码 `EXECUTE_SUB_PLAN` 的嵌套 `commands` 与 `inputs`，语义等价于对应的 `abi.decode`。
    /// @param _bytes 包含子计划命令字节流和参数数组的 ABI 编码输入。
    function decodeCommandsAndInputs(bytes calldata _bytes) internal pure returns (bytes calldata, bytes[] calldata) {
        return _bytes.decodeActionsRouterParams();
    }
}
