// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Real AlchemistV3 from source
import "../alchemix-v3/src/AlchemistV3.sol";
import "../alchemix-v3/src/AlchemistV3Position.sol";
import "../alchemix-v3/src/AlchemistTokenVault.sol";
import "../alchemix-v3/src/Transmuter.sol";
import "../alchemix-v3/src/interfaces/ITransmuter.sol";
import "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Our contracts
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/adapters/flashloan/AaveV3FlashLoanAdapter.sol";
import "../src/adapters/CurveSwapper.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/converters/WETHToWstETHConverter.sol";

// Interfaces
import "../alchemix-v3/src/interfaces/ITokenAdapter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IAlETHAdmin {
    function setWhitelist(address account, bool state) external;
    function whiteList(address) external view returns (bool);
}

/**
 * @title DeployFork
 * @notice Deploy full LeveragedVault system to mainnet fork
 * @dev All real contracts - no mocks:
 *      - Real WETH, wstETH from mainnet
 *      - Real alETH from mainnet (we whitelist our AlchemistV3)
 *      - Real Balancer Vault for flash loans
 *      - Real Curve alETH/ETH pool for swaps
 *      - Real AlchemistV3 deployed from source code
 *      - Our LeveragedVault and Leverager
 */
contract DeployFork is Script {
    // ============ Mainnet Addresses ============

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Real alETH token on mainnet (we'll whitelist our AlchemistV3)
    address constant ALETH = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;

    // Curve alETH/WETH pool on mainnet (StableSwap NG)
    address constant CURVE_ALETH_POOL = 0x8eFD02a0a40545F32DbA5D664CbBC1570D3FedF6;
    int128 constant CURVE_ALETH_WETH_INDEX = 1; // WETH
    int128 constant CURVE_ALETH_INDEX = 0; // alETH

    // Curve stETH/ETH pool on mainnet
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    int128 constant CURVE_STETH_ETH_INDEX = 0;
    int128 constant CURVE_STETH_INDEX = 1;

    // AlchemistV3 config
    uint256 constant FIXED_POINT_SCALAR = 1e18;
    uint256 constant MIN_COLLATERALIZATION = 1_111_111_111_111_111_111; // ~111%
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1_052_631_578_950_000_000; // ~105%
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1_111_111_111_111_111_111;
    uint256 constant BLOCKS_PER_YEAR = 2_600_000;

    struct Deployed {
        address tokenAdapter;
        address transmuter;
        address alchemist;
        address positionNFT;
        address feeVault;
        address flashLoanAdapter;
        address aaveFlashLoanAdapter;
        address swapper;
        address stEthSwapper;
        address converter;
        address leverager;
        address vaultFactory;
        address vault;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying Full LeveragedVault System ===");
        console.log("Deployer:", deployer);
        console.log("Deployer ETH:", deployer.balance / 1e18);

        vm.startBroadcast(deployerPrivateKey);

        Deployed memory d = _deploy(deployer);

        vm.stopBroadcast();

        _logDeployment(d);
        _writeContractsJson(d);
    }

    function _deploy(address deployer) internal returns (Deployed memory d) {
        // 1. Deploy CurveSwapper for stETH -> WETH (used by WstETHAdapter)
        CurveSwapper stEthSwapper = new CurveSwapper(
            CURVE_STETH_POOL,
            STETH,
            WETH,
            CURVE_STETH_ETH_INDEX,
            CURVE_STETH_INDEX,
            WETH,
            true,
            deployer
        );
        d.stEthSwapper = address(stEthSwapper);
        console.log("Curve stETH Swapper:", d.stEthSwapper);

        // 2. Deploy WstETH adapter (uses swapper for stETH -> WETH)
        WstETHAdapter tokenAdapter = new WstETHAdapter(d.stEthSwapper, 9950);
        d.tokenAdapter = address(tokenAdapter);
        console.log("WstETHAdapter:", d.tokenAdapter);

        // 3. Deploy Transmuter (required by AlchemistV3)
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: ALETH,           // Real mainnet alETH
            feeReceiver: deployer,
            timeToTransmute: 5_256_000,      // ~2 months in blocks
            transmutationFee: 10,            // 0.1%
            exitFee: 20,                     // 0.2%
            graphSize: 52_560_000
        });
        Transmuter transmuter = new Transmuter(transmuterParams);
        d.transmuter = address(transmuter);
        console.log("Transmuter:", d.transmuter);

        // 4. Deploy AlchemistV3 (real contract from source)
        d.alchemist = _deployAlchemistV3(deployer, d.tokenAdapter, d.transmuter);
        console.log("AlchemistV3:", d.alchemist);

        // 5. Deploy and configure Position NFT
        AlchemistV3Position positionNFT = new AlchemistV3Position(d.alchemist);
        d.positionNFT = address(positionNFT);
        AlchemistV3(d.alchemist).setAlchemistPositionNFT(d.positionNFT);
        console.log("AlchemistV3Position:", d.positionNFT);

        // 6. Deploy and configure Fee Vault
        AlchemistTokenVault feeVault = new AlchemistTokenVault(WETH, d.alchemist, deployer);
        d.feeVault = address(feeVault);
        feeVault.setAuthorization(d.alchemist, true);
        AlchemistV3(d.alchemist).setAlchemistFeeVault(d.feeVault);
        console.log("AlchemistTokenVault:", d.feeVault);

        // 7. Configure Transmuter
        transmuter.setAlchemist(d.alchemist);
        transmuter.setDepositCap(uint256(type(int256).max));

        // 8. Whitelist AlchemistV3 on real mainnet alETH
        _whitelistOnAlETH(d.alchemist);

        // 9. Deploy flash loan adapters
        // 9a. Balancer (0% fee, primary)
        BalancerFlashLoanAdapter flashLoanAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);
        d.flashLoanAdapter = address(flashLoanAdapter);
        console.log("BalancerFlashLoanAdapter:", d.flashLoanAdapter);

        // 9b. Aave V3 (0.05% fee, backup)
        AaveV3FlashLoanAdapter aaveAdapter = new AaveV3FlashLoanAdapter(address(0)); // Uses mainnet default
        d.aaveFlashLoanAdapter = address(aaveAdapter);
        console.log("AaveV3FlashLoanAdapter:", d.aaveFlashLoanAdapter);

        // 10. Deploy CurveSwapper (real Curve pool)
        CurveSwapper swapper = new CurveSwapper(
            CURVE_ALETH_POOL,
            ALETH,
            WETH,
            CURVE_ALETH_WETH_INDEX,
            CURVE_ALETH_INDEX,
            WETH,
            false,
            deployer
        );
        d.swapper = address(swapper);
        console.log("CurveSwapper:", d.swapper);

        // 11. Deploy WETHToWstETHConverter (underlying ↔ yield token conversion)
        WETHToWstETHConverter converter = new WETHToWstETHConverter(
            WETH,
            STETH,
            WSTETH,
            CURVE_STETH_POOL,
            CURVE_STETH_ETH_INDEX,
            CURVE_STETH_INDEX,
            9950
        );
        d.converter = address(converter);
        console.log("WETHToWstETHConverter:", d.converter);

        // 12. Deploy V3Leverager (modular, shared across vaults)
        V3Leverager leverager = new V3Leverager(deployer);
        d.leverager = address(leverager);
        console.log("V3Leverager:", d.leverager);

        // 13. Approve adapters on V3Leverager
        address[] memory converters = new address[](1);
        converters[0] = d.converter;

        address[] memory flashLoanAdapters = new address[](2);
        flashLoanAdapters[0] = d.flashLoanAdapter;
        flashLoanAdapters[1] = d.aaveFlashLoanAdapter;

        address[] memory swappers = new address[](1);
        swappers[0] = d.swapper;

        leverager.batchApprove(converters, flashLoanAdapters, swappers);
        console.log("Adapters approved on V3Leverager");

        // 14. Deploy LeveragedVaultFactory
        LeveragedVaultFactory factory = new LeveragedVaultFactory();
        d.vaultFactory = address(factory);
        console.log("LeveragedVaultFactory:", d.vaultFactory);

        // 15. Create LeveragedVault via factory
        d.vault = factory.createVault(
            "lvWSTETH",
            "Leveraged wstETH Vault",
            WSTETH,
            WETH,
            d.alchemist,
            d.leverager,
            100,
            200,
            d.converter,         // defaultConverter
            d.flashLoanAdapter,  // defaultFlashLoanAdapter (Balancer, 0% fee)
            d.swapper,           // defaultSwapper
            WETH                 // weth
        );
        console.log("LeveragedVault:", d.vault);

        return d;
    }

    function _deployAlchemistV3(
        address deployer,
        address _tokenAdapter,
        address _transmuter
    ) internal returns (address) {
        // Deploy implementation
        AlchemistV3 alchemistImpl = new AlchemistV3();

        // Prepare initialization params
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployer,
            debtToken: ALETH,                    // Real mainnet alETH
            underlyingToken: WETH,
            yieldToken: WSTETH,                  // Real mainnet wstETH
            blocksPerYear: BLOCKS_PER_YEAR,
            depositCap: type(uint256).max,
            minimumCollateralization: MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            tokenAdapter: _tokenAdapter,
            transmuter: _transmuter,
            protocolFee: 0,
            protocolFeeReceiver: deployer,
            liquidatorFee: 300                   // 3%
        });

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        ERC1967Proxy proxy = new ERC1967Proxy(address(alchemistImpl), initData);

        return address(proxy);
    }

    function _whitelistOnAlETH(address alchemist) internal {
        // Whitelist is done externally via start-local.sh using Anvil impersonation
        // This is necessary because we can't sign transactions for the alETH admin
        console.log("NOTE: Whitelist AlchemistV3 on alETH will be done post-deployment");
        console.log("AlchemistV3 to whitelist:", alchemist);
    }

    function _logDeployment(Deployed memory d) internal pure {
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("\nReal Mainnet Contracts:");
        console.log("  WETH:", WETH);
        console.log("  wstETH:", WSTETH);
        console.log("  alETH:", ALETH);
        console.log("  Balancer Vault:", BALANCER_VAULT);
        console.log("  Curve alETH/ETH:", CURVE_ALETH_POOL);
        console.log("\nDeployed from Source:");
        console.log("  AlchemistV3:", d.alchemist);
        console.log("  AlchemistV3Position:", d.positionNFT);
        console.log("  Transmuter:", d.transmuter);
        console.log("  AlchemistTokenVault:", d.feeVault);
        console.log("  WstETHAdapter:", d.tokenAdapter);
        console.log("\nModular Adapter Layer:");
        console.log("  BalancerFlashLoanAdapter:", d.flashLoanAdapter);
        console.log("  AaveV3FlashLoanAdapter:", d.aaveFlashLoanAdapter);
        console.log("  CurveSwapper:", d.swapper);
        console.log("  Curve stETH Swapper:", d.stEthSwapper);
        console.log("  WETHToWstETHConverter:", d.converter);
        console.log("\nCore Contracts:");
        console.log("  V3Leverager:", d.leverager);
        console.log("  LeveragedVaultFactory:", d.vaultFactory);
        console.log("  LeveragedVault:", d.vault);
    }

    function _writeContractsJson(Deployed memory d) internal {
        // Build JSON in parts to avoid stack too deep
        string memory part1 = string(abi.encodePacked(
            '{"weth":"', vm.toString(WETH),
            '","wsteth":"', vm.toString(WSTETH),
            '","aleth":"', vm.toString(ALETH),
            '","balancerVault":"', vm.toString(BALANCER_VAULT),
            '","curvePool":"', vm.toString(CURVE_ALETH_POOL),
            '","alchemist":"', vm.toString(d.alchemist),
            '","positionNFT":"', vm.toString(d.positionNFT)
        ));

        string memory part2 = string(abi.encodePacked(
            '","transmuter":"', vm.toString(d.transmuter),
            '","feeVault":"', vm.toString(d.feeVault),
            '","tokenAdapter":"', vm.toString(d.tokenAdapter),
            '","flashLoanAdapter":"', vm.toString(d.flashLoanAdapter),
            '","aaveFlashLoanAdapter":"', vm.toString(d.aaveFlashLoanAdapter),
            '","swapper":"', vm.toString(d.swapper),
            '","stEthSwapper":"', vm.toString(d.stEthSwapper),
            '","converter":"', vm.toString(d.converter)
        ));

        string memory part3 = string(abi.encodePacked(
            '","leverager":"', vm.toString(d.leverager),
            '","vaultFactory":"', vm.toString(d.vaultFactory),
            '","vault":"', vm.toString(d.vault),
            '"}'
        ));

        string memory json = string(abi.encodePacked(part1, part2, part3));
        vm.writeFile("dapp/src/contracts.json", json);
        console.log("\nAddresses written to dapp/src/contracts.json");
    }
}
