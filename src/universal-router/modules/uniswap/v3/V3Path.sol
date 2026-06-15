// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.6.0;

import {BytesLib} from './BytesLib.sol';
import {Constants} from '../../../libraries/Constants.sol';

/// @title Uniswap V3 多 hop path 操作库
library V3Path {
    using BytesLib for bytes;

    /// @notice 判断编码 path 是否至少包含两个 V3 pool。
    /// @param path 紧凑编码的 swap path。
    /// @return 包含两个或更多 pool 时为 true，否则为 false。
    function hasMultiplePools(bytes calldata path) internal pure returns (bool) {
        return path.length >= Constants.MULTIPLE_V3_POOLS_MIN_LENGTH;
    }

    /// @notice 解码 path 最前面的 `tokenA | fee | tokenB` pool 段。
    /// @param path bytes 紧凑编码的 swap path。
    /// @return tokenA 当前 pool 段的第一个 token。
    /// @return fee 当前 pool 的 fee tier。
    /// @return tokenB 当前 pool 段的第二个 token。
    function decodeFirstPool(bytes calldata path) internal pure returns (address, uint24, address) {
        return path.toPool();
    }

    /// @notice 截取 path 中定位第一个 V3 pool 所需的完整 43 字节片段。
    /// @param path bytes 紧凑编码的 swap path。
    /// @return 包含首个 pool 的 tokenA、fee 与 tokenB 的片段。
    function getFirstPool(bytes calldata path) internal pure returns (bytes calldata) {
        return path[:Constants.V3_POP_OFFSET];
    }

    function decodeFirstToken(bytes calldata path) internal pure returns (address tokenA) {
        tokenA = path.toAddress();
    }

    /// @notice 跳过一个 `token + fee` 段，使下一个 token 成为新 path 的起点。
    /// @dev 精确输入按正向逐 hop 推进；精确输出 path 本身按反向编码，回调中也用相同切片方式推进。
    /// @param path 当前 swap path。
    function skipToken(bytes calldata path) internal pure returns (bytes calldata) {
        return path[Constants.NEXT_V3_POOL_OFFSET:];
    }
}
