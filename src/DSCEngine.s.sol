//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/*
 *   @title DSCEngine
 *   @author Blagovest Georgiew
 *   Minimalistic system, and have tokens maintain a 1 token == 1 dollar anchored
 *   - Exogenous collateral
 *   - Dollar pegged
 *   - Algorithmic Stable
 *   This is the contract meant to be governed by the DSCEngine. This is the ERC20 implementation of ERC20
 *
 *   Is simmilar to DAI if DAI had no governance, no fees and was only backed by WETH and
 *   WTBC
 * COntract is core of DSC System, handles logic of minting and redeeming DSC, as well as depositing and withdrawing collateral
 * Contract is Very loosely based on MarketDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {
    ///errors///
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOkay();
    error DSCEngine__HealthFactorNotImproved(); 

    ///////////////
    //Type/////////
    ///////////////

    using OracleLib for AggregatorV3Interface;
    ///////////////
    ///state var///
    ///////////////
    

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% OVEr ColLATERALLIZED
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; //A 10$ bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //token to priceFeeds
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    /////////////
    ////Event////
    /////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTO,
        address indexed token,
        uint256 amount
    );

    ////////////////
    ///Modifiers////
    ////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////
    ///Functions////
    ////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        //Usd price feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedMustBeSameLength();
        }
        //Example USD / ETC,  BTC / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///external////
    /*
     *   @param tokenCollateralAddress the address of the token to deposit as colleteral
     *   @param amountCollateral The amount of collateral to deposit
     *   @param amountDscToMint The amount of decentralized stablecoin to mint
     *   @notice this function will deposit your collateral and mint dsc in one transaction
     *
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     *  @param Token collateralAddress The address of the token to deposit as collateral
     *  @amount collateral The amount of collateral to deposit
     *
     */

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // in order to redeem collateral:
    // 1.health factor must be over 1 AFTER COLLATERAL pulled
    // DRY DoNt Repeat urself

    //CEI Checks effects interactions
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        // 100 - 1000 -> revert based on solidity evm
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // @Notice follows CEI
    // @Param amountDscToMint The amount of decentralized stablecoin to mint
    // @Notice They must have more collateral value than minimum threshold
    //1. Check if collateral value > DSC amount. Price feeds, values etc...
    // 200$ ETH => 20$ DSC
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //If they minted too much ($150 DSC but only have 100$ ETH -> too much -> revert)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
     * @Param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount collateral to redeem
     * @amountDsctoBurn self explenatory
     */

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) public {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //This wouldnt break healthfactor ;3
    }

    //If we start getting undercollaterization, we need to liquidate positions

    //100$ ETH backing 50$ DSC
    // 20$ ETH BACK and $50 DSC <- DSC isnt worth 1$

    //75$ backing 50$ DSC
    //Liquidator take 75$ backing and burns off the 50$ DSC

    //IF someone is almost undercollaterized we will pay YOU to liquidate them

    /* @param addressThe erc20 collateral address to liquidate from the user
     *  @param user, the user who has broken the healthfactor, their _healthFactor should be below minhealthFactor
     *  @param debtToCover The amount to DSC you want to burn to improve the users healthfactor
     *  @notice you cannot partially liquidate user
     *  @notice you will get liqudation bonus for taking users funds
     *  @notice this function assumes the protocol will be roughly 200% overcollateralized
     *  @notice A known bug would be if the protocol were 100% or less collateralized, then we
     *  wouldnt be able to incentivize liquidators
     *  For exampl. if the price of the collateral plummeted before anyone could be liquidated
     *
     * Follows CEI checks effects interactions
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) public moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOkay();
        }
        // We want to burn their DSC debt
        // and take their collateral
        //Bad user:140$ eth deposited and 100$ of DSC,
        // debt to cover = 100$
        // 100$ DSC = ?ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give them 10% bonus
        // So we are giving the liquidator 110$ of WETH for 100DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);   
        //WE need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if(endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() public {}

    ////////////////////////
    ///Private & Internal///
    ////////////////////////

    // @dev Low level internal function, do not call unless the function calling it is checking for health factors being broken 
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
          s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    //Returns how close to liquidation a user is
    // If user goes below 1 they can get liquidated
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // Total collateral VALUE
        (
            uint256 totalDSCMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        if(totalDSCMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted; //150 / 100
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////
    ///Public & External//
    //////////////////////

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        //Loop through each collateral token, get the amount and map it to price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        // price of eth or token
        // $/Eth ??, 1000$ / ETH = 0.5eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return
            ((usdAmountInWei * PRECISION) / (uint256(price) *
            ADDITIONAL_FEED_PRECISION));
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
