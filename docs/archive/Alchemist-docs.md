Introducing Alchemix v3

-by Scoopy Trooples


It feels like a lifetime ago, February 2021 to be precise, when we introduced Alchemix and the concept of Self-Repaying Loans to the world. It was quite revolutionary then and remains a beloved DeFi protocol that has expanded and refined itself in various ways over the years. During this period, we have learned significantly more about lending and synthetic asset dynamics. After years of theorizing and iterating on our models, we are finally ready to introduce the world to Alchemix v3. We have enhanced it with smarter mechanics, improved fairness for all parties, and greater clarity. If you have enjoyed Alchemix in the past, this next evolution (or perhaps revolution) will feel like a natural, powerful upgrade.


Alchemix v3: Harnessing Yield and Time

At its core, Alchemix v3 still lets you borrow synthetic alAssets – alUSD and alETH – based on your future yield. Simply deposit USDC or ETH, borrow their synthetic counterpart, and watch your collateral generate yield to repay your loan. However, Alchemix v3 doesn’t stop there. It introduces temporal mechanics – carefully designed systems ensuring fair and efficient debt repayment for all users. To understand this better, we must first discuss the new and improved redemption module, The Transmuter.

Transmuter v3: Ensuring Peg Stability with Fixed-Duration Redemptions

In Alchemix v2, redemptions were powered by liquidated yield flowing from collateral repayments into the Transmuter. This created unpredictability, as redemption rates depended heavily on yield variability, potentially hurting both borrowers and decentralized exchange (DEX) liquidity providers (LPs) by weakening the synthetic peg. 

The Alchemix v3 transmuter fixes this dynamic. 

To maintain the value (or “peg”) of alUSD and alETH, Alchemix v3 introduces fixed-duration redemptions through our Transmuter redemption module. The Alchemix DAO sets specific redemption periods likely ranging from three or more months. When you deposit alUSD or alETH into the transmuter, you will know exactly when they become redeemable at their original value (e.g. 1 alUSD for 1 USDC).

This fixed-duration redemption creates predictable yield opportunities for arbitrageurs and establishes a new fixed-rate interest primitive in DeFi. For example, if alUSD drops to 0.98 USDC in value, and there is a 3-month duration redemption, the arbitrager can earn an effective 8% fixed yield. This activity stabilizes the alAsset peg and creates a consistent demand for alAssets. Moreover, this mechanism also directly protects DEX LPs from impermanent loss. If the peg begins to falter, LPs can let arbitrageurs restore the peg, or they can withdraw alAssets and redeem them 1:1, effectively erasing losses and even allowing profit opportunities. 

Alchemist v3: Simpler, More Powerful Collateralized Debt Positions (CDPs) and Temporal Leverage.

Meta-Yield Token

The first major advancement in the v3 CDP system, The Alchemist, is a massive UX simplification and optimization through the introduction of an Alchemix-DAO-managed Meta-Yield Token (MYT). In Alchemix v2, users could select from various yield strategies (e.g. Yearn, AAVE, wstETH) as collateral. While offering granular control, this approach made system-wide optimization difficult, increased user complexity, and risked obsolescence when strategies changed.

The MYT is a composite of multiple yield strategies integrated into one token. Built on Euler Finance’s Euler Earn protocol, a customized ERC-4626 implementation. This token will then be managed initially by the DAO Multisig and later fully governed onchain by Alchemix DAO. Strategies will include some of our current offerings, additional yield tokens from other protocols, and custom strategies developed by our community builders via our grants program. The goal is to weigh these strategies to balance yield optimization and safety, creating the best risk-adjusted yield token in DeFi. Furthermore, the specific composition of the MYT will vary across different chains, providing users with distinct strategy mixes suited to different risk profiles, ranging from conservative to more aggressive yield strategies. This significantly streamlines your yield generation and provides an exceptionally simple user experience. 

Additionally, if you prefer straightforward passive returns without borrowing, simply deposit into the MYT directly and let it earn yield effortlessly.

Alchemist CDP

With the vastly more robust peg-keeping mechanisms, Alchemix v3 will now allow you to borrow up to 90% of your collateral value, significantly enhancing capital efficiency. Sophisticated yield strategists will find plenty to appreciate here. Your collateral continuously compounds yield within the MYT, and unlike previous versions, repayments no longer come from liquidated yield but rather from redemption events from the Transmuter. Upon redemption, users’ collateral will be partially liquidated to repay earmarked debt and fund redemptions.

Understanding Earmarking and Time-Weighted Redemptions

Unlike in v2, where yield is automatically liquidated for debt repayments, Alchemix v3 introduces a structured redemption and earmarking system designed for fairness, transparency, and efficiency.

When a redemption event starts in the Transmuter, portions of users’ debts gradually become “earmarked debt” based on each user’s share of the total debt and how long they’ve held it during the redemption period. This earmarked debt is a subset specifically reserved by the system for repayment for redemptions. The purpose of earmarking is critical. Without it, sophisticated users could unfairly avoid repayments by sandwiching repaying debt immediately before a redemption and then quickly re-establishing their position afterward. Such activity would unfairly shift repayment burdens onto other users. 

To further ensure fairness, earmarking follows a “time-weighted” approach:

Users present for the entire redemption duration receive full proportional earmarked repayments.
Users joining midway through a redemption period receive proportionally less earmarking, reflecting their shorter debt exposure. 

Users retain flexibility to repay their debts at any time. However, normal debt repayment requires alAssets, while earmarked debt repayment specifically requires the MYT. Repaying earmarked debt early places the used MYT into a buffer, prioritizing future redemptions from this buffer, thus extending the temporal advantage to all participants.

The Temporal Advantage

The secret advantage comes from deferred redemptions from the fixed-duration transmuter redemptions. Unlike other synthetic-asset protocols with redemption mechanisms that immediately deduct collateral, our system waits until the redemption is completed. During this waiting period, your collateral continues earning yield on the full original amount, not the reduced post-redemption amount. For example, if you have 100 units of collateral and a redemption of 10 units is planned, you continue earning yield on the entire 100 units until the redemption actually takes place. This extended yield-earning period provides you with an inherent advantage – what we call “temporal advantage”. 


Safety and Stability

High leverage borrowing (up to 90%) demands robust safeguards. There is always risk in DeFi – protocol logic bugs, economic attacks, or mismanagement – all potentially leading to losses. Given the MYT consists of multiple DeFi strategies, any specific strategy might incur losses, reducing collateral value. Alchemix v3 employs clear and robust liquidation mechanisms, triggered only if the MYT loses backing—as determined by fundamental oracles measuring actual collateral value rather than market price—to maintain solvency if needed.


Why Choose Alchemix v3?

Alchemix v3 offers a comprehensive, improved approach to yield driven lending:

Self-Repaying Loans: Your debt automatically decreases as yield accrues.
Spend and Save: Use borrowed capital while your collateral continues earning yield.
Supercharged Yield: Leverage your CDP to amplify yield safely.
Predictable and Stable: Stable borrowing without interest rate surprises.
LP with Confidence: Robust pegging mechanisms ensure profitable arbitrage and LP safety.

Alchemix v3 refines and advances our original vision, balancing sophisticated financial strategies with simplicity, fairness, and safety. Our team at Alchemix DAO have lovingly crafted this protocol, and we hope that everyone takes advantage of one of the most innovative and powerful savings and credit platforms in DeFi today.


