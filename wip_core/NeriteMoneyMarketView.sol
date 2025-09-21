// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "./dependencies/Constants.sol";
import "./dependencies/IBorrowerOperations.sol";
import "./dependencies/ITroveManager.sol";
import "./dependencies/IActivePool.sol";
import "./dependencies/IPriceFeed.sol";
import "./dependencies/LatestTroveData.sol";
import "./NeriteReverseLookup.sol";
import "./NeriteUSNDOracle.sol";

// Add these imports to satisfy transitive dependencies:
import "./dependencies/ILiquityBase.sol";        // Required by IBorrowerOperations & ITroveManager
import "./dependencies/IAddRemoveManagers.sol";  // Required by IBorrowerOperations
import "./dependencies/IStabilityPool.sol";      // Required by ITroveManager
import "./dependencies/IInterestRouter.sol";     // Required by IActivePool
import "./dependencies/IBoldRewardsReceiver.sol"; // Required by IActivePool
import "./dependencies/IWETH.sol";               // Required by IBorrowerOperations
import "./dependencies/ITroveNFT.sol";           // Required by ITroveManager
import "./dependencies/ISortedTroves.sol";       // Required by ITroveManager
import "./dependencies/IBoldToken.sol";          // Required by ITroveManager
import "./dependencies/TroveChange.sol";         // Required by ITroveManager
import "./dependencies/BatchId.sol";             // Required by ISortedTroves

import "../dependencies/IWETH9.sol";  // From Contango/Libraries
import "../dependencies/Chainlink.sol"; // From Contango/Libraries

import "../BaseMoneyMarketView.sol";

