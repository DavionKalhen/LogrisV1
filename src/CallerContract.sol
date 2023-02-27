pragma solidity 0.8.19;

import {CallerStorage} from "./CallerStorage.sol";

contract CallerContract {
    constructor(address _delegateContract, uint256 _num) {
        CallerStorage.StorageStruct storage s = CallerStorage.getStorageStruct();
        s.num = _num;
        s.delegateContract = _delegateContract;
    }

    function setNum(uint _num) public returns(uint) {
        CallerStorage.StorageStruct storage s = CallerStorage.getStorageStruct();
        (bool success, bytes memory returnData) = s.delegateContract.delegatecall(
            abi.encodeWithSignature("setNum(uint256)", _num)
        );
        require(success, "delegate call failed");
        require(s.num==_num, "num failed to update");
        uint previousNum = abi.decode(returnData, (uint256));
        return previousNum;
    }

    function getNum() external view returns(uint) {
        CallerStorage.StorageStruct storage s = CallerStorage.getStorageStruct();
        return s.num;
    }

    function getPreviousNum() public returns(uint) {
        CallerStorage.StorageStruct storage s = CallerStorage.getStorageStruct();
        (bool success, bytes memory returnData) = s.delegateContract.delegatecall(
            abi.encodeWithSignature("getPreviousNum()")
        );
        require(success, "delegate call failed");
        uint previousNum = abi.decode(returnData, (uint256));
        return previousNum;
    }
}