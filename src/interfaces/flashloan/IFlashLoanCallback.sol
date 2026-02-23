// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IFlashLoanCallback
 * @notice Unified callback interface for flash loan recipients
 * @dev Contracts that receive flash loans must implement this interface
 */
interface IFlashLoanCallback {
    /**
     * @notice Called by the flash loan adapter after tokens have been transferred
     * @dev The recipient must approve the adapter to pull back amount + fee before returning
     * @param initiator The address that initiated the flash loan
     * @param token The token that was borrowed
     * @param amount The amount that was borrowed
     * @param fee The fee amount that must be repaid on top of the principal
     * @param data Arbitrary data passed from the flash loan initiator
     * @return success Must return true to indicate successful handling
     */
    function onFlashLoanReceived(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bool success);
}
