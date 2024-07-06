//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {FunctionsSource} from "./functionsSource.sol";

contract RealEstateNFT is
    ERC721,
    ERC721URIStorage,
    ERC721Burnable,
    ReentrancyGuard,
    IAny2EVMMessageReceiver,
    OwnerIsCreator,
    FunctionsClient
{
    using SafeERC20 for IERC20;
    using FunctionsRequest for FunctionsRequest.Request;

    enum PayFeesIn {
        Native,
        Link
    }

    struct NftDetails {
        address nftAddress;
        bytes ccipExtraArgsBytes;
    }

    struct PriceDetails {
        uint80 listPrice;
        uint80 originalListPrice;
        uint80 taxAssessedValue;
    }

    uint256 constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    IRouterClient internal immutable i_ccipRouter;
    LinkTokenInterface internal immutable i_linkToken;
    FunctionsSource internal immutable i_functionsSource;

    uint64 private immutable i_currentChainSelector; // This same contract must be deployed on several chains to allow cross chain functionality, this value will be the selector of the chain on which this contract is deployed, hence it is 'immutable'.

    bytes32 internal s_lastRequestId; //what is this?
    address internal s_automationForwarderAddress; //what is this?

    uint256 private _nextTokenId;

    mapping(uint64 destChainSelector => NftDetails nftDetailsPerChain) public s_chains;
    mapping(bytes32 requestId => address to) internal s_issueTo;
    mapping(uint256 tokenId => PriceDetails priceDetailsOfRealEstate) internal s_priceDetails;

    event chainEnabled(uint64 chainSelector, address nftAddress, bytes ccipExtraArgsBytes);
    event chainDisabled(uint64 chainSelector);
    event crossChainSent(
        address from, address to, uint256 tokenId, uint64 sourceChainSelector, uint64 destChainSelector
    );
    event crossChainReceived(
        address from, address to, uint256 tokenId, uint64 sourceChainSelector, uint64 destChainSelector
    );

    error InvalidRouter(address router);
    error OnlyAutomationForwarderCanCall();
    error OnlyOnArbitrumSepolia();
    error ChainNotEnabled();
    error SenderNotEnabled(address sender);
    error OperationNotAllowedOnCurrentChain(uint64 chainSelector);
    error NotEnoughBalanceForFee(uint256 balance, uint256 fee);
    error NothingToWithdraw();
    error FailedToWithdrawEth(address caller, address beneficiary, uint256 amount);
    error LatestIssueInProgress();

    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter)) {
            revert InvalidRouter(msg.sender);
        }
        _;
    }

    modifier onlyAutomationForwarder() {
        if (msg.sender != s_automationForwarderAddress) {
            revert OnlyAutomationForwarderCanCall();
        }
        _;
    }

    modifier onlyOnArbitrumSepolia() {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert OnlyOnArbitrumSepolia();
        }
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (s_chains[_chainSelector].nftAddress == address(0)) {
            revert ChainNotEnabled();
        }
        _;
    }

    modifier onlyEnabledSender(uint64 _chainSelector, address _sender) {
        if (s_chains[_chainSelector].nftAddress != _sender) {
            revert SenderNotEnabled(_sender);
        }
        _;
    }

    modifier onlyOtherChains(uint64 _chainSelector) {
        if (_chainSelector != i_currentChainSelector) {
            revert OperationNotAllowedOnCurrentChain(_chainSelector);
        }
        _;
    }

    constructor(
        address ccipRouterAddress,
        address linkTokenAddress,
        uint64 currentChainSelector,
        address functionsRouterAddress
    ) ERC721("Cross chain tokenized real estate", "RealEstateNFT") FunctionsClient(functionsRouterAddress) {
        if (ccipRouterAddress == address(0)) {
            revert InvalidRouter(address(0));
        }
        i_ccipRouter = IRouterClient(ccipRouterAddress);
        i_linkToken = LinkTokenInterface(linkTokenAddress);
        i_currentChainSelector = currentChainSelector;
        i_functionsSource = new FunctionsSource();
    }

    function enableChain(uint64 _chainSelector, address _nftAddress, bytes memory _ccipExtraArgs)
        external
        onlyOwner
        onlyOtherChains(_chainSelector)
    {
        s_chains[_chainSelector] = NftDetails({nftAddress: _nftAddress, ccipExtraArgsBytes: _ccipExtraArgs});
        emit chainEnabled(_chainSelector, _nftAddress, _ccipExtraArgs);
    }

    function disableChain(uint64 _chainSelector) external onlyOwner onlyOtherChains(_chainSelector) {
        delete s_chains[_chainSelector];
        emit chainDisabled(_chainSelector);
    }

    // should we have a check for legitimate token Id here?
    function crossChainTransaferFrom(
        address from,
        address to,
        uint256 tokenId,
        uint64 destinationChainSelector,
        PayFeesIn payFeeIn
    ) external nonReentrant onlyEnabledChain(destinationChainSelector) returns (bytes32 messageId) {
        // first burn the token on sender chain
        string memory tokenUri = tokenURI(tokenId);
        _burn(tokenId);

        // create a message for the destination chain token address containing information about this token(eg. tokenId)
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(s_chains[destinationChainSelector].nftAddress),
            data: abi.encode(from, to, tokenId, tokenUri), // this data can be decoded in the destination chain. I think tokenId and tokenUri both are sent so that everything can be kept same when it will be minted on destination chain
            tokenAmounts: new Client.EVMTokenAmount[](0), // we don't send any token
            feeToken: payFeeIn == PayFeesIn.Link ? address(i_linkToken) : address(0),
            extraArgs: s_chains[destinationChainSelector].ccipExtraArgsBytes
        });

        // get the fee required to send this message
        uint256 fee = i_ccipRouter.getFee(destinationChainSelector, message);

        if (payFeeIn == PayFeesIn.Link) {
            if (fee > i_linkToken.balanceOf(address(this))) {
                revert NotEnoughBalanceForFee(i_linkToken.balanceOf(address(this)), fee);
            }
            // approve the router to spend on smart contract's behalf
            i_linkToken.approve(address(i_ccipRouter), fee); //this will approve router to spend fee amount of LINK
            // send the message
            messageId = i_ccipRouter.ccipSend(destinationChainSelector, message);
        } else {
            if (fee > address(this).balance) {
                revert NotEnoughBalanceForFee(address(this).balance, fee);
            }
            messageId = i_ccipRouter.ccipSend{value: fee}(destinationChainSelector, message);
        }

        emit crossChainSent(from, to, tokenId, i_currentChainSelector, destinationChainSelector);
    }

    function ccipReceive(Client.Any2EVMMessage calldata message)
        external
        virtual
        override
        onlyRouter
        nonReentrant
        onlyEnabledChain(message.sourceChainSelector)
        onlyEnabledSender(message.sourceChainSelector, abi.decode(message.sender, (address)))
    {
        uint64 sourceChainSelector = message.sourceChainSelector;
        (address from, address to, uint256 tokenId, string memory tokenUri) =
            abi.decode(message.data, (address, address, uint256, string));

        // mint the nft in the destination chain and set correct tokenURI
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenUri);

        emit crossChainReceived(from, to, tokenId, sourceChainSelector, i_currentChainSelector);
    }

    function withdraw(address _beneficiary) public onlyOwner {
        uint256 amount = address(this).balance;

        if (amount == 0) {
            revert NothingToWithdraw();
        }

        (bool success,) = _beneficiary.call{value: amount}("");
        if (!success) {
            revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
        }
    }

    function withdrawToken(address _beneficiary, address _token) public onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));

        if (amount == 0) {
            revert NothingToWithdraw();
        }

        IERC20(_token).safeTransfer(_beneficiary, amount);
    }

    function issue(address to, uint64 subscriptionId, uint32 gasLimit, bytes32 donId)
        external
        onlyOwner
        onlyOnArbitrumSepolia
        returns (bytes32 requestId)
    {
        if (s_lastRequestId != bytes32(0)) {
            revert LatestIssueInProgress();
        }

        FunctionsRequest.Request memory req; // create a request body
        req.initializeRequestForInlineJavaScript(i_functionsSource.getNftMetadata()); // populate the req with information
        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId); // send the request

        s_issueTo[requestId] = to;
    }

    function updatePriceDetails(uint256 tokenId, uint64 subscriptionId, uint32 gasLimit, bytes32 donId)
        external
        onlyAutomationForwarder
        returns (bytes32 requestId)
    {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(i_functionsSource.getPrice());

        string[] memory args = new string[](1);
        args[0] = string(abi.encode(tokenId));

        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, gasLimit, donId);
    }

    function setAutomationForwarder(address automationForwarderAddress) external onlyOwner {
        s_automationForwarderAddress = automationForwarderAddress;
    }

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/ ) internal override {
        if (s_lastRequestId == requestId) {
            (string memory realEstateAddress, uint256 yearBuilt, uint256 lotSizeSquareFeet) =
                abi.decode(response, (string, uint256, uint256));

            uint256 tokenId = _nextTokenId++; // what should be the tokenId of the next token which will be minted

            // why not ' string memory uri = string(abi.encodePacked(...)) '?
            // why not ' string memory uri = Base64.encode(abi.encodePacked(...)) '?
            /* 
            1) abi.encodePacked returns raw bytes
            2) by converting it to 'String' we get a valid UTF-8 encoded string representation of the JSON string. Keeps it human-readable 
            */
            string memory uri = Base64.encode(
                bytes(
                    string(
                        abi.encodePacked(
                            '{"name": "Cross chain Tokenized Real Estate",',
                            '"description": "Cross chain Tokenized Real Estate",',
                            '"image": "",',
                            '"attributes": [',
                            '{"trait_type": "realEstateAddress", "value": ',
                            realEstateAddress,
                            "}",
                            '{"trait_type": "yearBuilt", "value": ',
                            yearBuilt,
                            "}",
                            '{"trait_type": "lotSizeSquareFeet", "value": ',
                            lotSizeSquareFeet,
                            "}",
                            "]}"
                        )
                    )
                )
            );

            string memory finalTokenUri = string(abi.encodePacked("data:application/json;base64,", uri));

            _safeMint(s_issueTo[requestId], tokenId);
            _setTokenURI(tokenId, finalTokenUri);
        } else {
            (uint256 tokenId, uint256 listPrice, uint256 originalListPrice, uint256 taxAssessedValue) =
                abi.decode(response, (uint256, uint256, uint256, uint256));

            s_priceDetails[tokenId] = PriceDetails({
                listPrice: uint80(listPrice),
                originalListPrice: uint80(originalListPrice),
                taxAssessedValue: uint80(taxAssessedValue)
            });
        }
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    function getCCIPRouter() public view returns (address) {
        return address(i_ccipRouter);
    }

    function getPriceDetails(uint256 tokenId) public view returns (PriceDetails memory) {
        return s_priceDetails[tokenId];
    }
}
