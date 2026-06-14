// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDeployScript} from "./BaseDeployScript.sol";

import {PoolManager} from "../src/v4-core/PoolManager.sol";
import {PositionDescriptor} from "../src/v4-periphery/PositionDescriptor.sol";
import {PositionManager} from "../src/v4-periphery/PositionManager.sol";
import {StateView} from "../src/v4-periphery/lens/StateView.sol";
import {V4Quoter} from "../src/v4-periphery/lens/V4Quoter.sol";
import {UniversalRouter} from "../src/universal-router/UniversalRouter.sol";
import {RouterParameters} from "../src/universal-router/types/RouterParameters.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "../src/v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "../src/v4-periphery/interfaces/external/IWETH9.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract UniswapV4DeployScript is BaseDeployScript {
    bytes32 internal constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct Deployment {
        PoolManager poolManager;
        PositionDescriptor positionDescriptorImplementation;
        IPositionDescriptor positionDescriptor;
        ProxyAdmin positionDescriptorProxyAdmin;
        PositionManager positionManager;
        StateView stateView;
        V4Quoter v4Quoter;
        UniversalRouter universalRouter;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATEKEY");
        address owner = vm.addr(privateKey);
        Config memory cfg = _getConfig();

        vm.startBroadcast(privateKey);
        deployment = _deploySuite(owner, cfg);
        vm.stopBroadcast();

        _saveDeployment(deployment);
    }

    function _deploySuite(address owner, Config memory cfg) internal returns (Deployment memory deployment) {
        deployment.poolManager = new PoolManager(owner);

        IPoolManager poolManager = IPoolManager(address(deployment.poolManager));
        deployment.positionDescriptorImplementation =
            new PositionDescriptor(poolManager, cfg.weth, cfg.nativeCurrencyLabel);

        TransparentUpgradeableProxy positionDescriptorProxy =
            new TransparentUpgradeableProxy(address(deployment.positionDescriptorImplementation), owner, "");
        deployment.positionDescriptor = IPositionDescriptor(address(positionDescriptorProxy));
        deployment.positionDescriptorProxyAdmin =
            ProxyAdmin(address(uint160(uint256(vm.load(address(positionDescriptorProxy), ERC1967_ADMIN_SLOT)))));

        deployment.positionManager = new PositionManager(
            poolManager,
            IAllowanceTransfer(cfg.permit2),
            cfg.unsubscribeGasLimit,
            deployment.positionDescriptor,
            IWETH9(cfg.weth)
        );
        deployment.stateView = new StateView(poolManager);
        deployment.v4Quoter = new V4Quoter(poolManager);

        // This deployment only supports standard V4 swaps. V2, V3,
        // permissioned pools, position migration, and Across are disabled.
        deployment.universalRouter = new UniversalRouter(
            RouterParameters({
                permit2: cfg.permit2,
                weth9: cfg.weth,
                v2Factory: address(0),
                v3Factory: address(0),
                pairInitCodeHash: bytes32(0),
                poolInitCodeHash: bytes32(0),
                v4PoolManager: address(deployment.poolManager),
                permissionsAdapterFactory: address(0),
                v3NFTPositionManager: address(0),
                v4PositionManager: address(deployment.positionManager),
                spokePool: address(0)
            })
        );
    }

    function _saveDeployment(Deployment memory deployment) internal {
        saveContract("PoolManager", address(deployment.poolManager));
        saveContract("PositionDescriptorImplementation", address(deployment.positionDescriptorImplementation));
        saveContract("PositionDescriptor", address(deployment.positionDescriptor));
        saveContract("PositionDescriptorProxyAdmin", address(deployment.positionDescriptorProxyAdmin));
        saveContract("PositionManager", address(deployment.positionManager));
        saveContract("StateView", address(deployment.stateView));
        saveContract("V4Quoter", address(deployment.v4Quoter));
        saveContract("UniversalRouter", address(deployment.universalRouter));
    }
}
