// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library ERC721PermitHash {
    /// @dev 数值等于 keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)")。
    bytes32 constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @dev 数值等于 keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)")。
    bytes32 constant PERMIT_FOR_ALL_TYPEHASH = 0x6673cb397ee2a50b6b8401653d3638b4ac8b3db9c28aa6870ffceb7574ec2f76;

    /// @notice 计算 `IERC721Permit_v4.permit()` 所签结构体的 EIP-712 数据哈希。
    /// @param spender 获得 tokenId 操作权的地址。
    /// @param tokenId 被授权的 NFT。
    /// @param nonce 防止签名重放的唯一无序 nonce。
    /// @param deadline 签名失效时间。
    /// @return digest 待签结构体哈希，等价于 `keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))`。
    function hashPermit(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // 等价于 keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))。
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_TYPEHASH)
            mstore(add(fmp, 0x20), and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), tokenId)
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // 清理临时内存。
            mstore(fmp, 0) // fmp held PERMIT_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held spender
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held tokenId
            mstore(add(fmp, 0x60), 0) // fmp+0x60 held nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 held deadline
        }
    }

    /// @notice 计算全局 operator Permit 所签结构体的 EIP-712 数据哈希。
    /// @param operator 可管理 owner 全部 tokenId 的地址。
    /// @param approved true 表示授予完整权限，false 表示撤销。
    /// @param nonce 防止签名重放的唯一无序 nonce。
    /// @param deadline 签名失效时间。
    /// @return digest 等价于 `keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline))`。
    function hashPermitForAll(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32 digest)
    {
        // 等价于 keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline))。
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(fmp, PERMIT_FOR_ALL_TYPEHASH)
            mstore(add(fmp, 0x20), and(operator, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(fmp, 0x40), and(approved, 0x1))
            mstore(add(fmp, 0x60), nonce)
            mstore(add(fmp, 0x80), deadline)
            digest := keccak256(fmp, 0xa0)

            // 清理临时内存。
            mstore(fmp, 0) // fmp held PERMIT_FOR_ALL_TYPEHASH
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held operator
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held approved
            mstore(add(fmp, 0x60), 0) // fmp+0x60 held nonce
            mstore(add(fmp, 0x80), 0) // fmp+0x80 held deadline
        }
    }
}
