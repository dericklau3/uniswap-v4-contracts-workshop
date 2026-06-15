// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {PositionInfo} from "./libraries/PositionInfoLibrary.sol";
import {Descriptor} from "./libraries/Descriptor.sol";
import {CurrencyRatioSortOrder} from "./libraries/CurrencyRatioSortOrder.sol";
import {SafeCurrencyMetadata} from "./libraries/SafeCurrencyMetadata.sol";

/// @title V4 仓位 NFT 描述器
/// @notice 根据仓位池、价格区间、当前价格和货币元数据，生成内联 JSON/SVG 的 ERC-721 data URI。
contract PositionDescriptor is IPositionDescriptor {
    using StateLibrary for IPoolManager;

    // 以太坊主网常用资产地址，用于决定价格比率的展示方向。
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address public immutable wrappedNative;
    bytes32 private immutable nativeCurrencyLabelBytes;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager, address _wrappedNative, bytes32 _nativeCurrencyLabelBytes) {
        poolManager = _poolManager;
        wrappedNative = _wrappedNative;
        nativeCurrencyLabelBytes = _nativeCurrencyLabelBytes;
    }

    /// @notice 将构造时保存的 bytes32 原生币标签转换为紧凑字符串。
    function nativeCurrencyLabel() public view returns (string memory) {
        uint256 len = 0;
        while (len < 32 && nativeCurrencyLabelBytes[len] != 0) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = nativeCurrencyLabelBytes[i];
        }
        return string(b);
    }

    /// @notice 为指定 V4 仓位 NFT 生成符合 ERC-721 标准的元数据 URI。
    /// @param positionManager 持有仓位信息和 PoolKey 的 PositionManager。
    /// @param tokenId 要描述的仓位 NFT；不存在或已销毁时回退。
    /// @return 包含内联 JSON 元数据和 SVG 图像的 data URI。
    function tokenURI(IPositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (positionInfo.poolId() == 0) {
            revert InvalidTokenId(tokenId);
        }
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);

        // 尽量把价值尺度更大的资产作为 base，使 quote/base 的价格数值更符合常见阅读习惯。
        // 当 currency0 的展示优先级高于 currency1 时翻转默认顺序。
        bool _flipRatio = flipRatio(currency0, currency1);

        // 不翻转：currency1 为 quote、currency0 为 base；翻转后两者对调。
        address quoteCurrency = !_flipRatio ? currency1 : currency0;
        address baseCurrency = !_flipRatio ? currency0 : currency1;

        return Descriptor.constructTokenURI(
            Descriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                quoteCurrency: quoteCurrency,
                baseCurrency: baseCurrency,
                quoteCurrencySymbol: SafeCurrencyMetadata.currencySymbol(quoteCurrency, nativeCurrencyLabel()),
                baseCurrencySymbol: SafeCurrencyMetadata.currencySymbol(baseCurrency, nativeCurrencyLabel()),
                quoteCurrencyDecimals: SafeCurrencyMetadata.currencyDecimals(quoteCurrency),
                baseCurrencyDecimals: SafeCurrencyMetadata.currencyDecimals(baseCurrency),
                flipRatio: _flipRatio,
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                tickCurrent: tick,
                tickSpacing: poolKey.tickSpacing,
                fee: poolKey.fee,
                poolManager: address(poolManager),
                hooks: address(poolKey.hooks)
            })
        );
    }

    /// @notice 判断展示价格时是否应交换 currency0 与 currency1 的分子分母位置。
    /// @param currency0 池的第一种货币。
    /// @param currency1 池的第二种货币。
    /// @return currency0 展示优先级更高时返回 true。
    function flipRatio(address currency0, address currency1) public view returns (bool) {
        return currencyRatioPriority(currency0) > currencyRatioPriority(currency1);
    }

    /// @notice 返回货币在价格比率展示中的优先级。
    /// @param currency 要评估的货币地址，零地址代表原生币。
    /// @return 正值更倾向放在价格分子，负值更倾向放在分母，0 表示无特殊偏好。
    function currencyRatioPriority(address currency) public view returns (int256) {
        // 主网展示顺序：USDC、USDT、DAI、(ETH, WETH)、TBTC、WBTC。
        // 各链包装原生币地址不同，因此通过构造参数注入。

        // 原生币与其包装版本使用相同展示层级。
        if (currency == address(0) || currency == wrappedNative) {
            return CurrencyRatioSortOrder.DENOMINATOR;
        }
        if (block.chainid == 1) {
            if (currency == USDC) {
                return CurrencyRatioSortOrder.NUMERATOR_MOST;
            } else if (currency == USDT) {
                return CurrencyRatioSortOrder.NUMERATOR_MORE;
            } else if (currency == DAI) {
                return CurrencyRatioSortOrder.NUMERATOR;
            } else if (currency == TBTC) {
                return CurrencyRatioSortOrder.DENOMINATOR_MORE;
            } else if (currency == WBTC) {
                return CurrencyRatioSortOrder.DENOMINATOR_MOST;
            }
        }
        return 0;
    }
}
