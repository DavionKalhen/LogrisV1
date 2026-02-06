// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Real AlchemistV3 imports
import "../alchemix-v3/src/AlchemistV3.sol";
import "../alchemix-v3/src/AlchemistV3Position.sol";
import "../alchemix-v3/src/AlchemistTokenVault.sol";
import "../alchemix-v3/src/Transmuter.sol";
import "../alchemix-v3/src/external/AlEth.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/ITransmuter.sol";
import "../alchemix-v3/src/interfaces/ITokenAdapter.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Our contracts
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/ILeveragedVaultCallback.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/**
 * @title MockYieldTokenWithAdapter
 * @notice ERC20 yield token that implements ITokenAdapter for price
 */
contract MockYieldTokenWithAdapter is ITokenAdapter {
    using SafeERC20 for IERC20;

    string public name = "Mock wstETH";
    string public symbol = "mwstETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public immutable override token;
    address public immutable override underlyingToken;
    uint256 private _price = 1e18; // 1:1 initially

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address _underlying) {
        token = address(this);
        underlyingToken = _underlying;
    }

    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    function price() external view override returns (uint256) {
        return _price;
    }

    function setPrice(uint256 newPrice) external {
        _price = newPrice;
    }

    function wrap(uint256 amount, address recipient) external returns (uint256) {
        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = (amount * 1e18) / _price;
        balanceOf[recipient] += shares;
        totalSupply += shares;
        emit Transfer(address(0), recipient, shares);
        return shares;
    }

    function unwrap(uint256 shares, address recipient) external returns (uint256) {
        require(balanceOf[msg.sender] >= shares, "Insufficient balance");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        uint256 amount = (shares * _price) / 1e18;
        IERC20(underlyingToken).safeTransfer(recipient, amount);
        emit Transfer(msg.sender, address(0), shares);
        return amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

/**
 * @title MockSwapperForE2E
 * @notice Swapper that works with real AlEth
 */
contract MockSwapperForE2E is ISwapper {
    using SafeERC20 for IERC20;

    address public debtToken;
    address public underlyingToken;
    AlEth public alEthToken;

    uint256 public swapFee = 30; // 0.3%
    uint256 public slippageTolerance = 100; // 1%

    constructor(address _debtToken, address _underlyingToken) {
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
        alEthToken = AlEth(_debtToken);
    }

    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        if (debtAmount == 0) revert InvalidAmount();

        // Transfer and burn debt tokens
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), debtAmount);
        alEthToken.burn(debtAmount);

        // Calculate output with fee
        uint256 output = (debtAmount * (10000 - swapFee)) / 10000;
        require(output >= minUnderlyingOut, "Slippage exceeded");

        // Transfer underlying
        IERC20(underlyingToken).safeTransfer(recipient, output);

        emit SwapExecuted(debtToken, underlyingToken, debtAmount, output, recipient);
        return output;
    }

    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256 minDebtOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        if (underlyingAmount == 0) revert InvalidAmount();

        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        uint256 output = (underlyingAmount * (10000 - swapFee)) / 10000;
        require(output >= minDebtOut, "Slippage exceeded");

        // Mint debt tokens (swapper must be whitelisted)
        alEthToken.mint(recipient, output);

        emit SwapExecuted(underlyingToken, debtToken, underlyingAmount, output, recipient);
        return output;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external view override returns (uint256 expectedUnderlying, uint256 minimumOutput) {
        expectedUnderlying = (debtAmount * (10000 - swapFee)) / 10000;
        minimumOutput = (expectedUnderlying * (10000 - slippageTolerance)) / 10000;
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external view override returns (uint256 expectedDebt, uint256 minimumOutput) {
        expectedDebt = (underlyingAmount * (10000 - swapFee)) / 10000;
        minimumOutput = (expectedDebt * (10000 - slippageTolerance)) / 10000;
    }

    function getDebtToUnderlyingRate() external view override returns (uint256) {
        return (1e18 * (10000 - swapFee)) / 10000;
    }

    function getUnderlyingToDebtRate() external view override returns (uint256) {
        return (1e18 * (10000 - swapFee)) / 10000;
    }

    function getSwapFee() external view override returns (uint256) {
        return swapFee;
    }

    function getSlippageTolerance() external view override returns (uint256) {
        return slippageTolerance;
    }

    function isSupportedPair(address tokenA, address tokenB) external view override returns (bool) {
        return (tokenA == debtToken && tokenB == underlyingToken) ||
               (tokenA == underlyingToken && tokenB == debtToken);
    }

    function fund(uint256 amount) external {
        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), amount);
    }
}

