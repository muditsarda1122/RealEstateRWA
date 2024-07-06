// the way we call our APIs is still written only in JS
const { ethers } = await import("npm:ethers@6.10.0");

const abiCoder = ethers.AbiCoder.defaultAbiCoder();

const apiResponse = await Functions.makeHttpRequest({
  url: `https://api.bridgedataoutput.com/api/v2/OData/test/Property('P_5dba1fb94aa4055b9f29696f')?access_token=6baca547742c6f96a6ff71b138424f21`,
});

const realEstateAddress = apiResponse.data.UnparsedAddress;
const yearBuilt = Number(apiResponse.data.YearBuilt);
const lotSizeSquareFeet = Number(apiResponse.data.LotSizeSquareFeet);

console.log(`Real Estate Address: ${realEstateAddress}`);
console.log(`Year Built: ${yearBuilt}`);
console.log(`Lot Size Square Feet: ${lotSizeSquareFeet}`);

const encoded = abiCoder.encode(
  [`string`, `uint256`, `uint256`],
  [realEstateAddress, yearBuilt, lotSizeSquareFeet]
); // used to translate JS types to Solidity types

return ethers.getBytes(encoded);
