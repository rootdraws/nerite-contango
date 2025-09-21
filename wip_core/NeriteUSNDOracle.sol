// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title NeriteUSNDOracle
 * @notice CRE-powered oracle for USND/USD pricing with last good price fallback
 * @dev Implements IReceiverTemplate pattern for Chainlink CRE integration
 * 
 * CRITICAL DESIGN DECISIONS:
 * - NO PRICE BOUNDS: Trusts CRE consensus completely
 * - NO SANITY CHECKS: Reports market reality, even during volatility
 * - LAST GOOD PRICE: Market-aware fallback, never hardcoded values
 * - STALENESS PROTECTION: Only protection against stale data
 */
contract NeriteUSNDOracle is AccessControl {
    using Math for uint256;

    bytes32 public constant CRE_UPDATER_ROLE = keccak256("CRE_UPDATER_ROLE");
    
    // Struct for CRE WriteReport generation
    struct PriceData {
        uint256 price;
    }
    
    // Current USND price in 18 decimals (e.g., 0.94e18 = $0.94 during depeg)
    uint256 public usndPrice;
    
    // Last good price - preserves market reality during oracle outages
    uint256 public lastGoodPrice;
    
    // Timestamp of last price update
    uint256 public lastUpdated;
    
    // Price staleness threshold (6 hours)
    uint256 public constant STALENESS_THRESHOLD = 6 hours;
    
    // Events
    event PriceUpdated(uint256 indexed newPrice, uint256 timestamp);
    event LastGoodPriceUpdated(uint256 indexed lastGoodPrice, uint256 timestamp);
    event StalePrice(uint256 stalePrice, uint256 timeSinceUpdate);
    event DepegDetected(uint256 price, uint256 deviation);
    
    // Errors
    error PriceStale(uint256 timeSinceUpdate, uint256 threshold);
    error ZeroPrice();

    constructor(address _admin, address _creUpdater) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CRE_UPDATER_ROLE, _creUpdater);
        
        // Initialize with $1 as safe default (only at deployment)
        usndPrice = 1e18;
        lastGoodPrice = 1e18;
        lastUpdated = block.timestamp;
        
        emit PriceUpdated(1e18, block.timestamp);
        emit LastGoodPriceUpdated(1e18, block.timestamp);
    }

    /**
     * @notice Handles incoming reports from Chainlink Forwarder
     * @param report ABI-encoded PriceData struct
     * @dev Called by Chainlink Forwarder with consensus data
     */
    function onReport(bytes calldata /* metadata */, bytes calldata report) external onlyRole(CRE_UPDATER_ROLE) {
        PriceData memory data = abi.decode(report, (PriceData));
        updateUSNDPrice(data);
    }

    /**
     * @notice Public function to expose PriceData struct for binding generation
     * @param data Price data struct
     * @dev This function exists solely for the CRE binding generator to create WriteReport methods
     */
    function updateUSNDPriceData(PriceData memory data) public onlyRole(CRE_UPDATER_ROLE) {
        updateUSNDPrice(data);
    }

    /**
     * @notice Updates USND price (internal function)
     * @param data Price data struct containing new USND price
     * @dev Called by onReport after decoding the report
     * 
     * CRITICAL: NO BOUNDS CHECKING
     * - Accepts ANY non-zero price (including depegs to $0.85, $0.70, etc.)
     * - Trusts CRE consensus completely (median aggregation protects against manipulation)
     * - Reports market reality, not sanitized version
     */
    function updateUSNDPrice(PriceData memory data) internal {
        if (data.price == 0) revert ZeroPrice();
        
        // Detect significant depegs for monitoring (but still accept the price)
        if (data.price < 0.98e18 || data.price > 1.02e18) {
            uint256 deviation = data.price > 1e18 ? data.price - 1e18 : 1e18 - data.price;
            emit DepegDetected(data.price, deviation);
        }
        
        usndPrice = data.price;
        lastGoodPrice = data.price;  // ALWAYS update last good price
        lastUpdated = block.timestamp;
        
        emit PriceUpdated(data.price, block.timestamp);
        emit LastGoodPriceUpdated(data.price, block.timestamp);
    }

    /**
     * @notice Gets current USND price with staleness check
     * @return price Current USND price in 18 decimals
     * @dev Returns current price if fresh, reverts if stale
     */
    function getUSNDPrice() external view returns (uint256 price) {
        uint256 timeSinceUpdate = block.timestamp - lastUpdated;
        
        if (timeSinceUpdate >= STALENESS_THRESHOLD) {
            revert PriceStale(timeSinceUpdate, STALENESS_THRESHOLD);
        }
        
        return usndPrice;
    }

    /**
     * @notice Gets last good price (for fallback scenarios)
     * @return price Last known accurate market price
     * @dev Used when oracle is down but need market-aware fallback
     */
    function getLastGoodPrice() external view returns (uint256 price) {
        return lastGoodPrice;
    }

    /**
     * @notice Gets USND price with staleness information
     * @return price Current USND price in 18 decimals
     * @return isStale Whether the price is considered stale
     */
    function getUSNDPriceWithStaleness() external view returns (uint256 price, bool isStale) {
        uint256 timeSinceUpdate = block.timestamp - lastUpdated;
        price = usndPrice;
        isStale = timeSinceUpdate >= STALENESS_THRESHOLD;
    }

    /**
     * @notice Checks if current price is stale
     * @return stale True if price is older than staleness threshold
     */
    function isStale() external view returns (bool stale) {
        return block.timestamp - lastUpdated >= STALENESS_THRESHOLD;
    }

    /**
     * @notice Gets time since last update
     * @return timeSinceUpdate Seconds since last price update
     */
    function getTimeSinceUpdate() external view returns (uint256 timeSinceUpdate) {
        return block.timestamp - lastUpdated;
    }

    /**
     * @notice Gets comprehensive oracle status
     * @return currentPrice Current USND price
     * @return lastGood Last good price (fallback value)
     * @return timeSinceUpdate Seconds since last update
     * @return isStale Whether price is stale
     */
    function getOracleStatus() external view returns (
        uint256 currentPrice,
        uint256 lastGood,
        uint256 timeSinceUpdate,
        bool isStale
    ) {
        currentPrice = usndPrice;
        lastGood = lastGoodPrice;
        timeSinceUpdate = block.timestamp - lastUpdated;
        isStale = timeSinceUpdate >= STALENESS_THRESHOLD;
    }

    /**
     * ╔══════════════════════════════════════════════════════════════════════════════════╗
     * ║                           CHAINLINK CRE INTEGRATION                             ║
     * ╚══════════════════════════════════════════════════════════════════════════════════╝
     * 
     * This oracle is designed for Chainlink CRE automation:
     * 
     * CRE WORKFLOW:
     * 1. Fetch USND price from CoinGecko API every 15 minutes
     * 2. Use median consensus aggregation across multiple nodes
     * 3. Call updateUSNDPrice() with consensus result
     * 4. NO BOUNDS CHECKING - trust CRE consensus completely
     * 
     * API INTEGRATION:
     * - Endpoint: https://api.coingecko.com/api/v3/simple/price?ids=us-nerite-dollar&vs_currencies=usd
     * - API Key: CG-GJSAvLK73Aw2tiawXBrmQKpc (Analyst plan)
     * - Rate limit: 500 requests/minute (sufficient for CRE nodes)
     * - Data freshness: 20 seconds (excellent for real-time pricing)
     * 
     * FALLBACK STRATEGY:
     * - If CRE fails: use lastGoodPrice (market-aware, not $1 hardcode)
     * - If price is $0.85 during depeg: oracle reports $0.85
     * - If oracle fails during depeg: fallback to last known depeg price
     * - NEVER falls back to hardcoded $1 (prevents enemy advantage)
     * 
     * DEPLOYMENT NOTES:
     * - Grant CRE_UPDATER_ROLE to Chainlink CRE wallet
     * - Monitor for depeg events via DepegDetected emissions
     * - Oracle provides accurate pricing during all market conditions
     */
}
