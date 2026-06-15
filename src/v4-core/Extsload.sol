// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IExtsload} from "./interfaces/IExtsload.sol";

/// @notice 向外部合约开放按槽位读取永久存储的能力，以便高效获取 PoolManager 的细粒度状态。
/// @dev 调用方需要自行理解存储布局并解码返回值；此能力主要供 StateLibrary 等只读集成使用。
/// https://eips.ethereum.org/EIPS/eip-2330#rationale
abstract contract Extsload is IExtsload {
    /// @notice 读取一个指定的永久存储槽位。
    /// @param slot 要执行 `sload` 的槽位键。
    /// @return value 该槽位中的原始 `bytes32` 值。
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 0x20)
        }
    }

    /// @notice 从 `startSlot` 开始连续读取 `nSlots` 个永久存储槽位。
    /// @dev 连续读取适合一次取回紧邻存储的数据，可减少多次外部调用的 gas。
    /// @param startSlot 连续读取的起始槽位键。
    /// @param nSlots 要读取并写入返回数组的槽位数量。
    /// @return values 按槽位递增顺序返回的原始值列表。
    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // 左移 5 位等价于乘以 32，但消耗的 gas 更少。
            let length := shl(5, nSlots)
            // 返回数据中动态数组的 ABI offset 为 32。
            mstore(memptr, 0x20)
            // 写入返回数组的长度。
            mstore(add(memptr, 0x20), nSlots)
            // 将 memptr 移到第一个结果元素的位置。
            memptr := add(memptr, 0x40)
            let end := add(memptr, length)
            for {} 1 {} {
                mstore(memptr, sload(startSlot))
                memptr := add(memptr, 0x20)
                startSlot := add(startSlot, 1)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }

    /// @notice 批量读取一组不连续的永久存储槽位。
    /// @dev 返回值顺序与 `slots` 输入顺序一致，适合一次读取分散在不同位置的池状态。
    /// @param slots 要执行 `sload` 的槽位键列表。
    /// @return values 各槽位对应的原始值列表。
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        assembly ("memory-safe") {
            let memptr := mload(0x40)
            let start := memptr
            // 按 ABI 编码返回值：动态数组内容从 offset 0x20 开始。
            mstore(memptr, 0x20)
            // 接着写入返回数组长度。
            mstore(add(memptr, 0x20), slots.length)
            // 将 memptr 移到第一个数组元素的位置。
            memptr := add(memptr, 0x40)
            // 左移 5 位等价于乘以 32，但消耗的 gas 更少。
            let end := add(memptr, shl(5, slots.length))
            let calldataptr := slots.offset
            for {} 1 {} {
                mstore(memptr, sload(calldataload(calldataptr)))
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }
}
