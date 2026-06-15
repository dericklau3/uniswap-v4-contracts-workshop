// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

struct UniswapParameters {
    address v2Factory;
    address v3Factory;
    bytes32 pairInitCodeHash;
    bytes32 poolInitCodeHash;
}

contract UniswapImmutables {
    /// @notice Uniswap V2 Factory 地址，用于确定性计算 Pair 地址。
    address internal immutable UNISWAP_V2_FACTORY;

    /// @notice Uniswap V2 Pair init code hash，与 Factory 一起用于 CREATE2 地址推导。
    bytes32 internal immutable UNISWAP_V2_PAIR_INIT_CODE_HASH;

    /// @notice Uniswap V3 Factory 地址，用于确定性计算 Pool 地址。
    address internal immutable UNISWAP_V3_FACTORY;

    /// @notice Uniswap V3 Pool init code hash，与 Factory、token 和 fee 一起用于 CREATE2 地址推导。
    bytes32 internal immutable UNISWAP_V3_POOL_INIT_CODE_HASH;

    constructor(UniswapParameters memory params) {
        UNISWAP_V2_FACTORY = params.v2Factory;
        UNISWAP_V2_PAIR_INIT_CODE_HASH = params.pairInitCodeHash;
        UNISWAP_V3_FACTORY = params.v3Factory;
        UNISWAP_V3_POOL_INIT_CODE_HASH = params.poolInitCodeHash;
    }
}