/**
 * @title LeveragedVaultForE2E
 * @notice Vault that works with real AlchemistV3
 */
contract LeveragedVaultForE2E is ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    AlchemistV3 public alchemist;
    address public leverager;
    address public owner;
    uint256 public vaultPositionId;

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _alchemist, address _leverager, address _owner) {
        alchemist = AlchemistV3(_alchemist);
        leverager = _leverager;
        owner = _owner;
    }

    function vaultDepositYieldTokens(uint256 amount) external onlyLeverager returns (uint256) {
        address yieldToken = alchemist.yieldToken();
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(address(alchemist), amount);

        if (vaultPositionId == 0) {
            alchemist.deposit(amount, address(this), 0);
            // Get the position ID from the NFT
            AlchemistV3Position nft = AlchemistV3Position(alchemist.alchemistPositionNFT());
            uint256 balance = nft.balanceOf(address(this));
            vaultPositionId = nft.tokenOfOwnerByIndex(address(this), balance - 1);
            emit VaultPositionCreated(vaultPositionId);
        } else {
            alchemist.deposit(amount, address(this), vaultPositionId);
        }

        return amount;
    }

    function vaultMintDebtTokens(uint256 amount, address recipient) external onlyLeverager {
        require(vaultPositionId > 0, "No position");
        alchemist.mint(vaultPositionId, amount, recipient);
    }

    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external onlyLeverager returns (uint256) {
        require(vaultPositionId > 0, "No position");
        return alchemist.withdraw(amount, recipient, vaultPositionId);
    }

    function vaultBurnDebtTokens(uint256 amount) external onlyLeverager {
        require(vaultPositionId > 0, "No position");
        address debtToken = alchemist.debtToken();
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(debtToken).approve(address(alchemist), amount);
        alchemist.burn(amount, vaultPositionId);
    }

    function getVaultPositionId() external view returns (uint256) {
        return vaultPositionId;
    }

    function getPosition() external view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        if (vaultPositionId == 0) return (0, 0, 0);
        return alchemist.getCDP(vaultPositionId);
    }
}

/**
 * @title LeveragerForE2E
 * @notice Leverager for E2E tests
 */
