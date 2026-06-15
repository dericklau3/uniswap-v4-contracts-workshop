// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPermit2Forwarder, IAllowanceTransfer} from "../interfaces/IPermit2Forwarder.sol";

/// @notice 将单笔或批量 Permit2 授权转发给 Permit2，便于与后续 V4 动作放入同一 multicall。
/// @dev 本合约不强制 permit 中的 spender 必须是自身，但正常集成应把本合约设为 spender。
contract Permit2Forwarder is IPermit2Forwarder {
    /// @notice 接收并记录授权的 Permit2 合约。
    IAllowanceTransfer public immutable permit2;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    /// @notice 向 Permit2 转发一笔代币额度授权。
    /// @param owner 代币所有者和签名者。
    /// @param permitSingle 单笔 Permit2 授权数据。
    /// @param signature 对授权数据的签名。
    /// @return err Permit2 调用失败时的原始错误数据；成功时为空。
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // permit 可能被抢先提交；捕获错误可避免已生效授权让整个 multicall 遭受拒绝服务。
        try permit2.permit(owner, permitSingle, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }

    /// @notice 向 Permit2 转发一组批量代币额度授权。
    /// @param owner 代币所有者和签名者。
    /// @param _permitBatch 批量 Permit2 授权数据。
    /// @param signature 对批量授权数据的签名。
    /// @return err Permit2 调用失败时的原始错误数据；成功时为空。
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
        returns (bytes memory err)
    {
        // 捕获被抢先使用等错误，使同一 multicall 中后续动作仍可利用已经存在的授权。
        try permit2.permit(owner, _permitBatch, signature) {}
        catch (bytes memory reason) {
            err = reason;
        }
    }
}
