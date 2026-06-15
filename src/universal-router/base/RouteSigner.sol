// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';

/// @title 路由签名上下文
/// @notice 使用 EIP-712 验证整组 Universal Router 命令，并用 transient storage 管理仅本交易有效的签名上下文。
abstract contract RouteSigner is EIP712 {
    /// @notice 保存路由签名者地址的瞬态存储槽。
    /// @dev bytes32(uint256(keccak256("RouteSigner")) - 1)
    bytes32 private constant ROUTE_SIGNER_SLOT = 0xd317c76a4357223a1868125ee857a1f31cabfcec288f6cdd0ea8c52b6a71ee31;

    /// @notice 保存应用业务意图的瞬态存储槽。
    /// @dev bytes32(uint256(keccak256("RouteIntent")) - 1)
    bytes32 private constant ROUTE_INTENT_SLOT = 0xa42de8dec63499ed8713dc6815ea14006a1f8e80e1664c66e3beb461bb65b0da;

    /// @notice 保存应用附加数据的瞬态存储槽。
    /// @dev bytes32(uint256(keccak256("RouteData")) - 1)
    bytes32 private constant ROUTE_DATA_SLOT = 0x17350132762f24cc4b86e10621ea1e0b5c33483a51cca86a1b11e7ed029b6eb6;

    /// @notice 签名执行所使用的 EIP-712 类型哈希。
    bytes32 internal constant EXECUTE_SIGNED_TYPEHASH = keccak256(
        'ExecuteSigned(bytes commands,bytes[] inputs,bytes32 intent,bytes32 data,address sender,bytes32 nonce,uint256 deadline)'
    );

    /// @notice 记录每个签名者已经消费的 nonce，用于防止同一路由签名被重复执行。
    /// @dev 使用无序 nonce，不要求签名按顺序上链，因此多个独立路由可以并行提交。
    mapping(address user => mapping(bytes32 nonce => bool used)) public noncesUsed;

    /// @notice 签名者的指定 nonce 已被消费时抛出。
    error NonceAlreadyUsed();

    /// @dev 对命令及全部输入构造 EIP-712 摘要，恢复签名者、消费 nonce，并把
    /// `(signer, intent, data)` 写入 transient storage，供本次命令链读取。
    function _setSignatureContext(
        bytes calldata commands,
        bytes[] calldata inputs,
        bytes32 intent,
        bytes32 data,
        bool verifySender,
        bytes32 nonce,
        bytes calldata signature,
        uint256 deadline
    ) internal returns (address signer) {
        // 按 EIP-712 数组规则先逐项哈希，再拼接所有元素哈希并整体哈希，确保每份命令参数都受签名保护。
        uint256 inputsLength = inputs.length;
        bytes32[] memory inputHashes = new bytes32[](inputsLength);
        for (uint256 i = 0; i < inputsLength; ++i) {
            inputHashes[i] = keccak256(inputs[i]);
        }
        bytes32 inputsHash = keccak256(abi.encodePacked(inputHashes));

        // 可选择把交易提交者绑定进签名；不绑定时使用 `address(0)`，允许 relayer 代提交。
        address sender = verifySender ? msg.sender : address(0);

        // 组合命令、输入、业务上下文、提交者、nonce 和截止时间，生成最终 EIP-712 摘要。
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_SIGNED_TYPEHASH, keccak256(commands), inputsHash, intent, data, sender, nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        // 从签名恢复实际授权本次路由的地址。
        signer = ECDSA.recover(digest, signature);

        // 检查并立即消费 nonce；最大值是显式跳过防重放记录的哨兵值。
        if (nonce != bytes32(type(uint256).max)) {
            if (noncesUsed[signer][nonce]) revert NonceAlreadyUsed();
            noncesUsed[signer][nonce] = true;
        }

        // 将签名上下文限制在当前交易内，避免永久存储成本，也不会跨交易残留。
        assembly ('memory-safe') {
            tstore(ROUTE_SIGNER_SLOT, signer)
            tstore(ROUTE_INTENT_SLOT, intent)
            tstore(ROUTE_DATA_SLOT, data)
        }
    }

    /// @dev 清空本次签名执行写入的瞬态上下文，使后续非签名调用读到零值。
    function _resetSignatureContext() internal {
        assembly ('memory-safe') {
            tstore(ROUTE_SIGNER_SLOT, 0)
            tstore(ROUTE_INTENT_SLOT, 0)
            tstore(ROUTE_DATA_SLOT, 0)
        }
    }

    /// @dev 从 transient storage 读取当前签名路由的 `(signer, intent, data)`。
    function _signedRouteContext() internal view returns (address signer, bytes32 intent, bytes32 data) {
        assembly ('memory-safe') {
            signer := tload(ROUTE_SIGNER_SLOT)
            intent := tload(ROUTE_INTENT_SLOT)
            data := tload(ROUTE_DATA_SLOT)
        }
    }
}
