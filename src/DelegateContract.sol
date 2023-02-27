pragma solidity 0.8.19;

import {CallerStorage} from "./CallerStorage.sol";
import {DelegateStorage} from "./DelegateStorage.sol";

contract DelegateContract {
    function setNum(uint _num) public returns(uint) {
        CallerStorage.StorageStruct storage s = CallerStorage.getStorageStruct();
        DelegateStorage.StorageStruct storage d = DelegateStorage.getStorageStruct();
        d.previousNum = s.num;
        s.num = _num;
        return d.previousNum;
    }

    function getPreviousNum() public view returns(uint) {
        DelegateStorage.StorageStruct storage d = DelegateStorage.getStorageStruct();
        return d.previousNum;
    }
}