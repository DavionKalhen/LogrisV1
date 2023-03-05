# Alchemix Leveraged Vaults

## Architecture Overview

![Architecture Overview](docs/AlchemixLeveragedVaultsOverview.png)

## Leverage Contract Overview

There are a stacked set of conditions the leverage contract needs to handle based on the vault capacity.

1) In the most basic case, the vault is full and we just revert.

2) If there is capacity for deposits but not for any leverage we just deposit what we can to the vault and exit.

3) If there is more capacity than the initial deposit but less than max leverage we flashloan as much as is necessary to receive the max deposit amount post slippage, mint as much alAsset as possible, swap it all, repay the loan, and any residual sits in the deposit pool.

4) If there is more ample capacity then we use the flow shown in the architecture overview.



# Frontend

```cd logrisv1-frontend```

```npm i```

```npm run dev```
