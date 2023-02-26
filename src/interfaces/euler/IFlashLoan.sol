pragma solidity >=0.5.0;
pragma abicoder v2;

// Mainnet imeplementation: 0x07df2ad9878f8797b4055230bbae5c808b8259b3
// requires an onFlashLoan callback method
//function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32) {
//   require(initiator == self, "only I can initiate a flash loan");
//   require(fee == 0, "no fee allowed");
//   return keccak256("ERC3156FlashBorrower.onFlashLoan")
// }

interface IFlashLoan {
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external returns (bool);
}