contract LeveragerForE2E is IFlashLoanCallback {
    using SafeERC20 for IERC20;

    IFlashLoanAdapter public flashLoanAdapter;
    ISwapper public swapper;

    address public immutable yieldToken;
    address public immutable underlyingToken;
    address public immutable debtToken;

    struct FlashLoanData {
        address vault;
        address user;
        uint256 initialDeposit;
        uint256 mintAmount;
    }

    event LeverageExecuted(
        address indexed vault,
        address indexed user,
        uint256 initialDeposit,
        uint256 flashLoanAmount,
        uint256 totalCollateral,
        uint256 debtMinted
    );

    constructor(
        address _flashLoanAdapter,
        address _swapper,
        address _yieldToken,
        address _underlyingToken,
        address _debtToken
    ) {
        flashLoanAdapter = IFlashLoanAdapter(_flashLoanAdapter);
        swapper = ISwapper(_swapper);
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
    }

    function leverage(
        address vault,
        uint256 initialDeposit,
        uint256 flashLoanAmount,
        uint256 mintAmount
    ) external {
        if (initialDeposit > 0) {
            IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), initialDeposit);
        }

        FlashLoanData memory data = FlashLoanData({
            vault: vault,
            user: msg.sender,
            initialDeposit: initialDeposit,
            mintAmount: mintAmount
        });

        flashLoanAdapter.flashLoan(
            underlyingToken,
            flashLoanAmount,
            address(this),
            abi.encode(data)
        );
    }

    function onFlashLoanReceived(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bool) {
        require(msg.sender == address(flashLoanAdapter), "Invalid caller");
        require(initiator == address(this), "Invalid initiator");

        FlashLoanData memory flashData = abi.decode(data, (FlashLoanData));
        ILeveragedVaultCallback vault = ILeveragedVaultCallback(flashData.vault);

        uint256 totalUnderlying = flashData.initialDeposit + amount;

        // 1. Wrap underlying to yield tokens
        IERC20(underlyingToken).approve(yieldToken, totalUnderlying);
        MockYieldTokenWithAdapter(yieldToken).wrap(totalUnderlying, address(this));

        // 2. Deposit yield tokens
        IERC20(yieldToken).approve(address(vault), totalUnderlying);
        vault.vaultDepositYieldTokens(totalUnderlying);

        // 3. Mint debt tokens
        vault.vaultMintDebtTokens(flashData.mintAmount, address(this));

        // 4. Swap debt for underlying
        IERC20(debtToken).approve(address(swapper), flashData.mintAmount);
        uint256 underlyingReceived = swapper.swapDebtToUnderlying(
            flashData.mintAmount,
            0,
            address(this),
            ""
        );

        // 5. Repay flash loan
        uint256 repayAmount = amount + fee;
        require(underlyingReceived >= repayAmount, "Insufficient to repay");

        IERC20(underlyingToken).approve(address(flashLoanAdapter), repayAmount);
        IERC20(underlyingToken).safeTransfer(address(flashLoanAdapter), repayAmount);

        // 6. Return surplus to user
        uint256 surplus = underlyingReceived - repayAmount;
        if (surplus > 0) {
            IERC20(underlyingToken).safeTransfer(flashData.user, surplus);
        }

        emit LeverageExecuted(
            flashData.vault,
            flashData.user,
            flashData.initialDeposit,
            amount,
            totalUnderlying,
            flashData.mintAmount
        );

        return true;
    }
}

/**
 * @title AlchemistV3E2ETest
 * @notice End-to-end tests using REAL AlchemistV3 contracts
 */
