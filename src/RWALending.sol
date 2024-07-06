// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {RealEstateNFT} from "./realEstateNft.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract RWALending is IERC721Receiver, OwnerIsCreator, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*
    if the value of the collateral(i.e the real estate) is $1,000,000 then the maximum loan that he will get is $600,000 and if the value of the collateral falls to 750,000 then someone can come in and liquidate them by repaying his loan and taking the real estate.

    this way we will make a profit of 750,000-600,000 = $150,000 
    */
    struct LoanDetails {
        address borrower;
        uint256 usdcAmountLoaned; // will be 60% of the collateral value
        uint256 usdcLiquidationThreshold; // will be 75% of the collateral value
    }

    RealEstateNFT internal immutable i_realEstateNFT;
    address internal immutable i_usdc;
    AggregatorV3Interface internal s_usdcUsdAggregator;
    uint32 internal s_usdcUsdFeedHeartbeat;

    uint256 internal immutable i_weightListPrice;
    uint256 internal immutable i_weightOriginalListPrice;
    uint256 internal immutable i_weightTaxAssessedValue;
    uint256 internal immutable i_ltvInitialThreshold;
    uint256 internal immutable i_ltvLiquidationThreshold;

    mapping(uint256 tokenId => LoanDetails) internal s_activeLoans;

    event Borrow(uint256 indexed tokenId, uint256 indexed loanAmount, uint256 indexed liquidationThreshold);
    event BorrowRepayed(uint256 indexed tokenId);
    event liquidated(uint256 indexed tokenId);

    error GivenNftNotSupported();
    error InvalidValuation();
    error SlippageToleranceExceeded();
    error PriceFeedDdosed();
    error InvalidRoundId();
    error StalePriceFeed();
    error OnlyBorrowerCanCall();
    error BorrowerCanNotCall();

    constructor(
        address _realEstateNFTAddress,
        address _usdcAddress,
        address _usdcUsdAggregatorAddress,
        uint32 _usdcUsdFeedHeartbeat
    ) {
        i_realEstateNFT = RealEstateNFT(_realEstateNFTAddress);
        i_usdc = _usdcAddress;
        s_usdcUsdAggregator = AggregatorV3Interface(_usdcUsdAggregatorAddress);
        s_usdcUsdFeedHeartbeat = _usdcUsdFeedHeartbeat;

        i_weightListPrice = 50;
        i_weightOriginalListPrice = 30;
        i_weightTaxAssessedValue = 20;

        i_ltvInitialThreshold = 60;
        i_ltvLiquidationThreshold = 75;
    }

    function borrow(uint256 _tokenId, uint256 _minLoanAmount, uint256 _maxLiquidationThreshold) external nonReentrant {
        uint256 normalizedValuation = getValuationInUsdc(_tokenId);
        if (normalizedValuation == 0) revert InvalidValuation();

        uint256 loanAmount = (normalizedValuation * i_ltvInitialThreshold) / 100;
        if (loanAmount < _minLoanAmount) revert SlippageToleranceExceeded();

        uint256 liquidationThreshold = (normalizedValuation * i_ltvLiquidationThreshold) / 100;
        if (liquidationThreshold > _maxLiquidationThreshold) revert SlippageToleranceExceeded();

        i_realEstateNFT.safeTransferFrom(msg.sender, address(this), _tokenId);

        s_activeLoans[_tokenId] = LoanDetails({
            borrower: msg.sender,
            usdcAmountLoaned: loanAmount,
            usdcLiquidationThreshold: liquidationThreshold
        });

        IERC20(i_usdc).safeTransfer(msg.sender, loanAmount);

        emit Borrow(_tokenId, loanAmount, liquidationThreshold);
    }

    function repay(uint256 _tokenId) external nonReentrant {
        LoanDetails memory loanDetail = s_activeLoans[_tokenId];

        if (msg.sender != loanDetail.borrower) revert OnlyBorrowerCanCall();

        delete s_activeLoans[_tokenId];

        IERC20(i_usdc).safeTransferFrom(msg.sender, address(this), loanDetail.usdcAmountLoaned);

        i_realEstateNFT.safeTransferFrom(address(this), msg.sender, _tokenId);

        emit BorrowRepayed(_tokenId);
    }

    function liquidate(uint256 _tokenId) external nonReentrant {
        if (msg.sender == s_activeLoans[_tokenId].borrower) revert BorrowerCanNotCall();
        uint256 normalizedValuation = getValuationInUsdc(_tokenId);
        if (normalizedValuation == 0) revert InvalidValuation();

        uint256 liquidationThreshold = (normalizedValuation * i_ltvLiquidationThreshold) / 100;
        if (liquidationThreshold < s_activeLoans[_tokenId].usdcLiquidationThreshold) {
            IERC20(i_usdc).safeTransferFrom(msg.sender, address(this), s_activeLoans[_tokenId].usdcAmountLoaned);
            i_realEstateNFT.safeTransferFrom(address(this), msg.sender, _tokenId);

            delete s_activeLoans[_tokenId];
        }
    }

    function setUsdcUsdPriceFeedDetails(address usdcUsdAggregatorAddress, uint32 usdcUsdFeedHeartbeat)
        external
        onlyOwner
    {
        s_usdcUsdAggregator = AggregatorV3Interface(usdcUsdAggregatorAddress);
        s_usdcUsdFeedHeartbeat = usdcUsdFeedHeartbeat;
    }

    function getValuationInUsdc(uint256 tokenId) public view returns (uint256) {
        RealEstateNFT.PriceDetails memory priceDetails = i_realEstateNFT.getPriceDetails(tokenId);

        uint256 valuation = (
            i_weightListPrice * priceDetails.listPrice + i_weightOriginalListPrice * priceDetails.originalListPrice
                + i_weightTaxAssessedValue * priceDetails.taxAssessedValue
        ) / (i_weightListPrice + i_weightOriginalListPrice + i_weightTaxAssessedValue);

        uint256 usdcPriceInUsd = getUsdcPriceInUsd();

        uint256 feedDecimals = s_usdcUsdAggregator.decimals();
        uint256 usdcDecimals = 6;

        uint256 normalizedValuation = Math.mulDiv((valuation * usdcPriceInUsd), 10 ** usdcDecimals, 10 ** feedDecimals);
        return normalizedValuation;
    }

    function getUsdcPriceInUsd() public view returns (uint256) {
        uint80 _roundId;
        int256 _price;
        uint256 _updatedAt;

        try s_usdcUsdAggregator.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, /*startedAt*/ uint256 updatedAt, uint80 /*answeredInRound*/
        ) {
            _roundId = roundId;
            _price = answer;
            _updatedAt = updatedAt;
        } catch {
            revert PriceFeedDdosed();
        }

        if (_roundId == 0) {
            revert InvalidRoundId();
        }

        if (_updatedAt < block.timestamp - s_usdcUsdFeedHeartbeat) {
            revert StalePriceFeed();
        }

        return uint256(_price);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(i_realEstateNFT)) {
            revert GivenNftNotSupported();
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}
