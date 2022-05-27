// SPDX-License-Identifier: GPL-2.0-only
// Copyright 2020 Spilsbury Holdings Ltd
pragma solidity >=0.8.4;
pragma experimental ABIEncoderV2;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IDefiBridge } from "../../interfaces/IDefiBridge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRollupProcessor} from '../../interfaces/IRollupProcessor.sol';

import { AztecTypes } from "../../aztec/AztecTypes.sol";
interface Ttoken is IERC20{
  function requestedWithdrawals(address account) external view returns (uint256, uint256);
  function requestWithdrawal(uint256 amount) external;
  function deposit(uint256 amount) external payable;
  function withdraw(uint256 requestedAmount) external;
  function withdraw(uint256 requestedAmount, bool asEth) external;
}
interface IManager {
  function getCurrentCycleIndex() external view returns (uint256);
}
contract DepositBridge is IDefiBridge {
    using SafeERC20 for IERC20;
    event TokenBalance(uint256 balance);

  address public tWETH = 0xD3D13a578a53685B4ac36A1Bab31912D2B2A2F36;
  address public tUSDC  = 0x04bDA0CF6Ad025948Af830E75228ED420b0e860d;
  address public tDAI  = 0x0CE34F4c26bA69158BC2eB8Bf513221e44FDfB75;
  address public tFRAX  = 0x94671A3ceE8C7A12Ea72602978D1Bb84E920eFB2;
  address public tWUST  = 0x482258099De8De2d0bda84215864800EA7e6B03D;

  address public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address public DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
  address public FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
  address public wUST = 0xa693B19d2931d498c5B318dF961919BB4aee87a5;

  address public MANAGER = 0xA86e412109f77c45a3BC1c5870b880492Fb86A14;

  address public immutable rollupProcessor;



  uint256 internal constant MAX_UINT = type(uint256).max;

  uint256 internal constant MIN_GAS_FOR_CHECK_AND_FINALISE = 83000;
  uint256 internal constant MIN_GAS_FOR_FUNCTION_COMPLETION = 5000;


  mapping(address=> uint256) pendingWithdarawls;

  struct Interaction {
      uint256 inputValue;
      address tAsset;
  }


  uint256[] nonces;

  // cache of all of our Defi interactions. keyed on nonce
  mapping(uint256 => Interaction) public pendingInteractions;

  constructor(address _rollupProcessor) public {
    rollupProcessor = _rollupProcessor;
    
  }

  function convert(
    AztecTypes.AztecAsset memory inputAssetA,
    AztecTypes.AztecAsset memory inputAssetB,
    AztecTypes.AztecAsset memory outputAssetA,
    AztecTypes.AztecAsset memory outputAssetB,
    uint256 totalInputValue,
    uint256 interactionNonce,
    uint64 auxData,
    address rollupBeneficiary
  )
    external
    payable
    override
    returns (
      uint256 outputValueA,
      uint256 outputValueB,
      bool isAsync
    )
  {
    // // ### INITIALIZATION AND SANITY CHECKS
    require(msg.sender == rollupProcessor, "Tokemak DepositBridge: INVALID_CALLER");
    require(inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20, "Tokemak DepositBridge: INVALID_ASSET_TYPE");
    require(outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20, "Tokemak DepositBridge: INVALID_ASSET_TYPE");

    // Check whether the call is for withdrawal or deposit
    bool isWithdrawal = _isWithdrawal(inputAssetA.erc20Address);
    address tAsset = isWithdrawal ? inputAssetA.erc20Address : _getPoolAddress(inputAssetA.erc20Address);
   
    require(tAsset != address(0),"Tokemak DepositBridge: INVALID_INPUT");

    // Withdraw or Deposit 
    outputValueB = 0;
    if (isWithdrawal) {
        isAsync = true;
        outputValueA = 0;
        addWithdrawalNonce(...);
    } else {
        isAsync = false;
        outputValueA =  _deposit(...);
    }

    finalisePendingInteractions(MIN_GAS_FOR_FUNCTION_COMPLETION);

  }

  function _canWithdraw(address tAsset, uint256 inputValue) private returns (bool){
       Ttoken tToken = Ttoken(tAsset);
    
    // Get our current request withdrawal data
    (uint256 minCycle, uint256 requestedWithdrawalAmount) = tToken.requestedWithdrawals(address(this));

    // Get current cycle index
    uint256 currentCycleIndex = IManager(MANAGER).getCurrentCycleIndex();

    // Check if need to request for withdraw first
    if(inputValue > requestedWithdrawalAmount){
      return false;
    }

    //Check if the withdrawal request is complete
    if(currentCycleIndex < minCycle){
      return false;
    }
    return true;
  }

  function addWithdrawalNonce(uint256 nonce, address tAsset, uint256 inputValue) private returns (uint256,bool ){
    Ttoken tToken = Ttoken(tAsset);
    tToken.requestWithdrawal(inputValue);

    nonces.push(nonce);
    pendingInteractions[nonce] =  Interaction(inputValue,tAsset);
    return (0, true);
  }

  function _finaliseWithdraw(address tAsset, uint256 inputValue, uint256 nonce) private returns (uint256 outputValue,bool withdrawComplete) {
    Ttoken tToken = Ttoken(tAsset);

    if(!_canWithdraw(tAsset,inputValue)){
        withdrawComplete = false;
        outputValue = 0;
        return (outputValue, withdrawComplete);
    }
    // Approve Tokemak Pool to transfer tAsset
    tToken.approve(tAsset, inputValue);

    //Get asset address from tAsset
    address asset = _getAssetAddress(tAsset);
    IERC20 assetToken = IERC20(address(asset));

    // Asset balance before withdrawal for calculating outputValue
    uint256 beforeBalance = assetToken.balanceOf(address(this));

    //Check if the pool is EthPool because withdrawal function is different
    if(asset == WETH){
      tToken.withdraw(inputValue, false);
    }else{
      tToken.withdraw(inputValue);
    }

    // Asset balance after withdrawal for calculating outputValue
    uint256 afterBalance = assetToken.balanceOf(address(this));

    outputValue = afterBalance - beforeBalance;

    //Approve Rollup Processor to withdraw asset
    assetToken.approve(rollupProcessor, outputValue);

    delete pendingInteractions[nonce];
    for(uint i = 0;i < nonces.length;i++){
      if(nonces[i] == nonce){
        delete nonces[i];
        break;
      }
    }
  }

  function _deposit(address tAsset, uint256 inputValue, address asset) private returns (uint256 outputValue) {
    // Approve asset to deposit in Tokemak Pool
    IERC20(asset).approve(tAsset, inputValue);

    Ttoken tToken = Ttoken(tAsset);

    // Asset balance before withdrawal for calculating outputValue
    uint256 beforeBalance = tToken.balanceOf(address(this));
    
    //Deposit in Tokemak Pool
    tToken.deposit(inputValue);

    // Asset balance after withdrawal for calculating outputValue
    uint256 afterBalance = tToken.balanceOf(address(this));

    // Output Value
    outputValue = afterBalance - beforeBalance;

    //Approve Rollup Processor to withdraw tAsset
    tToken.approve(rollupProcessor, outputValue);
  }
  
  function _isWithdrawal(address token) internal view returns(bool){
    if(token == tWETH || token == tUSDC || token == tDAI || token == tFRAX || token == tWUST){
      return true;
    }
    return false;
  }
  //Get asset address from tAsset address
  function _getAssetAddress(address tToken) internal view returns (address){
    if(tToken == tWETH){
      return WETH;
    }
    if(tToken == tUSDC){
      return USDC;
    }
    if(tToken == tFRAX){
      return FRAX;
    }
    if(tToken == tDAI){
      return DAI;
    }
    if(tToken == tWUST){
      return wUST;
    }
    return address(0);
  }
  //Get tAsset address from asset address
  function _getPoolAddress(address token) internal view returns (address){
    if(token == WETH){
      return tWETH;
    }
    if(token == USDC){
      return tUSDC;
    }
    if(token == FRAX){
      return tFRAX;
    }
    if(token == DAI){
      return tDAI;
    }
    if(token == wUST){
      return tWUST;
    }
    return address(0);
  }

  function finalise(
    AztecTypes.AztecAsset calldata inputAssetA,
    AztecTypes.AztecAsset calldata,
    AztecTypes.AztecAsset calldata outputAssetA,
    AztecTypes.AztecAsset calldata,
    uint256 interactionNonce,
    uint64 auxData
  ) external payable override returns (uint256 outputValueA, uint256 outputValueB, bool interactionCompleted ) {
    require(inputAssetA.assetType == AztecTypes.AztecAssetType.ERC20, "Tokemak DepositBridge: INVALID_ASSET_TYPE");
    require(outputAssetA.assetType == AztecTypes.AztecAssetType.ERC20, "Tokemak DepositBridge: INVALID_ASSET_TYPE");
    require(msg.sender == rollupProcessor, "Tokemak DepositBridge: INVALID_CALLER");

    // Pending withdrawal value
    uint256 inputValue = pendingInteractions[interactionNonce].inputValue;
    require(inputValue > 0);
        
    address tAsset = inputAssetA.erc20Address;
    require(tAsset != address(0),"Tokemak DepositBridge: INVALID_INPUT");
    // Withdraw pending withdrawals
    (outputValueA, interactionCompleted) =  _finaliseWithdraw(tAsset, inputValue, interactionNonce);
  }

    /**
     * @dev Function to attempt finalising of as many interactions as possible within the specified gas limit
     * Continue checking for and finalising interactions until we expend the available gas
     * @param gasFloor The amount of gas that needs to remain after this call has completed
     */
    function finalisePendingInteractions(uint256 gasFloor) internal {
        // check and finalise interactions until we don't have enough gas left to reliably update our state without risk of reverting the entire transaction
        // gas left must be enough for check for next expiry, finalise and leave this function without breaching gasFloor
        uint256 gasLoopCondition = MIN_GAS_FOR_CHECK_AND_FINALISE + MIN_GAS_FOR_FUNCTION_COMPLETION + gasFloor;
        uint256 ourGasFloor = MIN_GAS_FOR_FUNCTION_COMPLETION + gasFloor;
        while (gasleft() > gasLoopCondition) {
            // check the heap to see if we can finalise an expired transaction
            // we provide a gas floor to the function which will enable us to leave this function without breaching our gasFloor
            (bool available, uint256 nonce) = checkForNextInteractionToFinalise(ourGasFloor);
            if (!available) {
                break;
            }
            // make sure we will have at least ourGasFloor gas after the finalise in order to exit this function
            uint256 gasRemaining = gasleft();
            if (gasRemaining <= ourGasFloor) {
                break;
            }
            uint256 gasForFinalise = gasRemaining - ourGasFloor;
            // make the call to finalise the interaction with the gas limit        
            try IRollupProcessor(rollupProcessor).processAsyncDefiInteraction{gas: gasForFinalise}(nonce) returns (bool interactionCompleted) {
                // no need to do anything here, we just need to know that the call didn't throw
            } catch {
                break;
            }
        }
    }
  
    /**
     * @dev Function to get the next interaction to finalise
     * @param gasFloor The amount of gas that needs to remain after this call has completed
     */
    function checkForNextInteractionToFinalise(uint256 gasFloor)
        internal
        returns (
            bool ,
            uint256 
        )
    {
        // do we have any expiries and if so is the earliest expiry now expired
        if (nonces.length == 0) {
            return (false, 0);
        }
       
        uint256 minGasForLoop = gasFloor;
        uint i = 0;
        while(i < nonces.length && gasleft() >= minGasForLoop){
          uint256 nonce = nonces[i];
          i++;
          if(nonce == 0){
            continue;
          }

          Interaction storage interaction = pendingInteractions[nonce];
          if(interaction.inputValue == 0){
            continue;
          }

          if(_canWithdraw(interaction.tAsset, interaction.inputValue)){
            return (true, nonce);
          }
        }
        return (false, 0);
    }
 
}
