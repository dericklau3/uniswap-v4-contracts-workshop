// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {EIP712_v4} from "./EIP712_v4.sol";
import {ERC721PermitHash} from "../libraries/ERC721PermitHash.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {IERC721Permit_v4} from "../interfaces/IERC721Permit_v4.sol";
import {UnorderedNonce} from "./UnorderedNonce.sol";

/// @title 支持 Permit 的 ERC-721
/// @notice 允许 NFT 持有人通过 EIP-712 签名授权单个 token 或全局 operator，无需本人发送授权交易。
abstract contract ERC721Permit_v4 is ERC721, IERC721Permit_v4, EIP712_v4, UnorderedNonce {
    using SignatureVerification for bytes;

    /// @notice 初始化 ERC-721 元数据，并用名称建立 EIP-712 域。
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) EIP712_v4(name_) {}

    /// @notice 要求当前区块时间不晚于签名截止时间。
    modifier checkSignatureDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert SignatureDeadlineExpired();
        _;
    }

    /// @notice 使用持有人签名授权 `spender` 管理指定 NFT。
    /// @param spender 获得该 NFT 操作权的地址。
    /// @param tokenId 被授权的 NFT ID。
    /// @param deadline 签名最晚可上链时间。
    /// @param nonce 持有人的无序 nonce，高 248 位定位 bitmap 字，低 8 位定位其中一位。
    /// @param signature 持有人生成的 secp256k1 签名。
    /// @dev 验证成功后消费 nonce，再写入授权；同一签名无法重复使用。
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable
        checkSignatureDeadline(deadline)
    {
        // SignatureVerification.verify 会同时拒绝 owner 为零地址的不存在 token。
        address owner = _ownerOf[tokenId];

        bytes32 digest = ERC721PermitHash.hashPermit(spender, tokenId, nonce, deadline);
        signature.verify(_hashTypedData(digest), owner);

        _useUnorderedNonce(owner, nonce);
        _approve(owner, spender, tokenId);
    }

    /// @notice 使用 owner 签名授予或撤销 operator 对其全部 NFT 的操作权。
    /// @param owner 签名并拥有 NFT 的账户。
    /// @param operator 要设置的全局操作员。
    /// @param approved true 表示授权，false 表示撤销。
    /// @param deadline 签名最晚可上链时间。
    /// @param nonce owner 的无序 nonce。
    /// @param signature owner 生成的 secp256k1 签名。
    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external payable checkSignatureDeadline(deadline) {
        bytes32 digest = ERC721PermitHash.hashPermitForAll(operator, approved, nonce, deadline);
        signature.verify(_hashTypedData(digest), owner);

        _useUnorderedNonce(owner, nonce);
        _approveForAll(owner, operator, approved);
    }

    /// @notice 授予或撤销第三方 operator 管理 `msg.sender` 全部 NFT 的权限。
    /// @dev 发出 `ApprovalForAll`；每个 owner 可同时配置多个 operator。
    /// 覆盖 Solmate 实现，使直接授权和签名授权共用 `_approveForAll` 状态写入路径。
    /// @param operator 要配置的操作员地址。
    /// @param approved true 表示授权，false 表示撤销。
    function setApprovalForAll(address operator, bool approved) public override {
        _approveForAll(msg.sender, operator, approved);
    }

    function _approveForAll(address owner, address operator, bool approved) internal {
        isApprovedForAll[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /// @notice 修改或重申某一 NFT 的单独授权地址。
    /// @dev 覆盖 Solmate 实现，使 `approve()` 与 `permit()` 共用 `_approve`。
    /// `spender` 为零地址时清除现有授权；只有 NFT owner 或其全局 operator 可以调用。
    /// @param spender 新的 NFT 控制者。
    /// @param id 要授权的 NFT token ID。
    function approve(address spender, uint256 id) public override {
        address owner = _ownerOf[id];

        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert Unauthorized();

        _approve(owner, spender, id);
    }

    function _approve(address owner, address spender, uint256 id) internal {
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        return
            spender == ownerOf(tokenId) || getApproved[tokenId] == spender
                || isApprovedForAll[ownerOf(tokenId)][spender];
    }
}
