// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice 每个 tokenId 对应一个 configId：低 255 位保存 PositionConfig 截断哈希，最高位表示是否有订阅者。
struct PositionConfigId {
    bytes32 id;
}

library PositionConfigIdLibrary {
    bytes32 constant MASK_UPPER_BIT = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    bytes32 constant DIRTY_UPPER_BIT = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @notice 返回给定 tokenId 对应的 PositionConfig 截断哈希，不含订阅标志位。
    function getConfigId(PositionConfigId storage _configId) internal view returns (bytes32 configId) {
        configId = _configId.id & MASK_UPPER_BIT;
    }

    /// @dev 配置只在铸造时设置，输入 ID 的最高位保证为 0，因此可直接覆盖完整 32 字节。
    function setConfigId(PositionConfigId storage _configId, bytes32 configId) internal {
        _configId.id = configId;
    }

    function setSubscribe(PositionConfigId storage configId) internal {
        configId.id |= DIRTY_UPPER_BIT;
    }

    function setUnsubscribe(PositionConfigId storage configId) internal {
        configId.id &= MASK_UPPER_BIT;
    }

    function hasSubscriber(PositionConfigId storage configId) internal view returns (bool subscribed) {
        bytes32 _id = configId.id;
        assembly ("memory-safe") {
            subscribed := shr(255, _id)
        }
    }
}
