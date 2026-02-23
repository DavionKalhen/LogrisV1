// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Real AlchemistV3 contracts
import "../alchemix-v3/src/AlchemistV3.sol";
import "../alchemix-v3/src/AlchemistV3Position.sol";
import "../alchemix-v3/src/AlchemistTokenVault.sol";
import "../alchemix-v3/src/Transmuter.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../alchemix-v3/src/interfaces/ITransmuter.sol";
import {IVaultV2} from "../alchemix-v3/lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TokenUtils} from "../alchemix-v3/src/libraries/TokenUtils.sol";

// Alchemix test mocks (for MYT/VaultV2 setup)
import {AlchemicTokenV3} from "../alchemix-v3/src/test/mocks/AlchemicTokenV3.sol";
import {TestERC20} from "../alchemix-v3/src/test/mocks/TestERC20.sol";
import {MockYieldToken} from "../alchemix-v3/src/test/mocks/MockYieldToken.sol";
import {MockMYTVault} from "../alchemix-v3/src/test/mocks/MockMYTVault.sol";
import {MockMYTStrategy} from "../alchemix-v3/src/test/mocks/MockMYTStrategy.sol";
import {MockAlchemistAllocator} from "../alchemix-v3/src/test/mocks/MockAlchemistAllocator.sol";
import {MYTTestHelper} from "../alchemix-v3/src/test/libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../alchemix-v3/src/interfaces/IMYTStrategy.sol";

