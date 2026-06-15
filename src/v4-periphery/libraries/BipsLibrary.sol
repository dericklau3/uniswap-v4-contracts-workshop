// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title 基点比例计算库，用 10,000 基点表示 100%。
library BipsLibrary {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice 比例超过 10,000 基点时回退。
    error InvalidBips();

    /// @param amount 计算比例所依据的总数量。
    /// @param bips 要计算的比例，单位为基点。
    function calculatePortion(uint256 amount, uint256 bips) internal pure returns (uint256) {
        if (bips > BPS_DENOMINATOR) revert InvalidBips();
        return (amount * bips) / BPS_DENOMINATOR;
    }
}
