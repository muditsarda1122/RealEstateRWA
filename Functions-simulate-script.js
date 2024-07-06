const { simulateScript } = require("@chainlink/functions-toolkit");
const requestConfig = require("./Functions-request-config");

async function main() {
  const { responseBytesHexstring, capturedTerminalOutput, errorString } =
    await simulateScript(requestConfig);

  console.log(responseBytesHexstring);
  console.log(errorString);
  console.log(capturedTerminalOutput);

  console.log(761167 * 99998122, "USDC");

  console.log(
    "normalized USDC to be sent: ",
    761152.70528374,
    "USDC ( (761167*99998122) * 10^6 / 10^8 )"
  );
}

// node Functions-simulate-script.js
main();
