pragma solidity 0.8.19;

library EulerCurveMetaLeveragerStorage {
    bytes32 constant STORAGE_STRUCT_POSITION = keccak256("leveragedvaults.leverager");

    struct Storage {
        address yieldToken;
        address underlyingToken;
        address debtToken;
        address flashLoan;
        address debtSource;
        address dexPool;
        int128 debtTokenCurveIndex;
        int128 underlyingTokenCurveIndex;
    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = STORAGE_STRUCT_POSITION;
        assembly {
            s.slot := position
        }
    }
}
