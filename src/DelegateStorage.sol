pragma solidity 0.8.19;

library DelegateStorage {
    bytes32 constant STORAGE_STRUCT_POSITION = keccak256("leveragedvaults.leverager");

    struct StorageStruct {
        uint previousNum;
    }

    function getStorageStruct() internal pure returns (StorageStruct storage s) {
        bytes32 position = STORAGE_STRUCT_POSITION;
        assembly {
            s.slot := position
        }
    }
}
