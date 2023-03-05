import { defineStore } from "pinia";
import { ethers } from "ethers";
import { addresses } from "../constants/addresses";
import LeveragedVaultABI from "../constants/LeveragedVault.json";
import AlchemixABI from "../constants/AlchemixV2.json";

declare global {
  interface Window {
    ethereum: any;
  }
}

type ethErrors = {
  [key: string]: string;
};
export const useWalletStore = defineStore({
  id: "useWalletStore",
  state: () => ({
    address: "",
    addresses: addresses[1],
    balance: ethers.utils.parseEther("0"),
    deposit: ethers.utils.parseEther("0"),
    pool: ethers.utils.parseEther("0"),
    maxMint: ethers.utils.parseEther("0"),
    leveragable: ethers.utils.parseEther("0"),
    balances: {},
    last_blockheight: 0,
    loading: false,
    chainId: 0,
    unsupported_network: false,
    transactions: <ethErrors>{},
    errors: <ethErrors>{
      "4001": "User rejected transaction",
      "4100":
        "The requested method and/or account has not been authorized by the user.",
      "4200": "The Provider does not support the requested method.",
      "4900": "	The Provider is disconnected from all chains.",
      "4901": "The Provider is not connected to the requested chain.",
      "-32000": "Insufficent Ethereum for Transaction",
      "-32001": "Requested resource not found",
      "-32002": "Requested resource not available",
      "-32003": "Transaction creation failed",
      "-32004": "Method is not implemented on contract",
      "-32005": "Request exceeds defined limit",
      "-32006": "Version of JSON-RPC protocol is not supported",
      "-32015": "Transaction underpriced",
      "-32016": "Transaction nonce too low",
      "-32600": "Invalid request",
      "-32601": "Method not found",
      "-32602": "Invalid params",
      "-32603": "Internal error",
      "-32700": "Parse error",
    },
  }),
  getters: {
    connectAddress(state) {
      if (state.address == "" || state.address == undefined) return "Connect";

      return state.address.slice(0, 7) + "..." + state.address.slice(-5);
    },
    provider(state) {
      return new ethers.providers.Web3Provider(window.ethereum);
    },
  },
  actions: {
    async connectWallet() {
      const { ethereum } = window;
      if (ethereum && this.address == "" && this.loading === false) {
        try {
          await ethereum.request({ method: "eth_requestAccounts" });
        } catch (error) {
          console.log(error);
        }
        const accounts = await ethereum.request({ method: "eth_accounts" });
        const provider = this.provider;
        const signer = provider.getSigner();
        const chainId = await signer.getChainId();
        this.address = await signer.getAddress();
        this.balance = await signer.getBalance();
        await this.getDepositBalance();
        await this.getFullBalance();
        await this.getMintCapacity();
        this.chainId = chainId;
        ethereum.on("accountsChanged", (accounts: string[]) =>
          this.onAccountChange(accounts)
        );

      }
    },
    // Network Events
    async onAccountChange(accounts: string[]) {
      console.log("Account Changed", accounts);
      this.address = accounts[0];
      this.balance = ethers.utils.parseEther("0");
      this.balances = {};
      this.last_blockheight = 0;
      if (accounts.length == 0) {
        await this.connectWallet();
      }
    },

    // Methods
    async updateBalance() {
      const provider = this.provider;
      const signer = provider.getSigner();
      this.balance = await signer.getBalance();
    },
    async getDepositBalance() {
      const provider = this.provider;
      const signer = provider.getSigner();
    
      const contract = new ethers.Contract(
        this.addresses.LOGRISVAULT,
        LeveragedVaultABI,
        signer
      );
      const address = this.address
      console.log(address)
      const shares = await contract.balanceOf(address);
      const balance = await contract.convertSharesToUnderlyingTokens(shares);
      this.deposit = balance;
    },
    async getFullBalance() {
      const provider = this.provider;
      const signer = provider.getSigner();

      const contract = new ethers.Contract(
        this.addresses.LOGRISVAULT,
        LeveragedVaultABI,
        signer
      );
      const balance = await contract.getVaultDepositedBalance();
      this.pool = balance;
      return balance;
    },
    async leverage() {
      const provider = this.provider;
      const signer = provider.getSigner();

      const contract = new ethers.Contract(
        this.addresses.LOGRISVAULT,
        LeveragedVaultABI,
        signer
      );
      const tx = await contract.leverage();
      await tx.wait();
    },
    async getMintCapacity() {
      const provider = this.provider;
      const signer = provider.getSigner();

      const contract = new ethers.Contract(
        this.addresses.ALCHEMIXV2,
        AlchemixABI,
        signer
      );
      const params = await contract.getYieldTokenParameters(this.addresses.YIELDTOKEN);
      this.maxMint = params[4];
    },
    async depositETH(amount: number) {
      const provider = this.provider;
      const signer = provider.getSigner();
      //add DepositUnderlying event
      const contract = new ethers.Contract(
        this.addresses.LOGRISVAULT,
        [{
          "inputs": [],
          "name": "depositUnderlying",
          "outputs": [
            {
              "internalType": "uint256",
              "name": "shares",
              "type": "uint256"
            }
          ],
          "stateMutability": "payable",
          "type": "function"
        },
        {
          "anonymous": false,
          "inputs": [
            {
              "indexed": true,
              "internalType": "address",
              "name": "sender",
              "type": "address"
            },
            {
              "indexed": true,
              "internalType": "address",
              "name": "underlyingToken",
              "type": "address"
            },
            {
              "indexed": false,
              "internalType": "uint256",
              "name": "amount",
              "type": "uint256"
            }
          ],
          "name": "DepositUnderlying",
          "type": "event"
        },],
        signer
      );
      const tx = await contract.depositUnderlying({
        value: ethers.utils.parseEther(amount.toFixed(17).toString()),
      });

      contract.on("DepositUnderlying", async (user, amount, shares) => {
        await this.getDepositBalance();
        await this.getFullBalance();
        await this.getMintCapacity();
      });
      return tx;
    }
  },
});