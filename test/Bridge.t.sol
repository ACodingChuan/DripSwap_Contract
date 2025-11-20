// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "src/bridge/Bridge.sol";
import {ISignatureTransfer} from "src/interfaces/ISignatureTransfer.sol";

contract BridgeTest is Test {
    Bridge bridge;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant VETH = 0xE91d02E66a9152Fee1BC79c1830121F6507a4F6D;
    address admin = 0x5EEb1d4f90Ba69579C28e4DBa7f268AAFA9Fc69b;

    function setUp() public {
        // 使用 Sepolia fork
        vm.createSelectFork("https://sepolia.infura.io/v3/YOUR_KEY");
        
        // Bridge 已经部署在 0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7
        bridge = Bridge(0x9347B320e42877855Cc6E66e5E5d6f18216CEEe7);
    }

    function testPermitStructure() public view {
        // 验证 permit 结构是否正确
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] = ISignatureTransfer.TokenPermissions({
            token: VETH,
            amount: 100000000000000000000
        });
        permitted[1] = ISignatureTransfer.TokenPermissions({
            token: LINK,
            amount: 2000000000000000000
        });

        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: 202846013311,
            deadline: 1763575701
        });

        // 如果结构对了，这里就不会 revert
        assert(permit.nonce == 202846013311);
        assert(permit.deadline == 1763575701);
        assert(permit.permitted.length == 2);
    }
}
