// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/LeveragedVault.sol";
import "../src/leveragers/V3Leverager.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockERC20
 * @notice Simple mock ERC20 for local testing
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockWETH
 * @notice Mock WETH with deposit/withdraw
 */
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/**
 * @title MockAlchemistV3Position
 * @notice Minimal mock for position NFT with enumerable-like functionality
 */
contract MockAlchemistV3Position is ERC721 {
    uint256 private _tokenIdCounter;

    // Simplified enumerable: owner => token IDs array
    mapping(address => uint256[]) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    constructor() ERC721("Alchemist V3 Position", "ALCV3POS") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = ++_tokenIdCounter;
        _mint(to, tokenId);
        _ownedTokens[to].push(tokenId);
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length - 1;
        return tokenId;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        return _ownedTokens[owner].length;
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        require(index < _ownedTokens[owner].length, "Index out of bounds");
        return _ownedTokens[owner][index];
    }
}

/**
 * @title MockAlchemistV3
 * @notice Simplified AlchemistV3 mock for local testing
 */
contract MockAlchemistV3 {
    MockERC20 public yieldToken;
    MockERC20 public debtToken;
    MockAlchemistV3Position public positionNFT;

    mapping(uint256 => uint256) public positionDeposits;
    mapping(uint256 => uint256) public positionDebts;

    uint256 public constant COLLATERAL_RATIO = 2e18; // 200% collateralization

    constructor(address _yieldToken, address _debtToken) {
        yieldToken = MockERC20(_yieldToken);
        debtToken = MockERC20(_debtToken);
        positionNFT = new MockAlchemistV3Position();
    }

    function alchemistPositionNFT() external view returns (address) {
        return address(positionNFT);
    }

    function deposit(uint256 amount, address recipient, uint256 positionId) external returns (uint256) {
        yieldToken.transferFrom(msg.sender, address(this), amount);

        if (positionId == 0) {
            positionId = positionNFT.mint(recipient);
        }
        positionDeposits[positionId] += amount;
        return positionId;
    }

    function withdraw(uint256 amount, address recipient, uint256 positionId) external {
        require(positionDeposits[positionId] >= amount, "Insufficient deposit");
        positionDeposits[positionId] -= amount;
        yieldToken.transfer(recipient, amount);
    }

    function mint(uint256 amount, address recipient, uint256 positionId) external {
        uint256 maxDebt = (positionDeposits[positionId] * 1e18) / COLLATERAL_RATIO;
        require(positionDebts[positionId] + amount <= maxDebt, "Exceeds max debt");
        positionDebts[positionId] += amount;
        debtToken.mint(recipient, amount);
    }

    function burn(uint256 amount, uint256 positionId) external {
        require(positionDebts[positionId] >= amount, "Exceeds debt");
        debtToken.transferFrom(msg.sender, address(this), amount);
        positionDebts[positionId] -= amount;
    }

    function getPositionDebt(uint256 positionId) external view returns (int256) {
        return int256(positionDebts[positionId]);
    }

    function getPositionCollateral(uint256 positionId) external view returns (uint256) {
        return positionDeposits[positionId];
    }

    function getMaxBorrowable(uint256 positionId) external view returns (uint256) {
        uint256 maxDebt = (positionDeposits[positionId] * 1e18) / COLLATERAL_RATIO;
        if (maxDebt > positionDebts[positionId]) {
            return maxDebt - positionDebts[positionId];
        }
        return 0;
    }
}

/**
 * @title MockConverter
 * @notice Simple 1:1 converter for testing
 */
