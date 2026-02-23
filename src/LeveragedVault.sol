// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ERC4626Upgradeable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/ILeveragedVault.sol";
import "./interfaces/ILeveragedVaultCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/ILeveragerV3.sol";
import "./interfaces/ITokenConverter.sol";
import "./interfaces/flashloan/IFlashLoanAdapter.sol";
import {IWETH} from "../alchemix-v3/src/interfaces/IWETH.sol";
import {IAlchemistV3} from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

/**
 * @title LeveragedVault
 * @notice ERC4626 vault that manages a shared leveraged position in AlchemistV3
 * @dev Deployed as an EIP-1167 minimal proxy clone. Each clone has its own storage
 *      but delegates calls to a shared implementation contract.
 *
 * Architecture:
 * - Users call depositUnderlying() to add funds to the pool
 * - Operator calls leverage() to leverage the pooled deposits
 * - All depositors share in the leveraged position proportionally
 * - Users can withdraw via withdrawUnderlying() (may trigger deleveraging)
 */
contract LeveragedVault is
    Initializable,
    OwnableUpgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ILeveragedVault,
    ILeveragedVaultCallback,
    IERC721Receiver
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 constant BASIS_POINTS = 10_000;

    // ============ ERC-7201 Namespaced Storage ============

    /// @custom:storage-location erc7201:logris.storage.LeveragedVault
    struct LeveragedVaultStorage {
        // Former immutables
        IAlchemistV3 alchemist;
        IERC20 underlyingToken;
        address yieldToken;
        address leverager;
        IWETH wETH;
        address converter;
        address flashLoanAdapter;
        address swapper;
        // State variables
        uint256 vaultPositionId;
        bool operationInProgress;
        uint32 underlyingSlippageBasisPoints;
        uint32 debtSlippageBasisPoints;
    }

    // keccak256(abi.encode(uint256(keccak256("logris.storage.LeveragedVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LeveragedVaultStorageLocation = 0x66ffcd6e30a6e809fc5f771c6fbd297089c8842af4bafa5c4f2a8100b3cc4600;

    function _getLeveragedVaultStorage() private pure returns (LeveragedVaultStorage storage $) {
        assembly {
            $.slot := LeveragedVaultStorageLocation
        }
    }

    // ============ Events ============

    /// @notice Emitted when the vault executes a leverage operation.
    /// @param depositAmount Amount of underlying tokens deposited from the pool.
    /// @param flashLoanAmount Amount of underlying tokens obtained via flash loan.
    /// @param debtMinted Amount of debt tokens minted during the leverage.
    event VaultLeveraged(uint256 depositAmount, uint256 flashLoanAmount, uint256 debtMinted);
    /// @notice Emitted when the vault deleverages during a withdrawal.
    /// @param sharesWithdrawn Number of vault shares burned.
    /// @param debtBurned Amount of debt tokens repaid.
    event VaultDeleveraged(uint256 sharesWithdrawn, uint256 debtBurned);
    /// @notice Emitted when the owner updates slippage parameters.
    /// @param underlyingSlippageBps New slippage tolerance for underlying token operations.
    /// @param debtSlippageBps New slippage tolerance for debt token swaps.
    event SlippageParametersUpdated(uint32 underlyingSlippageBps, uint32 debtSlippageBps);
    /// @notice Emitted when the owner sweeps an accidentally-sent ERC20 token.
    /// @param token The token address swept.
    /// @param amount The amount transferred.
    /// @param recipient The address that received the tokens.
    event EmergencySweep(address indexed token, uint256 amount, address indexed recipient);
    /// @notice Emitted when the owner sweeps ETH stuck in the vault.
    /// @param amount The ETH amount transferred.
    /// @param recipient The address that received the ETH.
    event EmergencySweepETH(uint256 amount, address indexed recipient);
    /// @notice Emitted when a vault clone is initialized.
    /// @param yieldToken The yield token this vault manages.
    /// @param underlyingToken The underlying token accepted for deposits.
    /// @param alchemist The AlchemistV3 contract address.
    event VaultInitialized(address indexed yieldToken, address indexed underlyingToken, address indexed alchemist);
    /// @notice Emitted when an unknown position NFT is swept from the vault.
    /// @param tokenId The position NFT ID transferred.
    /// @param to The recipient address.
    event PositionSwept(uint256 indexed tokenId, address indexed to);

    // ============ Custom Errors ============

    /// @dev Thrown when a required address parameter is address(0).
    error ZeroAddress();
    /// @dev Thrown when a function restricted to the leverager is called by another address.
    error OnlyLeverager();
    /// @dev Thrown when a new operation is attempted while another is in progress.
    error OperationInProgress();
    /// @dev Thrown when a deposit exceeds the maximum allowed by ERC4626.
    error DepositExceedsMax();
    /// @dev Thrown when ETH deposit is attempted on a non-WETH vault.
    error NonWETHVault();
    /// @dev Thrown when the requested leverage amount exceeds the pool's underlying balance.
    error InsufficientPoolBalance();
    /// @dev Thrown when a zero-amount deposit is attempted.
    error ZeroDeposit();
    /// @dev Thrown when yield token conversion returns fewer tokens than the minimum.
    error InsufficientYieldFromConversion();
    /// @dev Thrown when the requested mint exceeds the Alchemist borrow capacity.
    error MintExceedsCapacity();
    /// @dev Thrown when deposits are paused on the Alchemist.
    error DepositsPaused();
    /// @dev Thrown when a deposit would exceed the Alchemist deposit cap.
    error DepositCapExceeded();
    /// @dev Thrown when trying to create a position but the vault already holds one.
    error PositionAlreadyExists();
    /// @dev Thrown when a position NFT was not minted after deposit.
    error PositionNotMinted();
    /// @dev Thrown when an operation requires a position but none exists.
    error NoPosition();
    /// @dev Thrown when loans are paused on the Alchemist.
    error LoansPaused();
    /// @dev Thrown when the caller does not hold enough vault shares.
    error InsufficientShares();
    /// @dev Thrown when a withdrawal produces fewer underlying tokens than required.
    error InsufficientWithdrawal();
    /// @dev Thrown when the recipient address is address(0).
    error InvalidRecipient();
    /// @dev Thrown when trying to sweep the vault's active Alchemist position.
    error CannotSweepActivePosition();
    /// @dev Thrown when the vault does not own the specified position NFT.
    error VaultNotOwner();
    /// @dev Thrown when the vault holds more than one position NFT.
    error MultiplePositions();
    /// @dev Thrown when the vault is not the owner of its recorded position.
    error NotPositionOwner();
    /// @dev Thrown when the debt swap minimum is below the enforced slippage floor.
    error SwapSlippageBelowMinimum();
    /// @dev Thrown when a slippage parameter is >= 10000 basis points (100%).
    error SlippageTooHigh();
    /// @dev Thrown when emergencySweepToken is called with the underlying or yield token.
    error CannotSweepVaultToken();
    /// @dev Thrown when emergencySweepETH is called but the vault holds no ETH.
    error NoETHToSweep();
    /// @dev Thrown when an ETH transfer fails.
    error ETHTransferFailed();
    /// @dev Thrown when the transaction deadline has passed.
    error DeadlineExpired();

    // ============ Modifiers ============

    /// @notice Restricts access to the configured leverager contract.
    /// @dev Reverts with OnlyLeverager if msg.sender is not the leverager.
    modifier onlyLeverager() {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (msg.sender != $.leverager) revert OnlyLeverager();
        _;
    }

    /// @notice Prevents concurrent deposit/leverage/withdraw operations.
    /// @dev Sets a flag before execution and clears it after to block reentrancy at the operation level.
    ///      Cannot use nonReentrant on entry-point functions because leverager callbacks
    ///      (vaultDepositYieldTokens, etc.) already carry nonReentrant and share the same guard slot.
    modifier noConcurrentOperation() {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.operationInProgress) revert OperationInProgress();
        $.operationInProgress = true;
        _;
        $.operationInProgress = false;
    }

    // ============ Constructor (locks implementation) ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize a new LeveragedVault clone with all required configuration.
    /// @dev Called once by LeveragedVaultFactory immediately after cloning. Protected
    ///      by the `initializer` modifier so it cannot be called again on the same proxy.
    /// @param yieldToken_ Yield-bearing token deposited into Alchemist (e.g. wstETH).
    /// @param underlyingTokenAddress Underlying token accepted for deposits (e.g. WETH).
    /// @param _alchemist AlchemistV3 contract managing the CDP position.
    /// @param _leverager Leverager contract authorized to execute leverage/deleverage.
    /// @param _underlyingSlippageBasisPoints Default slippage tolerance for underlying operations.
    /// @param _debtSlippageBasisPoints Default slippage tolerance for debt token swaps.
    /// @param _converter Token converter for underlying <-> yield conversions.
    /// @param _flashLoanAdapter Flash loan adapter for leverage/deleverage operations.
    /// @param _swapper Swap adapter for debt token trades.
    /// @param _weth WETH contract address for ETH wrapping.
    /// @param initialOwner Address that will own this vault clone.
    function initialize(
        address yieldToken_,
        address underlyingTokenAddress,
        address _alchemist,
        address _leverager,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        address _converter,
        address _flashLoanAdapter,
        address _swapper,
        address _weth,
        address initialOwner
    ) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (_alchemist == address(0)) revert ZeroAddress();
        if (_leverager == address(0)) revert ZeroAddress();
        if (yieldToken_ == address(0)) revert ZeroAddress();
        if (underlyingTokenAddress == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_converter == address(0)) revert ZeroAddress();
        if (_flashLoanAdapter == address(0)) revert ZeroAddress();
        if (_swapper == address(0)) revert ZeroAddress();

        __Ownable_init(initialOwner);
        string memory underlyingSymbol = IERC20Metadata(underlyingTokenAddress).symbol();
        __ERC20_init(
            string.concat("Logris Leveraged ", underlyingSymbol),
            string.concat("lv", underlyingSymbol)
        );
        __ERC4626_init(IERC20(underlyingTokenAddress));
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();

        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        $.alchemist = IAlchemistV3(_alchemist);
        $.leverager = _leverager;
        $.underlyingToken = IERC20(underlyingTokenAddress);
        $.yieldToken = yieldToken_;
        $.underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        $.debtSlippageBasisPoints = _debtSlippageBasisPoints;
        $.converter = _converter;
        $.flashLoanAdapter = _flashLoanAdapter;
        $.swapper = _swapper;
        $.wETH = IWETH(_weth);

        emit VaultInitialized(yieldToken_, underlyingTokenAddress, _alchemist);
    }

    // ============ Public Getters (formerly public immutables) ============

    /// @notice Returns the AlchemistV3 instance this vault interacts with.
    /// @return The AlchemistV3 contract.
    function alchemist() public view returns (IAlchemistV3) {
        return _getLeveragedVaultStorage().alchemist;
    }

    /// @notice Returns the leverager contract authorized to execute leverage operations.
    /// @return The leverager address.
    function leverager() public view returns (address) {
        return _getLeveragedVaultStorage().leverager;
    }

    /// @notice Returns the WETH contract used for ETH wrapping.
    /// @return The WETH interface.
    function wETH() public view returns (IWETH) {
        return _getLeveragedVaultStorage().wETH;
    }

    /// @notice Returns the token converter used for underlying <-> yield conversions.
    /// @return The converter address.
    function converter() public view returns (address) {
        return _getLeveragedVaultStorage().converter;
    }

    /// @notice Returns the flash loan adapter used for leverage/deleverage.
    /// @return The flash loan adapter address.
    function flashLoanAdapter() public view returns (address) {
        return _getLeveragedVaultStorage().flashLoanAdapter;
    }

    /// @notice Returns the swap adapter used for debt token trades.
    /// @return The swapper address.
    function swapper() public view returns (address) {
        return _getLeveragedVaultStorage().swapper;
    }

    /// @notice Returns the vault's AlchemistV3 position NFT ID.
    /// @return The position ID, or 0 if no position exists.
    function vaultPositionId() public view returns (uint256) {
        return _getLeveragedVaultStorage().vaultPositionId;
    }

    /// @notice Returns the default slippage tolerance for underlying token operations.
    /// @return Slippage in basis points.
    function underlyingSlippageBasisPoints() public view returns (uint32) {
        return _getLeveragedVaultStorage().underlyingSlippageBasisPoints;
    }

    /// @notice Returns the default slippage tolerance for debt token swaps.
    /// @return Slippage in basis points.
    function debtSlippageBasisPoints() public view returns (uint32) {
        return _getLeveragedVaultStorage().debtSlippageBasisPoints;
    }

    // ============ View Functions ============

    /// @inheritdoc ILeveragedVault
    function getYieldToken() external view override(ILeveragedVault) returns (address) {
        return _getLeveragedVaultStorage().yieldToken;
    }

    /// @inheritdoc ILeveragedVault
    function getUnderlyingToken() external view override(ILeveragedVault) returns (address) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        return address($.underlyingToken);
    }

    /// @inheritdoc ILeveragedVault
    function getDepositPoolBalance() external view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        return $.underlyingToken.balanceOf(address(this));
    }

    /// @inheritdoc ILeveragedVault
    function getVaultDepositedBalance() external view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;
        (uint256 collateral, , ) = $.alchemist.getCDP($.vaultPositionId);
        return collateral;
    }

    /// @inheritdoc ILeveragedVault
    function getVaultDebtBalance() external view override returns (int256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;
        (, uint256 debt, ) = $.alchemist.getCDP($.vaultPositionId);
        return int256(debt);
    }

    /// @inheritdoc ILeveragedVault
    function getVaultRedeemableBalance() public view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        uint256 poolBalance = $.underlyingToken.balanceOf(address(this));
        if ($.vaultPositionId == 0) return poolBalance;

        (uint256 collateral, uint256 debt, uint256 earmarked) = $.alchemist.getCDP($.vaultPositionId);
        uint256 freeCollateral = collateral > earmarked ? collateral - earmarked : 0;
        uint256 collateralUnderlying = $.alchemist.convertYieldTokensToUnderlying(freeCollateral);
        uint256 debtInUnderlying = $.alchemist.normalizeDebtTokensToUnderlying(debt);
        uint256 alchemistBalance = collateralUnderlying > debtInUnderlying
            ? collateralUnderlying - debtInUnderlying
            : 0;

        return poolBalance + alchemistBalance;
    }

    /// @inheritdoc ILeveragedVault
    function getDepositCapacity() public view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        uint256 depositCap = $.alchemist.depositCap();
        uint256 totalDeposited = $.alchemist.getTotalDeposited();
        if (depositCap >= totalDeposited) {
            return depositCap - totalDeposited;
        }
        return 0;
    }

    /// @inheritdoc ILeveragedVault
    function getBorrowCapacity() public view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;
        return $.alchemist.getMaxBorrowable($.vaultPositionId);
    }

    /// @inheritdoc ILeveragedVault
    function getFreeWithdrawCapacity() public view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;

        uint256 minimumCollateralization = $.alchemist.minimumCollateralization();
        (uint256 collateral, uint256 debt, uint256 earmarked) = $.alchemist.getCDP($.vaultPositionId);
        uint256 freeCollateral = collateral > earmarked ? collateral - earmarked : 0;

        uint256 collateralUnderlying = $.alchemist.convertYieldTokensToUnderlying(freeCollateral);
        if (debt == 0) return collateralUnderlying;

        uint256 debtInUnderlying = $.alchemist.normalizeDebtTokensToUnderlying(debt);
        uint256 lockedCollateral = debtInUnderlying * minimumCollateralization / FIXED_POINT_SCALAR;

        if (collateralUnderlying > lockedCollateral) {
            return collateralUnderlying - lockedCollateral;
        }
        return 0;
    }

    /// @inheritdoc ILeveragedVault
    function getTotalWithdrawCapacity() public view override returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;
        (uint256 collateral, , uint256 earmarked) = $.alchemist.getCDP($.vaultPositionId);
        uint256 freeCollateral = collateral > earmarked ? collateral - earmarked : 0;
        return $.alchemist.convertYieldTokensToUnderlying(freeCollateral);
    }

    /// @inheritdoc ILeveragedVault
    function pokePosition() external override {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }
    }

    /// @inheritdoc ILeveragedVault
    function convertUnderlyingTokensToShares(uint256 amount) public view override returns (uint256) {
        return convertToShares(amount);
    }

    /// @inheritdoc ILeveragedVault
    function convertSharesToUnderlyingTokens(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc ILeveragedVaultCallback
    function getVaultPositionId() external view override returns (uint256) {
        return _getLeveragedVaultStorage().vaultPositionId;
    }

    // ============ Parameter Calculation Functions ============

    /// @inheritdoc ILeveragedVault
    function getLeverageParameters(uint256 depositAmount)
        external view returns (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        )
    {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        return getLeverageParameters(depositAmount, $.underlyingSlippageBasisPoints, $.debtSlippageBasisPoints);
    }

    /// @inheritdoc ILeveragedVault
    function getWithdrawUnderlyingParameters(uint256 shares)
        external view returns (
            uint256 flashLoanAmount,
            uint256 repayAmount,
            uint256 minUnderlyingOut
        )
    {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        return getWithdrawUnderlyingParameters(shares, $.underlyingSlippageBasisPoints, $.debtSlippageBasisPoints);
    }

    /// @inheritdoc ILeveragedVault
    function getLeverageParameters(
        uint256 depositAmount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) public view override returns (
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        uint256 depositCapacity = getDepositCapacity();
        uint256 expectedYieldFromDeposit = $.alchemist.convertUnderlyingTokensToYield(depositAmount);

        if (depositCapacity <= expectedYieldFromDeposit) {
            clampedDeposit = $.alchemist.convertYieldTokensToUnderlying(depositCapacity);
            underlyingDepositMin = _basisPointAdjustment(depositCapacity, _underlyingSlippageBasisPoints);
        } else {
            clampedDeposit = depositAmount;
            uint256 borrowCapacity = getBorrowCapacity();

            flashLoanAmount = _calculateFlashLoanAmount(
                depositAmount,
                _underlyingSlippageBasisPoints,
                _debtSlippageBasisPoints,
                borrowCapacity,
                $.alchemist.minimumCollateralization()
            );

            // Note: flash loan fee is NOT pre-added here. The leverager handles fee
            // repayment from the debt swap output during execution. Pre-adding the fee
            // caused inconsistency when the deposit capacity check clamped flashLoanAmount.
            uint256 expectedYieldFromTotal = $.alchemist.convertUnderlyingTokensToYield(depositAmount + flashLoanAmount);
            if (expectedYieldFromTotal > depositCapacity) {
                uint256 maxUnderlying = $.alchemist.convertYieldTokensToUnderlying(depositCapacity);
                flashLoanAmount = maxUnderlying > depositAmount ? maxUnderlying - depositAmount : 0;
                expectedYieldFromTotal = depositCapacity;
            }

            underlyingDepositMin = _basisPointAdjustment(expectedYieldFromTotal, _underlyingSlippageBasisPoints);

            // Convert yield → underlying → debt units so newBorrowCapacity matches borrowCapacity units
            uint256 minUnderlyingValue = $.alchemist.convertYieldTokensToUnderlying(underlyingDepositMin);
            uint256 minDebtValue = $.alchemist.normalizeUnderlyingTokensToDebt(minUnderlyingValue);
            uint256 newBorrowCapacity = minDebtValue * FIXED_POINT_SCALAR / $.alchemist.minimumCollateralization();
            mintAmount = borrowCapacity + newBorrowCapacity;

            debtTradeMin = _basisPointAdjustment(mintAmount, _debtSlippageBasisPoints);
        }
    }

    /// @inheritdoc ILeveragedVault
    /// @dev For repay-based deleverage, the debt slippage BPS only applies to the
    ///      underlying→MYT conversion (which is deterministic via VaultV2, so typically ~0).
    ///      The underlying slippage BPS applies to minimum output protection.
    function getWithdrawUnderlyingParameters(
        uint256 shares,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) public view override returns (
        uint256 flashLoanAmount,
        uint256 repayAmount,
        uint256 minUnderlyingOut
    ) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        uint256 underlyingAmount = convertToAssets(shares);
        uint256 poolBalance = $.underlyingToken.balanceOf(address(this));

        // Path 1: Pool has enough for direct transfer (matches _executeWithdraw path 1)
        if (poolBalance >= underlyingAmount) {
            minUnderlyingOut = underlyingAmount;
            return (flashLoanAmount, repayAmount, minUnderlyingOut);
        }

        // Combine pool balance + free Alchemist collateral for total non-flash-loan capacity
        uint256 availableUnderlying = getFreeWithdrawCapacity() + poolBalance;

        if (underlyingAmount <= availableUnderlying) {
            // Path 2: Pool + Alchemist withdrawal without deleveraging
            minUnderlyingOut = _basisPointAdjustment(underlyingAmount, _underlyingSlippageBasisPoints);
        } else {
            // Path 3: Repay-based deleverage needed
            // For the repay path: flash loan underlying → convert to MYT → repay → withdraw freed MYT → convert to underlying
            // repayAmount is in MYT terms: convert the remaining underlying deficit to yield tokens
            uint256 remainingUnderlying = underlyingAmount - availableUnderlying;

            // repayAmount in MYT = debt equivalent of remainingUnderlying, adjusted for collateralization
            // Each MYT of repay frees (minColl / (minColl - 1e18)) MYT of collateral
            // Use ceiling division (+denominator-1) for rounding safety.
            uint256 minColl = $.alchemist.minimumCollateralization();
            uint256 denominator = minColl - FIXED_POINT_SCALAR;
            uint256 repayUnderlying = (remainingUnderlying * FIXED_POINT_SCALAR + denominator - 1) / denominator;
            repayAmount = $.alchemist.convertUnderlyingTokensToYield(repayUnderlying);

            // For near-full withdrawals, the computed repayAmount can fall short of total debt
            // by a few wei due to accumulated fixed-point rounding across conversion functions.
            // This leaves dust debt that triggers Undercollateralized on the subsequent withdraw.
            // Fix: when repayAmount covers > 90% of actual debt, round up to clear all debt.
            (, uint256 currentDebt, ) = $.alchemist.getCDP($.vaultPositionId);
            if (currentDebt > 0) {
                uint256 debtInMyt = $.alchemist.convertDebtTokensToYield(currentDebt);
                if (repayAmount > debtInMyt * 90 / 100) {
                    // Overshoot slightly: alchemist.repay() caps credit at actual debt,
                    // so excess MYT is harmlessly left in the vault.
                    repayAmount = debtInMyt + 10;
                    repayUnderlying = $.alchemist.convertYieldTokensToUnderlying(repayAmount);
                }
            }

            // Flash loan needs to cover the underlying for the repay conversion
            flashLoanAmount = repayUnderlying;

            // minOutput: all deterministic via VaultV2, but apply slippage tolerance for safety
            minUnderlyingOut = _basisPointAdjustment(underlyingAmount, _underlyingSlippageBasisPoints);
        }
    }

    /// @dev Computes the optimal flash loan size for a leverage operation.
    /// @param depositAmount Amount of underlying tokens being deposited.
    /// @param _underlyingSlippageBasisPoints Slippage tolerance for underlying operations.
    /// @param _debtSlippageBasisPoints Slippage tolerance for debt token swaps.
    /// @param borrowCapacity Current remaining borrow capacity on the position.
    /// @param minimumCollateralization Alchemist minimum collateralization ratio (1e18 = 100%).
    /// @return flashLoanAmount The recommended flash loan amount in underlying tokens.
    function _calculateFlashLoanAmount(
        uint256 depositAmount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 borrowCapacity,
        uint256 minimumCollateralization
    ) internal pure returns (uint256 flashLoanAmount) {
        uint256 debtTradeLoss = _basisPointAdjustment(FIXED_POINT_SCALAR, _debtSlippageBasisPoints);
        uint256 totalTradeLoss = _basisPointAdjustment(debtTradeLoss, _underlyingSlippageBasisPoints);

        uint256 numerator = (totalTradeLoss * depositAmount)
            + (minimumCollateralization * debtTradeLoss * borrowCapacity / FIXED_POINT_SCALAR);

        uint256 denominator = minimumCollateralization - totalTradeLoss;

        if (denominator == 0) return 0;

        flashLoanAmount = numerator / denominator;
    }

    /// @dev Applies a basis-point reduction to an amount: amount * (10000 - bps) / 10000.
    function _basisPointAdjustment(uint256 amount, uint32 slippageBasisPoints) internal pure returns (uint256) {
        return amount * (BASIS_POINTS - slippageBasisPoints) / BASIS_POINTS;
    }

    // ============ User Deposit Functions ============

    /// @inheritdoc ILeveragedVault
    function depositUnderlying(uint256 amount) external override nonReentrant whenNotPaused noConcurrentOperation returns (uint256 leveragedVaultShares) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (amount == 0) revert ZeroDeposit();
        if (amount > maxDeposit(msg.sender)) revert DepositExceedsMax();

        // Sync Alchemist position state so share price reflects accrued yield.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        leveragedVaultShares = previewDeposit(amount);
        $.underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, leveragedVaultShares);
        emit Deposit(msg.sender, msg.sender, amount, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address($.underlyingToken), amount);
    }

    /// @inheritdoc ILeveragedVault
    function depositUnderlying() external payable override nonReentrant whenNotPaused noConcurrentOperation returns (uint256 leveragedVaultShares) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (msg.value == 0) revert ZeroDeposit();
        if (msg.value > maxDeposit(msg.sender)) revert DepositExceedsMax();
        if (address($.underlyingToken) != address($.wETH)) revert NonWETHVault();

        // Sync Alchemist position state so share price reflects accrued yield.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        leveragedVaultShares = previewDeposit(msg.value);
        $.wETH.deposit{value: msg.value}();
        _depositETH(msg.sender, msg.sender, msg.value, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address($.underlyingToken), msg.value);
    }

    // ============ Deposit + Leverage Functions ============

    /// @inheritdoc ILeveragedVault
    function depositAndLeverageAtomic(
        uint256 amount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 deadline
    ) external override whenNotPaused noConcurrentOperation returns (uint256 shares) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (amount == 0) revert ZeroDeposit();
        if (amount > maxDeposit(msg.sender)) revert DepositExceedsMax();
        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();

        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();

        // Sync Alchemist position state so share price reflects accrued yield.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        // Deposit: pull tokens, mint shares
        shares = previewDeposit(amount);
        $.underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, msg.sender, amount, shares);
        emit DepositUnderlying(msg.sender, address($.underlyingToken), amount);

        // Leverage: compute params and execute
        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = getLeverageParameters(amount, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        _executeLeverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    /// @inheritdoc ILeveragedVault
    function depositAndLeverageAtomic(
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 deadline
    ) external payable override whenNotPaused noConcurrentOperation returns (uint256 shares) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert ZeroDeposit();
        if (msg.value > maxDeposit(msg.sender)) revert DepositExceedsMax();
        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();

        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (address($.underlyingToken) != address($.wETH)) revert NonWETHVault();

        // Sync Alchemist position state so share price reflects accrued yield.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        // Deposit: wrap ETH, mint shares
        shares = previewDeposit(msg.value);
        $.wETH.deposit{value: msg.value}();
        _depositETH(msg.sender, msg.sender, msg.value, shares);
        emit DepositUnderlying(msg.sender, address($.underlyingToken), msg.value);

        // Leverage: compute params and execute
        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = getLeverageParameters(msg.value, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        _executeLeverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    // ============ Leverage Functions ============

    /// @inheritdoc ILeveragedVault
    /// @dev No access control — see ILeveragedVault for security implications.
    function leverage(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin,
        uint256 deadline
    ) external override whenNotPaused noConcurrentOperation {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        _executeLeverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    /// @dev Core leverage logic shared by leverage() and leverageAtomic().
    function _executeLeverage(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) internal {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();

        // Sync Alchemist position state before reading collateral/debt values.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        uint256 poolBalance = $.underlyingToken.balanceOf(address(this));
        if (clampedDeposit > poolBalance) revert InsufficientPoolBalance();
        if (clampedDeposit == 0) revert ZeroDeposit();

        _enforceMinimumSlippage(mintAmount, debtTradeMin);

        int256 debtBefore = int256(_getVaultDebt());

        $.underlyingToken.forceApprove($.converter, clampedDeposit);
        uint256 minYieldFromDeposit = flashLoanAmount == 0 ? underlyingDepositMin : 0;
        uint256 yieldTokensReceived = ITokenConverter($.converter).toYield(
            clampedDeposit,
            address(this),
            minYieldFromDeposit
        );
        if (minYieldFromDeposit > 0) {
            if (yieldTokensReceived < minYieldFromDeposit) revert InsufficientYieldFromConversion();
        }

        uint256 minCollateralization = $.alchemist.minimumCollateralization();
        // Convert yield → underlying → debt units so newBorrowCapacity matches borrowCapacity units
        uint256 minUnderlyingValue = $.alchemist.convertYieldTokensToUnderlying(underlyingDepositMin);
        uint256 minDebtValue = $.alchemist.normalizeUnderlyingTokensToDebt(minUnderlyingValue);
        uint256 newBorrowCapacity = minDebtValue * FIXED_POINT_SCALAR / minCollateralization;
        uint256 borrowCapacity = getBorrowCapacity();
        if (mintAmount > borrowCapacity + newBorrowCapacity) revert MintExceedsCapacity();

        IERC20($.yieldToken).forceApprove($.leverager, yieldTokensReceived);

        if ($.vaultPositionId > 0) {
            $.alchemist.approveMint($.vaultPositionId, $.leverager, mintAmount);
        }

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(this),
            converter: $.converter,
            flashLoanAdapter: $.flashLoanAdapter,
            swapper: $.swapper,
            depositAmount: yieldTokensReceived,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: debtTradeMin,
            minYieldOut: underlyingDepositMin
        });

        ILeveragerV3($.leverager).leverage(params);

        int256 debtAfter = int256(_getVaultDebt());
        emit Leverage($.yieldToken, clampedDeposit + flashLoanAmount, debtAfter - debtBefore);
        emit VaultLeveraged(clampedDeposit, flashLoanAmount, mintAmount);
    }

    /// @inheritdoc ILeveragedVault
    function leverageAtomic(
        uint256 depositAmount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 deadline
    ) external override whenNotPaused noConcurrentOperation {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = getLeverageParameters(depositAmount, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        _executeLeverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    // ============ Callback Functions (called by leverager) ============

    /// @inheritdoc ILeveragedVaultCallback
    function vaultDepositYieldTokens(uint256 amount) external override nonReentrant onlyLeverager returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.alchemist.depositsPaused()) revert DepositsPaused();
        uint256 capacity = getDepositCapacity();
        if (amount > capacity) revert DepositCapExceeded();
        IERC20 yieldToken_ = IERC20($.yieldToken);
        yieldToken_.safeTransferFrom(msg.sender, address(this), amount);
        yieldToken_.forceApprove(address($.alchemist), amount);
        IAlchemistV3Position positionNFT = IAlchemistV3Position($.alchemist.alchemistPositionNFT());

        if ($.vaultPositionId == 0) {
            if (positionNFT.balanceOf(address(this)) != 0) revert PositionAlreadyExists();
            $.alchemist.deposit(amount, address(this), 0);
            uint256 balance = positionNFT.balanceOf(address(this));
            if (balance != 1) revert PositionNotMinted();
            $.vaultPositionId = positionNFT.tokenOfOwnerByIndex(address(this), 0);
            emit VaultPositionCreated($.vaultPositionId);
        } else {
            _requireSinglePosition(positionNFT);
            $.alchemist.deposit(amount, address(this), $.vaultPositionId);
        }

        return amount;
    }

    /// @inheritdoc ILeveragedVaultCallback
    function vaultMintDebtTokens(uint256 amount, address recipient) external override nonReentrant onlyLeverager {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) revert NoPosition();
        if ($.alchemist.loansPaused()) revert LoansPaused();
        IAlchemistV3Position positionNFT = IAlchemistV3Position($.alchemist.alchemistPositionNFT());
        _requireSinglePosition(positionNFT);
        if (amount > $.alchemist.getMaxBorrowable($.vaultPositionId)) revert MintExceedsCapacity();
        $.alchemist.mint($.vaultPositionId, amount, recipient);
        emit VaultDebtMinted(amount, recipient);
    }

    /// @inheritdoc ILeveragedVaultCallback
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external override nonReentrant onlyLeverager returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) revert NoPosition();
        IAlchemistV3Position positionNFT = IAlchemistV3Position($.alchemist.alchemistPositionNFT());
        _requireSinglePosition(positionNFT);
        uint256 withdrawn = $.alchemist.withdraw(amount, recipient, $.vaultPositionId);
        emit VaultYieldWithdrawn(withdrawn, recipient);
        return withdrawn;
    }

    /// @inheritdoc ILeveragedVaultCallback
    /// @dev Cannot be called in the same block as vaultMintDebtTokens (CannotRepayOnMintBlock).
    function vaultRepayWithYieldTokens(uint256 amount) external override nonReentrant onlyLeverager returns (uint256 amountRepaid) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) revert NoPosition();
        IAlchemistV3Position positionNFT = IAlchemistV3Position($.alchemist.alchemistPositionNFT());
        _requireSinglePosition(positionNFT);

        IERC20($.yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20($.yieldToken).forceApprove(address($.alchemist), amount);
        amountRepaid = $.alchemist.repay(amount, $.vaultPositionId);
        IERC20($.yieldToken).forceApprove(address($.alchemist), 0);

        emit VaultDebtRepaid(amount, amountRepaid);
    }

    // ============ Withdraw Functions ============

    /// @inheritdoc ILeveragedVault
    /// @dev Intentionally NOT gated by whenNotPaused so users can always exit.
    function withdrawUnderlying(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 repayAmount,
        uint256 minUnderlyingOut,
        uint256 deadline
    ) external override noConcurrentOperation returns (uint256 underlyingWithdrawAmount) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        return _executeWithdraw(shares, flashLoanAmount, repayAmount, minUnderlyingOut);
    }

    /// @dev Core withdrawal logic shared by withdrawUnderlying() and withdrawUnderlyingAtomic().
    function _executeWithdraw(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 repayAmount,
        uint256 minUnderlyingOut
    ) internal returns (uint256 underlyingWithdrawAmount) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();

        // Sync Alchemist position state before reading collateral/debt values.
        if ($.vaultPositionId > 0) {
            $.alchemist.poke($.vaultPositionId);
        }

        if (shares > balanceOf(msg.sender)) revert InsufficientShares();

        underlyingWithdrawAmount = convertToAssets(shares);
        uint256 poolBalance = $.underlyingToken.balanceOf(address(this));

        // Path 1: Pool has enough for direct transfer
        if (poolBalance >= underlyingWithdrawAmount) {
            _burn(msg.sender, shares);
            $.underlyingToken.safeTransfer(msg.sender, underlyingWithdrawAmount);
        // Path 2: Pool + Alchemist withdrawal without deleveraging
        } else if (repayAmount == 0) {
            uint256 neededFromAlchemist = underlyingWithdrawAmount - poolBalance;
            if ($.vaultPositionId == 0) revert NoPosition();
            _requireSinglePosition(IAlchemistV3Position($.alchemist.alchemistPositionNFT()));

            // CEI: burn shares before external calls (consistent with Path 3 / S-03 fix).
            _burn(msg.sender, shares);

            uint256 yieldToWithdraw = $.alchemist.convertUnderlyingTokensToYield(neededFromAlchemist);
            uint256 withdrawn = $.alchemist.withdraw(yieldToWithdraw, address(this), $.vaultPositionId);
            IERC20($.yieldToken).forceApprove($.converter, withdrawn);
            uint256 minOutForConverter = minUnderlyingOut > poolBalance
                ? minUnderlyingOut - poolBalance
                : 0;
            uint256 underlyingReceived = ITokenConverter($.converter).toUnderlying(
                withdrawn,
                address(this),
                minOutForConverter
            );
            uint256 totalUnderlyingOut = poolBalance + underlyingReceived;
            if (totalUnderlyingOut < minUnderlyingOut) revert InsufficientWithdrawal();
            if (totalUnderlyingOut < underlyingWithdrawAmount) revert InsufficientWithdrawal();

            $.underlyingToken.safeTransfer(msg.sender, underlyingWithdrawAmount);
        // Path 3: Flash loan repay-based deleverage (no DEX swap)
        } else {
            if ($.vaultPositionId == 0) revert NoPosition();
            _requireSinglePosition(IAlchemistV3Position($.alchemist.alchemistPositionNFT()));

            // S-02 fix: Only withdraw from Alchemist the portion not covered by pool balance.
            uint256 alchemistUnderlying = underlyingWithdrawAmount > poolBalance
                ? underlyingWithdrawAmount - poolBalance
                : 0;

            // The leverager's net output to user = withdrawAmount - repayAmount (in MYT terms,
            // converted back to underlying). So we need withdrawAmount = userPortion + repayAmount.
            uint256 userWithdrawMyt = $.alchemist.convertUnderlyingTokensToYield(alchemistUnderlying);
            uint256 withdrawMyt = userWithdrawMyt + repayAmount;

            // Cap at actual collateral to avoid undercollateralized revert from rounding.
            // When repay covers nearly all debt, all collateral becomes freely withdrawable,
            // but userWithdrawMyt + repayAmount may slightly exceed collateral due to
            // accumulated fixed-point rounding across conversion functions.
            (uint256 posCollateral, , ) = $.alchemist.getCDP($.vaultPositionId);
            if (withdrawMyt > posCollateral) {
                withdrawMyt = posCollateral;
            }

            ILeveragerV3.DeleverageRepayParams memory params = ILeveragerV3.DeleverageRepayParams({
                vault: address(this),
                converter: $.converter,
                flashLoanAdapter: $.flashLoanAdapter,
                recipient: msg.sender,
                withdrawAmount: withdrawMyt,
                flashLoanAmount: flashLoanAmount,
                repayAmount: repayAmount,
                minOutput: 0  // vault does its own post-check (H-2 fix)
            });

            // S-03 fix: Burn shares before external calls (checks-effects-interactions).
            _burn(msg.sender, shares);

            // H-2: Capture user balance BEFORE any transfers so the check covers
            // both pool portion and leverager delivery (minUnderlyingOut includes both).
            uint256 userBalBefore = $.underlyingToken.balanceOf(msg.sender);

            // Transfer pool portion to user before deleverage handles the rest.
            if (poolBalance > 0) {
                $.underlyingToken.safeTransfer(msg.sender, poolBalance);
            }

            ILeveragerV3($.leverager).deleverageRepay(params);

            if (minUnderlyingOut > 0) {
                uint256 received = $.underlyingToken.balanceOf(msg.sender) - userBalBefore;
                if (received < minUnderlyingOut) revert InsufficientWithdrawal();
            }
        }

        emit WithdrawUnderlying(msg.sender, address($.underlyingToken), shares);
        if (repayAmount > 0) {
            emit VaultDeleveraged(shares, repayAmount);
        }
    }

    /// @notice Transfers an unexpected Alchemist position NFT out of the vault.
    /// @dev Only positions other than the vault's active position can be swept.
    ///      Reverts if `tokenId` matches the active position or if the vault doesn't own it.
    /// @param tokenId The Alchemist position NFT ID to transfer out.
    /// @param to The recipient address.
    function sweepUnknownPosition(uint256 tokenId, address to) external onlyOwner {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (to == address(0)) revert InvalidRecipient();
        // S-04 fix: Allow sweeping when vaultPositionId == 0 to recover griefed positions.
        if ($.vaultPositionId != 0 && tokenId == $.vaultPositionId) revert CannotSweepActivePosition();
        IAlchemistV3Position positionNFT = IAlchemistV3Position($.alchemist.alchemistPositionNFT());
        if (positionNFT.ownerOf(tokenId) != address(this)) revert VaultNotOwner();
        positionNFT.transferFrom(address(this), to, tokenId);
        emit PositionSwept(tokenId, to);
    }

    /// @inheritdoc ILeveragedVault
    /// @dev Intentionally NOT gated by whenNotPaused so users can always exit.
    function withdrawUnderlyingAtomic(
        uint256 shares,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 deadline
    ) external override noConcurrentOperation returns (uint256 underlyingAmount) {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        (
            uint256 flashLoanAmount,
            uint256 repayAmount,
            uint256 minUnderlyingOut
        ) = getWithdrawUnderlyingParameters(shares, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        return _executeWithdraw(shares, flashLoanAmount, repayAmount, minUnderlyingOut);
    }

    // ============ Internal Helpers ============

    /// @dev Returns the vault's current debt from its Alchemist position, or 0 if no position.
    function _getVaultDebt() internal view returns (uint256) {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if ($.vaultPositionId == 0) return 0;
        (, uint256 debt, ) = $.alchemist.getCDP($.vaultPositionId);
        return debt;
    }

    /// @dev Asserts the vault holds exactly one position NFT and owns the recorded position.
    function _requireSinglePosition(IAlchemistV3Position positionNFT) internal view {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (positionNFT.balanceOf(address(this)) != 1) revert MultiplePositions();
        if (positionNFT.ownerOf($.vaultPositionId) != address(this)) revert NotPositionOwner();
    }

    // ============ ERC4626 Overrides ============

    /// @inheritdoc ERC4626Upgradeable
    /// @dev totalAssets() reads the Alchemist's convertYieldTokensToUnderlying(), which depends
    ///      on the yield token adapter's price feed. For wstETH this is Lido's stEthPerToken()
    ///      (~$20B TVL, manipulation-infeasible). Future yield token integrations MUST use a
    ///      manipulation-resistant price source — AMM spot prices are NOT safe here, as a
    ///      flash-loan price manipulation would directly affect share price during deposits
    ///      and withdrawals.
    function totalAssets() public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return getVaultRedeemableBalance();
    }

    /// @dev Virtual share offset for ERC4626 inflation attack protection.
    /// A value of 3 creates 10^3 = 1000 virtual shares, requiring an attacker to
    /// donate ~1000x the victim's deposit to execute an inflation attack (economically infeasible).
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3;
    }

    // ============ ETH Handling ============

    /// @dev Allows the vault to receive ETH (e.g. during WETH unwrapping in flash loan repayment).
    receive() external payable {}

    // ============ Slippage Enforcement ============

    /// @dev Ensures the debt swap minimum is not unreasonably low relative to the vault's configured slippage.
    ///      When debtSlippageBasisPoints == 0, enforces debtTradeMin >= mintAmount (zero tolerance).
    function _enforceMinimumSlippage(uint256 mintAmount, uint256 debtTradeMin) internal view {
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (mintAmount > 0) {
            uint256 enforcementBps = uint256($.debtSlippageBasisPoints);
            if (enforcementBps >= BASIS_POINTS) enforcementBps = BASIS_POINTS - 1;
            uint256 minAcceptableSwap = mintAmount * (BASIS_POINTS - enforcementBps) / BASIS_POINTS;
            if (debtTradeMin < minAcceptableSwap) revert SwapSlippageBelowMinimum();
        }
    }

    // ============ ERC721 Receiver ============

    /// @dev Allows the vault to receive ERC721 tokens (AlchemistV3 position NFTs).
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ============ Admin Functions ============

    /// @notice Pauses deposits and leverage operations. Withdrawals remain available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resumes deposits and leverage operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Updates the vault's default slippage parameters.
    /// @param _underlyingSlippageBasisPoints New slippage for underlying token operations (< 10000).
    /// @param _debtSlippageBasisPoints New slippage for debt token swaps (< 10000).
    function setSlippageParameters(
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) external onlyOwner {
        if (_underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (_debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        $.underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        $.debtSlippageBasisPoints = _debtSlippageBasisPoints;
        emit SlippageParametersUpdated(_underlyingSlippageBasisPoints, _debtSlippageBasisPoints);
    }

    /// @notice Transfers accidentally-sent ERC20 tokens out of the vault.
    /// @dev Cannot sweep the vault's underlying or yield token to prevent rug pulls.
    /// @param token The ERC20 token address to sweep.
    /// @param amount The amount to transfer.
    /// @param recipient The address to receive the tokens.
    function emergencySweepToken(address token, uint256 amount, address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        LeveragedVaultStorage storage $ = _getLeveragedVaultStorage();
        if (token == address($.underlyingToken) || token == $.yieldToken) revert CannotSweepVaultToken();
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencySweep(token, amount, recipient);
    }

    /// @notice Transfers ETH stuck in the vault (e.g. from selfdestruct or coinbase) to a recipient.
    /// @param recipient The address to receive the ETH.
    function emergencySweepETH(address payable recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToSweep();
        (bool success,) = recipient.call{value: balance}("");
        if (!success) revert ETHTransferFailed();
        emit EmergencySweepETH(balance, recipient);
    }
}
