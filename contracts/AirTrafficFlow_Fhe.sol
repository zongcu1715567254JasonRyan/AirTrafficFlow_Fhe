// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract AirTrafficFlow_Fhe is SepoliaConfig {
    struct EncryptedFlightData {
        uint256 flightId;
        euint32 encryptedLatitude;
        euint32 encryptedLongitude;
        euint32 encryptedAltitude;
        euint32 encryptedTimestamp;
        euint32 encryptedCountryCode;
        uint256 publicTimestamp;
    }

    struct TrafficAnalysis {
        euint32 encryptedFlowScore;
        euint32 encryptedCongestionScore;
        euint32 encryptedOptimalRoute;
        bool isCompleted;
        bool isRevealed;
    }

    struct DecryptedAnalysis {
        uint32 flowScore;
        uint32 congestionScore;
        uint32 optimalRoute;
        bool isRevealed;
    }

    mapping(address => EncryptedFlightData[]) public countryFlightData;
    mapping(address => TrafficAnalysis[]) public trafficAnalyses;
    mapping(address => DecryptedAnalysis[]) public decryptedAnalyses;
    
    uint256 public flightCount;
    uint256 public analysisCount;
    address public admin;
    mapping(address => bool) public authorizedAgencies;
    
    event AgencyRegistered(address indexed agency);
    event FlightDataSubmitted(address indexed country, uint256 flightId);
    event AnalysisRequested(address indexed requester, uint256 analysisId);
    event AnalysisCompleted(address indexed requester, uint256 analysisId);
    event AnalysisRevealed(address indexed requester, uint256 analysisId);

    constructor() {
        admin = msg.sender;
        authorizedAgencies[admin] = true;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Admin only");
        _;
    }

    modifier onlyAuthorized() {
        require(authorizedAgencies[msg.sender], "Unauthorized agency");
        _;
    }

    function registerAgency(address agency) public onlyAdmin {
        authorizedAgencies[agency] = true;
        emit AgencyRegistered(agency);
    }

    function submitFlightData(
        euint32 latitude,
        euint32 longitude,
        euint32 altitude,
        euint32 countryCode
    ) public onlyAuthorized {
        flightCount++;
        countryFlightData[msg.sender].push(EncryptedFlightData({
            flightId: flightCount,
            encryptedLatitude: latitude,
            encryptedLongitude: longitude,
            encryptedAltitude: altitude,
            encryptedTimestamp: FHE.asEuint32(uint32(block.timestamp)),
            encryptedCountryCode: countryCode,
            publicTimestamp: block.timestamp
        }));
        emit FlightDataSubmitted(msg.sender, flightCount);
    }

    function requestTrafficAnalysis() public onlyAuthorized returns (uint256) {
        analysisCount++;
        uint256 analysisId = analysisCount;
        
        trafficAnalyses[msg.sender].push(TrafficAnalysis({
            encryptedFlowScore: FHE.asEuint32(0),
            encryptedCongestionScore: FHE.asEuint32(0),
            encryptedOptimalRoute: FHE.asEuint32(0),
            isCompleted: false,
            isRevealed: false
        }));
        
        emit AnalysisRequested(msg.sender, analysisId);
        return analysisId;
    }

    function performAnalysis(uint256 analysisId) public onlyAuthorized {
        require(analysisId <= analysisCount, "Invalid analysis ID");
        require(!trafficAnalyses[msg.sender][analysisId-1].isCompleted, "Already analyzed");
        
        euint32 totalFlow = FHE.asEuint32(0);
        euint32 totalCongestion = FHE.asEuint32(0);
        euint32 routeScore = FHE.asEuint32(0);
        uint32 dataCount = 0;
        
        for (uint256 i = 0; i < countryFlightData[msg.sender].length; i++) {
            EncryptedFlightData storage flight = countryFlightData[msg.sender][i];
            
            euint32 flow = calculateFlowScore(
                flight.encryptedLatitude,
                flight.encryptedLongitude,
                flight.encryptedAltitude
            );
            
            euint32 congestion = calculateCongestionScore(
                flight.encryptedLatitude,
                flight.encryptedLongitude
            );
            
            totalFlow = FHE.add(totalFlow, flow);
            totalCongestion = FHE.add(totalCongestion, congestion);
            routeScore = FHE.add(routeScore, FHE.mul(flow, congestion));
            dataCount++;
        }
        
        trafficAnalyses[msg.sender][analysisId-1] = TrafficAnalysis({
            encryptedFlowScore: FHE.div(totalFlow, FHE.asEuint32(dataCount)),
            encryptedCongestionScore: FHE.div(totalCongestion, FHE.asEuint32(dataCount)),
            encryptedOptimalRoute: FHE.div(routeScore, FHE.asEuint32(dataCount)),
            isCompleted: true,
            isRevealed: false
        });
        
        emit AnalysisCompleted(msg.sender, analysisId);
    }

    function calculateFlowScore(
        euint32 latitude,
        euint32 longitude,
        euint32 altitude
    ) private pure returns (euint32) {
        return FHE.div(
            FHE.add(
                FHE.add(latitude, longitude),
                altitude
            ),
            FHE.asEuint32(3)
        );
    }

    function calculateCongestionScore(
        euint32 latitude,
        euint32 longitude
    ) private pure returns (euint32) {
        return FHE.div(
            FHE.mul(latitude, longitude),
            FHE.asEuint32(1000)
        );
    }

    function requestAnalysisDecryption(uint256 analysisId) public onlyAuthorized {
        require(analysisId <= analysisCount, "Invalid analysis ID");
        require(trafficAnalyses[msg.sender][analysisId-1].isCompleted, "Analysis not complete");
        require(!trafficAnalyses[msg.sender][analysisId-1].isRevealed, "Already revealed");
        
        TrafficAnalysis storage analysis = trafficAnalyses[msg.sender][analysisId-1];
        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(analysis.encryptedFlowScore);
        ciphertexts[1] = FHE.toBytes32(analysis.encryptedCongestionScore);
        ciphertexts[2] = FHE.toBytes32(analysis.encryptedOptimalRoute);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptAnalysis.selector);
    }

    function decryptAnalysis(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public onlyAuthorized {
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        uint32[] memory results = abi.decode(cleartexts, (uint32[]));
        address agency = msg.sender;
        uint256 analysisId = trafficAnalyses[agency].length - 1;
        
        decryptedAnalyses[agency].push(DecryptedAnalysis({
            flowScore: results[0],
            congestionScore: results[1],
            optimalRoute: results[2],
            isRevealed: true
        }));
        
        trafficAnalyses[agency][analysisId].isRevealed = true;
        emit AnalysisRevealed(agency, analysisId);
    }

    function compareAirspaceUtilization(
        address country1,
        address country2
    ) public view onlyAuthorized returns (ebool) {
        uint256 count1 = countryFlightData[country1].length;
        uint256 count2 = countryFlightData[country2].length;
        
        return FHE.gt(
            FHE.asEuint32(uint32(count1)),
            FHE.asEuint32(uint32(count2))
        );
    }

    function getFlightDataCount(address country) public view returns (uint256) {
        return countryFlightData[country].length;
    }

    function getAnalysisCount(address agency) public view returns (uint256) {
        return trafficAnalyses[agency].length;
    }

    function getDecryptedAnalysis(address agency, uint256 analysisId) public view returns (
        uint32 flowScore,
        uint32 congestionScore,
        uint32 optimalRoute,
        bool isRevealed
    ) {
        require(analysisId <= decryptedAnalyses[agency].length, "Invalid analysis ID");
        DecryptedAnalysis storage analysis = decryptedAnalyses[agency][analysisId-1];
        return (
            analysis.flowScore,
            analysis.congestionScore,
            analysis.optimalRoute,
            analysis.isRevealed
        );
    }
}