contract MockConverter {
    MockERC20 public underlying;
    MockERC20 public yield;

    constructor(address _underlying, address _yield) {
        underlying = MockERC20(_underlying);
        yield = MockERC20(_yield);
    }

    function toYield(uint256 amount, address recipient, uint256 minYieldOut) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), amount);
        yield.mint(recipient, amount);
        require(amount >= minYieldOut, "Insufficient yield output");
        return amount;
    }

    function toUnderlying(
        uint256 amount,
        address recipient,
        uint256 /* minUnderlyingOut */
    ) external returns (uint256) {
        yield.transferFrom(msg.sender, address(this), amount);
        underlying.mint(recipient, amount);
        return amount;
    }

    function previewToYield(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function previewToUnderlying(uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

/**
 * @title MockSwapper
 * @notice Simple 1:1 swapper for testing
 */
contract MockSwapper {
    MockERC20 public underlying;
    MockERC20 public debt;

    constructor(address _underlying, address _debt) {
        underlying = MockERC20(_underlying);
        debt = MockERC20(_debt);
    }

    function swapDebtToUnderlying(uint256 amount, uint256, address recipient) external returns (uint256) {
        debt.transferFrom(msg.sender, address(this), amount);
        underlying.mint(recipient, amount);
        return amount;
    }

    function swapUnderlyingToDebt(uint256 amount, uint256, address recipient) external returns (uint256) {
        underlying.transferFrom(msg.sender, address(this), amount);
        debt.mint(recipient, amount);
        return amount;
    }

    function previewSwapDebtToUnderlying(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function previewSwapUnderlyingToDebt(uint256 amount) external pure returns (uint256) {
        return amount;
    }
}

/**
 * @title MockFlashLoanAdapter
 * @notice Flash loan adapter that mints tokens for the loan
 */
contract MockFlashLoanAdapter {
    function flashLoan(
        address borrowToken,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external {
        // Mint tokens for the flash loan
        MockERC20(borrowToken).mint(recipient, amount);

        // Call the callback
        (bool success,) = recipient.call(
            abi.encodeWithSignature(
                "onFlashLoanReceived(address,address,uint256,uint256,bytes)",
                msg.sender,
                borrowToken,
                amount,
                0, // 0 fee
                data
            )
        );
        require(success, "Flash loan callback failed");

        // Burn the repayment (transfer to this contract and let it sit)
        MockERC20(borrowToken).transferFrom(recipient, address(this), amount);
    }

    function getFlashLoanFee(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isTokenSupported(address) external pure returns (bool) {
        return true;
    }

    function maxFlashLoan(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getProvider() external view returns (address) {
        return address(this);
    }
}

/**
 * @title DeployMock
 * @notice Deploys entire system with mocks for local testing (no mainnet fork needed)
 */
contract DeployMock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deploying mock system...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy mock tokens
        MockWETH weth = new MockWETH();
        console.log("WETH (mock):", address(weth));

        MockERC20 wsteth = new MockERC20("Wrapped stETH", "wstETH", 18);
        console.log("wstETH (mock):", address(wsteth));

        MockERC20 aleth = new MockERC20("Alchemix ETH", "alETH", 18);
        console.log("alETH (mock):", address(aleth));

        // 2. Deploy mock Alchemist
        MockAlchemistV3 alchemist = new MockAlchemistV3(address(wsteth), address(aleth));
        console.log("AlchemistV3 (mock):", address(alchemist));
        console.log("Position NFT:", address(alchemist.positionNFT()));

        // 3. Deploy mock adapters
        MockConverter converter = new MockConverter(address(weth), address(wsteth));
        console.log("Converter (mock):", address(converter));

        MockSwapper swapper = new MockSwapper(address(weth), address(aleth));
        console.log("Swapper (mock):", address(swapper));

        MockFlashLoanAdapter flashLoanAdapter = new MockFlashLoanAdapter();
        console.log("FlashLoanAdapter (mock):", address(flashLoanAdapter));

        // 4. Deploy V3Leverager
        V3Leverager leverager = new V3Leverager(deployer);
        console.log("V3Leverager:", address(leverager));

        // 5. Approve adapters in leverager
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        leverager.setSwapperApproval(address(swapper), true);
        console.log("Adapters approved in leverager");

        // 6. Deploy factory
        LeveragedVaultFactory factory = new LeveragedVaultFactory();
        console.log("VaultFactory:", address(factory));

        // 7. Deploy vault
        address vault = factory.createVault(
            "Logris Leveraged wstETH",
            "lvWSTETH",
            address(wsteth),
            address(weth),
            address(alchemist),
            address(leverager),
            100,
            300,
            address(converter),
            address(flashLoanAdapter),
            address(swapper),
            address(weth)
        );
        console.log("Vault:", vault);

        // 8. Mint some tokens to deployer for testing
        weth.deposit{value: 100 ether}();
        console.log("Minted 100 WETH to deployer");

        // 9. Mint tokens to test accounts
        address testUser = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        weth.mint(testUser, 100 ether);
        console.log("Minted 100 WETH to test user");

        vm.stopBroadcast();

        // Write contracts.json
        string memory json = string(abi.encodePacked(
            '{"weth":"', vm.toString(address(weth)),
            '","wsteth":"', vm.toString(address(wsteth)),
            '","aleth":"', vm.toString(address(aleth)),
            '","alchemist":"', vm.toString(address(alchemist)),
            '","positionNFT":"', vm.toString(address(alchemist.positionNFT())),
            '","converter":"', vm.toString(address(converter)),
            '","swapper":"', vm.toString(address(swapper)),
            '","flashLoanAdapter":"', vm.toString(address(flashLoanAdapter)),
            '","leverager":"', vm.toString(address(leverager)),
            '","vaultFactory":"', vm.toString(address(factory)),
            '","vault":"', vm.toString(vault),
            '","isMock":true}'
        ));

        vm.writeFile("dapp/src/contracts.json", json);
        console.log("\nContracts written to dapp/src/contracts.json");

        console.log("\n=== Deployment Complete ===");
        console.log("This is a MOCK deployment for local UI testing.");
        console.log("All tokens and swaps are 1:1 mocks.");
    }
}
