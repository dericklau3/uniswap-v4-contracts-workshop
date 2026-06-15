// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "./PoolKey.sol";

type PoolId is bytes32;

/// @notice 根据 PoolKey 计算唯一 PoolId 的工具库。
library PoolIdLibrary {
    /// @notice 返回与 `keccak256(abi.encode(poolKey))` 相等的池标识。
    function toId(PoolKey memory poolKey) internal pure returns (PoolId poolId) {
        assembly ("memory-safe") {
            // PoolKey 由 5 个 32 byte 槽位组成，总长度为 0xa0。
            poolId := keccak256(poolKey, 0xa0)
        }
    }
}
