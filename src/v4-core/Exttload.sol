// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExttload} from "./interfaces/IExttload.sol";

/// @notice 向外部合约开放按槽位读取瞬态存储的能力，以便高效查看本次交易内的结算状态。
/// @dev 瞬态存储会在交易结束后自动清空，调用方需要自行理解槽位布局并解码返回值。
/// https://eips.ethereum.org/EIPS/eip-2330#rationale
abstract contract Exttload is IExttload {
    /// @notice 读取一个指定的瞬态存储槽位。
    /// @param slot 要执行 `tload` 的槽位键。
    /// @return value 该槽位中的原始 `bytes32` 值。
    function exttload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, tload(slot))
            return(0, 0x20)
        }
    }

    /// @notice 批量读取一组不连续的瞬态存储槽位。
    /// @dev 返回值顺序与 `slots` 输入顺序一致，可用于读取 currency delta、锁状态等交易内数据。
    /// @param slots 要执行 `tload` 的槽位键列表。
    /// @return values 各槽位对应的原始值列表。
    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
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
                mstore(memptr, tload(calldataload(calldataptr)))
                memptr := add(memptr, 0x20)
                calldataptr := add(calldataptr, 0x20)
                if iszero(lt(memptr, end)) { break }
            }
            return(start, sub(end, start))
        }
    }
}
