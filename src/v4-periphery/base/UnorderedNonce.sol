// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUnorderedNonce} from "../interfaces/IUnorderedNonce.sol";

/// @title 无序 Nonce
/// @notice 用 bitmap 管理签名 nonce，使用户可并行签署和独立撤销，不必按递增顺序使用。
contract UnorderedNonce is IUnorderedNonce {
    /// @notice 记录每个 owner 已消费的 nonce 位图；每个 word 容纳 256 个 nonce。
    mapping(address owner => mapping(uint256 word => uint256 bitmap)) public nonces;

    /// @notice 消费一个 nonce；若对应位已经置位，则回退。
    /// @param owner nonce 所属的签名者地址。
    /// @param nonce 要消费的 nonce；高 248 位是 word 索引，低 8 位是该 word 中的 bit 位置。
    function _useUnorderedNonce(address owner, uint256 nonce) internal {
        uint256 wordPos = nonce >> 8;
        uint256 bitPos = uint8(nonce);

        uint256 bit = 1 << bitPos;
        uint256 flipped = nonces[owner][wordPos] ^= bit;
        if (flipped & bit == 0) revert NonceAlreadyUsed();
    }

    /// @notice 由调用者主动消费一个尚未上链的 nonce，使相关签名永久失效。
    /// @param nonce 要撤销的无序 nonce。
    function revokeNonce(uint256 nonce) external payable {
        _useUnorderedNonce(msg.sender, nonce);
    }
}
