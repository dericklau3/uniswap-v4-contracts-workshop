// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice 在 transient storage 中保存 V3 精确输出 swap 允许消耗的最大输入量，用于回调结算时检查滑点。
library MaxInputAmount {
    // 瞬态保存最大输入量的槽位。bytes32(uint256(keccak256("MaxAmountIn")) - 1)
    bytes32 constant MAX_AMOUNT_IN_SLOT = 0xaf28d9864a81dfdf71cab65f4e5d79a0cf9b083905fb8971425e6cb581b3f692;

    function set(uint256 maxAmountIn) internal {
        assembly ('memory-safe') {
            tstore(MAX_AMOUNT_IN_SLOT, maxAmountIn)
        }
    }

    function get() internal view returns (uint256 maxAmountIn) {
        assembly ('memory-safe') {
            maxAmountIn := tload(MAX_AMOUNT_IN_SLOT)
        }
    }
}
