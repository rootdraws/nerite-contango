Hey Joseph,

This is my best draft for integrating Contango into Nerite. 

This is specifically the area of the Contango Repo that I was studying to make this work: 

https://github.com/contango-xyz/core-v2/tree/main/src/moneymarkets

You can see in there, that there are examples of different money markets: 
- Compound III
- Compound v2
- Morpho
- Aave
- Euler

I used an LLM to study what those repos were, and how the core contracts worked, and then I discovered that these two were the main patterns: 

- https://github.com/contango-xyz/core-v2/blob/main/src/moneymarkets/BaseMoneyMarket.sol
- https://github.com/contango-xyz/core-v2/blob/main/src/moneymarkets/BaseMoneyMarketView.sol

## NeriteMoneyMarket.sol 

Is basically the connector between the contango contracts, and opening nerite positions. 

One problem that I forsee here, is that the way this works, it's a flash loan loop -- which means: 

1. Flash Loan. 
2. Deposit Collateral. 
3. Borrow [Minimum $500]
4. Swap
5. Deposit Collateral. 
6. Borrow [Minimum $500]
7. etc.

This is bundled up into a single transaction, and so it might be difficult to make sure that you have the right minimums to open a position of enough size to where it doesn't revert, cause the minimums are not being met. 

.:. 

Some notes on Contango -- it's a similar structure to yours -- they have an NFT, which holds all of the position information / health of the flash loan. They handle the position on top of Nerite. 

## NeriteMoneyMarketView.sol

This gets all of the information on the position. 
Contango Lens is associated with this. 

## NeriteReverseLookup.sol

This is about how Contango knows which Nerite Position is associated with which Contango Position. 

.:. 

There were a few things that were complications: 

1) I noticed that you have a Subgraph which processes the average rates per asset on your frontend. This is interesting, because Nerite has the ability to set your rates - when you open a position. But, Compound, and Euler, and the other money markets have a set rate. 

This means, that IF you wanted to be composible with Contango - without haivng your own frontend, like if you wanted contango users to be able to do cPerps of Nerite positions, I think you'd need to feed that open position function with a value for the borrow rate. 

I would have created an oracle that pulled from that subgraph, did the calculations, and then fed that value of "a good average position + 0.5%" into the function which opens up the position for contango. 

Otherwise, you need a function which allows a custom rate, and you need a unique frontend. -- which I have included in my draft. 


2) If you want NeriteMoneyMarketView.sol to be able to provide reliable position information, you'll need a USND oracle. 

This is actually the case for any composible product that uses USND - our Euler markets. 

.:. 

I noticed that you have flash loan tools built right into Nerite Repo, so I don't think you actually need this integration. But, it was a fun thing to explore.
