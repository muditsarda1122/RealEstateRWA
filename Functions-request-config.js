const fs = require("fs");
const {
  Location,
  ReturnType,
  CodeLanguage,
} = require("@chainlink/functions-toolkit");

const requestConfig = {
  codeLocation: Location.Inline,
  codeLanguage: CodeLanguage.JavaScript,

  //source: fs.readFileSync("./Functions-source-getNftMetadata.js").toString(),
  source: fs.readFileSync("./Functions-source-getPrices.js").toString(),

  secrets: {},
  perNodeSecrets: [],
  walletPrivateKey: process.env["PRIVATE_KEY"],
  args: ["0"],
  expectedReturnType: ReturnType.bytes,
  secretsURLs: [],
};

module.exports = requestConfig;
