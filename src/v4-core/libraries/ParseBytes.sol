// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @notice 解析 hook 返回的 bytes，以及用于校验 hook 返回值的函数 selector。
/// @dev parseSelector 也用于解析期望的 selector。所有 hook 返回值只会采用以下三种形态之一：
///      bytes4、(bytes4, 32-byte-delta) 或 (bytes4, 32-byte-delta, uint24)。
library ParseBytes {
    function parseSelector(bytes memory result) internal pure returns (bytes4 selector) {
        // 等价于：(selector,) = abi.decode(result, (bytes4, int256));
        assembly ("memory-safe") {
            selector := mload(add(result, 0x20))
        }
    }

    function parseFee(bytes memory result) internal pure returns (uint24 lpFee) {
        // 等价于：(,, lpFee) = abi.decode(result, (bytes4, int256, uint24));
        assembly ("memory-safe") {
            lpFee := mload(add(result, 0x60))
        }
    }

    function parseReturnDelta(bytes memory result) internal pure returns (int256 hookReturn) {
        // 等价于：(, hookReturnDelta) = abi.decode(result, (bytes4, int256));
        assembly ("memory-safe") {
            hookReturn := mload(add(result, 0x40))
        }
    }
}
