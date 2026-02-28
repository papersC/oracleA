// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../DynamicTrustDecay.sol";

/**
 * @title TestDynamicTrust
 * @dev Comprehensive test suite for the DynamicTrustDecay contract
 * Tests oracle registration, reporting, trust computation, and slashing
 */
contract TestDynamicTrust is Test {
    /// @dev Contract instance
    DynamicTrustDecay trustContract;

    /// @dev Test accounts
    address admin = address(1);
    address oracle1 = address(2);
    address oracle2 = address(3);
    address oracle3 = address(4);
    address oracle4 = address(5);

    /// @dev Precision constant for fixed-point math
    uint256 private constant PRECISION = 1e18;

    /// @notice Set up test environment
    function setUp() public {
        // Deploy contract with admin as owner
        vm.prank(admin);
        trustContract = new DynamicTrustDecay();

        // Fund test accounts
        vm.deal(oracle1, 100 ether);
        vm.deal(oracle2, 100 ether);
        vm.deal(oracle3, 100 ether);
        vm.deal(oracle4, 100 ether);
    }

    // ============ Registration Tests ============

    function testOracleRegistration() public {
        // Oracle 1 registers with 5 ether stake
        vm.prank(oracle1);
        uint256 oracleId = trustContract.registerOracle{value: 5 ether}(5 ether);

        assertEq(oracleId, 1, "First oracle should have ID 1");
        assertEq(trustContract.oracleCount(), 1, "Oracle count should be 1");

        // Verify oracle data
        DynamicTrustDecay.Oracle memory oracle = trustContract.getOracle(oracleId);
        assertEq(oracle.addr, oracle1, "Oracle address mismatch");
        assertEq(oracle.stake, 5 ether, "Oracle stake mismatch");
        assertEq(oracle.active, true, "Oracle should be active");
    }

    function testMultipleOracleRegistration() public {
        // Register multiple oracles
        vm.prank(oracle1);
        uint256 id1 = trustContract.registerOracle{value: 5 ether}(5 ether);
        assertEq(id1, 1, "First oracle ID should be 1");

        vm.prank(oracle2);
        uint256 id2 = trustContract.registerOracle{value: 10 ether}(10 ether);
        assertEq(id2, 2, "Second oracle ID should be 2");

        vm.prank(oracle3);
        uint256 id3 = trustContract.registerOracle{value: 3 ether}(3 ether);
        assertEq(id3, 3, "Third oracle ID should be 3");

        assertEq(trustContract.oracleCount(), 3, "Should have 3 oracles");
    }

    function testCannotRegisterWithInsufficientStake() public {
        vm.prank(oracle1);
        vm.expectRevert("Insufficient stake");
        trustContract.registerOracle{value: 0.5 ether}(0.5 ether);
    }

    function testCannotRegisterTwice() public {
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        vm.prank(oracle1);
        vm.expectRevert("Oracle already registered");
        trustContract.registerOracle{value: 5 ether}(5 ether);
    }

    function testOracleDeregistration() public {
        // Register oracle
        vm.prank(oracle1);
        uint256 oracleId = trustContract.registerOracle{value: 5 ether}(5 ether);

        uint256 initialBalance = oracle1.balance;

        // Deregister oracle
        vm.prank(oracle1);
        trustContract.deregisterOracle(oracleId);

        // Verify deregistration
        DynamicTrustDecay.Oracle memory oracle = trustContract.getOracle(oracleId);
        assertEq(oracle.active, false, "Oracle should be inactive");

        // Verify stake returned
        assertEq(oracle1.balance, initialBalance + 5 ether, "Stake should be returned");
    }

    // ============ Report Submission Tests ============

    function testReportSubmission() public {
        // Register oracle
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Submit report with value 100 (scaled to 100e18)
        uint256 reportValue = 100 * PRECISION;
        vm.prank(oracle1);
        trustContract.submitReport(reportValue);

        // Verify report
        (uint256 value, , bool submitted) = trustContract.getReport(1, 1);
        assertEq(value, reportValue, "Report value mismatch");
        assertEq(submitted, true, "Report should be marked as submitted");
    }

    function testMultipleReports() public {
        // Register oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Both submit reports for round 1
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(105 * PRECISION);

        // Verify both reports
        (uint256 value1, , bool submitted1) = trustContract.getReport(1, 1);
        (uint256 value2, , bool submitted2) = trustContract.getReport(2, 1);

        assertEq(submitted1, true, "Oracle 1 report should be submitted");
        assertEq(submitted2, true, "Oracle 2 report should be submitted");
        assertEq(value1, 100 * PRECISION, "Oracle 1 value mismatch");
        assertEq(value2, 105 * PRECISION, "Oracle 2 value mismatch");
    }

    function testCannotSubmitDuplicateReport() public {
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);

        // Attempt to submit again
        vm.prank(oracle1);
        vm.expectRevert("Report already submitted for this round");
        trustContract.submitReport(105 * PRECISION);
    }

    function testCannotSubmitAfterDeregistration() public {
        vm.prank(oracle1);
        uint256 oracleId = trustContract.registerOracle{value: 5 ether}(5 ether);

        vm.prank(oracle1);
        trustContract.deregisterOracle(oracleId);

        vm.prank(oracle1);
        vm.expectRevert("Oracle not active");
        trustContract.submitReport(100 * PRECISION);
    }

    // ============ Volatility and Alpha Tests ============

    function testVolatilityCalculation() public {
        // Register oracles
        for (uint256 i = 0; i < 4; i++) {
            address oracle = address(uint160(2 + i));
            vm.deal(oracle, 100 ether);
            vm.prank(oracle);
            trustContract.registerOracle{value: 5 ether}(5 ether);
        }

        // Submit reports with different values (to create volatility)
        uint256[] memory values = new uint256[](4);
        values[0] = 100 * PRECISION;
        values[1] = 105 * PRECISION;
        values[2] = 95 * PRECISION;
        values[3] = 110 * PRECISION;

        for (uint256 i = 0; i < 4; i++) {
            address oracle = address(uint160(2 + i));
            vm.prank(oracle);
            trustContract.submitReport(values[i]);
        }

        // Complete round (triggers volatility calculation internally)
        vm.prank(admin);
        trustContract.completeRound();

        // Verify round was advanced
        assertEq(trustContract.currentRound(), 2, "Round should advance to 2");
    }

    // ============ Edge Weight Tests ============

    function testEdgeWeightUpdate() public {
        // Register two oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Both submit reports
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(105 * PRECISION);

        // Complete round (updates edge weights)
        vm.prank(admin);
        trustContract.completeRound();

        // Verify edge weight was updated
        (uint256 weight, ) = trustContract.getEdgeWeight(1, 2);
        // Expected weight: |100 - 105| = 5 (scaled)
        assertEq(weight, 5 * PRECISION, "Edge weight should be difference in reports");
    }

    function testEdgeWeightAEWMA() public {
        // Register two oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Round 1: submit reports with 5-unit difference
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(105 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        (uint256 weight1, ) = trustContract.getEdgeWeight(1, 2);
        assertEq(weight1, 5 * PRECISION, "First weight should be 5");

        // Round 2: submit reports with 3-unit difference
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(103 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        (uint256 weight2, ) = trustContract.getEdgeWeight(1, 2);
        // AEWMA: should move towards 3 but not fully due to alpha weighting
        assertLt(weight2, weight1, "Weight should decrease with lower difference");
        assertGt(weight2, 3 * PRECISION, "Weight should be above new value due to averaging");
    }

    // ============ Trust Score Tests ============

    function testTrustScoreCalculation() public {
        // Register multiple oracles for trust calculation
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle3);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Submit reports - oracle1 matches others
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle3);
        trustContract.submitReport(105 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Oracle1 should have high trust (matches oracle2)
        uint256 trustScore1 = trustContract.getTrustScore(1);
        uint256 trustScore3 = trustContract.getTrustScore(3);

        // Oracle 3 differs from others, should have lower trust score
        assertGt(trustScore1, trustScore3, "Matching oracle should have higher trust");
    }

    // ============ Slashing Tests ============

    function testSlashingMechanism() public {
        // Register oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle3);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Set low trust threshold to trigger slashing
        vm.prank(admin);
        trustContract.setTau(0.1e18); // Very low threshold

        // Oracle1 submits outlier report
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(1000 * PRECISION);
        vm.prank(oracle3);
        trustContract.submitReport(1005 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Oracle2 should be slashed for outlier report
        DynamicTrustDecay.Oracle memory slashedOracle = trustContract.getOracle(2);
        assertLt(slashedOracle.stake, 5 ether, "Oracle stake should be reduced");
        assertEq(slashedOracle.active, false, "Oracle should be deactivated if stake too low");
    }

    function testCannotSubmitReportAfterSlashing() public {
        // Register oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle3);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Set low trust threshold
        vm.prank(admin);
        trustContract.setTau(0.1e18);

        // Submit and slash
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(1000 * PRECISION);
        vm.prank(oracle3);
        trustContract.submitReport(1005 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Try to submit report for slashed oracle
        vm.prank(oracle2);
        vm.expectRevert("Oracle has been slashed");
        trustContract.submitReport(500 * PRECISION);
    }

    // ============ MIS Extraction Tests ============

    function testMISExtraction() public {
        // Register oracles
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle3);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle4);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // All oracles submit similar reports (low weights)
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(101 * PRECISION);
        vm.prank(oracle3);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle4);
        trustContract.submitReport(99 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Extract MIS
        (uint256[] memory misNodeIds, uint256[] memory misReports) = trustContract.extractMIS();

        // All nodes should be in MIS (low weights)
        assertEq(misNodeIds.length, 4, "All nodes should be in MIS with low weights");
        assertEq(misReports.length, 4, "Should have 4 reports in MIS");
    }

    // ============ Admin Function Tests ============

    function testSetAlphaBase() public {
        uint256 newAlpha = 0.2e18;
        vm.prank(admin);
        trustContract.setAlphaBase(newAlpha);

        assertEq(trustContract.alphaBase(), newAlpha, "Alpha base should be updated");
    }

    function testSetBeta() public {
        uint256 newBeta = 1e18;
        vm.prank(admin);
        trustContract.setBeta(newBeta);

        assertEq(trustContract.beta(), newBeta, "Beta should be updated");
    }

    function testSetTau() public {
        uint256 newTau = 0.3e18;
        vm.prank(admin);
        trustContract.setTau(newTau);

        assertEq(trustContract.tau(), newTau, "Tau should be updated");
    }

    function testOnlyAdminCanSetParameters() public {
        vm.prank(oracle1);
        vm.expectRevert("Ownable: caller is not the owner");
        trustContract.setAlphaBase(0.2e18);
    }

    function testPauseUnpause() public {
        // Pause contract
        vm.prank(admin);
        trustContract.pause();

        // Register oracle
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Try to complete round while paused
        vm.prank(admin);
        vm.expectRevert("Pausable: paused");
        trustContract.completeRound();

        // Unpause
        vm.prank(admin);
        trustContract.unpause();

        // Should work now
        vm.prank(admin);
        trustContract.completeRound();
    }

    // ============ Edge Cases ============

    function testHandleNoReports() public {
        vm.prank(admin);
        trustContract.completeRound();
        assertEq(trustContract.currentRound(), 2, "Should advance round even with no reports");
    }

    function testHandleSingleOracle() public {
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Oracle with single node should have 0 connections, avg weight = 0
        uint256 trustScore = trustContract.getTrustScore(1);
        assertEq(trustScore, PRECISION, "Single oracle with no comparisons should have max trust");
    }

    function testHandleSameReports() public {
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        // Both submit identical reports
        vm.prank(oracle1);
        trustContract.submitReport(100 * PRECISION);
        vm.prank(oracle2);
        trustContract.submitReport(100 * PRECISION);

        vm.prank(admin);
        trustContract.completeRound();

        // Edge weight should be 0 (no difference)
        (uint256 weight, ) = trustContract.getEdgeWeight(1, 2);
        assertEq(weight, 0, "Identical reports should have 0 weight");

        // Both should have maximum trust
        uint256 trust1 = trustContract.getTrustScore(1);
        uint256 trust2 = trustContract.getTrustScore(2);
        assertEq(trust1, PRECISION, "Oracle 1 should have max trust");
        assertEq(trust2, PRECISION, "Oracle 2 should have max trust");
    }

    function testGetTotalLockedStake() public {
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);
        vm.prank(oracle2);
        trustContract.registerOracle{value: 10 ether}(10 ether);
        vm.prank(oracle3);
        trustContract.registerOracle{value: 3 ether}(3 ether);

        uint256 totalStake = trustContract.getTotalLockedStake();
        assertEq(totalStake, 18 ether, "Total stake should match sum of all stakes");
    }

    function testEmergencyWithdraw() public {
        // Fund contract
        vm.prank(oracle1);
        trustContract.registerOracle{value: 5 ether}(5 ether);

        uint256 contractBalance = address(trustContract).balance;
        assertGt(contractBalance, 0, "Contract should have balance");

        // Emergency withdraw
        uint256 adminBalanceBefore = admin.balance;
        vm.prank(admin);
        trustContract.emergencyWithdraw(5 ether);

        assertEq(admin.balance, adminBalanceBefore + 5 ether, "Admin should receive withdrawn amount");
    }

    // ============ Integration Tests ============

    function testFullRoundWorkflow() public {
        // Register 4 oracles
        address[] memory oracles = new address[](4);
        oracles[0] = oracle1;
        oracles[1] = oracle2;
        oracles[2] = oracle3;
        oracles[3] = oracle4;

        for (uint256 i = 0; i < 4; i++) {
            vm.prank(oracles[i]);
            trustContract.registerOracle{value: 5 ether}(5 ether);
        }

        // Multiple rounds
        for (uint256 round = 1; round <= 3; round++) {
            // Submit reports
            vm.prank(oracle1);
            trustContract.submitReport(100 * PRECISION);
            vm.prank(oracle2);
            trustContract.submitReport(102 * PRECISION);
            vm.prank(oracle3);
            trustContract.submitReport(99 * PRECISION);
            vm.prank(oracle4);
            trustContract.submitReport(101 * PRECISION);

            // Complete round
            vm.prank(admin);
            trustContract.completeRound();

            assertEq(trustContract.currentRound(), round + 1, "Round should advance");
        }

        // Verify trust scores were computed
        uint256 trust1 = trustContract.getTrustScore(1);
        assertGt(trust1, 0, "Trust score should be computed");
    }
}