// OZ proxy
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Our contracts
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/leveragers/V3Leverager.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Full ERC20 mock with metadata (name/symbol/decimals).
///         The alchemix TestERC20 lacks these, which causes LeveragedVault.initialize() to revert.
contract MockERC20WithMetadata {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        require(balanceOf[from] >= amount, "insufficient balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title LocalAlchemistV3Base
/// @notice Test base contract that deploys a REAL AlchemistV3 stack locally (no fork needed).
///         Tests inheriting from this get a fully functional Alchemist with MYT vault,
///         position NFTs, transmuter, and fee vault.
/// @dev Architecture overview:
///      TestERC20 (underlying) → VaultV2/MYT (ERC4626 shares) → AlchemistV3 (collateral)
///      AlchemistV3 mints AlchemicTokenV3 (debt token) against MYT collateral.
abstract contract LocalAlchemistV3Base is Test {
    // ============ Constants ============

    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 constant BPS = 10_000;
    uint256 constant MIN_COLLATERALIZATION = 1_111_111_111_111_111_111; // ~111%
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1_052_631_578_950_000_000; // ~105%
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1_111_111_111_111_111_111;
    uint256 constant PROTOCOL_FEE_BPS = 0;
    uint256 constant LIQUIDATOR_FEE_BPS = 300;
    uint256 constant REPAYMENT_FEE_BPS = 100;

    // ============ Real AlchemistV3 Stack ============

    AlchemistV3 public alchemist;
    AlchemistV3Position public positionNFT;
    Transmuter public transmuter;
    AlchemistTokenVault public feeVault;
    AlchemicTokenV3 public debtToken;

    // ============ MYT / VaultV2 ============

    MockERC20WithMetadata public underlying; // Simulates WETH (with name/symbol/decimals)
    MockYieldToken public yieldToken;      // Simulates wstETH (wraps underlying)
    MockMYTVault public mytVault;          // VaultV2 - the MYT token contract
    MockMYTStrategy public mytStrategy;
    MockAlchemistAllocator public allocator;

    // ============ Our Contracts ============

    LeveragedVault public vaultImpl;

    // ============ Addresses ============

    address public alchemistAdmin;
    address public vaultAdmin;
    address public mytCurator;
    address public mytOperator;
    address public proxyOwner;

    // ============ Setup ============

    /// @notice Deploys the full AlchemistV3 stack locally.
    ///         Call this from your test's setUp().
    function _deployLocalAlchemistV3() internal {
        alchemistAdmin = makeAddr("alchemistAdmin");
        vaultAdmin = makeAddr("vaultAdmin");
        mytCurator = makeAddr("mytCurator");
        mytOperator = makeAddr("mytOperator");
        proxyOwner = makeAddr("proxyOwner");

        _deployMYTStack();
        _deployAlchemistV3();
    }

    function _deployMYTStack() internal {
        // 1. Create underlying token (simulates WETH, 18 decimals, with metadata)
        vm.startPrank(alchemistAdmin);
        underlying = new MockERC20WithMetadata("Wrapped Ether", "WETH", 18);

        // 2. Create mock yield token (wraps underlying, simulates wstETH)
        yieldToken = new MockYieldToken(address(underlying));

        // 3. Setup VaultV2 (MYT) with mock strategy
        mytVault = MYTTestHelper._setupVault(address(underlying), alchemistAdmin, mytCurator);
        mytStrategy = MYTTestHelper._setupStrategy(
            address(mytVault),
            address(yieldToken),
            alchemistAdmin,
            "MockToken",
            "MockTokenProtocol",
            IMYTStrategy.RiskClass.LOW
        );
        allocator = new MockAlchemistAllocator(address(mytVault), alchemistAdmin, mytOperator);
        vm.stopPrank();

        // 4. Configure VaultV2 governance
        vm.startPrank(mytCurator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        mytVault.setIsAllocator(address(allocator), true);

        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(mytStrategy)));
        mytVault.addAdapter(address(mytStrategy));

        bytes memory idData = mytStrategy.getIdData();
        uint256 bigCap = 2_000_000_000e18;
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, bigCap)));
        mytVault.increaseAbsoluteCap(idData, bigCap);

        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        mytVault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();
    }

    function _deployAlchemistV3() internal {
        vm.startPrank(alchemistAdmin);

        // 1. Create debt token
        debtToken = new AlchemicTokenV3("Test alToken", "alTEST", 0);

        // 2. Create Transmuter
        ITransmuter.TransmuterInitializationParams memory transParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: address(debtToken),
            feeReceiver: alchemistAdmin,
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });
        transmuter = new Transmuter(transParams);

        // 3. Deploy AlchemistV3 via proxy
        AlchemistV3 alchemistImpl = new AlchemistV3();
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: alchemistAdmin,
            debtToken: address(debtToken),
            underlyingToken: address(mytVault.asset()),
            depositCap: type(uint256).max,
            minimumCollateralization: MIN_COLLATERALIZATION,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            transmuter: address(transmuter),
            protocolFee: PROTOCOL_FEE_BPS,
            protocolFeeReceiver: alchemistAdmin,
            liquidatorFee: LIQUIDATOR_FEE_BPS,
            repaymentFee: REPAYMENT_FEE_BPS,
            myt: address(mytVault)
        });
        bytes memory initData = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(alchemistImpl),
            proxyOwner,
            initData
        );
        alchemist = AlchemistV3(address(proxy));

        // 4. Whitelist alchemist for minting debt tokens
        debtToken.setWhitelist(address(alchemist), true);

        // 5. Create and set position NFT
        positionNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(positionNFT));

        // 6. Create and set fee vault
        feeVault = new AlchemistTokenVault(address(mytVault.asset()), address(alchemist), alchemistAdmin);
        feeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(feeVault));

        // 7. Configure transmuter
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));

        vm.stopPrank();
    }

    // ============ Helpers ============

    /// @notice Fund an address with MYT (VaultV2 shares) by minting underlying and depositing.
    /// @param to Recipient of MYT shares
    /// @param underlyingAmount Amount of underlying token to deposit into VaultV2
    /// @return shares Amount of MYT shares received
    function _fundWithMYT(address to, uint256 underlyingAmount) internal returns (uint256 shares) {
        underlying.mint(to, underlyingAmount);
        vm.startPrank(to);
        IERC20(address(underlying)).approve(address(mytVault), underlyingAmount);
        shares = mytVault.deposit(underlyingAmount, to);
        vm.stopPrank();

        // Allocate to strategy so VaultV2 can price shares properly
        vm.prank(mytOperator);
        allocator.allocate(address(mytStrategy), underlyingAmount);
    }

    /// @notice Fund an address with underlying tokens only.
    function _fundWithUnderlying(address to, uint256 amount) internal {
        underlying.mint(to, amount);
    }

    /// @notice Fund an address with debt tokens.
    function _fundWithDebtTokens(address to, uint256 amount) internal {
        deal(address(debtToken), to, amount);
    }

    /// @notice Deposit MYT into alchemist and create a position for `depositor`.
    /// @return posId The position NFT token ID
    function _depositToAlchemist(address depositor, uint256 mytAmount) internal returns (uint256 posId) {
        vm.startPrank(depositor);
        IERC20(address(mytVault)).approve(address(alchemist), mytAmount);
        alchemist.deposit(mytAmount, depositor, 0);
        posId = positionNFT.tokenOfOwnerByIndex(depositor, 0);
        vm.stopPrank();
    }

    /// @dev Submit a VaultV2 governance action and fast-forward past the timelock.
    function _vaultSubmitAndFastForward(bytes memory data) internal {
        mytVault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + mytVault.timelock(selector));
    }

    /// @notice Deploy a LeveragedVault clone configured for the local AlchemistV3.
    /// @dev Uses MYT as the "yield token" since that's what AlchemistV3 now accepts.
    ///      Converter, flashLoan, swapper are set to the provided addresses (can be mocks).
    function _deployLeveragedVault(
        address _leverager,
        address _converter,
        address _flashLoan,
        address _swapper,
        address _owner
    ) internal returns (LeveragedVault vault) {
        if (address(vaultImpl) == address(0)) {
            vaultImpl = new LeveragedVault();
        }
        vault = LeveragedVault(payable(Clones.clone(address(vaultImpl))));
        vault.initialize(
            address(mytVault),       // yieldToken = MYT (VaultV2 shares)
            address(underlying),     // underlyingToken
            address(alchemist),
            _leverager,
            100,                     // underlyingSlippageBps
            200,                     // debtSlippageBps
            _converter,
            _flashLoan,
            _swapper,
            address(underlying),     // weth (use underlying as stand-in)
            _owner
        );
    }
}
