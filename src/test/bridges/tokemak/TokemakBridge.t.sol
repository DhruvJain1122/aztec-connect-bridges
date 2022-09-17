// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {BridgeTestBase} from "./../../aztec/base/BridgeTestBase.sol";

// Example-specific imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IManager} from "../../../interfaces/tokemak/IManager.sol";

import {TokemakBridge} from "../../../bridges/tokemak/TokemakBridge.sol";

import {AztecTypes} from "../../../aztec/libraries/AztecTypes.sol";

contract TokemakBridgeTest is BridgeTestBase {
    // Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address public constant tWETH = 0xD3D13a578a53685B4ac36A1Bab31912D2B2A2F36;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MANAGER = 0xA86e412109f77c45a3BC1c5870b880492Fb86A14;
    address public constant DEPLOYER = 0x9e0bcE7ec474B481492610eB9dd5D69EB03718D5;
    event TokenBalance(uint256 previousBalance, uint256 newBalance);

    uint256 nonce;
    TokemakBridge bridge;
    AztecTypes.AztecAsset private empty;

    uint256 private bridgeAddressId;

    AztecTypes.AztecAsset private wAsset;
    AztecTypes.AztecAsset private wtAsset;

    function setUp() public {
        bridge = new TokemakBridge(address(ROLLUP_PROCESSOR));
        vm.deal(address(bridge), 0);
        vm.startPrank(MULTI_SIG);

        ROLLUP_PROCESSOR.setSupportedBridge(address(bridge), 2000000);

        ROLLUP_PROCESSOR.setSupportedAsset(WETH, 100000);

        ROLLUP_PROCESSOR.setSupportedAsset(tWETH, 100000);

        vm.stopPrank();

        bridgeAddressId = ROLLUP_PROCESSOR.getSupportedBridgesLength();

        wAsset = getRealAztecAsset(WETH);

        wtAsset = getRealAztecAsset(tWETH);
    }

    function testTokemakBridge() public {
        validateTokemakBridge(1000, 500);
    }

    function validateTokemakBridge(uint256 balance, uint256 depositAmount) public {
        deal(WETH, address(ROLLUP_PROCESSOR), balance * 3);

        //Deposit to Pool
        uint256 output = depositToPool(depositAmount);

        //Request Withdraw
        requestWithdrawFromPool(output);

        //Next Cycle
        uint256 newTimestamp = 1748641030;
        vm.warp(newTimestamp);
        vm.startPrank(DEPLOYER);
        IManager(MANAGER).completeRollover("complete");
        IManager(MANAGER).completeRollover("complete2");
        vm.stopPrank();

        //Test if automatic process withdrawal working
        uint256 output2 = depositToPool(depositAmount * 2);

        nonce = getNextNonce();

        //Request Withdraw
        requestWithdrawFromPool(output2);

        //Next Cycle
        newTimestamp = 1758641030;
        vm.warp(newTimestamp);
        vm.startPrank(DEPLOYER);
        IManager(MANAGER).completeRollover("complete3");
        IManager(MANAGER).completeRollover("complete4");
        vm.stopPrank();

        //Withdraw
        processPendingWithdrawal(WETH);
    }

    function depositToPool(uint256 depositAmount) public returns (uint256) {
        IERC20 assetToken = IERC20(WETH);
        uint256 beforeBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));

        uint256 bridgeCallData = encodeBridgeCallData(bridgeAddressId, wAsset, empty, wtAsset, empty, 0);

        (uint256 outputValueA, , ) = sendDefiRollup(bridgeCallData, depositAmount);

        uint256 afterBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));

        emit TokenBalance(beforeBalance, afterBalance);

        return outputValueA;
    }

    function requestWithdrawFromPool(uint256 withdrawAmount) public returns (uint256) {
        IERC20 assetToken = IERC20(WETH);

        uint256 beforeBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));
        uint256 bridgeCallData = encodeBridgeCallData(bridgeAddressId, wtAsset, empty, wAsset, empty, 1);

        (uint256 outputValueA, , ) = sendDefiRollup(bridgeCallData, withdrawAmount);
        uint256 afterBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));

        emit TokenBalance(beforeBalance, afterBalance);
        return outputValueA;
    }

    function processPendingWithdrawal(address asset) public {
        IERC20 assetToken = IERC20(WETH);
        uint256 beforeBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));
        bool completed = ROLLUP_PROCESSOR.processAsyncDefiInteraction(nonce);
        uint256 afterBalance = assetToken.balanceOf(address(ROLLUP_PROCESSOR));
        emit TokenBalance(beforeBalance, afterBalance);
    }
}
