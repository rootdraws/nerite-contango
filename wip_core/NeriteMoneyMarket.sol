// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./dependencies/Constants.sol";
import "./dependencies/IActivePool.sol";
import "./dependencies/IBorrowerOperations.sol";
import "./dependencies/ITroveManager.sol";
import "./dependencies/IHintHelpers.sol";
import "./dependencies/ISortedTroves.sol";
import "./dependencies/IBoldToken.sol";
import "./dependencies/IPriceFeed.sol";
import "./dependencies/ICollateralRegistry.sol";
import "./NeriteReverseLookup.sol";
import "./NeriteRateOracle.sol";
import "./dependencies/LatestTroveData.sol";
import "./dependencies/TroveChange.sol";

// Add these imports to satisfy transitive dependencies:
import "./dependencies/ILiquityBase.sol";        // Required by IBorrowerOperations & ITroveManager
import "./dependencies/IAddRemoveManagers.sol";  // Required by IBorrowerOperations
import "./dependencies/IStabilityPool.sol";      // Required by ITroveManager
import "./dependencies/IInterestRouter.sol";     // Required by IActivePool
import "./dependencies/IBoldRewardsReceiver.sol"; // Required by IActivePool
import "./dependencies/IWETH.sol";               // Required by IBorrowerOperations
import "./dependencies/BatchId.sol";             // Required by ISortedTroves
import "./dependencies/ITroveNFT.sol";           // Required by ITroveManager
import "./dependencies/LatestBatchData.sol";     // Required by ITroveManager

import "../BaseMoneyMarket.sol";
import "../../libraries/ERC20Lib.sol";
import "../interfaces/IContango.sol";
import "../libraries/DataTypes.sol";

