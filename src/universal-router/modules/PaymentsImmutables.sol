// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {IWETH9} from '@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol';
import {IPermit2} from 'permit2/src/interfaces/IPermit2.sol';

struct PaymentsParameters {
    address permit2;
    address weth9;
}

contract PaymentsImmutables {
    /// @notice 用于 ETH 包装与解包的 WETH9 合约。
    IWETH9 internal immutable WETH9;

    /// @notice 统一管理用户 ERC20 授权与批量转账的 Permit2 合约。
    IPermit2 internal immutable PERMIT2;

    constructor(PaymentsParameters memory params) {
        WETH9 = IWETH9(params.weth9);
        PERMIT2 = IPermit2(params.permit2);
    }
}
