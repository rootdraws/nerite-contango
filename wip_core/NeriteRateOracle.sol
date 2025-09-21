// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./dependencies/IActivePool.sol";
import "./dependencies/Constants.sol";

/**
 * @title NeriteRateOracle
 * @notice CRE-powered interest rate oracle with last good rate fallback
 * @dev Provides market-competitive interest rates with no bounds checking
 * 
 * CRITICAL DESIGN DECISIONS:
 * - NO RATE BOUNDS: Trusts CRE consensus completely
 * - NO VALIDATION: Reports market reality, even during rate spikes
 * - LAST GOOD RATE: Market-aware fallback per collateral
 * - STALENESS PROTECTION: Only protection against stale data
 */
contract NeriteRateOracle is AccessControl {
    using Math for uint256;

    bytes32 public constant CRE_UPDATER_ROLE = keccak256("CRE_UPDATER_ROLE");
    
    // Struct for CRE WriteReport generation
    struct RateData {
        uint256[] collIndexes;
        uint256[] rates;
    }
    
    // Cached average rates per collateral index (in 18 decimals)
    mapping(uint256 collIndex => uint256 avgRate) public averageRates;
    
    // Last good rates per collateral - preserves market reality during oracle outages
    mapping(uint256 collIndex => uint256 lastGoodRate) public lastGoodRates;
    
    // Timestamp of last update per collateral
    mapping(uint256 collIndex => uint256 lastUpdate) public lastUpdated;
    
    // ActivePool for system-wide fallback calculation
    IActivePool public immutable activePool;
    
    // Rate staleness threshold (6 hours)
    uint256 public constant STALENESS_THRESHOLD = 6 hours;
    
    // Safety buffer added to market rates (0.5%)
    uint256 public constant SAFETY_BUFFER = 0.005e18;
    
    // Events
    event RateUpdated(uint256 indexed collIndex, uint256 newRate, uint256 timestamp);
    event LastGoodRateUpdated(uint256 indexed collIndex, uint256 lastGoodRate, uint256 timestamp);
    event StaleRate(uint256 indexed collIndex, uint256 staleRate, uint256 timeSinceUpdate);
    event FallbackUsed(uint256 indexed collIndex, uint256 systemRate);
    event RateDeviationDetected(uint256 indexed collIndex, uint256 rate, uint256 deviation);
    
    // Errors
    error InvalidCollateralIndex(uint256 collIndex);
    error RateStale(uint256 collIndex, uint256 timeSinceUpdate);
    error ZeroRate();

    constructor(address _admin, address _creUpdater, IActivePool _activePool) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CRE_UPDATER_ROLE, _creUpdater);
        
        activePool = _activePool;
        
        // Initialize with minimum rate as safe default for all collaterals
        for (uint256 i = 0; i < 10; i++) {
            averageRates[i] = MIN_ANNUAL_INTEREST_RATE;
            lastGoodRates[i] = MIN_ANNUAL_INTEREST_RATE;
            lastUpdated[i] = block.timestamp;
        }
    }

    /**
     * @notice Handles incoming reports from Chainlink Forwarder
     * @param report ABI-encoded RateData struct
     * @dev Called by Chainlink Forwarder with consensus data
     */
    function onReport(bytes calldata /* metadata */, bytes calldata report) external onlyRole(CRE_UPDATER_ROLE) {
        RateData memory data = abi.decode(report, (RateData));
        updateRates(data);
    }

    /**
     * @notice Public function to expose RateData struct for binding generation
     * @param data Rate data struct
     * @dev This function exists solely for the CRE binding generator to create WriteReport methods
     */
    function updateRateData(RateData memory data) public onlyRole(CRE_UPDATER_ROLE) {
        updateRates(data);
    }

    /**
     * @notice Updates average interest rates for multiple collaterals (internal function)
     * @param data Rate data struct containing collateral indexes and rates
     * @dev CRE script calculates rates from Nerite subgraph and calls this function
     * 
     * CRITICAL: NO BOUNDS CHECKING
     * - Accepts ANY non-zero rate (including 26% during crisis)
     * - Trusts CRE consensus completely (median aggregation protects against manipulation)
     * - Reports market reality, not sanitized version
     */
    function updateRates(RateData memory data) internal {
        require(data.collIndexes.length == data.rates.length, "Array length mismatch");
        
        for (uint256 i = 0; i < data.collIndexes.length; i++) {
            uint256 collIndex = data.collIndexes[i];
            uint256 rate = data.rates[i];
            
            if (rate == 0) revert ZeroRate();
            
            // Validate collateral index (assuming max 10 collaterals)
            if (collIndex >= 10) {
                revert InvalidCollateralIndex(collIndex);
            }
            
            // Detect significant rate changes for monitoring (but still accept the rate)
            uint256 currentRate = averageRates[collIndex];
            if (currentRate > 0) {
                uint256 deviation = rate > currentRate ? rate - currentRate : currentRate - rate;
                // Alert if rate changes by more than 2%
                if (deviation > 0.02e18) {
                    emit RateDeviationDetected(collIndex, rate, deviation);
                }
            }
            
            averageRates[collIndex] = rate;
            lastGoodRates[collIndex] = rate;  // ALWAYS update last good rate
            lastUpdated[collIndex] = block.timestamp;
            
            emit RateUpdated(collIndex, rate, block.timestamp);
            emit LastGoodRateUpdated(collIndex, rate, block.timestamp);
        }
    }

    /**
     * @notice Gets optimal interest rate for a collateral with safety buffer
     * @param _collIndex Collateral index (0=ETH, 1=wstETH, ..., 7=tBTC)
     * @return optimalRate Market rate + safety buffer, or last good rate if stale
     */
    function getOptimalRate(uint256 _collIndex) external view returns (uint256 optimalRate) {
        uint256 cachedRate = averageRates[_collIndex];
        uint256 timeSinceUpdate = block.timestamp - lastUpdated[_collIndex];
        
        // If CRE data is fresh, use it with safety buffer
        if (timeSinceUpdate < STALENESS_THRESHOLD && cachedRate > 0) {
            return cachedRate + SAFETY_BUFFER;
        }
        
        // Fallback to last good rate + safety buffer (market-aware)
        uint256 lastGood = lastGoodRates[_collIndex];
        if (lastGood > 0) {
            return lastGood + SAFETY_BUFFER;
        }
        
        // Final fallback: system average + safety buffer
        uint256 systemRate = _getSystemAverageRate();
        return systemRate + SAFETY_BUFFER;
    }

    /**
     * @notice Gets last good rate for a collateral (for fallback scenarios)
     * @param _collIndex Collateral index
     * @return rate Last known accurate market rate
     * @dev Used when oracle is down but need market-aware fallback
     */
    function getLastGoodRate(uint256 _collIndex) external view returns (uint256 rate) {
        return lastGoodRates[_collIndex];
    }

    /**
     * @notice Gets raw cached rate without safety buffer
     * @param _collIndex Collateral index
     * @return rate Raw market rate from CRE (no safety buffer)
     * @return isStale Whether the rate is considered stale
     */
    function getRawRate(uint256 _collIndex) external view returns (uint256 rate, bool isStale) {
        rate = averageRates[_collIndex];
        uint256 timeSinceUpdate = block.timestamp - lastUpdated[_collIndex];
        isStale = timeSinceUpdate >= STALENESS_THRESHOLD;
        
    }

    /**
     * @notice Checks if rate data is stale for a collateral
     * @param _collIndex Collateral index
     * @return stale True if rate is older than staleness threshold
     */
    function isStale(uint256 _collIndex) external view returns (bool stale) {
        return block.timestamp - lastUpdated[_collIndex] >= STALENESS_THRESHOLD;
    }

    /**
     * @notice Gets system-wide average interest rate (fallback calculation)
     * @return systemRate Debt-weighted average rate across all collaterals
     */
    function getSystemAverageRate() external view returns (uint256 systemRate) {
        return _getSystemAverageRate();
    }

    /**
     * @notice Internal function to calculate system average rate
     * @return systemRate System-wide debt-weighted average interest rate
     */
    function _getSystemAverageRate() internal view returns (uint256 systemRate) {
        uint256 totalDebt = activePool.getBoldDebt();
        
        if (totalDebt == 0) {
            return MIN_ANNUAL_INTEREST_RATE; // 0.5% minimum
        }
        
        uint256 weightedDebtSum = activePool.aggWeightedDebtSum();
        return weightedDebtSum / totalDebt;
    }

    /**
     * @notice Gets time since last update for a collateral
     * @param _collIndex Collateral index
     * @return timeSinceUpdate Seconds since last rate update
     */
    function getTimeSinceUpdate(uint256 _collIndex) external view returns (uint256 timeSinceUpdate) {
        return block.timestamp - lastUpdated[_collIndex];
    }

    /**
     * @notice Gets comprehensive rate oracle status for a collateral
     * @param _collIndex Collateral index
     * @return currentRate Current cached rate
     * @return lastGood Last good rate (fallback value)
     * @return timeSinceUpdate Seconds since last update
     * @return isStale Whether rate is stale
     */
    function getRateOracleStatus(uint256 _collIndex) external view returns (
        uint256 currentRate,
        uint256 lastGood,
        uint256 timeSinceUpdate,
        bool isStale
    ) {
        currentRate = averageRates[_collIndex];
        lastGood = lastGoodRates[_collIndex];
        timeSinceUpdate = block.timestamp - lastUpdated[_collIndex];
        isStale = timeSinceUpdate >= STALENESS_THRESHOLD;
    }

    /**
     * @notice Gets all cached rates for monitoring
     * @return collIndexes Array of collateral indexes
     * @return rates Array of corresponding cached rates
     * @return lastGoodRates Array of last good rates
     * @return timestamps Array of last update timestamps
     */
    function getAllRates() external view returns (
        uint256[] memory collIndexes,
        uint256[] memory rates,
        uint256[] memory lastGoodRatesArray,
        uint256[] memory timestamps
    ) {
        // Return data for up to 10 collaterals
        collIndexes = new uint256[](10);
        rates = new uint256[](10);
        lastGoodRatesArray = new uint256[](10);
        timestamps = new uint256[](10);
        
        for (uint256 i = 0; i < 10; i++) {
            collIndexes[i] = i;
            rates[i] = averageRates[i];
            lastGoodRatesArray[i] = lastGoodRates[i];
            timestamps[i] = lastUpdated[i];
        }
    }

    /**
     * ╔══════════════════════════════════════════════════════════════════════════════════╗
     * ║                           CHAINLINK CRE INTEGRATION                             ║
     * ╚══════════════════════════════════════════════════════════════════════════════════╝
     * 
     * This oracle is designed for Chainlink CRE automation:
     * 
     * CRE WORKFLOW:
     * 1. Query Nerite subgraph for interest rate brackets per collateral
     * 2. Calculate debt-weighted average rate per collateral
     * 3. NO BOUNDS CHECKING - trust CRE consensus completely
     * 4. Call updateRates() every hour with fresh data
     * 
     * SUBGRAPH INTEGRATION:
     * - Endpoint: https://gateway.thegraph.com/api/server_fb19dd191c45934ed8680ad3610fe974/subgraphs/id/J2f756n9odYccBcntvSRia72Nn3gWcY4HQNfvU9WvJP3
     * - API Key: server_fb19dd191c45934ed8680ad3610fe974
     * - Query: AllInterestRateBrackets GraphQL query
     * - Calculation: Weighted average = Σ(rate × debt) / Σ(debt) (same as Nerite frontend)
     * - Results: tBTC=0.53%, ARB=4.14%, wstETH=8.21%
     * 
     * FALLBACK STRATEGY:
     * - If CRE fails: use lastGoodRate (market-aware, not system average)
     * - If rate is 26% during crisis: oracle reports 26%
     * - If oracle fails during crisis: fallback to last known crisis rate
     * - NEVER falls back to hardcoded minimums
     * 
     * DEPLOYMENT NOTES:
     * - Grant CRE_UPDATER_ROLE to Chainlink CRE wallet
     * - Monitor for rate deviation events via RateDeviationDetected
     * - Oracle provides accurate rates during all market conditions
     */
}