// CORRECTED: Removed IFlashBorrowProvider - Nerite doesn't support BOLD flash loans
// Nerite's flash loan system is designed for collateral tokens through Balancer, not for BOLD
contract NeriteMoneyMarket is BaseMoneyMarket {
    using SafeERC20 for *;
    using ERC20Lib for *;

    bool public constant override NEEDS_ACCOUNT = true;

    // Nerite Protocol Contracts
    IBorrowerOperations public immutable borrowerOperations;
    IHintHelpers public immutable hintHelpers;
    IBoldToken public immutable boldToken;
    IPriceFeed public immutable priceFeed;
    NeriteReverseLookup public immutable reverseLookup;
    IActivePool public immutable activePool;
    NeriteRateOracle public immutable rateOracle;

    // CollateralRegistry for multi-collateral support
    ICollateralRegistry public immutable collateralRegistry;

    // Collateral and Debt Tokens
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken; // BOLD token

    // User rate preferences for custom frontend
    mapping(PositionId => uint256) public userSelectedRates;
    mapping(PositionId => uint256) public rateSetTimestamp;

    // Rate preference timeout (1 hour)
    uint256 public constant RATE_TIMEOUT = 1 hours;

    // Events
    event TroveOpened(PositionId indexed positionId, uint256 indexed troveId, uint256 interestRate);
    event InterestRateAdjusted(PositionId indexed positionId, uint256 indexed troveId, uint256 newRate);

    // Errors
    error InvalidTroveId();
    error TroveNotActive();
    error SystemShutdown();
    error UnsupportedOperation();
    error InvalidInterestRate();
    error InvalidExpiry();

    constructor(
        MoneyMarketId _moneyMarketId,
        IContango _contango,
        IBorrowerOperations _borrowerOperations,
        IActivePool _activePool,
        IHintHelpers _hintHelpers,
        IPriceFeed _priceFeed,
        NeriteReverseLookup _reverseLookup,
        NeriteRateOracle _rateOracle,
        ICollateralRegistry _collateralRegistry,
        IERC20 _collateralToken,
        IBoldToken _boldToken
    ) BaseMoneyMarket(_moneyMarketId, _contango) {
        borrowerOperations = _borrowerOperations;
        activePool = _activePool;
        hintHelpers = _hintHelpers;
        priceFeed = _priceFeed;
        reverseLookup = _reverseLookup;
        rateOracle = _rateOracle;
        collateralRegistry = _collateralRegistry;
        collateralToken = _collateralToken;
        boldToken = _boldToken;
        debtToken = _boldToken;

        // Set infinite approvals for Nerite protocol
        collateralToken.forceApprove(address(_borrowerOperations), type(uint256).max);
        boldToken.forceApprove(address(_borrowerOperations), type(uint256).max);

        /**
         * ╔══════════════════════════════════════════════════════════════════════════════════╗
         * ║                        DEPLOYMENT AND REGISTRATION REQUIREMENTS                     ║
         * ╚══════════════════════════════════════════════════════════════════════════════════╝
         * 
         * This contract requires several post-deployment registration steps to integrate
         * with the Contango ecosystem. Execute in this EXACT ORDER:
         * 
         * 1. DEPLOY CONTRACTS (in dependency order):
         *    ┌─ Deploy NeriteReverseLookup first (has no dependencies)
         *    ├─ Deploy NeriteMoneyMarket (this contract)
         *    └─ Deploy NeriteMoneyMarketView (requires this contract address)
         * 
         * 2. GRANT OPERATOR ROLE (as timelock/admin):
         *    reverseLookup.grantRole(OPERATOR_ROLE, address(neriteMoneyMarket));
         *    
         *    ⚠️  CRITICAL: This allows the money market to call reverseLookup.setTrove()
         *        when opening new troves. Without this, position creation WILL FAIL.
         * 
         * 3. REGISTER WITH POSITION FACTORY (as operator):
         *    positionFactory.registerMoneyMarket(neriteMoneyMarket);
         *    
         *    ⚠️  CRITICAL: This enables Contango to route position operations to this 
         *        money market. Without this, positions CANNOT BE CREATED.
         * 
         * 4. REGISTER VIEW WITH CONTANGO LENS (as operator):
         *    contangoLens.setMoneyMarketView(neriteMoneyMarketView);
         *    
         *    ⚠️  IMPORTANT: This enables the front-end and external integrations to 
         *        query position data through the unified Lens interface.
         * 
         * 5. VERIFY INTEGRATION:
         *    ├─ Test position creation through Contango interface
         *    ├─ Verify ContangoLens returns correct position data
         *    ├─ Confirm trove operations work (lend, borrow, repay, withdraw)
         *    └─ Test external flash loan providers work with positions
         * 
         * ╔══════════════════════════════════════════════════════════════════════════════════╗
         * ║                            FLASH LOAN INTEGRATION                                ║
         * ╚══════════════════════════════════════════════════════════════════════════════════╝
         * 
         * IMPORTANT: This contract does NOT implement IFlashBorrowProvider because:
         * 
         * 1. Nerite's flash loan system is designed for collateral tokens (WETH, etc.)
         * 2. BOLD flash loans would require borrowing from position troves
         * 3. This would conflict with position debt accounting and risk liquidation
         * 4. Contango will automatically use external flash loan providers instead
         * 
         * External flash loan providers supported by Contango:
         * - Balancer Vault
         * - Aave (external)
         * - 1inch
         * - Any ERC-7399 compatible provider
         * 
         * This approach matches Comet, Euler, and Morpho integrations.
         */
    }

    // ====== IMoneyMarket =======

    function _initialise(PositionId positionId, IERC20 collateralAsset, IERC20 debtAsset) internal override {
        require(positionId.isPerp(), InvalidExpiry());
        require(collateralAsset == collateralToken, "Invalid collateral asset");
        require(debtAsset == debtToken, "Invalid debt asset");

        // Check system is not shut down
        if (borrowerOperations.hasBeenShutDown()) {
            revert SystemShutdown();
        }

        // For Nerite, we don't open the trove here - it's opened during the first lend operation
        // This is because Nerite requires both collateral and debt amounts at trove opening
    }

    function _collateralBalance(PositionId positionId, IERC20 asset) internal override returns (uint256 balance) {
        require(asset == collateralToken, "Invalid asset");
        
        uint256 troveId = _getTroveId(positionId);
        if (troveId == 0) return 0;

        ITroveManager tm = _getTroveManager(asset);
        LatestTroveData memory troveData = tm.getLatestTroveData(troveId);
        return troveData.entireColl;
    }

    function _debtBalance(PositionId positionId, IERC20 asset) internal override returns (uint256 balance) {
        require(asset == debtToken, "Invalid asset");
        
        uint256 troveId = _getTroveId(positionId);
        if (troveId == 0) return 0;

        ITroveManager tm = _getTroveManager(collateralToken);
        LatestTroveData memory troveData = tm.getLatestTroveData(troveId);
        return troveData.entireDebt;
    }

    function _lend(PositionId positionId, IERC20 asset, uint256 amount, address payer, uint256)
        internal
        override
        returns (uint256 actualAmount)
    {
        require(asset == collateralToken, "Invalid asset");
        if (borrowerOperations.hasBeenShutDown()) {
            revert SystemShutdown();
        }

        actualAmount = asset.transferOut(payer, address(this), amount);
        
        uint256 troveId = _getTroveId(positionId);
        
        if (troveId == 0) {
            // Open new trove with collateral and minimal debt
            troveId = _openTrove(positionId, actualAmount);
        } else {
            // Add collateral to existing trove
            _requireTroveIsActive(troveId);
            borrowerOperations.addColl(troveId, actualAmount);
        }
        return actualAmount;
    }

    function _borrow(PositionId positionId, IERC20 asset, uint256 amount, address to, uint256)
        internal
        override
        returns (uint256 actualAmount)
    {
        require(asset == debtToken, "Invalid asset");
        if (borrowerOperations.hasBeenShutDown()) {
            revert SystemShutdown();
        }

        uint256 troveId = _getTroveId(positionId);
        _requireTroveExists(troveId);
        _requireTroveIsActive(troveId);
        
        // Validate collateral ratio before borrowing
        _validateCollateralRatio(troveId);

        // Estimate upfront fee
        uint256 maxUpfrontFee = _estimateUpfrontFee(troveId, amount);
        
        borrowerOperations.withdrawBold(troveId, amount, maxUpfrontFee);
        actualAmount = asset.transferOut(address(this), to, amount);
    }

    function _repay(PositionId positionId, IERC20 asset, uint256 amount, address payer, uint256 debt)
        internal
        override
        returns (uint256 actualAmount)
    {
        require(asset == debtToken, "Invalid asset");
        
        uint256 troveId = _getTroveId(positionId);
        _requireTroveExists(troveId);
        _requireTroveIsActive(troveId);

        actualAmount = Math.min(amount, debt);
        if (actualAmount > 0) {
            asset.transferOut(payer, address(this), actualAmount);
            borrowerOperations.repayBold(troveId, actualAmount);
        }
    }

    function _withdraw(PositionId positionId, IERC20 asset, uint256 amount, address to, uint256)
        internal
        override
        returns (uint256 actualAmount)
    {
        require(asset == collateralToken, "Invalid asset");
        
        uint256 troveId = _getTroveId(positionId);
        _requireTroveExists(troveId);
        _requireTroveIsActive(troveId);
        
        // Validate collateral ratio before withdrawal
        _validateCollateralRatio(troveId);

        borrowerOperations.withdrawColl(troveId, amount);
        actualAmount = asset.transferOut(address(this), to, amount);
    }

    function _claimRewards(PositionId, IERC20, IERC20, address) internal override {}
    // Nerite rewards are gained from the stability pool, not through borrowing.
    // This function is included, because it is expected from BaseMoneyMarket.

    // ===== CollateralRegistry Integration =====

    /**
     * @notice Gets collateral index for a given collateral asset
     * @param _collateralAsset The collateral token address
     * @return collIndex The index of the collateral (0=ETH, 1=wstETH, ..., 7=tBTC)
     */
    function _getCollateralIndex(IERC20 _collateralAsset) internal view returns (uint256 collIndex) {
        for (uint256 i = 0; i < collateralRegistry.totalCollaterals(); i++) {
            if (collateralRegistry.getToken(i) == _collateralAsset) {
                return i;
            }
        }
        revert("Unsupported collateral");
    }

    /**
     * @notice Gets the TroveManager for a specific collateral
     * @param _collateralAsset The collateral token address
     * @return troveManager The TroveManager instance for this collateral
     */
    function _getTroveManager(IERC20 _collateralAsset) internal view returns (ITroveManager troveManager) {
        uint256 collIndex = _getCollateralIndex(_collateralAsset);
        return collateralRegistry.getTroveManager(collIndex);
    }

    /**
     * @notice Gets the SortedTroves for a specific collateral
     * @param _collateralAsset The collateral token address
     * @return sortedTroves The SortedTroves instance for this collateral
     */
    function _getSortedTroves(IERC20 _collateralAsset) internal view returns (ISortedTroves sortedTroves) {
        return _getTroveManager(_collateralAsset).sortedTroves();
    }

    // ===== Interest Rate Management =====

    /**
     * @notice Sets interest rate preference for a position (custom frontend)
     * @param _positionId The position ID
     * @param _interestRate User's chosen interest rate in 18 decimals
     */
    function setPositionInterestRate(PositionId _positionId, uint256 _interestRate) external onlyContango {
        require(
            _interestRate >= MIN_ANNUAL_INTEREST_RATE && 
            _interestRate <= MAX_ANNUAL_INTEREST_RATE,
            "Invalid interest rate"
        );
        
        userSelectedRates[_positionId] = _interestRate;
        rateSetTimestamp[_positionId] = block.timestamp;
        
        emit InterestRateAdjusted(_positionId, 0, _interestRate); // troveId = 0 since not created yet
    }

    /**
     * @notice Enhanced lend function with user-specified interest rate (custom frontend)
     * @param _positionId Position ID
     * @param _asset Collateral asset
     * @param _amount Amount to lend
     * @param _interestRate User's chosen interest rate
     * @return actualAmount Actual amount lent
     */
    function setRateAndLend(
        PositionId _positionId,
        IERC20 _asset,
        uint256 _amount,
        uint256 _interestRate
    ) external onlyContango returns (uint256 actualAmount) {
        require(
            _interestRate >= MIN_ANNUAL_INTEREST_RATE && 
            _interestRate <= MAX_ANNUAL_INTEREST_RATE,
            "Invalid interest rate"
        );
        
        return _lendWithRate(_positionId, _asset, _amount, _interestRate);
    }

    /**
     * @notice Gets optimal interest rate for a collateral (with backup)
     * @param _collateralAsset The collateral token
     * @return optimalRate Optimal rate from oracle or system average fallback
     */
    function _getOptimalInterestRate(IERC20 _collateralAsset) internal view returns (uint256 optimalRate) {
        uint256 collIndex = _getCollateralIndex(_collateralAsset);
        
        // Try to get optimal rate from CRE oracle
        try rateOracle.getOptimalRate(collIndex) returns (uint256 oracleRate) {
            // Sanity check: Rate should be reasonable
            if (oracleRate >= MIN_ANNUAL_INTEREST_RATE && oracleRate <= 0.1e18) { // Max 10%
                return oracleRate;
            }
        } catch {
            // Oracle failed, use fallback
        }
        
        // FALLBACK: Use system average + safety buffer
        uint256 systemRate = rateOracle.getSystemAverageRate();
        return systemRate + 0.005e18; // +0.5% safety buffer
        
        // TODO: Remove fallback when CRE oracle is proven reliable on mainnet
    }

    // ===== Helper Functions =====

    function _openTrove(PositionId positionId, uint256 collAmount) internal returns (uint256 troveId) {
        return _openTroveWithRate(positionId, collAmount, _getOptimalInterestRate(collateralToken));
    }

    function _openTroveWithRate(PositionId positionId, uint256 collAmount, uint256 interestRate) internal returns (uint256 troveId) {
        // Calculate minimal debt for trove opening
        uint256 minDebtAmount = MIN_DEBT;
        uint256 collIndex = _getCollateralIndex(collateralToken);

        // Get hints for sorted insertion
        (uint256 upperHint, uint256 lowerHint) = _getHints(collateralToken, interestRate);
        
        // Estimate upfront fee with correct collateral index
        uint256 maxUpfrontFee = hintHelpers.predictOpenTroveUpfrontFee(
            collIndex,
            minDebtAmount,
            interestRate
        );

        // Open trove
        troveId = borrowerOperations.openTrove(
            address(this), // owner
            uint256(uint160(address(this))), // owner index (using contract address)
            collAmount,
            minDebtAmount,
            upperHint,
            lowerHint,
            interestRate,
            maxUpfrontFee,
            address(0), // no add manager
            address(0), // no remove manager  
            address(this) // receiver
        );

        // Map trove to position
        Payload payload = reverseLookup.setTrove(troveId);
        require(Payload.unwrap(payload) == positionId.getPayload(), "Payload mismatch");

        emit TroveOpened(positionId, troveId, interestRate);
    }

    function _lendWithRate(
        PositionId positionId,
        IERC20 asset,
        uint256 amount,
        uint256 interestRate
    ) internal returns (uint256 actualAmount) {
        require(asset == collateralToken, "Invalid asset");
        if (borrowerOperations.hasBeenShutDown()) {
            revert SystemShutdown();
        }

        actualAmount = asset.transferOut(msg.sender, address(this), amount);
        
        uint256 troveId = _getTroveId(positionId);
        
        if (troveId == 0) {
            // Open new trove with user-specified rate
            troveId = _openTroveWithRate(positionId, actualAmount, interestRate);
        } else {
            // Add collateral to existing trove
            ITroveManager tm = _getTroveManager(asset);
            _requireTroveIsActive(tm, troveId);
            borrowerOperations.addColl(troveId, actualAmount);
        }
        return actualAmount;
    }

    function _getTroveId(PositionId positionId) internal view returns (uint256 troveId) {
        try reverseLookup.troveId(Payload.wrap(positionId.getPayload())) returns (uint256 id) {
            return id;
        } catch {
            return 0; // Trove not found
        }
    }

    function _getHints(IERC20 _collateralAsset, uint256 interestRate) internal view returns (uint256 upperHint, uint256 lowerHint) {
        uint256 collIndex = _getCollateralIndex(_collateralAsset);
        ISortedTroves sortedTroves = _getSortedTroves(_collateralAsset);
        
        // Use hint helpers to find optimal position
        (uint256 hintId,,) = hintHelpers.getApproxHint(
            collIndex,
            interestRate,
            15, // numTrials
            block.timestamp // random seed
        );
        
        (upperHint, lowerHint) = sortedTroves.findInsertPosition(
            interestRate,
            hintId,
            hintId
        );
    }

    function _estimateUpfrontFee(uint256 troveId, uint256 debtIncrease) internal view returns (uint256) {
        if (debtIncrease == 0) return 0;
        
        uint256 collIndex = _getCollateralIndex(collateralToken);
        return hintHelpers.predictAdjustTroveUpfrontFee(
            collIndex,
            troveId,
            debtIncrease
        );
    }

    function _requireTroveExists(uint256 troveId) internal pure {
        require(troveId != 0, InvalidTroveId());
    }

    function _requireTroveIsActive(ITroveManager tm, uint256 troveId) internal view {
        ITroveManager.Status status = tm.getTroveStatus(troveId);
        require(status == ITroveManager.Status.active, TroveNotActive());
    }

    function _requireTroveIsActive(uint256 troveId) internal view {
        ITroveManager tm = _getTroveManager(collateralToken);
        _requireTroveIsActive(tm, troveId);
    }

    // ===== Interface Support =====

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IMoneyMarket).interfaceId;
        // REMOVED: IFlashBorrowProvider interface support
        // Contango will use external flash loan providers instead
    }

    // ===== Simplified Collateral Ratio Validation (No Batch Support) =====

    function _validateCollateralRatio(uint256 troveId) internal view {
        // Get current price from price feed
        (uint256 price,) = priceFeed.fetchPrice();
        require(price > 0, "Invalid price");
        
        // Use Nerite's native ICR calculation
        ITroveManager tm = _getTroveManager(collateralToken);
        uint256 icr = tm.getCurrentICR(troveId, price);
        
        // Use MCR from protocol (no batch support - individual troves only)
        uint256 mcr = borrowerOperations.MCR();
        require(icr >= mcr, "Below minimum collateral ratio");
        
        // NOTE: Batch detection removed - this integration focuses on individual troves
        // for leverage trading use case. Batches are for passive borrowers seeking
        // professional management, which conflicts with user rate control.
    }
}
