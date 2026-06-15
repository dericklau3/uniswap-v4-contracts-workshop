// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IMulticall_v4} from "../interfaces/IMulticall_v4.sol";

/// @title V4 多调用
/// @notice 通过 delegatecall 在一次交易中按顺序执行本合约的多个方法，并原子返回全部结果。
abstract contract Multicall_v4 is IMulticall_v4 {
    /// @notice 依次调用本合约的多个编码方法，任一子调用失败则整批回退。
    /// @param data 每个子调用的 calldata。
    /// @return results 与输入顺序一致的返回数据数组。
    /// @dev 所有 delegatecall 看到相同的 `msg.sender` 和 `msg.value`；子调用应按合约实时余额判断可用 ETH。
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                // 原样向上传递失败子调用的 revert 数据，保留具体错误。
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }

            results[i] = result;
        }
    }
}