contract NeriteMoneyMarketView is BaseMoneyMarketView {
    using Math for *;

    error OracleNotFound(IERC20 asset);

    // Nerite protocol contracts
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IActivePool public immutable activePool;
    IPriceFeed public immutable priceFeed;
    NeriteReverseLookup public immutable reverseLookup;
    NeriteUSNDOracle public immutable usndOracle;

    // Tokens
    IERC20 public immutable collateralToken;
    IERC20 public immutable boldToken;

    constructor(
        MoneyMarketId _moneyMarketId,
        string memory _moneyMarketName,
        IContango _contango,
        IBorrowerOperations _borrowerOperations,
        ITroveManager _troveManager,
        IActivePool _activePool,
        IPriceFeed _priceFeed,
        NeriteReverseLookup _reverseLookup,
        NeriteUSNDOracle _usndOracle,
        IERC20 _collateralToken,
        IERC20 _boldToken,
        IWETH9 _nativeToken,
        IAggregatorV2V3 _nativeUsdOracle
    ) BaseMoneyMarketView(_moneyMarketId, _moneyMarketName, _contango, _nativeToken, _nativeUsdOracle) {
        borrowerOperations = _borrowerOperations;
        troveManager = _troveManager;
        activePool = _activePool;
        priceFeed = _priceFeed;
        reverseLookup = _reverseLookup;
        usndOracle = _usndOracle;
        collateralToken = _collateralToken;
        boldToken = _boldToken;
    }

    // ====== IMoneyMarketView =======

    function _balances(PositionId positionId, IERC20, IERC20) internal view virtual override returns (Balances memory balances_) {
        uint256 troveId = _getTroveId(positionId);
        if (troveId == 0) return balances_;

        LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);
        balances_.collateral = troveData.entireColl;
        balances_.debt = troveData.entireDebt;
    }

    function _thresholds(PositionId positionId, IERC20, IERC20)
        internal
        view
        virtual
        override
        returns (uint256 ltv, uint256 liquidationThreshold)
    {
        // Simplified thresholds - no batch support for leverage trading
        uint256 mcr = borrowerOperations.MCR();
        liquidationThreshold = mcr;
        ltv = mcr; // LTV is always MCR for new troves
        
        // NOTE: Batch detection removed - this integration focuses on individual troves
        // for leverage trading use case. All positions use standard MCR requirements.
    }

    function _liquidity(PositionId positionId, IERC20 collateralAsset, IERC20)
        internal
        view
        virtual
        override
        returns (uint256 borrowing, uint256 lending)
    {
        if (borrowerOperations.hasBeenShutDown()) return (0, 0);
        
        lending = collateralAsset.totalSupply(); // Essentially unlimited for collateral
        
        uint256 troveId = _getTroveId(positionId);
        if (troveId != 0) {
            LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);
            (uint256 price,) = priceFeed.fetchPrice();
            
            if (price > 0) {
                uint256 collateralValue = troveData.entireColl * price / 1e18;
                uint256 mcr = borrowerOperations.MCR();
                uint256 maxDebt = collateralValue * 1e18 / mcr;
                borrowing = maxDebt > troveData.entireDebt ? maxDebt - troveData.entireDebt : 0;
            }
        }
    }

    function _rates(PositionId positionId, IERC20, IERC20) internal view virtual override returns (uint256 borrowing, uint256 lending) {
        uint256 troveId = _getTroveId(positionId);
        borrowing = troveId != 0 ? troveManager.getTroveAnnualInterestRate(troveId) : 0.05e18;
        lending = 0; // No lending rewards
    }

    function _irmRaw(PositionId positionId, IERC20, IERC20) internal view virtual override returns (bytes memory data) {
        uint256 troveId = _getTroveId(positionId);
        
        if (troveId == 0) {
            return abi.encode(NeriteIrmData({
                troveExists: false,
                troveId: 0,
                annualInterestRate: 0.05e18,
                systemDebt: activePool.getBoldDebt(),
                isShutDown: borrowerOperations.hasBeenShutDown()
            }));
        }

        LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);
        return abi.encode(NeriteIrmData({
            troveExists: true,
            troveId: troveId,
            annualInterestRate: troveData.annualInterestRate,
            systemDebt: activePool.getBoldDebt(),
            isShutDown: borrowerOperations.hasBeenShutDown()
        }));
    }

    function _prices(PositionId positionId, IERC20 collateralAsset, IERC20 debtAsset) 
    internal 
    view 
    virtual 
    override 
    returns (Prices memory prices_) 
{
    require(collateralAsset == collateralToken, "Invalid collateral asset");
    require(debtAsset == boldToken, "Invalid debt asset");
    
    // Get collateral price from Nerite price feed
    (uint256 collateralPrice,) = priceFeed.fetchPrice();
    prices_.collateral = collateralPrice;
    
    // Get USND price from CRE-updated oracle with market-aware fallback
    try usndOracle.getUSNDPrice() returns (uint256 usndPrice) {
        prices_.debt = usndPrice;  // ✅ TRUST CRE CONSENSUS COMPLETELY
    } catch {
        // ✅ Use last known market price (NOT hardcoded $1)
        prices_.debt = usndOracle.getLastGoodPrice();
    }
    
    // CRE script monitors CoinGecko API:
    // - Endpoint: https://api.coingecko.com/api/v3/simple/price?ids=us-nerite-dollar&vs_currencies=usd
    // - API Key: CG-GJSAvLK73Aw2tiawXBrmQKpc
    // - Updates every 15 minutes with real-time market data
    // - NO BOUNDS CHECKING: Reports accurate prices during depegs
    // - Fallback: Last good price (market-aware, never $1 hardcode)
    
    prices_.unit = 1e18;
}

    function _getTroveId(PositionId positionId) internal view returns (uint256 troveId) {
        try reverseLookup.troveId(Payload.wrap(positionId.getPayload())) returns (uint256 id) {
            return id;
        } catch {
            return 0;
        }
    }

    // These functions are not needed since we override _prices() directly
    // Following the pattern used by Comet and Morpho money market implementations
    function _oraclePrice(IERC20 asset) internal view virtual override returns (uint256) { }
    function _oracleUnit() internal view virtual override returns (uint256) { }
    function priceInUSD(IERC20 asset) public view virtual override returns (uint256 price_) { }
    function priceInNativeToken(IERC20 asset) public view virtual override returns (uint256 price_) { }


    // Data structure for IRM raw data
    struct NeriteIrmData {
        bool troveExists;
        uint256 troveId;
        uint256 annualInterestRate;
        uint256 systemDebt;
        bool isShutDown;
    }
}