contract AlchemistV3E2ETest is Test {
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    uint256 constant FIXED_POINT_SCALAR = 1e18;

    // Real AlchemistV3 contracts
    AlchemistV3 public alchemist;
    AlchemistV3Position public positionNFT;
    Transmuter public transmuter;
    AlchemistTokenVault public feeVault;
    AlEth public alEth;
    MockYieldTokenWithAdapter public yieldToken;

    // Leverager system
    BalancerFlashLoanAdapter public flashLoanAdapter;
    MockSwapperForE2E public swapper;
    LeveragerForE2E public leverager;

    // Test users
    address public deployer;
    address public alice;
    address public bob;

    function setUp() public {
        // Fork mainnet - use the RPC URL from environment or command line
        // When running with --fork-url, the fork is already created
        // Only create fork if not already in a forked environment
        try vm.activeFork() {
            // Already forked via --fork-url
        } catch {
            string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com"));
            vm.createSelectFork(rpcUrl, 19500000);
        }

        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy the full system
        _deployAlchemistV3System();
        _deployLeveragerSystem();
        _fundTestAccounts();
    }

    function _deployAlchemistV3System() internal {
        // 1. Deploy tokens
        yieldToken = new MockYieldTokenWithAdapter(WETH);
        alEth = new AlEth();

        // 2. Deploy transmuter
        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(alEth),
            feeReceiver: deployer,
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });
        transmuter = new Transmuter(transParams);

        // 3. Deploy AlchemistV3 via proxy
        AlchemistV3 alchemistLogic = new AlchemistV3();

        // 90% LTV = 111.11% min collateralization
        uint256 minColl = (FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployer,
            debtToken: address(alEth),
            underlyingToken: WETH,
            yieldToken: address(yieldToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: minColl,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // ~105%
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // ~111%
            tokenAdapter: address(yieldToken),
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: deployer,
            liquidatorFee: 300
        });

        bytes memory initData = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(alchemistLogic),
            deployer,
            initData
        );
        alchemist = AlchemistV3(address(proxy));

        // 4. Deploy and configure position NFT
        positionNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(positionNFT));

        // 5. Deploy and configure fee vault
        feeVault = new AlchemistTokenVault(WETH, address(alchemist), deployer);
        feeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(feeVault));

        // 6. Configure transmuter
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));

        // 7. Whitelist alchemist for minting
        alEth.setWhitelist(address(alchemist), true);
    }

    function _deployLeveragerSystem() internal {
        // Flash loan adapter (uses real Balancer)
        flashLoanAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);

        // Swapper
        swapper = new MockSwapperForE2E(address(alEth), WETH);
        alEth.setWhitelist(address(swapper), true);

        // Fund swapper with WETH
        vm.deal(address(this), 2000 ether);
        IWETH(WETH).deposit{value: 1000 ether}();
        IERC20(WETH).approve(address(swapper), 1000 ether);
        swapper.fund(1000 ether);

        // Leverager
        leverager = new LeveragerForE2E(
            address(flashLoanAdapter),
            address(swapper),
            address(yieldToken),
            WETH,
            address(alEth)
        );
    }

    function _fundTestAccounts() internal {
        // Fund alice and bob with ETH and WETH
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.prank(alice);
        IWETH(WETH).deposit{value: 50 ether}();

        vm.prank(bob);
        IWETH(WETH).deposit{value: 50 ether}();
    }

    // ============ ALCHEMIST V3 DIRECT TESTS ============

    function test_AlchemistV3_DirectDeposit() public {
        uint256 depositAmount = 10 ether;

        // Get WETH and wrap to yield token
        vm.startPrank(alice);
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);

        // Deposit into Alchemist
        yieldToken.approve(address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, alice, 0);
        vm.stopPrank();

        // Verify position was created
        uint256 positionId = positionNFT.tokenOfOwnerByIndex(alice, 0);
        assertTrue(positionId > 0, "Position should be created");

        // Check CDP
        (uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(positionId);
        assertEq(collateral, depositAmount, "Collateral should match deposit");
        assertEq(debt, 0, "Debt should be 0");
        assertEq(earmarked, 0, "Earmarked should be 0");

        console.log("Direct deposit test passed");
        console.log("  Position ID:", positionId);
        console.log("  Collateral:", collateral / 1e18, "wstETH");
    }

    function test_AlchemistV3_DepositAndMint() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);

        // Wrap and deposit
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);
        yieldToken.approve(address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, alice, 0);

        uint256 positionId = positionNFT.tokenOfOwnerByIndex(alice, 0);

        // Mint debt (50% of max to stay safe)
        uint256 maxBorrowable = alchemist.getMaxBorrowable(positionId);
        uint256 mintAmount = maxBorrowable / 2;

        alchemist.mint(positionId, mintAmount, alice);

        vm.stopPrank();

        // Check CDP after mint
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(positionId);
        assertEq(collateral, depositAmount, "Collateral unchanged");
        assertEq(debt, mintAmount, "Debt should match mint");

        // Check alice received alETH
        uint256 alEthBalance = alEth.balanceOf(alice);
        assertEq(alEthBalance, mintAmount, "Should receive alETH");

        console.log("Deposit and mint test passed");
        console.log("  Max borrowable:", maxBorrowable / 1e18);
        console.log("  Minted:", mintAmount / 1e18, "alETH");
    }

    function test_AlchemistV3_Withdraw() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);

        // Deposit
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);
        yieldToken.approve(address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, alice, 0);

        uint256 positionId = positionNFT.tokenOfOwnerByIndex(alice, 0);

        // Withdraw half
        uint256 withdrawAmount = depositAmount / 2;
        alchemist.withdraw(withdrawAmount, alice, positionId);

        vm.stopPrank();

        // Check CDP after withdraw
        (uint256 collateral,,) = alchemist.getCDP(positionId);
        assertEq(collateral, depositAmount - withdrawAmount, "Collateral should decrease");

        // Check alice received yield tokens
        uint256 yieldBalance = yieldToken.balanceOf(alice);
        assertEq(yieldBalance, withdrawAmount, "Should receive yield tokens");
    }

    function test_AlchemistV3_BurnDebt() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);

        // Deposit and mint
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);
        yieldToken.approve(address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, alice, 0);

        uint256 positionId = positionNFT.tokenOfOwnerByIndex(alice, 0);
        uint256 mintAmount = 5 ether;
        alchemist.mint(positionId, mintAmount, alice);

        // Move forward one block (can't burn on same block as mint)
        vm.roll(block.number + 1);

        // Burn half the debt
        uint256 burnAmount = mintAmount / 2;
        alEth.approve(address(alchemist), burnAmount);
        alchemist.burn(burnAmount, positionId);

        vm.stopPrank();

        // Check CDP after burn
        (, uint256 debt,) = alchemist.getCDP(positionId);
        assertEq(debt, mintAmount - burnAmount, "Debt should decrease");
    }

    function test_AlchemistV3_RevertOnUndercollateralized() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);

        // Deposit
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);
        yieldToken.approve(address(alchemist), depositAmount);
        alchemist.deposit(depositAmount, alice, 0);

        uint256 positionId = positionNFT.tokenOfOwnerByIndex(alice, 0);

        // Try to mint more than allowed
        uint256 maxBorrowable = alchemist.getMaxBorrowable(positionId);

        vm.expectRevert();
        alchemist.mint(positionId, maxBorrowable + 1 ether, alice);

        vm.stopPrank();
    }

    // ============ LEVERAGER E2E TESTS ============

    function test_Leverager_BasicLeverage() public {
        // Create vault for alice
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        uint256 initialDeposit = 5 ether;
        uint256 flashLoanAmount = 10 ether;
        // Need to mint enough to cover flash loan after swap fee (0.3%)
        uint256 mintAmount = flashLoanAmount * 1004 / 1000; // 0.4% buffer

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        // Verify position was created
        uint256 positionId = vault.getVaultPositionId();
        assertTrue(positionId > 0, "Position should be created");

        // Check CDP
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(positionId);

        console.log("=== Basic Leverage Test ===");
        console.log("Initial deposit:", initialDeposit / 1e18, "WETH");
        console.log("Flash loan:", flashLoanAmount / 1e18, "WETH");
        console.log("Total collateral:", collateral / 1e18, "wstETH");
        console.log("Debt:", debt / 1e18, "alETH");

        assertEq(collateral, initialDeposit + flashLoanAmount, "Collateral should be total");
        assertEq(debt, mintAmount, "Debt should match mint");

        // Verify health factor
        uint256 healthFactor = (collateral * 100) / debt;
        console.log("Health factor:", healthFactor, "%");
        assertTrue(healthFactor >= 111, "Should be properly collateralized");
    }

    function test_Leverager_2xLeverage() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // 2x leverage: deposit 10, borrow 10, total 20
        uint256 initialDeposit = 10 ether;
        uint256 flashLoanAmount = 10 ether; // 2x
        uint256 mintAmount = flashLoanAmount * 1004 / 1000;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());

        console.log("=== 2x Leverage Test ===");
        console.log("Collateral:", collateral / 1e18, "wstETH");
        console.log("Debt:", debt / 1e18, "alETH");
        console.log("Effective leverage:", (collateral * 100) / initialDeposit, "%");

        assertEq(collateral, 20 ether, "Should have 2x collateral");
    }

    function test_Leverager_3xLeverage() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // 3x leverage: deposit 10, borrow 20, total 30
        uint256 initialDeposit = 10 ether;
        uint256 flashLoanAmount = 20 ether;
        uint256 mintAmount = flashLoanAmount * 1004 / 1000;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());

        console.log("=== 3x Leverage Test ===");
        console.log("Collateral:", collateral / 1e18, "wstETH");
        console.log("Debt:", debt / 1e18, "alETH");

        assertEq(collateral, 30 ether, "Should have 3x collateral");

        // Verify still healthy
        uint256 healthFactor = (collateral * 100) / debt;
        assertTrue(healthFactor >= 111, "Should be properly collateralized");
    }

    function test_Leverager_MaxLeverage() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // Near-max leverage at 80% LTV: ~4x theoretical
        // But accounting for fees, practical max is ~3.5x
        uint256 initialDeposit = 10 ether;
        uint256 flashLoanAmount = 25 ether; // 3.5x
        uint256 mintAmount = flashLoanAmount * 1004 / 1000;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());

        console.log("=== Max Leverage Test ===");
        console.log("Collateral:", collateral / 1e18, "wstETH");
        console.log("Debt:", debt / 1e18, "alETH");

        uint256 healthFactor = (collateral * 100) / debt;
        console.log("Health factor:", healthFactor, "%");

        // Should be close to minimum (111%)
        assertTrue(healthFactor >= 111 && healthFactor < 150, "Should be near minimum health");
    }

    function test_Leverager_MultipleVaults() public {
        // Create vaults for alice and bob
        LeveragedVaultForE2E aliceVault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        LeveragedVaultForE2E bobVault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            bob
        );

        // Alice: 2x leverage
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 10 ether);
        leverager.leverage(address(aliceVault), 10 ether, 10 ether, 10.04 ether);
        vm.stopPrank();

        // Bob: 3x leverage
        vm.startPrank(bob);
        IERC20(WETH).approve(address(leverager), 5 ether);
        leverager.leverage(address(bobVault), 5 ether, 10 ether, 10.04 ether);
        vm.stopPrank();

        // Verify positions
        (uint256 aliceCol, uint256 aliceDebt,) = alchemist.getCDP(aliceVault.getVaultPositionId());
        (uint256 bobCol, uint256 bobDebt,) = alchemist.getCDP(bobVault.getVaultPositionId());

        console.log("=== Multiple Vaults Test ===");
        console.log("Alice - Collateral:", aliceCol / 1e18, "Debt:", aliceDebt / 1e18);
        console.log("Bob - Collateral:", bobCol / 1e18, "Debt:", bobDebt / 1e18);

        assertEq(aliceCol, 20 ether, "Alice should have 20 collateral");
        assertEq(bobCol, 15 ether, "Bob should have 15 collateral");

        // Verify total debt in system
        uint256 totalDebt = alchemist.totalDebt();
        assertEq(totalDebt, aliceDebt + bobDebt, "Total debt should match");
    }

    function test_Leverager_SequentialLeverages() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // First leverage: 2x
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 20 ether);
        leverager.leverage(address(vault), 10 ether, 10 ether, 10.04 ether);

        (uint256 col1, uint256 debt1,) = alchemist.getCDP(vault.getVaultPositionId());
        console.log("After first leverage - Col:", col1 / 1e18, "Debt:", debt1 / 1e18);

        // Second leverage on same vault: add more
        leverager.leverage(address(vault), 5 ether, 5 ether, 5.02 ether);
        vm.stopPrank();

        (uint256 col2, uint256 debt2,) = alchemist.getCDP(vault.getVaultPositionId());
        console.log("After second leverage - Col:", col2 / 1e18, "Debt:", debt2 / 1e18);

        assertTrue(col2 > col1, "Collateral should increase");
        assertTrue(debt2 > debt1, "Debt should increase");
    }

    // ============ EDGE CASE TESTS ============

    function test_RevertOnExcessiveLeverage() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // Try 10x leverage (should definitely fail)
        // At 90% LTV, max theoretical leverage is ~10x, but accounting for fees it's lower
        // deposit 2, borrow 18, total 20 collateral
        // max debt at 90% = 18, but need to mint more to cover swap fee
        uint256 initialDeposit = 2 ether;
        uint256 flashLoanAmount = 18 ether; // 10x
        uint256 mintAmount = flashLoanAmount * 1004 / 1000; // ~18.07 alETH

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);

        // This should revert because:
        // - Total collateral = 20 wstETH
        // - Max borrowable at 90% LTV = 18 alETH
        // - Need to mint 18.07 alETH > max borrowable
        vm.expectRevert();
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();
    }

    function test_FlashLoanFeeAccounting() public {
        // Balancer has 0% flash loan fee, verify this
        uint256 fee = flashLoanAdapter.getFlashLoanFee(WETH, 100 ether);
        assertEq(fee, 0, "Balancer should have 0% fee");

        uint256 maxFlashLoan = flashLoanAdapter.maxFlashLoan(WETH);
        assertTrue(maxFlashLoan > 10000 ether, "Should have significant liquidity");

        console.log("Flash loan fee:", fee);
        console.log("Max flash loan:", maxFlashLoan / 1e18, "WETH");
    }

    function test_YieldTokenPriceChange() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        // Create leveraged position
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 10 ether);
        leverager.leverage(address(vault), 10 ether, 10 ether, 10.04 ether);
        vm.stopPrank();

        uint256 positionId = vault.getVaultPositionId();
        (uint256 colBefore, uint256 debtBefore,) = alchemist.getCDP(positionId);

        // Simulate yield accrual: price increases 5%
        yieldToken.setPrice(1.05e18);

        // CDP collateral count stays the same, but value increases
        (uint256 colAfter, uint256 debtAfter,) = alchemist.getCDP(positionId);

        console.log("=== Yield Accrual Test ===");
        console.log("Collateral before:", colBefore / 1e18);
        console.log("Collateral after:", colAfter / 1e18);
        console.log("Debt before:", debtBefore / 1e18);
        console.log("Debt after:", debtAfter / 1e18);

        // Collateral amount stays same (in yield tokens)
        assertEq(colAfter, colBefore, "Collateral token count unchanged");
        // But underlying value increases, so health improves
    }

    // ============ GAS TESTS ============

    function test_GasConsumption_Leverage() public {
        LeveragedVaultForE2E vault = new LeveragedVaultForE2E(
            address(alchemist),
            address(leverager),
            alice
        );

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 10 ether);

        uint256 gasBefore = gasleft();
        leverager.leverage(address(vault), 10 ether, 10 ether, 10.04 ether);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        console.log("=== Gas Consumption ===");
        console.log("Leverage operation gas:", gasUsed);

        // Should be reasonable (under 1.5M for complex operation)
        assertTrue(gasUsed < 1_500_000, "Gas should be under 1.5M");
    }

    function test_GasConsumption_DirectDeposit() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(yieldToken), depositAmount);
        yieldToken.wrap(depositAmount, alice);
        yieldToken.approve(address(alchemist), depositAmount);

        uint256 gasBefore = gasleft();
        alchemist.deposit(depositAmount, alice, 0);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        console.log("Direct deposit gas:", gasUsed);
        assertTrue(gasUsed < 500_000, "Deposit should be under 500k gas");
    }
}
