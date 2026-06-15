// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// beforeSwap hook 的返回差额类型。
// 高 128 bit 是 specified token 的差额，低 128 bit 是 unspecified token 的差额，以便与 afterSwap hook 的表达方式一致。
type BeforeSwapDelta is int256;

// 使用 specified 与 unspecified 两部分差额创建 BeforeSwapDelta。
function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
    pure
    returns (BeforeSwapDelta beforeSwapDelta)
{
    assembly ("memory-safe") {
        beforeSwapDelta := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
    }
}

/// @notice 从 BeforeSwapDelta 中读取 specified 与 unspecified 差额的工具库。
library BeforeSwapDeltaLibrary {
    /// @notice 两部分差额都为 0 的 BeforeSwapDelta。
    BeforeSwapDelta public constant ZERO_DELTA = BeforeSwapDelta.wrap(0);

    /// @notice 从 beforeSwap 返回的 BeforeSwapDelta 高 128 bit 提取 specified token 差额。
    function getSpecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaSpecified) {
        assembly ("memory-safe") {
            deltaSpecified := sar(128, delta)
        }
    }

    /// @notice 从 beforeSwap/afterSwap 返回值的低 128 bit 提取 unspecified token 差额。
    function getUnspecifiedDelta(BeforeSwapDelta delta) internal pure returns (int128 deltaUnspecified) {
        assembly ("memory-safe") {
            deltaUnspecified := signextend(15, delta)
        }
    }
}
