pragma solidity >=0.5.0;
pragma abicoder v2;

interface IFlashLoan {
    function onFlashLoan(bytes memory data) external;
}
