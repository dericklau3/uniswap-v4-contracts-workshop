// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseDeployScript} from "./BaseDeployScript.sol";

contract WalletScript is BaseDeployScript {

    uint256 privatekey = vm.envUint("PRIVATEKEY");

    function run() public {
        
        vm.startBroadcast(privatekey);
        
        vm.stopBroadcast();
    }
}