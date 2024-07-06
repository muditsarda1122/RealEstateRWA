# RealEstateRWA

These smart contracts facilitate transforming your real estate to digital tokens(ERC721) which are made cross-chain (using Chainlink's CCIP), to allow maximum benefits to the user. The minting of the tokens can be done only on Arbitrum Sepolia, thus keeping the minting charges low. Chainlink Functions are utilized to call APIs to get real-time information about the real estate and Chainlink Automation is utilised to automate periodic calling of the function to get the latest price details using the same API. A Lending smart contract is also a part of the project where users can deposit their real estate tokens as collateral and procure a loan against it(a liquidation mechanism is also kept in place so that users could never render the system insolvent).

Function script can be run using the command
```
npm run simulate
```

There are 2 scripts, first to get the price of the real estate and second to get NFT metadata(extra information about the real estate). Make sure to comment out either one in 'Functions-request-config.js' to run the other one. For example: 
```
//source: fs.readFileSync("./Functions-source-getNftMetadata.js").toString(),
source: fs.readFileSync("./Functions-source-getPrices.js").toString(),
  ```

Many thanks to [andrejrakic](https://github.com/andrejrakic) whose Chainlink video inspired me to learn about Chainlink Functions. 
