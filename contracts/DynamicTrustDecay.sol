// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title DynamicTrustDecay
 * @dev Implements the Dynamic Trust Decay AEWMA (Adaptive Exponentially Weighted Moving Average)
 * mechanism for blockchain oracles. This contract manages oracle registration, report submission,
 * trust computation, and slashing based on adaptive trust scores.
 *
 * Key features:
 * - Oracle registration with staking
 * - Per-round report submission
 * - On-chain AEWMA edge weight computation
 * - Adaptive alpha calculation based on volatility
 * - Trust score computation using exponential decay
 * - Slashing mechanism for low-trust nodes
 * - MIS extraction for high-quality data sources
 */
contract DynamicTrustDecay is Ownable, ReentrancyGuard, Pausable {
    /// @dev Fixed-point precision factor (18 decimals)
    uint256 private constant PRECISION = 1e18;

    /// @dev Maximum value for fixed-point math (prevent overflow)
    uint256 private constant MAX_VALUE = type(uint256).max / PRECISION;

    /// @notice Current round number
    uint256 public currentRound;

    /// @notice Total number of registered oracles
    uint256 public oracleCount;

    /// @notice Base alpha parameter for adaptive weighting
    uint256 public alphaBase = 0.1e18; // 0.1 with 18 decimals

    /// @notice Beta parameter for volatility adjustment
    uint256 public beta = 0.5e18; // 0.5 with 18 decimals

    /// @notice Trust threshold for slashing eligibility
    uint256 public tau = 0.5e18; // 0.5 with 18 decimals

    /// @notice Lambda parameter for slashing penalty calculation
    uint256 public lambda = 1e18; // 1.0 with 18 decimals

    /// @notice Scale parameter for trust score exponential calculation
    uint256 public scale = 2e18; // 2.0 with 18 decimals

    /// @notice Weight threshold for MIS extraction
    uint256 public misWeightThreshold = 2e18; // 2.0 with 18 decimals

    /// @notice Minimum stake required for oracle registration
    uint256 public minimumStake = 1 ether;

    /// @notice Oracle information structure
    struct Oracle {
        address addr;
        uint256 stake;
        uint256 totalStake;
        bool active;
        uint256 lastReportRound;
    }

    /// @notice Report data for a specific round
    struct Report {
        uint256 reportValue; // Fixed-point value with PRECISION
        uint256 timestamp;
        bool submitted;
    }

    /// @notice Edge weight tracking for AEWMA
    struct EdgeWeight {
        uint256 weight; // Fixed-point weight with PRECISION
        uint256 lastUpdated;
    }

    /// @dev Mapping from oracle ID to oracle information
    mapping(uint256 => Oracle) public oracles;

    /// @dev Mapping from oracle ID to round to report data
    mapping(uint256 => mapping(uint256 => Report)) public reports;

    /// @dev Mapping from (oracleId1, oracleId2) to edge weight
    /// Using packed keys: (oracleId1 * 10000 + oracleId2) to save storage
    mapping(uint256 => EdgeWeight) public edgeWeights;

    /// @dev Mapping from oracle ID to trust score
    mapping(uint256 => uint256) public trustScores;

    /// @dev Mapping from oracle ID to slashed status
    mapping(uint256 => bool) public slashed;

    /// @dev Mapping from address to oracle ID
    mapping(address => uint256) public addressToOracleId;

    /// @notice Event emitted when oracle registers
    event OracleRegistered(
        uint256 indexed oracleId,
        address indexed oracleAddr,
        uint256 stake
    );

    /// @notice Event emitted when oracle deregisters
    event OracleDeregistered(uint256 indexed oracleId, address indexed oracleAddr);

    /// @notice Event emitted when report is submitted
    event ReportSubmitted(
        uint256 indexed oracleId,
        uint256 indexed round,
        uint256 reportValue
    );

    /// @notice Event emitted when edge weight is updated
    event EdgeWeightUpdated(
        uint256 indexed oracleId1,
        uint256 indexed oracleId2,
        uint256 newWeight
    );

    /// @notice Event emitted when trust score is updated
    event TrustScoreUpdated(uint256 indexed oracleId, uint256 newScore);

    /// @notice Event emitted when oracle is slashed
    event OracleSlashed(
        uint256 indexed oracleId,
        uint256 slashAmount,
        uint256 remainingStake
    );

    /// @notice Event emitted when round completes
    event RoundCompleted(
        uint256 indexed round,
        uint256 volatility,
        uint256 adaptiveAlpha
    );

    /// @notice Event emitted when MIS is extracted
    event MISExtracted(uint256[] misNodeIds, uint256[] misReports);

    /// @notice Event emitted when parameters are updated
    event ParametersUpdated(
        string paramName,
        uint256 oldValue,
        uint256 newValue
    );

    /// @dev Modifier to check if oracle is registered and active
    modifier onlyActiveOracle(uint256 oracleId) {
        require(oracleId > 0 && oracleId <= oracleCount, "Invalid oracle ID");
        require(oracles[oracleId].active, "Oracle not active");
        require(!slashed[oracleId], "Oracle has been slashed");
        _;
    }

    /// @dev Modifier to check if report can be submitted for round
    modifier validRound(uint256 oracleId, uint256 round) {
        require(round > 0 && round <= currentRound + 1, "Invalid round");
        require(
            !reports[oracleId][round].submitted,
            "Report already submitted for this round"
        );
        _;
    }

    constructor() {
        currentRound = 1;
        oracleCount = 0;
    }

    /**
     * @notice Register a new oracle with initial stake
     * @param stake The amount of stake (in wei) to deposit
     * @return oracleId The ID assigned to the new oracle
     */
    function registerOracle(uint256 stake) external payable nonReentrant returns (uint256) {
        require(msg.value >= minimumStake, "Insufficient stake");
        require(stake == msg.value, "Stake amount mismatch");
        require(addressToOracleId[msg.sender] == 0, "Oracle already registered");

        oracleCount++;
        uint256 oracleId = oracleCount;

        oracles[oracleId] = Oracle({
            addr: msg.sender,
            stake: stake,
            totalStake: stake,
            active: true,
            lastReportRound: 0
        });

        addressToOracleId[msg.sender] = oracleId;

        emit OracleRegistered(oracleId, msg.sender, stake);

        return oracleId;
    }

    /**
     * @notice Deregister an oracle and withdraw remaining stake
     * @param oracleId The ID of the oracle to deregister
     */
    function deregisterOracle(uint256 oracleId) external nonReentrant {
        require(oracleId > 0 && oracleId <= oracleCount, "Invalid oracle ID");
        Oracle storage oracle = oracles[oracleId];
        require(oracle.active, "Oracle already inactive");
        require(msg.sender == oracle.addr || msg.sender == owner(), "Unauthorized");

        oracle.active = false;
        uint256 remainingStake = oracle.stake;

        emit OracleDeregistered(oracleId, oracle.addr);

        // Withdraw remaining stake
        if (remainingStake > 0) {
            oracle.stake = 0;
            (bool success, ) = oracle.addr.call{value: remainingStake}("");
            require(success, "Withdrawal failed");
        }
    }

    /**
     * @notice Submit a report for the current round
     * @param reportValue The reported value (should be scaled by PRECISION for fixed-point math)
     */
    function submitReport(uint256 reportValue) external onlyActiveOracle(addressToOracleId[msg.sender]) {
        uint256 oracleId = addressToOracleId[msg.sender];
        require(!reports[oracleId][currentRound].submitted, "Report already submitted");

        reports[oracleId][currentRound] = Report({
            reportValue: reportValue,
            timestamp: block.timestamp,
            submitted: true
        });

        oracles[oracleId].lastReportRound = currentRound;

        emit ReportSubmitted(oracleId, currentRound, reportValue);
    }

    /**
     * @notice Get the edge weight key for two oracles (packs IDs to save storage)
     * @param id1 First oracle ID
     * @param id2 Second oracle ID
     * @return The packed key for the edge weight mapping
     */
    function _getEdgeWeightKey(uint256 id1, uint256 id2) internal pure returns (uint256) {
        // Normalize to avoid storing both (a,b) and (b,a)
        if (id1 > id2) {
            (id1, id2) = (id2, id1);
        }
        return id1 * 10000 + id2;
    }

    /**
     * @notice Update edge weight between two oracles using AEWMA
     * @param oracleId1 First oracle ID
     * @param oracleId2 Second oracle ID
     * @param currentAlpha The adaptive alpha value to use
     */
    function _updateEdgeWeight(
        uint256 oracleId1,
        uint256 oracleId2,
        uint256 currentAlpha
    ) internal {
        require(oracleId1 != oracleId2, "Cannot compare oracle with itself");

        Report storage report1 = reports[oracleId1][currentRound];
        Report storage report2 = reports[oracleId2][currentRound];

        // Skip if either oracle didn't submit a report
        if (!report1.submitted || !report2.submitted) {
            return;
        }

        uint256 key = _getEdgeWeightKey(oracleId1, oracleId2);
        EdgeWeight storage ew = edgeWeights[key];

        // Calculate absolute difference: |x_i,t - x_j,t|
        uint256 diff = report1.reportValue > report2.reportValue
            ? report1.reportValue - report2.reportValue
            : report2.reportValue - report1.reportValue;

        // AEWMA update: w_ij,t = (1 - alpha_t) * w_ij,t-1 + alpha_t * |x_i,t - x_j,t|
        uint256 oneMinusAlpha = PRECISION > currentAlpha
            ? PRECISION - currentAlpha
            : 0;

        uint256 newWeight = (oneMinusAlpha * ew.weight) / PRECISION +
            (currentAlpha * diff) / PRECISION;

        ew.weight = newWeight;
        ew.lastUpdated = block.timestamp;

        emit EdgeWeightUpdated(oracleId1, oracleId2, newWeight);
    }

    /**
     * @notice Calculate standard deviation of all submitted reports in current round
     * @return volatility The standard deviation (fixed-point with PRECISION)
     */
    function _calculateVolatility() internal view returns (uint256 volatility) {
        uint256 count = 0;
        uint256 sum = 0;

        // First pass: calculate mean
        for (uint256 i = 1; i <= oracleCount; i++) {
            if (reports[i][currentRound].submitted) {
                sum += reports[i][currentRound].reportValue;
                count++;
            }
        }

        if (count == 0) {
            return 0;
        }

        uint256 mean = sum / count;

        // Second pass: calculate variance
        uint256 variance = 0;
        for (uint256 i = 1; i <= oracleCount; i++) {
            if (reports[i][currentRound].submitted) {
                uint256 report = reports[i][currentRound].reportValue;
                uint256 deviation = report > mean ? report - mean : mean - report;

                // Use squared deviation: (report - mean)^2
                uint256 squared = (deviation * deviation) / PRECISION;
                variance += squared;
            }
        }

        variance = variance / count;

        // Approximate square root using Newton's method
        volatility = _sqrt(variance);
    }

    /**
     * @notice Calculate adaptive alpha based on volatility
     * @param volatility The current volatility (fixed-point with PRECISION)
     * @return adaptiveAlpha The computed adaptive alpha value
     */
    function _calculateAdaptiveAlpha(uint256 volatility) internal view returns (uint256 adaptiveAlpha) {
        // alpha_t = alpha_base / (1 + beta * sigma_t)
        uint256 denominator = PRECISION + (beta * volatility) / PRECISION;

        if (denominator == 0) {
            return alphaBase;
        }

        adaptiveAlpha = (alphaBase * PRECISION) / denominator;

        // Cap alpha between 0 and 1
        if (adaptiveAlpha > PRECISION) {
            adaptiveAlpha = PRECISION;
        }
    }

    /**
     * @notice Calculate trust score for an oracle
     * @param oracleId The oracle ID
     * @param avgWeight The average edge weight for this oracle
     * @return trustScore The calculated trust score (0 to PRECISION)
     */
    function _calculateTrustScore(uint256 oracleId, uint256 avgWeight)
        internal
        view
        returns (uint256 trustScore)
    {
        // S_i = exp(-w_i / scale)
        // Using approximation: exp(-x) ≈ 1 / (1 + x) for simplicity
        uint256 exponent = avgWeight > 0 ? (avgWeight * PRECISION) / scale : 0;

        if (exponent >= PRECISION * 10) {
            // exp(-x) is very close to 0 for large x
            trustScore = 0;
        } else if (exponent == 0) {
            trustScore = PRECISION;
        } else {
            // Use rational approximation for exp
            trustScore = _expNegative(exponent);
        }
    }

    /**
     * @notice Compute approximate exp(-x) using Taylor series approximation
     * @param x The exponent value (fixed-point with PRECISION)
     * @return result The approximate exp(-x) value
     */
    function _expNegative(uint256 x) internal pure returns (uint256 result) {
        // exp(-x) using Taylor series: 1 - x + x^2/2 - x^3/6 + ...
        // For stability, limit iterations

        if (x > PRECISION * 10) {
            return 0; // exp(-x) is effectively 0 for large x
        }

        result = PRECISION;

        // First term: -x
        if (x <= PRECISION) {
            result -= x;
        } else {
            return (PRECISION * PRECISION) / (PRECISION + x); // Use approximation
        }

        // Second term: x^2 / 2
        uint256 x2 = (x * x) / PRECISION / 2;
        if (x2 < PRECISION * PRECISION) {
            result += x2 / PRECISION;
        }

        // Third term: -x^3 / 6
        uint256 x3 = (x * x * x) / PRECISION / PRECISION / 6;
        if (x3 < PRECISION * PRECISION && result > x3 / PRECISION) {
            result -= x3 / PRECISION;
        }
    }

    /**
     * @notice Integer square root using Newton's method
     * @param x The number to compute square root of
     * @return y The integer square root
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;

        uint256 z = (x + 1) / 2;
        y = x;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Complete a round: update trust scores, compute adaptive alpha, and slash low-trust nodes
     * This should be called after all oracles have submitted reports
     */
    function completeRound() external onlyOwner nonReentrant whenNotPaused {
        // Calculate volatility
        uint256 volatility = _calculateVolatility();

        // Calculate adaptive alpha
        uint256 adaptiveAlpha = _calculateAdaptiveAlpha(volatility);

        // Update edge weights between all oracle pairs
        for (uint256 i = 1; i <= oracleCount; i++) {
            for (uint256 j = i + 1; j <= oracleCount; j++) {
                if (oracles[i].active && oracles[j].active) {
                    _updateEdgeWeight(i, j, adaptiveAlpha);
                }
            }
        }

        // Calculate average weights and update trust scores
        for (uint256 i = 1; i <= oracleCount; i++) {
            if (oracles[i].active) {
                uint256 totalWeight = 0;
                uint256 connectionCount = 0;

                // Sum edge weights for this oracle
                for (uint256 j = 1; j <= oracleCount; j++) {
                    if (i != j && oracles[j].active) {
                        uint256 key = _getEdgeWeightKey(i, j);
                        totalWeight += edgeWeights[key].weight;
                        connectionCount++;
                    }
                }

                // Calculate average weight
                uint256 avgWeight = connectionCount > 0
                    ? totalWeight / connectionCount
                    : 0;

                // Calculate and update trust score
                uint256 newTrustScore = _calculateTrustScore(i, avgWeight);
                trustScores[i] = newTrustScore;

                emit TrustScoreUpdated(i, newTrustScore);

                // Slash if trust score below threshold
                if (newTrustScore < tau) {
                    _slashOracle(i, avgWeight);
                }
            }
        }

        emit RoundCompleted(currentRound, volatility, adaptiveAlpha);
        currentRound++;
    }

    /**
     * @notice Slash an oracle: reduce stake proportionally to weight
     * @param oracleId The oracle ID to slash
     * @param weight The weight value used for penalty calculation
     */
    function _slashOracle(uint256 oracleId, uint256 weight) internal {
        require(oracles[oracleId].active, "Oracle not active");

        // Penalty = Stake_i * (1 - exp(-lambda * w_i))
        uint256 exponent = (lambda * weight) / PRECISION;
        uint256 expTerm = _expNegative(exponent);

        // (1 - exp(-lambda * w_i))
        uint256 penaltyFactor = PRECISION > expTerm
            ? PRECISION - expTerm
            : PRECISION;

        uint256 slashAmount = (oracles[oracleId].stake * penaltyFactor) / PRECISION;

        // Ensure slash amount doesn't exceed stake
        if (slashAmount > oracles[oracleId].stake) {
            slashAmount = oracles[oracleId].stake;
        }

        oracles[oracleId].stake -= slashAmount;
        slashed[oracleId] = true;

        emit OracleSlashed(oracleId, slashAmount, oracles[oracleId].stake);

        // If stake drops to zero or below threshold, deactivate
        if (oracles[oracleId].stake < minimumStake) {
            oracles[oracleId].active = false;
        }
    }

    /**
     * @notice Extract MIS (Maximal Independent Set) - nodes with avg weight below threshold
     * @return misNodeIds Array of oracle IDs in the MIS
     * @return misReports Array of report values from MIS nodes
     */
    function extractMIS()
        external
        view
        returns (uint256[] memory misNodeIds, uint256[] memory misReports)
    {
        uint256[] memory candidates = new uint256[](oracleCount);
        uint256 candidateCount = 0;

        // First pass: identify nodes with avg weight below threshold
        for (uint256 i = 1; i <= oracleCount; i++) {
            if (!oracles[i].active || !reports[i][currentRound].submitted) {
                continue;
            }

            uint256 totalWeight = 0;
            uint256 connectionCount = 0;

            for (uint256 j = 1; j <= oracleCount; j++) {
                if (i != j && oracles[j].active && reports[j][currentRound].submitted) {
                    uint256 key = _getEdgeWeightKey(i, j);
                    totalWeight += edgeWeights[key].weight;
                    connectionCount++;
                }
            }

            uint256 avgWeight = connectionCount > 0 ? totalWeight / connectionCount : 0;

            if (avgWeight < misWeightThreshold) {
                candidates[candidateCount] = i;
                candidateCount++;
            }
        }

        // Second pass: build MIS arrays
        misNodeIds = new uint256[](candidateCount);
        misReports = new uint256[](candidateCount);

        for (uint256 i = 0; i < candidateCount; i++) {
            uint256 oracleId = candidates[i];
            misNodeIds[i] = oracleId;
            misReports[i] = reports[oracleId][currentRound].reportValue;
        }

        emit MISExtracted(misNodeIds, misReports);
    }

    /**
     * @notice Get report for an oracle in a specific round
     * @param oracleId The oracle ID
     * @param round The round number
     * @return reportValue The report value (0 if not submitted)
     * @return timestamp The submission timestamp
     * @return submitted Whether report was submitted
     */
    function getReport(uint256 oracleId, uint256 round)
        external
        view
        returns (
            uint256 reportValue,
            uint256 timestamp,
            bool submitted
        )
    {
        Report storage report = reports[oracleId][round];
        return (report.reportValue, report.timestamp, report.submitted);
    }

    /**
     * @notice Get edge weight between two oracles
     * @param oracleId1 First oracle ID
     * @param oracleId2 Second oracle ID
     * @return weight The edge weight value
     * @return lastUpdated The last update timestamp
     */
    function getEdgeWeight(uint256 oracleId1, uint256 oracleId2)
        external
        view
        returns (uint256 weight, uint256 lastUpdated)
    {
        uint256 key = _getEdgeWeightKey(oracleId1, oracleId2);
        EdgeWeight storage ew = edgeWeights[key];
        return (ew.weight, ew.lastUpdated);
    }

    /**
     * @notice Get oracle information
     * @param oracleId The oracle ID
     * @return oracle The oracle struct
     */
    function getOracle(uint256 oracleId)
        external
        view
        returns (Oracle memory oracle)
    {
        require(oracleId > 0 && oracleId <= oracleCount, "Invalid oracle ID");
        return oracles[oracleId];
    }

    /**
     * @notice Get trust score for an oracle
     * @param oracleId The oracle ID
     * @return score The trust score (0 to PRECISION)
     */
    function getTrustScore(uint256 oracleId) external view returns (uint256 score) {
        require(oracleId > 0 && oracleId <= oracleCount, "Invalid oracle ID");
        return trustScores[oracleId];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the base alpha parameter
     * @param newAlphaBase The new alpha base value (should include PRECISION scaling)
     */
    function setAlphaBase(uint256 newAlphaBase) external onlyOwner {
        require(newAlphaBase > 0 && newAlphaBase <= PRECISION, "Invalid alpha base");
        uint256 oldValue = alphaBase;
        alphaBase = newAlphaBase;
        emit ParametersUpdated("alphaBase", oldValue, newAlphaBase);
    }

    /**
     * @notice Set the beta parameter
     * @param newBeta The new beta value
     */
    function setBeta(uint256 newBeta) external onlyOwner {
        require(newBeta > 0, "Beta must be positive");
        uint256 oldValue = beta;
        beta = newBeta;
        emit ParametersUpdated("beta", oldValue, newBeta);
    }

    /**
     * @notice Set the trust threshold parameter
     * @param newTau The new tau value (should include PRECISION scaling)
     */
    function setTau(uint256 newTau) external onlyOwner {
        require(newTau > 0 && newTau <= PRECISION, "Invalid tau");
        uint256 oldValue = tau;
        tau = newTau;
        emit ParametersUpdated("tau", oldValue, newTau);
    }

    /**
     * @notice Set the lambda parameter for slashing
     * @param newLambda The new lambda value
     */
    function setLambda(uint256 newLambda) external onlyOwner {
        require(newLambda > 0, "Lambda must be positive");
        uint256 oldValue = lambda;
        lambda = newLambda;
        emit ParametersUpdated("lambda", oldValue, newLambda);
    }

    /**
     * @notice Set the scale parameter
     * @param newScale The new scale value
     */
    function setScale(uint256 newScale) external onlyOwner {
        require(newScale > 0, "Scale must be positive");
        uint256 oldValue = scale;
        scale = newScale;
        emit ParametersUpdated("scale", oldValue, newScale);
    }

    /**
     * @notice Set the MIS weight threshold
     * @param newThreshold The new threshold value
     */
    function setMISWeightThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be positive");
        uint256 oldValue = misWeightThreshold;
        misWeightThreshold = newThreshold;
        emit ParametersUpdated("misWeightThreshold", oldValue, newThreshold);
    }

    /**
     * @notice Set minimum stake required
     * @param newMinimumStake The new minimum stake in wei
     */
    function setMinimumStake(uint256 newMinimumStake) external onlyOwner {
        require(newMinimumStake > 0, "Minimum stake must be positive");
        uint256 oldValue = minimumStake;
        minimumStake = newMinimumStake;
        emit ParametersUpdated("minimumStake", oldValue, newMinimumStake);
    }

    /**
     * @notice Pause contract (prevent report submission and round completion)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of contract balance (owner only)
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner nonReentrant {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Get total stake locked in contract
     * @return totalLocked The total locked stake
     */
    function getTotalLockedStake() external view returns (uint256 totalLocked) {
        for (uint256 i = 1; i <= oracleCount; i++) {
            if (oracles[i].active) {
                totalLocked += oracles[i].stake;
            }
        }
    }

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
