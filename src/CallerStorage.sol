pragma solidity 0.8.19;

library CallerStorage {
    bytes32 constant STORAGE_STRUCT_POSITION = keccak256("leveragedvaults.leveragedvault");

    struct StorageStruct {
        uint num;
        address delegateContract;
    }

    function getStorageStruct() internal pure returns (StorageStruct storage s) {
        bytes32 position = STORAGE_STRUCT_POSITION;
        assembly {
            s.slot := position
        }
    }
}
