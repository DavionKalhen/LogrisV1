// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/ILeveragedVaultCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ICurveStETHPool {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}

/**
 * @title MockAlchemistV3ForIntegration
 * @notice More realistic mock of AlchemistV3 for integration testing
 */
contract MockAlchemistV3ForIntegration {
    using SafeERC20 for IERC20;

    address public immutable yieldToken;
    address public immutable debtToken;
    address public immutable underlyingToken;

    // Simplified position storage
    struct Position {
        uint256 collateral;
        uint256 debt;
        address owner;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId = 1;

    // Mock position NFT
    mapping(address => uint256[]) public userPositions;

    // Config
    uint256 public minimumCollateralization = 1111111111111111111; // ~90% LTV
    uint256 public depositCap = type(uint256).max;

    address public alchemistPositionNFT;

    event Deposit(uint256 amount, uint256 indexed recipientId);
    event Mint(uint256 indexed tokenId, uint256 amount, address recipient);
    event Burn(address indexed sender, uint256 amount, uint256 indexed recipientId);
    event Withdraw(uint256 amount, uint256 indexed tokenId, address recipient);

    constructor(address _yieldToken, address _debtToken, address _underlyingToken) {
        yieldToken = _yieldToken;
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
        alchemistPositionNFT = address(new MockPositionNFT(address(this)));
    }

    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256) {
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 positionId;
        if (recipientId == 0) {
            // Create new position
            positionId = nextPositionId++;
            positions[positionId].owner = recipient;
            userPositions[recipient].push(positionId);
            MockPositionNFT(alchemistPositionNFT).mint(recipient, positionId);
        } else {
            positionId = recipientId;
            require(positions[positionId].owner == recipient, "Not position owner");
        }

        positions[positionId].collateral += amount;
        emit Deposit(amount, positionId);

        return amount;
    }

    function mint(uint256 positionId, uint256 amount, address recipient) external {
        Position storage pos = positions[positionId];
        require(pos.owner != address(0), "Position not found");

        // Check collateralization
        uint256 maxBorrowable = getMaxBorrowable(positionId);
        require(amount <= maxBorrowable, "Exceeds max borrowable");

        pos.debt += amount;

        // Mint debt tokens (in real implementation, debt token would have mint permission)
        MockDebtToken(debtToken).mint(recipient, amount);

        emit Mint(positionId, amount, recipient);
    }

    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        Position storage pos = positions[recipientId];
        require(pos.owner != address(0), "Position not found");

        uint256 burnAmount = amount > pos.debt ? pos.debt : amount;

        // Burn debt tokens
        MockDebtToken(debtToken).burn(msg.sender, burnAmount);
        pos.debt -= burnAmount;

        emit Burn(msg.sender, burnAmount, recipientId);
        return burnAmount;
    }

    function withdraw(uint256 amount, address recipient, uint256 positionId) external returns (uint256) {
        Position storage pos = positions[positionId];
        require(pos.owner != address(0), "Position not found");

        // Check if withdrawal maintains collateralization
        uint256 newCollateral = pos.collateral - amount;
        if (pos.debt > 0) {
            uint256 newRatio = (newCollateral * 1e18) / pos.debt;
            require(newRatio >= minimumCollateralization, "Would undercollateralize");
        }

        pos.collateral -= amount;
        IERC20(yieldToken).safeTransfer(recipient, amount);

        emit Withdraw(amount, positionId, recipient);
        return amount;
    }

    function repay(uint256 amount, uint256 recipientTokenId) external returns (uint256) {
        Position storage pos = positions[recipientTokenId];
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);

        // Convert yield tokens to debt value (1:1 for simplicity)
        uint256 debtRepaid = amount > pos.debt ? pos.debt : amount;
        pos.debt -= debtRepaid;

        return debtRepaid;
    }

    function approveMint(uint256 tokenId, address spender, uint256 amount) external {}

    function getCDP(uint256 positionId) external view returns (uint256, uint256, uint256) {
        Position storage pos = positions[positionId];
        return (pos.collateral, pos.debt, 0);
    }

    function getMaxBorrowable(uint256 positionId) public view returns (uint256) {
        Position storage pos = positions[positionId];
        // 90% LTV
        uint256 maxDebt = (pos.collateral * 90) / 100;
        return maxDebt > pos.debt ? maxDebt - pos.debt : 0;
    }

    function totalDebt() external view returns (uint256) {
        return MockDebtToken(debtToken).totalSupply();
    }

    function poke(uint256) external {}
}

