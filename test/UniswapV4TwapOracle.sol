// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Uniswap V4 1-hour TWAP oracle hook
/// @notice 使用同一个不可变基础币为已配置代币计价，返回统一 18 位精度的 1 小时 TWAP 价格。
/// @dev V4 PoolManager 不像 V3 Pool 一样内置 observation 数组；本合约必须作为 pool hook 使用，
///      并在 afterInitialize / afterSwap 中自行记录 tick 累计值，才能提供真正的 TWAP。
contract UniswapV4TwapOracle is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 public constant TWAP_PERIOD = 1 hours;
    uint256 private constant Q96 = 2 ** 96;

    error BaseCurrencyCannotPriceItself();
    error InvalidPool();
    error PoolNotConfigured();
    error InsufficientHistory();
    error UnsupportedDecimals();

    event PoolConfigured(address indexed token, PoolId indexed poolId, Currency baseCurrency, PoolKey poolKey);
    event ObservationRecorded(PoolId indexed poolId, uint32 timestamp, int56 tickCumulative, int24 tick);

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
        int24 tick;
    }

    struct PoolConfig {
        PoolKey key;
        PoolId poolId;
        bool enabled;
    }

    Currency public immutable baseCurrency;

    mapping(address token => PoolConfig config) private poolConfigs;
    mapping(PoolId poolId => Observation[] observations) private poolObservations;

    constructor(IPoolManager _poolManager, Currency _baseCurrency, address initialOwner)
        BaseHook(_poolManager)
        Ownable(initialOwner)
    {
        baseCurrency = _baseCurrency;
    }

    /// @notice 本 oracle 需要在建池后和每次 swap 后记录 tick。
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice 配置某个 token 的 V4 pool，pool 必须以 immutable baseCurrency 为另一边资产。
    /// @dev 如果 pool 已初始化，会立刻记录当前 tick；否则等 afterInitialize 首次记录。
    function setPool(address token, PoolKey calldata key) external onlyOwner {
        if (token == Currency.unwrap(baseCurrency)) revert BaseCurrencyCannotPriceItself();
        if (address(key.hooks) != address(this)) revert InvalidPool();

        Currency tokenCurrency = Currency.wrap(token);
        bool tokenIsCurrency0 = key.currency0 == tokenCurrency && key.currency1 == baseCurrency;
        bool tokenIsCurrency1 = key.currency1 == tokenCurrency && key.currency0 == baseCurrency;
        if (!tokenIsCurrency0 && !tokenIsCurrency1) revert InvalidPool();

        PoolKey memory keyMemory = key;
        PoolId poolId = keyMemory.toId();
        poolConfigs[token] = PoolConfig({key: keyMemory, poolId: poolId, enabled: true});

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != 0) {
            _recordObservation(poolId, tick);
        }

        emit PoolConfigured(token, poolId, baseCurrency, keyMemory);
    }

    /// @notice 返回 token 以 baseCurrency 计价的 1 小时 TWAP，统一缩放为 18 位精度。
    /// @dev 返回值含义是：1 个完整 token 的 baseCurrency 价格，按 1e18 精度表达。
    function getPrice(address token) external view returns (uint256 priceX18) {
        PoolConfig storage config = poolConfigs[token];
        if (!config.enabled) revert PoolNotConfigured();

        uint32 timestampNow = _blockTimestamp();
        if (timestampNow < TWAP_PERIOD) revert InsufficientHistory();
        uint32 targetTimestamp = timestampNow - TWAP_PERIOD;
        int56 currentCumulative = _currentTickCumulative(config.poolId, timestampNow);
        int56 pastCumulative = _tickCumulativeAt(config.poolId, targetTimestamp);
        int24 arithmeticMeanTick = int24((currentCumulative - pastCumulative) / int56(uint56(TWAP_PERIOD)));

        uint8 tokenDecimals = _currencyDecimals(Currency.wrap(token));
        uint8 baseDecimals = _currencyDecimals(baseCurrency);
        uint256 tokenUnit = 10 ** uint256(tokenDecimals);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(arithmeticMeanTick);

        uint256 rawBaseAmount;
        if (config.key.currency0 == Currency.wrap(token)) {
            rawBaseAmount = _quoteCurrency0ToCurrency1(tokenUnit, sqrtPriceX96);
        } else {
            rawBaseAmount = _quoteCurrency1ToCurrency0(tokenUnit, sqrtPriceX96);
        }

        priceX18 = _scaleTo18(rawBaseAmount, baseDecimals);
    }

    function getPool(address token) external view returns (PoolKey memory key, PoolId poolId, bool enabled) {
        PoolConfig storage config = poolConfigs[token];
        return (config.key, config.poolId, config.enabled);
    }

    function getObservationCount(PoolId poolId) external view returns (uint256) {
        return poolObservations[poolId].length;
    }

    function getObservation(PoolId poolId, uint256 index) external view returns (Observation memory) {
        return poolObservations[poolId][index];
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        _recordConfiguredPoolObservation(key, tick);
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolKey memory keyMemory = key;
        (, int24 tick,,) = poolManager.getSlot0(keyMemory.toId());
        _recordConfiguredPoolObservation(key, tick);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _recordConfiguredPoolObservation(PoolKey calldata key, int24 tick) private {
        PoolKey memory keyMemory = key;
        PoolId poolId = keyMemory.toId();
        address token = _configuredTokenForKey(key);
        PoolConfig storage config = poolConfigs[token];
        if (config.enabled && PoolId.unwrap(config.poolId) == PoolId.unwrap(poolId)) {
            _recordObservation(poolId, tick);
        }
    }

    function _configuredTokenForKey(PoolKey calldata key) private view returns (address token) {
        if (key.currency0 == baseCurrency) return Currency.unwrap(key.currency1);
        if (key.currency1 == baseCurrency) return Currency.unwrap(key.currency0);
        return address(0);
    }

    function _recordObservation(PoolId poolId, int24 tick) private {
        uint32 timestampNow = _blockTimestamp();
        Observation[] storage observations = poolObservations[poolId];
        uint256 length = observations.length;

        if (length == 0) {
            observations.push(Observation({timestamp: timestampNow, tickCumulative: 0, tick: tick}));
            emit ObservationRecorded(poolId, timestampNow, 0, tick);
            return;
        }

        Observation storage last = observations[length - 1];
        if (last.timestamp == timestampNow) {
            last.tick = tick;
            emit ObservationRecorded(poolId, timestampNow, last.tickCumulative, tick);
            return;
        }

        int56 tickCumulative = last.tickCumulative + int56(last.tick) * int56(uint56(timestampNow - last.timestamp));
        observations.push(Observation({timestamp: timestampNow, tickCumulative: tickCumulative, tick: tick}));
        emit ObservationRecorded(poolId, timestampNow, tickCumulative, tick);
    }

    function _currentTickCumulative(PoolId poolId, uint32 timestampNow) private view returns (int56) {
        Observation[] storage observations = poolObservations[poolId];
        uint256 length = observations.length;
        if (length == 0) revert InsufficientHistory();

        Observation storage last = observations[length - 1];
        return last.tickCumulative + int56(last.tick) * int56(uint56(timestampNow - last.timestamp));
    }

    function _tickCumulativeAt(PoolId poolId, uint32 targetTimestamp) private view returns (int56) {
        Observation[] storage observations = poolObservations[poolId];
        uint256 length = observations.length;
        if (length == 0 || targetTimestamp < observations[0].timestamp) revert InsufficientHistory();

        for (uint256 i = length; i > 0; i--) {
            Observation storage observation = observations[i - 1];
            if (observation.timestamp <= targetTimestamp) {
                return observation.tickCumulative + int56(observation.tick)
                    * int56(uint56(targetTimestamp - observation.timestamp));
            }
        }

        revert InsufficientHistory();
    }

    function _currencyDecimals(Currency currency) private view returns (uint8) {
        if (currency == Currency.wrap(address(0))) return 18;

        uint8 decimals = IERC20Metadata(Currency.unwrap(currency)).decimals();
        if (decimals > 38) revert UnsupportedDecimals();
        return decimals;
    }

    function _quoteCurrency0ToCurrency1(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(amount0, uint256(sqrtPriceX96), Q96);
        return FullMath.mulDiv(intermediate, uint256(sqrtPriceX96), Q96);
    }

    function _quoteCurrency1ToCurrency0(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 intermediate = FullMath.mulDiv(amount1, Q96, uint256(sqrtPriceX96));
        return FullMath.mulDiv(intermediate, Q96, uint256(sqrtPriceX96));
    }

    function _scaleTo18(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** uint256(18 - decimals));
        return amount / (10 ** uint256(decimals - 18));
    }

    function _blockTimestamp() private view returns (uint32) {
        return uint32(block.timestamp);
    }
}
