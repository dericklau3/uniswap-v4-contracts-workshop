// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

/// @title 始终回滚的占位合约
/// @notice 部署到某条链不支持的协议地址位，确保 Universal Router 误调用该协议时明确回滚。
contract UnsupportedProtocol {
    error UnsupportedProtocolError();

    fallback() external {
        revert UnsupportedProtocolError();
    }
}