contract MockPositionNFT {
    address public alchemist;
    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256[]) public ownedTokens;

    constructor(address _alchemist) {
        alchemist = _alchemist;
    }

    function mint(address to, uint256 tokenId) external {
        require(msg.sender == alchemist, "Only alchemist");
        ownerOf[tokenId] = to;
        ownedTokens[to].push(tokenId);
    }

    function balanceOf(address owner) external view returns (uint256) {
        return ownedTokens[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        return ownedTokens[owner][index];
    }
}

contract MockDebtToken {
    string public name = "Mock alETH";
    string public symbol = "malETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public alchemist;

    constructor() {
        alchemist = msg.sender;
    }

    function setAlchemist(address _alchemist) external {
        alchemist = _alchemist;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * @title MockYieldToken
 * @notice Mock wstETH-like yield token
 */
contract MockYieldToken {
    using SafeERC20 for IERC20;

    string public name = "Mock wstETH";
    string public symbol = "mwstETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    address public immutable underlying; // WETH

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function wrap(uint256 amount, address recipient) external returns (uint256) {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        balanceOf[recipient] += amount;
        totalSupply += amount;
        return amount;
    }

    function unwrap(uint256 amount, address recipient) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        IERC20(underlying).safeTransfer(recipient, amount);
        return amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/**
 * @title MockSwapperForIntegration
 * @notice Swapper that uses real Curve stETH pool for swaps
 */
contract MockSwapperForIntegration is ISwapper {
    using SafeERC20 for IERC20;

    address public constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address public debtToken;
    address public underlyingToken;

    constructor(address _debtToken, address _underlyingToken) {
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
    }

    // For integration test, simulate 1:1 swap (typical for alETH/ETH)
    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), debtAmount);

        // 1:1 swap with small fee (realistic for stablecoin-like pairs)
        uint256 output = (debtAmount * 995) / 1000; // 0.5% fee
        require(output >= minUnderlyingOut, "Insufficient output");

        // Transfer underlying from our reserves (test needs to fund this)
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
        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        uint256 output = underlyingAmount * 99 / 100;
        require(output >= minDebtOut, "Insufficient output");

        // Mint mock debt tokens
        MockDebtToken(debtToken).mint(recipient, output);

        emit SwapExecuted(underlyingToken, debtToken, underlyingAmount, output, recipient);
        return output;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external pure override returns (uint256, uint256) {
        uint256 expected = debtAmount * 99 / 100;
        return (expected, expected * 95 / 100);
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external pure override returns (uint256, uint256) {
        uint256 expected = underlyingAmount * 99 / 100;
        return (expected, expected * 95 / 100);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) {
        return 0.99e18;
    }

    function getUnderlyingToDebtRate() external pure override returns (uint256) {
        return 0.99e18;
    }

    function getSwapFee() external pure override returns (uint256) {
        return 10; // 0.1%
    }

    function getSlippageTolerance() external pure override returns (uint256) {
        return 100; // 1%
    }

    function isSupportedPair(address, address) external pure override returns (bool) {
        return true;
    }
}

/**
 * @title SimpleLeverager
 * @notice Simplified leverager for integration testing
 * @dev Implements proper leverage economics with initial deposit + flash loan amplification
 */
contract SimpleLeverager is IFlashLoanCallback {
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
        address vault,
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

    /**
     * @notice Execute leveraged position
     * @param vault The vault to leverage
     * @param initialDeposit User's initial deposit (underlying tokens)
     * @param flashLoanAmount Amount to flash loan (max ~4x initialDeposit for 80% LTV)
     * @param mintAmount Amount of debt to mint (must cover flash loan repayment)
     */
    function leverage(
        address vault,
        uint256 initialDeposit,
        uint256 flashLoanAmount,
        uint256 mintAmount
    ) external {
        // Pull initial deposit from user
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

        // Calculate total underlying (initial deposit + flash loan)
        uint256 totalUnderlying = flashData.initialDeposit + amount;

        // 1. Wrap all underlying to yield tokens
        IERC20(underlyingToken).approve(yieldToken, totalUnderlying);
        MockYieldToken(yieldToken).wrap(totalUnderlying, address(this));

        // 2. Deposit all yield tokens through vault
        IERC20(yieldToken).approve(address(vault), totalUnderlying);
        vault.vaultDepositYieldTokens(totalUnderlying);

        // 3. Mint debt tokens
        vault.vaultMintDebtTokens(flashData.mintAmount, address(this));

        // 4. Swap debt tokens for underlying
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

        // 6. Return any surplus to user
        uint256 surplus = underlyingReceived - repayAmount;
        if (surplus > 0) {
            IERC20(underlyingToken).safeTransfer(flashData.user, surplus);
        }

        emit LeverageExecuted(
            flashData.vault,
            flashData.initialDeposit,
            amount,
            totalUnderlying,
            flashData.mintAmount
        );

        return true;
    }
}

/**
 * @title SimpleLeveragedVault
 * @notice Simplified vault for integration testing
 */
contract SimpleLeveragedVault is ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    MockAlchemistV3ForIntegration public alchemist;
    address public leverager;
    uint256 public vaultPositionId;

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    constructor(address _alchemist, address _leverager) {
        alchemist = MockAlchemistV3ForIntegration(_alchemist);
        leverager = _leverager;
    }

    function vaultDepositYieldTokens(uint256 amount) external onlyLeverager returns (uint256) {
        IERC20(alchemist.yieldToken()).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(alchemist.yieldToken()).approve(address(alchemist), amount);

        if (vaultPositionId == 0) {
            alchemist.deposit(amount, address(this), 0);
            // Get the actual position ID from the NFT
            MockPositionNFT nft = MockPositionNFT(alchemist.alchemistPositionNFT());
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

    function vaultRepayWithYieldTokens(uint256 amount) external onlyLeverager returns (uint256) {
        require(vaultPositionId > 0, "No position");
        IERC20(alchemist.yieldToken()).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(alchemist.yieldToken()).approve(address(alchemist), amount);
        return alchemist.repay(amount, vaultPositionId);
    }

    function getVaultPositionId() external view returns (uint256) {
        return vaultPositionId;
    }
}

/**
 * @title IntegrationForkTest
 * @notice Full integration test with real Balancer flash loans
 */
contract IntegrationForkTest is Test {
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Deployed contracts
    BalancerFlashLoanAdapter public flashLoanAdapter;
    MockYieldToken public yieldToken;
    MockDebtToken public debtToken;
    MockAlchemistV3ForIntegration public alchemist;
    MockSwapperForIntegration public swapper;
    SimpleLeverager public leverager;
    SimpleLeveragedVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);

        // Deploy mock tokens
        yieldToken = new MockYieldToken(WETH);
        debtToken = new MockDebtToken();

        // Deploy mock alchemist
        alchemist = new MockAlchemistV3ForIntegration(
            address(yieldToken),
            address(debtToken),
            WETH
        );
        debtToken.setAlchemist(address(alchemist));

        // Deploy real Balancer flash loan adapter
        flashLoanAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);

        // Deploy swapper
        swapper = new MockSwapperForIntegration(address(debtToken), WETH);

        // Fund swapper with WETH for simulated swaps
        vm.deal(address(swapper), 1000 ether);
        vm.prank(address(swapper));
        IWETH(WETH).deposit{value: 1000 ether}();

        // Deploy leverager
        leverager = new SimpleLeverager(
            address(flashLoanAdapter),
            address(swapper),
            address(yieldToken),
            WETH,
            address(debtToken)
        );

        // Deploy vault
        vault = new SimpleLeveragedVault(address(alchemist), address(leverager));

        // Fund alice
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        IWETH(WETH).deposit{value: 50 ether}();
    }

    // ============ Flash Loan Integration Tests ============

    function test_BalancerFlashLoanWorks() public {
        // Verify flash loan adapter can borrow from Balancer
        uint256 maxFlashLoan = flashLoanAdapter.maxFlashLoan(WETH);
        assertTrue(maxFlashLoan > 1000 ether, "Should have significant WETH liquidity");
    }

    function test_FlashLoanAdapterConfiguration() public view {
        assertEq(flashLoanAdapter.getProvider(), BALANCER_VAULT);
        assertEq(flashLoanAdapter.getFlashLoanFee(WETH, 100 ether), 0); // Balancer has 0 fees
        assertTrue(flashLoanAdapter.isTokenSupported(WETH));
    }

    // ============ Full Leverage Cycle Tests ============

    function test_FullLeverageCycle() public {
        // Leverage math:
        // - User deposits 5 WETH
        // - Flash loan 10 WETH (2x leverage)
        // - Total collateral = 15 WETH
        // - Max debt = 15 * 0.8 = 12 WETH
        // - Mint ~10.05 debt to repay 10 WETH flash loan (0.5% swap fee)
        uint256 initialDeposit = 5 ether;
        uint256 flashLoanAmount = 10 ether;
        uint256 mintAmount = 10.1 ether; // Slightly more to cover swap fees

        // Fund alice and approve
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);

        // Execute leverage
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        // Verify position was created
        uint256 positionId = vault.getVaultPositionId();
        assertTrue(positionId > 0, "Position should be created");

        // Check position state
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(positionId);

        assertEq(collateral, initialDeposit + flashLoanAmount, "Collateral should equal total deposit");
        assertEq(debt, mintAmount, "Debt should equal mint amount");

        // Verify health
        uint256 collateralRatio = (collateral * 100) / debt;
        assertTrue(collateralRatio >= 111, "Should be properly collateralized");
    }

    function test_LeverageWithLargerAmount() public {
        // 3x leverage: deposit 100, flash loan 200
        uint256 initialDeposit = 100 ether;
        uint256 flashLoanAmount = 200 ether;
        // Need to mint enough to cover flash loan after 0.5% swap fee
        // 200 / 0.995 = 201.005, use 202 to be safe
        uint256 mintAmount = 202 ether;

        // Fund alice with more WETH
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        IWETH(WETH).deposit{value: 100 ether}();

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        uint256 positionId = vault.getVaultPositionId();
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(positionId);

        assertEq(collateral, initialDeposit + flashLoanAmount);
        assertEq(debt, mintAmount);
    }

    // ============ Edge Case Tests ============

    function test_LeverageWithMinimumAmount() public {
        uint256 initialDeposit = 0.5 ether;
        uint256 flashLoanAmount = 1 ether;
        uint256 mintAmount = 1.01 ether;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), initialDeposit);
        leverager.leverage(address(vault), initialDeposit, flashLoanAmount, mintAmount);
        vm.stopPrank();

        uint256 positionId = vault.getVaultPositionId();
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(positionId);

        assertEq(collateral, initialDeposit + flashLoanAmount);
        assertEq(debt, mintAmount);
    }

    function test_MultipleUsers() public {
        // Deploy second vault for bob
        address bob = makeAddr("bob");
        SimpleLeveragedVault bobVault = new SimpleLeveragedVault(address(alchemist), address(leverager));

        // Fund bob
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        IWETH(WETH).deposit{value: 50 ether}();

        // Alice leverages (5 + 10 = 15 collateral, max debt = 12, use 10.1)
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 5 ether);
        leverager.leverage(address(vault), 5 ether, 10 ether, 10.1 ether);
        vm.stopPrank();

        // Bob leverages (10 + 15 = 25 collateral, max debt = 20, use 15.1)
        // Using smaller flash loan to stay within 80% LTV
        vm.startPrank(bob);
        IERC20(WETH).approve(address(leverager), 10 ether);
        leverager.leverage(address(bobVault), 10 ether, 15 ether, 15.1 ether);
        vm.stopPrank();

        // Verify both positions
        (uint256 aliceCol, uint256 aliceDebt,) = alchemist.getCDP(vault.getVaultPositionId());
        (uint256 bobCol, uint256 bobDebt,) = alchemist.getCDP(bobVault.getVaultPositionId());

        assertEq(aliceCol, 15 ether);
        assertEq(aliceDebt, 10.1 ether);
        assertEq(bobCol, 25 ether);
        assertEq(bobDebt, 15.1 ether);

    }

    // ============ Gas Measurement Tests ============

    function test_GasConsumption() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(leverager), 5 ether);

        uint256 gasBefore = gasleft();
        leverager.leverage(address(vault), 5 ether, 10 ether, 10.1 ether);
        uint256 gasUsed = gasBefore - gasleft();

        vm.stopPrank();

        // Should be reasonable gas consumption
        assertTrue(gasUsed < 1_500_000, "Gas should be under 1.5M");
    }
}
