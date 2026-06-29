// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @dev `PositionInfo` 是仓位信息的压缩表示，把多个字段放入一个 uint256，减少存储槽和内存开销。
 *
 * 布局：
 * 200 bits poolId | 24 bits tickUpper | 24 bits tickLower | 8 bits hasSubscriber
 *
 * 从最低有效位向高位依次为：
 *
 * tokenId 是否绑定订阅者的标志：
 * uint8 hasSubscriber;
 *
 * 仓位上界：
 * int24 tickUpper;
 *
 * 仓位下界：
 * int24 tickLower;
 *
 * 截断后的 poolId：取原 bytes32 最高 200 位，仅用于在 `poolKeys` 映射中查找完整 PoolKey：
 * bytes25 poolId;
 *
 * 注意：若未来需要更多位，hasSubscriber 实际可以压缩为单个 bit。
 */
type PositionInfo is uint256;

using PositionInfoLibrary for PositionInfo global;

library PositionInfoLibrary {
    PositionInfo internal constant EMPTY_POSITION_INFO = PositionInfo.wrap(0);

    uint256 internal constant MASK_UPPER_200_BITS = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;
    uint256 internal constant MASK_8_BITS = 0xFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint256 internal constant SET_UNSUBSCRIBE = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00;
    uint256 internal constant SET_SUBSCRIBE = 0x01;
    uint8 internal constant TICK_LOWER_OFFSET = 8;
    uint8 internal constant TICK_UPPER_OFFSET = 32;

    /// @dev 该 poolId 已截断为 25 字节，与 V4 core 的完整 PoolId 不兼容，只能用于查询 `poolKeys` 映射。
    function poolId(PositionInfo info) internal pure returns (bytes25 _poolId) {
        assembly ("memory-safe") {
            _poolId := and(MASK_UPPER_200_BITS, info)
        }
    }

    function tickLower(PositionInfo info) internal pure returns (int24 _tickLower) {
        assembly ("memory-safe") {
            _tickLower := signextend(2, shr(TICK_LOWER_OFFSET, info))
        }
    }

    function tickUpper(PositionInfo info) internal pure returns (int24 _tickUpper) {
        assembly ("memory-safe") {
            _tickUpper := signextend(2, shr(TICK_UPPER_OFFSET, info))
        }
    }

    function hasSubscriber(PositionInfo info) internal pure returns (bool _hasSubscriber) {
        assembly ("memory-safe") {
            _hasSubscriber := and(MASK_8_BITS, info)
        }
    }

    /// @dev 纯函数只返回设置订阅标志后的新值，不会直接写入存储。
    function setSubscribe(PositionInfo info) internal pure returns (PositionInfo _info) {
        assembly ("memory-safe") {
            _info := or(info, SET_SUBSCRIBE)
        }
    }

    /// @dev 纯函数只返回清除订阅标志后的新值，不会直接写入存储。
    function setUnsubscribe(PositionInfo info) internal pure returns (PositionInfo _info) {
        assembly ("memory-safe") {
            _info := and(info, SET_UNSUBSCRIBE)
        }
    }

    /// @notice 创建新仓位的默认压缩 PositionInfo。
    /// @dev 铸造仓位时调用；订阅标志默认关闭。
    /// @param _poolKey 仓位所属池键。
    /// @param _tickLower 仓位价格区间下界。
    /// @param _tickUpper 仓位价格区间上界。
    /// @return info 包含截断 poolId、上下 tick 和 false 订阅标志的压缩值。
    function initialize(PoolKey memory _poolKey, int24 _tickLower, int24 _tickUpper)
        internal
        pure 
        returns (PositionInfo info)
    {
        bytes25 _poolId = bytes25(PoolId.unwrap(_poolKey.toId()));
        assembly {
            info := or(
                or(and(MASK_UPPER_200_BITS, _poolId), shl(TICK_UPPER_OFFSET, and(MASK_24_BITS, _tickUpper))),
                shl(TICK_LOWER_OFFSET, and(MASK_24_BITS, _tickLower))
            )
        }
    }
}
