<template>
  <div class="app">
      <div class="panel">
        <div class="depositAmount">
          <h2>Logris Vault</h2>
          <div class="input-group">
            <input v-model="amount" type="number" class="form-control" placeholder="Enter Amount" aria-label="Enter Amount" aria-describedby="basic-addon2">
            <div class="input-group-append" v-if="address != null && loading === false">
              <button class="btn btn-outline-secondary" type="button" @click="deposit">Deposit</button>
              <!-- <button class="btn btn-outline-secondary" type="button" @click="withdraw">Withdraw</button>-->

            </div>
            <div class="input-group-append" v-else-if="address === null">
              <button class="btn btn-outline-secondary" type="button" @click="connectWallet">Connect Wallet</button>
            </div>
            <div class="input-group-append" v-else-if="loading === true">
                <img class="loading" src="./assets/loading.gif" alt="loading..." />
            </div>            
          </div>
        </div>
        <div class="stats" v-if="address">
          <h2>Stats for {{ address.slice(0,7) }}...{{  address.slice(-5) }}</h2>
            <div>Ethereum Balance: {{ parseFloat(displayBigNum(wallet.balance)).toFixed(2) }}<span></span></div>
            <div>Depostied Amount:  {{ parseFloat(displayBigNum(wallet.deposit)).toFixed(2) }}<span></span></div>
            <div>Pool Balance:  {{ parseFloat(displayBigNum(wallet.pool)).toFixed(2) }}<span></span></div>
            <div>Mint Capacity: {{ parseFloat(displayBigNum(wallet.maxMint)).toFixed(2) }}</div>
            <div>Withdrawable Balance: {{ parseFloat(displayBigNum(wallet.shares)).toFixed(2) }}</div>
        </div>
        <button v-if="address != null && wallet.leveragable > toBigNum('0') " class="btn btn-outline-secondary leverage" type="button" @click="leverage">Leverage</button>

      </div>
  </div>
</template>

<script>
import {ethers} from 'ethers';
import {useWalletStore} from './stores/useWalletStore';

export default {
name: 'App',
components: {
},
data() {
  return {
    wallet: useWalletStore(),
    address: null,
    amount: "",
    loading: false,
  };
},
watch: {
  'wallet.address'() {
    this.address = this.wallet.connectAddress;
  },
},
methods: {
    connectWallet() {
      this.wallet.connectWallet();
    },
    async deposit() {
      this.loading = true;
      const txn = await this.wallet.depositETH(this.amount).catch((err) => {
        console.log(err);
        this.loading = false;
      });

      this.amount = "";
      this.loading = false;
    },
    async leverage() {
      this.loading = true;
      const txn = await this.wallet.leverage(this.amount).catch((err) => {
        console.log(err);
        this.loading = false;
      });

      this.amount = "";
      this.loading = false;
    },
    async withdraw() {
      this.loading = true;
      const txn = await this.wallet.withdrawETH(this.amount).catch((err) => {
        console.log(err);
        this.loading = false;
      });

      this.amount = "";
      this.loading = false;
    },
    displayBigNum(num) {
      return ethers.utils.formatEther(num);
    },
    toBigNum(num) {
      return ethers.utils.parseEther(num);
    },
},
}
</script>

<style>
body {
  background: linear-gradient(171.08deg,#010101 -11.16%,#141921 6.1%,#0a0d11 49.05%,#000000 93.22%) no-repeat fixed;
  color: #f5f5f5;
  width: 100vw;
  height: 100vh;
}
</style>
<style scoped>
.panel {
background-color:#141921;
border-radius: 10px;
border: 1px solid white;
width: 500px;
min-height: 500px;
margin: 20vh auto;
padding: 2rem;
text-align: center;
}

input {
border: 1px solid #f5f5f5;
border-radius: 5px;
padding: 1rem;
background-color: #141921;
color: #f5f5f5;
width: 90%;
}

.btn-outline-secondary {
border: 1px solid #f5f5f5;
border-radius: 5px;
padding: 1rem;
background-color: #141921;
color: #f5f5f5;
margin: 1rem 1rem;
}

.loading {
  width: 50px;
  height: 50px;
  margin: 1rem auto;
}

.leverage {
  margin: 1rem auto;
min-width: 50% !important;
}

.btn {
  min-width: 10rem;
}
</style>