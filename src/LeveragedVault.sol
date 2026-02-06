// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "./interfaces/ILeveragedVault.sol";
import "./interfaces/ILeveragedVaultCallback.sol";
import "./interfaces/ILeveragerV3.sol";
import "./interfaces/ITokenConverter.sol";
import "./interfaces/flashloan/IFlashLoanAdapter.sol";
import {IWETH} from "alchemix-v3/src/interfaces/IWETH.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

/**
 * @title LeveragedVault
 * @notice ERC4626 vault that manages a shared leveraged position in AlchemistV3
 * @dev Users deposit underlying tokens, and leverage() is called to create a shared leveraged position.
 *      All depositors benefit proportionally from the leveraged yield.
 *
 * Architecture:
 * - Users call depositUnderlying() to add funds to the pool
 * - Operator calls leverage() to leverage the pooled deposits
 * - All depositors share in the leveraged position proportionally
 * - Users can withdraw via withdrawUnderlying() (may trigger deleveraging)
 */
contract LeveragedVault is Ownable, ERC4626, ReentrancyGuard, Pausable, ILeveragedVault, ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 constant BASIS_POINTS = 10000;

    // ============ Immutables ============

    IAlchemistV3 public immutable alchemist;
    IERC20 private immutable _underlyingToken;
    address private immutable _yieldToken;
    address public immutable leverager;

    /// @notice WETH contract address
    IWETH public immutable wETH;

    // ============ State ============

    /// @notice The vault's single shared AlchemistV3 position NFT ID
    uint256 public vaultPositionId;

    /// @dev Prevent overlapping leverage/deleverage operations
    bool private _operationInProgress;

    // ============ Default Adapters (V3) ============

    /// @notice Default token converter (underlying ↔ yield)
    address public defaultConverter;
    /// @notice Default flash loan adapter
    address public defaultFlashLoanAdapter;
    /// @notice Default swapper (debt ↔ underlying)
    address public defaultSwapper;

    // ============ Default Slippage Parameters ============

    /// @notice Default slippage tolerance for underlying token operations (basis points, e.g. 100 = 1%)
    uint32 public underlyingSlippageBasisPoints;
    /// @notice Default slippage tolerance for debt token swap (basis points, includes peg deviation)
    uint32 public debtSlippageBasisPoints;

    // ============ Events ============

    event VaultLeveraged(uint256 depositAmount, uint256 flashLoanAmount, uint256 debtMinted);
    event VaultDeleveraged(uint256 sharesWithdrawn, uint256 debtBurned);
    event DefaultAdapterSet(string adapterType, address adapter);
    event SlippageParametersUpdated(uint32 underlyingSlippageBps, uint32 debtSlippageBps);

    // ============ Modifiers ============

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    modifier noConcurrentOperation() {
        require(!_operationInProgress, "Operation in progress");
        _operationInProgress = true;
        _;
        _operationInProgress = false;
    }

    // ============ Constructor ============

    constructor(
        string memory tokenName,
        string memory tokenDescription,
        address yieldToken,
        address underlyingTokenAddress,
        address _alchemist,
        address _leverager,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        address _defaultConverter,
        address _defaultFlashLoanAdapter,
        address _defaultSwapper,
        address _weth
    ) payable
        ERC4626(IERC20(underlyingTokenAddress))
        ERC20(tokenDescription, tokenName)
        Ownable(msg.sender)
    {
        require(_alchemist != address(0), "Alchemist cannot be zero");
        require(_leverager != address(0), "Leverager cannot be zero");
        require(yieldToken != address(0), "Yield token cannot be zero");
        require(underlyingTokenAddress != address(0), "Underlying token cannot be zero");
        require(_weth != address(0), "WETH cannot be zero");
        alchemist = IAlchemistV3(_alchemist);
        leverager = _leverager;
        _underlyingToken = IERC20(underlyingTokenAddress);
        _yieldToken = yieldToken;
        underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        debtSlippageBasisPoints = _debtSlippageBasisPoints;
        defaultConverter = _defaultConverter;
        defaultFlashLoanAdapter = _defaultFlashLoanAdapter;
        defaultSwapper = _defaultSwapper;
        wETH = IWETH(_weth);
    }

    // ============ View Functions ============

    /// @inheritdoc ILeveragedVault
    function getYieldToken() external view override(ILeveragedVault) returns (address) {
        return _yieldToken;
    }

    /// @inheritdoc ILeveragedVault
    function getUnderlyingToken() external view override(ILeveragedVault) returns (address) {
        return address(_underlyingToken);
    }

    /// @inheritdoc ILeveragedVault
    function getDepositPoolBalance() external view override returns (uint256) {
        return _underlyingToken.balanceOf(address(this));
    }

    /// @inheritdoc ILeveragedVault
    function getVaultDepositedBalance() external view override returns (uint256) {
        if (vaultPositionId == 0) return 0;
        (uint256 collateral, , ) = alchemist.getCDP(vaultPositionId);
        return collateral;
    }

    /// @inheritdoc ILeveragedVault
    function getVaultDebtBalance() external view override returns (int256) {
        if (vaultPositionId == 0) return 0;
        (, uint256 debt, ) = alchemist.getCDP(vaultPositionId);
        return int256(debt);
    }

    /// @inheritdoc ILeveragedVault
    function getVaultRedeemableBalance() public view override returns (uint256) {
        uint256 poolBalance = _underlyingToken.balanceOf(address(this));
        if (vaultPositionId == 0) return poolBalance;

        (uint256 collateral, uint256 debt, ) = alchemist.getCDP(vaultPositionId);
        uint256 collateralUnderlying = alchemist.convertYieldTokensToUnderlying(collateral);
        uint256 debtInUnderlying = alchemist.normalizeDebtTokensToUnderlying(debt);
        uint256 alchemistBalance = collateralUnderlying > debtInUnderlying
            ? collateralUnderlying - debtInUnderlying
            : 0;

        return poolBalance + alchemistBalance;
    }

    /// @inheritdoc ILeveragedVault
    function getDepositCapacity() public view override returns (uint256) {
        uint256 depositCap = alchemist.depositCap();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        if (depositCap >= totalDeposited) {
            return depositCap - totalDeposited;
        }
        return 0;
    }

    /// @inheritdoc ILeveragedVault
    function getBorrowCapacity() public view override returns (uint256) {
        if (vaultPositionId == 0) return 0;
        return alchemist.getMaxBorrowable(vaultPositionId);
    }

    /// @inheritdoc ILeveragedVault
    function getFreeWithdrawCapacity() public view override returns (uint256) {
        if (vaultPositionId == 0) return 0;

        uint256 minimumCollateralization = alchemist.minimumCollateralization();
        (uint256 collateral, uint256 debt, ) = alchemist.getCDP(vaultPositionId);

        uint256 collateralUnderlying = alchemist.convertYieldTokensToUnderlying(collateral);
        if (debt == 0) return collateralUnderlying;

        // Calculate how much collateral is locked to back the debt
        uint256 debtInUnderlying = alchemist.normalizeDebtTokensToUnderlying(debt);
        uint256 lockedCollateral = debtInUnderlying * minimumCollateralization / FIXED_POINT_SCALAR;

        if (collateralUnderlying > lockedCollateral) {
            return collateralUnderlying - lockedCollateral;
        }
        return 0;
    }

    /// @inheritdoc ILeveragedVault
    function getTotalWithdrawCapacity() public view override returns (uint256) {
        if (vaultPositionId == 0) return 0;
        (uint256 collateral, , ) = alchemist.getCDP(vaultPositionId);
        return alchemist.convertYieldTokensToUnderlying(collateral);
    }

    /// @inheritdoc ILeveragedVault
    function convertUnderlyingTokensToShares(uint256 amount) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return amount;
        uint256 redeemable = getVaultRedeemableBalance();
        if (redeemable == 0) return amount;
        return amount * supply / redeemable;
    }

    /// @inheritdoc ILeveragedVault
    function convertSharesToUnderlyingTokens(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return shares * getVaultRedeemableBalance() / supply;
    }

    /// @inheritdoc ILeveragedVaultCallback
    function getVaultPositionId() external view override returns (uint256) {
        return vaultPositionId;
    }

    // ============ Parameter Calculation Functions ============

    /// @notice Calculate leverage parameters using vault's default slippage settings
    /// @param depositAmount Amount of underlying tokens to leverage
    function getLeverageParameters(uint256 depositAmount)
        external view returns (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        )
    {
        return getLeverageParameters(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
    }

    /// @notice Calculate withdraw parameters using vault's default slippage settings
    /// @param shares Amount of vault shares to withdraw
    function getWithdrawUnderlyingParameters(uint256 shares)
        external view returns (
            uint256 flashLoanAmount,
            uint256 burnAmount,
            uint256 minUnderlyingOut
        )
    {
        return getWithdrawUnderlyingParameters(shares, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
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
        uint256 depositCapacity = getDepositCapacity(); // yield token units
        uint256 expectedYieldFromDeposit = alchemist.convertUnderlyingTokensToYield(depositAmount);

        if (depositCapacity <= expectedYieldFromDeposit) {
            // Vault is at or near capacity - just deposit what we can, no flash loan
            clampedDeposit = alchemist.convertYieldTokensToUnderlying(depositCapacity);
            underlyingDepositMin = _basisPointAdjustment(depositCapacity, _underlyingSlippageBasisPoints);
            // No flash loan, no mint, no trade
        } else {
            clampedDeposit = depositAmount;
            uint256 borrowCapacity = getBorrowCapacity();

            flashLoanAmount = _calculateFlashLoanAmount(
                depositAmount,
                _underlyingSlippageBasisPoints,
                _debtSlippageBasisPoints,
                borrowCapacity,
                alchemist.minimumCollateralization()
            );
            if (flashLoanAmount > 0 && defaultFlashLoanAdapter.code.length > 0) {
                uint256 fee = IFlashLoanAdapter(defaultFlashLoanAdapter).getFlashLoanFee(
                    address(_underlyingToken),
                    flashLoanAmount
                );
                flashLoanAmount += fee;
            }

            // Clamp flash loan to deposit capacity
            uint256 expectedYieldFromTotal = alchemist.convertUnderlyingTokensToYield(depositAmount + flashLoanAmount);
            if (expectedYieldFromTotal > depositCapacity) {
                uint256 maxUnderlying = alchemist.convertYieldTokensToUnderlying(depositCapacity);
                flashLoanAmount = maxUnderlying > depositAmount ? maxUnderlying - depositAmount : 0;
                expectedYieldFromTotal = depositCapacity;
            }

            // Calculate expected yield tokens from total deposit
            underlyingDepositMin = _basisPointAdjustment(expectedYieldFromTotal, _underlyingSlippageBasisPoints);

            // Calculate mint amount: existing borrow capacity + new capacity from deposit
            // New capacity = deposit value / collateralization ratio
            uint256 minUnderlyingValue = alchemist.convertYieldTokensToUnderlying(underlyingDepositMin);
            uint256 newBorrowCapacity = minUnderlyingValue * FIXED_POINT_SCALAR / alchemist.minimumCollateralization();
            mintAmount = borrowCapacity + newBorrowCapacity;

            // Calculate minimum underlying from debt swap
            debtTradeMin = _basisPointAdjustment(mintAmount, _debtSlippageBasisPoints);
        }
    }

    /// @inheritdoc ILeveragedVault
    function getWithdrawUnderlyingParameters(
        uint256 shares,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) public view override returns (
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    ) {
        uint256 freeUnderlying = getFreeWithdrawCapacity();
        uint256 underlyingAmount = convertSharesToUnderlyingTokens(shares);

        if (underlyingAmount <= freeUnderlying) {
            // Simple withdrawal - no deleveraging needed
            minUnderlyingOut = _basisPointAdjustment(underlyingAmount, _underlyingSlippageBasisPoints);
        } else {
            // Need to deleverage to free up collateral
            uint256 remainingUnderlying = underlyingAmount - freeUnderlying;
            uint256 debtTradeLoss = _basisPointAdjustment(1 ether, _debtSlippageBasisPoints);

            // Calculate flash loan needed to free remaining shares
            // Flash loan → swap to debt → burn debt → withdraw collateral → repay flash loan
            flashLoanAmount = remainingUnderlying * FIXED_POINT_SCALAR * FIXED_POINT_SCALAR
                / (alchemist.minimumCollateralization() * debtTradeLoss);

            burnAmount = _basisPointAdjustment(flashLoanAmount, _debtSlippageBasisPoints);
            minUnderlyingOut = _basisPointAdjustment(
                flashLoanAmount - burnAmount + freeUnderlying,
                _underlyingSlippageBasisPoints
            );
        }
    }

    /**
     * @notice Calculate optimal flash loan amount for leverage
     * @dev Formula derivation:
     *      We want to maximize leverage while ensuring we can repay the flash loan.
     *
     *      Let:
     *      - D = deposit amount
     *      - X = flash loan amount
     *      - CR = collateralization ratio (e.g., 1.11 for 111%)
     *      - debtLoss = 1 - debtSlippage (what we get back per unit of debt swapped)
     *      - totalLoss = debtLoss * (1 - underlyingSlippage)
     *
     *      After depositing (D + X), we can mint (D + X) / CR in debt.
     *      Plus we have existing borrowCapacity.
     *      We swap debt for underlying to repay X.
     *
     *      Solving for X where repay amount = flash loan amount:
     *      X = ((totalLoss * D) + (CR * debtLoss * borrowCapacity)) / (CR - totalLoss)
     */
    function _calculateFlashLoanAmount(
        uint256 depositAmount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints,
        uint256 borrowCapacity,
        uint256 minimumCollateralization
    ) internal pure returns (uint256 flashLoanAmount) {
        // debtTradeLoss represents what fraction we keep after debt swap
        uint256 debtTradeLoss = _basisPointAdjustment(1 ether, _debtSlippageBasisPoints);
        // totalTradeLoss accounts for both underlying and debt slippage
        uint256 totalTradeLoss = _basisPointAdjustment(debtTradeLoss, _underlyingSlippageBasisPoints);

        // Numerator: (totalTradeLoss * depositAmount) + (CR * debtTradeLoss * borrowCapacity / 1e18)
        uint256 numerator = (totalTradeLoss * depositAmount)
            + (minimumCollateralization * debtTradeLoss * borrowCapacity / FIXED_POINT_SCALAR);

        // Denominator: CR - totalTradeLoss
        uint256 denominator = minimumCollateralization - totalTradeLoss;

        if (denominator == 0) return 0;

        flashLoanAmount = numerator / denominator;
    }

    /**
     * @notice Apply slippage reduction to an amount
     * @param amount Original amount
     * @param slippageBasisPoints Slippage in basis points (e.g., 100 = 1%)
     * @return Reduced amount after slippage
     */
    function _basisPointAdjustment(uint256 amount, uint32 slippageBasisPoints) internal pure returns (uint256) {
        return amount * (BASIS_POINTS - slippageBasisPoints) / BASIS_POINTS;
    }

    // ============ User Deposit Functions ============

    /// @inheritdoc ILeveragedVault
    function depositUnderlying(uint256 amount) external override whenNotPaused returns (uint256 leveragedVaultShares) {
        require(amount <= maxDeposit(msg.sender), "ERC4626: deposit more than max");

        leveragedVaultShares = previewDeposit(amount);
        _underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, leveragedVaultShares);
        emit Deposit(msg.sender, msg.sender, amount, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address(_underlyingToken), amount);
    }

    /// @inheritdoc ILeveragedVault
    function depositUnderlying() external payable override whenNotPaused returns (uint256 leveragedVaultShares) {
        require(msg.value <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
        require(address(_underlyingToken) == address(wETH), "ERC4626: depositing ETH to non-wETH vault");
        // Calculate shares BEFORE wrapping ETH, so totalAssets() doesn't include this deposit yet
        leveragedVaultShares = previewDeposit(msg.value);
        wETH.deposit{value: msg.value}();
        _depositETH(msg.sender, msg.sender, msg.value, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address(_underlyingToken), msg.value);
    }

    // ============ Leverage Functions ============

    /// @inheritdoc ILeveragedVault
    function leverage(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) external override whenNotPaused noConcurrentOperation {
        _leverageWithAdapters(
            clampedDeposit,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin,
            defaultConverter,
            defaultFlashLoanAdapter,
            defaultSwapper
        );
    }

    /// @notice Execute leverage with custom adapters
    /// @dev Allows users to specify different adapters than defaults
    function leverageWithAdapters(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin,
        address converter,
        address flashLoanAdapter,
        address swapper
    ) external whenNotPaused noConcurrentOperation {
        _leverageWithAdapters(
            clampedDeposit,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin,
            converter,
            flashLoanAdapter,
            swapper
        );
    }

    function _leverageWithAdapters(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin,
        address converter,
        address flashLoanAdapter,
        address swapper
    ) internal {
        uint256 poolBalance = _underlyingToken.balanceOf(address(this));
        require(clampedDeposit <= poolBalance, "Insufficient pool balance");
        require(clampedDeposit > 0, "Must deposit something");
        require(converter != address(0), "Converter not set");
        require(flashLoanAdapter != address(0), "Flash loan adapter not set");
        require(swapper != address(0), "Swapper not set");

        // Enforce minimum slippage protection on debt swap (sandwich attack vector)
        _enforceMinimumSlippage(mintAmount, debtTradeMin);

        int256 debtBefore = int256(_getVaultDebt());

        // Convert underlying → yield tokens using the converter
        _underlyingToken.forceApprove(converter, clampedDeposit);
        uint256 minYieldFromDeposit = flashLoanAmount == 0 ? underlyingDepositMin : 0;
        uint256 yieldTokensReceived = ITokenConverter(converter).toYield(
            clampedDeposit,
            address(this),
            minYieldFromDeposit
        );
        if (minYieldFromDeposit > 0) {
            require(yieldTokensReceived >= minYieldFromDeposit, "Insufficient yield tokens from conversion");
        }

        uint256 minCollateralization = alchemist.minimumCollateralization();
        uint256 minUnderlyingValue = alchemist.convertYieldTokensToUnderlying(underlyingDepositMin);
        uint256 newBorrowCapacity = minUnderlyingValue * FIXED_POINT_SCALAR / minCollateralization;
        uint256 borrowCapacity = getBorrowCapacity();
        require(mintAmount <= borrowCapacity + newBorrowCapacity, "Mint exceeds capacity");

        // Approve leverager to pull yield tokens
        IERC20(_yieldToken).forceApprove(leverager, yieldTokensReceived);

        // Approve leverager to mint debt from our position (if position exists)
        if (vaultPositionId > 0) {
            alchemist.approveMint(vaultPositionId, leverager, mintAmount);
        }

        // Construct V3 leverage params
        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(this),
            converter: converter,
            flashLoanAdapter: flashLoanAdapter,
            swapper: swapper,
            depositAmount: yieldTokensReceived,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: debtTradeMin,
            minYieldOut: underlyingDepositMin
        });

        // Call V3 leverager
        ILeveragerV3(leverager).leverage(params);

        int256 debtAfter = int256(_getVaultDebt());
        emit Leverage(_yieldToken, clampedDeposit + flashLoanAmount, debtAfter - debtBefore);
        emit VaultLeveraged(clampedDeposit, flashLoanAmount, mintAmount);
    }

    /// @inheritdoc ILeveragedVault
    function leverageAtomic(
        uint256 depositAmount,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) external override whenNotPaused noConcurrentOperation {
        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = getLeverageParameters(depositAmount, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        _leverageWithAdapters(
            clampedDeposit,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin,
            defaultConverter,
            defaultFlashLoanAdapter,
            defaultSwapper
        );
    }

    // ============ Callback Functions (called by leverager) ============

    /// @inheritdoc ILeveragedVaultCallback
    function vaultDepositYieldTokens(uint256 amount) external override nonReentrant onlyLeverager returns (uint256) {
        require(!alchemist.depositsPaused(), "Deposits paused");
        uint256 capacity = getDepositCapacity();
        require(amount <= capacity, "Deposit cap exceeded");
        IERC20 yieldToken = IERC20(_yieldToken);
        yieldToken.safeTransferFrom(msg.sender, address(this), amount);
        yieldToken.forceApprove(address(alchemist), amount);
        IAlchemistV3Position positionNFT = IAlchemistV3Position(alchemist.alchemistPositionNFT());

        if (vaultPositionId == 0) {
            require(positionNFT.balanceOf(address(this)) == 0, "Position already exists");
            // Create new position via AlchemistV3 (mints the NFT internally)
            alchemist.deposit(amount, address(this), 0);
            uint256 balance = positionNFT.balanceOf(address(this));
            require(balance == 1, "Position not minted");
            vaultPositionId = positionNFT.tokenOfOwnerByIndex(address(this), 0);
            emit VaultPositionCreated(vaultPositionId);
        } else {
            _requireSinglePosition(positionNFT);
            // Deposit to existing position
            alchemist.deposit(amount, address(this), vaultPositionId);
        }

        return amount;
    }

    /// @inheritdoc ILeveragedVaultCallback
    function vaultMintDebtTokens(uint256 amount, address recipient) external override nonReentrant onlyLeverager {
        require(vaultPositionId > 0, "No position");
        require(!alchemist.loansPaused(), "Loans paused");
        IAlchemistV3Position positionNFT = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        _requireSinglePosition(positionNFT);
        require(amount <= alchemist.getMaxBorrowable(vaultPositionId), "Mint exceeds capacity");
        alchemist.mint(vaultPositionId, amount, recipient);
    }

    /// @inheritdoc ILeveragedVaultCallback
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external override nonReentrant onlyLeverager returns (uint256) {
        require(vaultPositionId > 0, "No position");
        IAlchemistV3Position positionNFT = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        _requireSinglePosition(positionNFT);
        return alchemist.withdraw(amount, recipient, vaultPositionId);
    }

    /// @inheritdoc ILeveragedVaultCallback
    function vaultBurnDebtTokens(uint256 amount) external override nonReentrant onlyLeverager {
        require(vaultPositionId > 0, "No position");
        address debtToken = alchemist.debtToken();
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(debtToken).forceApprove(address(alchemist), amount);
        alchemist.burn(amount, vaultPositionId);
    }

    // ============ Withdraw Functions ============

    /// @inheritdoc ILeveragedVault
    function withdrawUnderlying(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    ) external override noConcurrentOperation returns (uint256 underlyingWithdrawAmount) {
        return _withdrawUnderlyingWithAdapters(
            shares,
            flashLoanAmount,
            burnAmount,
            minUnderlyingOut,
            defaultConverter,
            defaultFlashLoanAdapter,
            defaultSwapper
        );
    }

    /// @notice Withdraw with custom adapters
    function withdrawUnderlyingWithAdapters(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut,
        address converter,
        address flashLoanAdapter,
        address swapper
    ) external noConcurrentOperation returns (uint256 underlyingWithdrawAmount) {
        return _withdrawUnderlyingWithAdapters(
            shares,
            flashLoanAmount,
            burnAmount,
            minUnderlyingOut,
            converter,
            flashLoanAdapter,
            swapper
        );
    }

    function _withdrawUnderlyingWithAdapters(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut,
        address converter,
        address flashLoanAdapter,
        address swapper
    ) internal returns (uint256 underlyingWithdrawAmount) {
        require(shares <= balanceOf(msg.sender), "Insufficient shares");

        underlyingWithdrawAmount = convertSharesToUnderlyingTokens(shares);
        uint256 poolBalance = _underlyingToken.balanceOf(address(this));

        if (poolBalance >= underlyingWithdrawAmount) {
            // Simple case: pool has enough unleveraged funds
            _burn(msg.sender, shares);
            _underlyingToken.safeTransfer(msg.sender, underlyingWithdrawAmount);
        } else if (burnAmount == 0) {
            // Need to withdraw from Alchemist but no debt to burn (free collateral)
            uint256 neededFromAlchemist = underlyingWithdrawAmount - poolBalance;
            require(vaultPositionId > 0, "No position to withdraw from");
            require(converter != address(0), "Converter not set");
            _requireSinglePosition(IAlchemistV3Position(alchemist.alchemistPositionNFT()));

            uint256 yieldToWithdraw = alchemist.convertUnderlyingTokensToYield(neededFromAlchemist);
            uint256 withdrawn = alchemist.withdraw(yieldToWithdraw, address(this), vaultPositionId);
            IERC20(_yieldToken).forceApprove(converter, withdrawn);
            uint256 minOutForConverter = minUnderlyingOut > poolBalance
                ? minUnderlyingOut - poolBalance
                : 0;
            uint256 underlyingReceived = ITokenConverter(converter).toUnderlying(
                withdrawn,
                address(this),
                minOutForConverter
            );
            uint256 totalUnderlyingOut = poolBalance + underlyingReceived;
            require(totalUnderlyingOut >= minUnderlyingOut, "Insufficient withdrawal");
            require(totalUnderlyingOut >= underlyingWithdrawAmount, "Insufficient withdrawal");

            _burn(msg.sender, shares);
            _underlyingToken.safeTransfer(msg.sender, underlyingWithdrawAmount);
        } else {
            // Need to deleverage: flash loan → swap to debt → burn → withdraw → repay
            require(vaultPositionId > 0, "No position");
            require(converter != address(0), "Converter not set");
            require(flashLoanAdapter != address(0), "Flash loan adapter not set");
            require(swapper != address(0), "Swapper not set");
            _requireSinglePosition(IAlchemistV3Position(alchemist.alchemistPositionNFT()));

            // Construct V3 deleverage params
            ILeveragerV3.DeleverageParams memory params = ILeveragerV3.DeleverageParams({
                vault: address(this),
                converter: converter,
                flashLoanAdapter: flashLoanAdapter,
                swapper: swapper,
                recipient: msg.sender,
                withdrawAmount: alchemist.convertUnderlyingTokensToYield(underlyingWithdrawAmount),
                flashLoanAmount: flashLoanAmount,
                burnAmount: burnAmount,
                minOutput: minUnderlyingOut
            });

            // Call V3 leverager
            ILeveragerV3(leverager).deleverage(params);

            _burn(msg.sender, shares);
            // Leverager sends underlying directly to user
        }

        emit WithdrawUnderlying(msg.sender, address(_underlyingToken), shares);
        emit VaultDeleveraged(shares, burnAmount);
    }

    function sweepUnknownPosition(uint256 tokenId, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(vaultPositionId != 0, "No stored position");
        require(tokenId != vaultPositionId, "Cannot sweep active position");
        IAlchemistV3Position positionNFT = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        require(positionNFT.ownerOf(tokenId) == address(this), "Vault not owner");
        positionNFT.transferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc ILeveragedVault
    function withdrawUnderlyingAtomic(
        uint256 shares,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) external override noConcurrentOperation returns (uint256 underlyingAmount) {
        (
            uint256 flashLoanAmount,
            uint256 burnAmount,
            uint256 minUnderlyingOut
        ) = getWithdrawUnderlyingParameters(shares, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints);

        return _withdrawUnderlyingWithAdapters(
            shares,
            flashLoanAmount,
            burnAmount,
            minUnderlyingOut,
            defaultConverter,
            defaultFlashLoanAdapter,
            defaultSwapper
        );
    }

    // ============ Internal Helpers ============

    function _getVaultDebt() internal view returns (uint256) {
        if (vaultPositionId == 0) return 0;
        (, uint256 debt, ) = alchemist.getCDP(vaultPositionId);
        return debt;
    }

    function _requireSinglePosition(IAlchemistV3Position positionNFT) internal view {
        require(positionNFT.balanceOf(address(this)) == 1, "Multiple positions");
        require(positionNFT.ownerOf(vaultPositionId) == address(this), "Not position owner");
    }

    // ============ ERC4626 Overrides ============

    function totalAssets() public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return getVaultRedeemableBalance();
    }

    // ============ ETH Handling ============

    /// @notice Allow vault to receive ETH (needed for WETH unwrapping and converter operations)
    receive() external payable {}

    // ============ Slippage Enforcement ============

    /// @notice Enforce minimum slippage protection on the debt swap
    /// @dev The debt swap (alETH → WETH via Curve) is the primary sandwich attack vector.
    ///      Deposit-side conversion (WETH → wstETH via Lido) is not price-manipulable,
    ///      so we only enforce minimums on the debt swap.
    ///
    ///      We use 2x the vault's debtSlippageBasisPoints as the floor because
    ///      debtSlippageBasisPoints includes both peg deviation (~2-3%) and trade slippage (~1%).
    ///      The floor must accommodate the peg deviation gap between mintAmount (in debt tokens)
    ///      and debtTradeMin (in underlying tokens).
    function _enforceMinimumSlippage(uint256 mintAmount, uint256 debtTradeMin) internal view {
        if (debtSlippageBasisPoints > 0 && mintAmount > 0) {
            // Use 2x the configured slippage as the enforcement floor
            uint256 enforcementBps = uint256(debtSlippageBasisPoints) * 2;
            if (enforcementBps >= BASIS_POINTS) enforcementBps = BASIS_POINTS - 1;
            uint256 minAcceptableSwap = mintAmount * (BASIS_POINTS - enforcementBps) / BASIS_POINTS;
            require(debtTradeMin >= minAcceptableSwap, "Swap slippage below vault minimum");
        }
    }

    // ============ Admin Functions ============

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set the default token converter
    function setDefaultConverter(address _converter) external onlyOwner {
        require(_converter != address(0), "Converter cannot be zero");
        defaultConverter = _converter;
        emit DefaultAdapterSet("converter", _converter);
    }

    /// @notice Set the default flash loan adapter
    function setDefaultFlashLoanAdapter(address _adapter) external onlyOwner {
        require(_adapter != address(0), "Flash loan adapter cannot be zero");
        defaultFlashLoanAdapter = _adapter;
        emit DefaultAdapterSet("flashLoanAdapter", _adapter);
    }

    /// @notice Set the default swapper
    function setDefaultSwapper(address _swapper) external onlyOwner {
        require(_swapper != address(0), "Swapper cannot be zero");
        defaultSwapper = _swapper;
        emit DefaultAdapterSet("swapper", _swapper);
    }

    /// @notice Set all default adapters at once
    function setDefaultAdapters(
        address _converter,
        address _flashLoanAdapter,
        address _swapper
    ) external onlyOwner {
        require(_converter != address(0), "Converter cannot be zero");
        require(_flashLoanAdapter != address(0), "Flash loan adapter cannot be zero");
        require(_swapper != address(0), "Swapper cannot be zero");
        defaultConverter = _converter;
        defaultFlashLoanAdapter = _flashLoanAdapter;
        defaultSwapper = _swapper;
        emit DefaultAdapterSet("converter", _converter);
        emit DefaultAdapterSet("flashLoanAdapter", _flashLoanAdapter);
        emit DefaultAdapterSet("swapper", _swapper);
    }

    /// @notice Set default slippage parameters
    /// @param _underlyingSlippageBasisPoints Slippage for underlying operations (e.g. 100 = 1%)
    /// @param _debtSlippageBasisPoints Slippage for debt swaps, includes peg deviation (e.g. 300 = 3%)
    function setSlippageParameters(
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints
    ) external onlyOwner {
        require(_underlyingSlippageBasisPoints < 10000, "Underlying slippage too high");
        require(_debtSlippageBasisPoints < 10000, "Debt slippage too high");
        underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        debtSlippageBasisPoints = _debtSlippageBasisPoints;
        emit SlippageParametersUpdated(_underlyingSlippageBasisPoints, _debtSlippageBasisPoints);
    }

    /// @notice Emergency withdraw stuck ERC20 tokens (not underlying or yield tokens in active use)
    /// @dev Only callable by owner. Safeguard against tokens stuck from failed operations.
    /// @param token Token address to sweep
    /// @param amount Amount to sweep
    /// @param recipient Address to receive swept tokens
    function emergencySweepToken(address token, uint256 amount, address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(recipient, amount);
    }
}
