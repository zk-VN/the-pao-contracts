// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IDKG.sol";
import "./interfaces/IVerifier.sol";
import "./interfaces/IFundManager.sol";
import "./interfaces/IDKGRequest.sol";
import "./libs/CurveBabyJubJub.sol";
import "./libs/Math.sol";

contract DKG is IDKG {
    address public owner;
    uint256 distributedKeyCounter;

    mapping(uint256 => DistributedKey) public distributedKeys;
    mapping(bytes32 => TallyTracker) public tallyTrackers; // rename

    IVerifier public round2Verifier;
    // dimension => Verifier
    mapping(uint256 => IVerifier) public fundingVerifiers;
    mapping(uint256 => IVerifier) public votingVerifiers;
    mapping(uint256 => IVerifier) public tallyContributionVerifiers;
    mapping(uint256 => IVerifier) public resultVerifiers;

    mapping(bytes32 => mapping(uint256 => IVerifier)) verifiers;

    constructor(DKGConfig memory _dkgConfig) {
        owner = msg.sender;
        round2Verifier = IVerifier(_dkgConfig.round2Verfier);
        fundingVerifiers[3] = IVerifier(_dkgConfig.fundingVerifier);
        votingVerifiers[3] = IVerifier(_dkgConfig.votingVerifier);
        tallyContributionVerifiers[3] = IVerifier(
            _dkgConfig.tallyContributionVerifier
        );
        resultVerifiers[3] = IVerifier(_dkgConfig.resultVerifier);
    }

    modifier onlyFounder() override {
        require(IFundManager(owner).isFounder(msg.sender));
        _;
    }

    modifier onlyOwner() override {
        require(msg.sender == owner);
        _;
    }

    modifier onlyCommittee() override {
        require(IFundManager(owner).isCommittee(msg.sender));
        _;
    }

    modifier onlyWhitelistedDAO() override {
        require(IFundManager(owner).isWhitelistedDAO(msg.sender));
        _;
    }

    function generateDistributedKey(
        uint8 _dimension,
        DistributedKeyType _distributedKeyType
    ) external override onlyFounder returns (uint256 distributedKeyID) {
        distributedKeyID = distributedKeyCounter;
        distributedKeyCounter += 1;
        DistributedKey storage distributedKey = distributedKeys[
            distributedKeyID
        ];
        address verifier;
        if (_distributedKeyType == DistributedKeyType.FUNDING) {
            require(
                address(fundingVerifiers[_dimension]) != address(0),
                "DKG Contract: No funding verifier exists with corresponding dimensionality"
            );
            verifier = address(fundingVerifiers[_dimension]);
        } else if (_distributedKeyType == DistributedKeyType.VOTING) {
            require(
                address(votingVerifiers[_dimension]) != address(0),
                "DKG Contract: No funding verifier exists with corresponding dimensionality"
            );
            verifier = address(votingVerifiers[_dimension]);
        }
        distributedKey.keyType = _distributedKeyType;
        distributedKey.dimension = _dimension;
        distributedKey.verifier = verifier;
        distributedKey.publicKeyX = 0;
        distributedKey.publicKeyY = 1;
        distributedKey.usageCounter = 0;

        emit DistributedKeyGenerated(distributedKeyID);
    }

    function submitRound1Contribution(
        uint256 _distributedKeyID,
        Round1Contribution calldata _round1Contribution
    ) external override onlyCommittee returns (uint8) {
        DistributedKey storage distributedKey = distributedKeys[
            _distributedKeyID
        ];
        (uint8 t, ) = IFundManager(owner).getDKGParams();
        require(
            getDistributedKeyState(_distributedKeyID) ==
                DistributedKeyState.CONTRIBUTION_ROUND_1
        );
        require(
            _round1Contribution.x.length == _round1Contribution.y.length &&
                _round1Contribution.x.length == t
        );

        for (uint i; i < t; i++) {
            require(
                CurveBabyJubJub.isOnCurve(
                    _round1Contribution.x[i],
                    _round1Contribution.y[i]
                )
            );
        }

        distributedKey.round1DataSubmissions.push(
            Round1DataSubmission(
                msg.sender,
                distributedKey.round1Counter,
                _round1Contribution.x,
                _round1Contribution.y
            )
        );
        (distributedKey.publicKeyX, distributedKey.publicKeyY) = CurveBabyJubJub
            .pointAdd(
                distributedKey.publicKeyX,
                distributedKey.publicKeyY,
                _round1Contribution.x[0],
                _round1Contribution.y[0]
            );

        distributedKey.round1Counter += 1;

        emit Round1DataSubmitted(msg.sender);
        return distributedKey.round1Counter;
    }

    function submitRound2Contribution(
        uint256 _distributedKeyID,
        Round2Contribution calldata _round2Contribution
    ) external override onlyCommittee {
        DistributedKey storage distributedKey = distributedKeys[
            _distributedKeyID
        ];
        (uint8 t, uint8 n) = IFundManager(owner).getDKGParams();
        require(
            getDistributedKeyState(_distributedKeyID) ==
                DistributedKeyState.CONTRIBUTION_ROUND_2
        );
        require(_round2Contribution.recipientIndexes.length == n - 1);
        require(_round2Contribution.ciphers.length == n);
        require(
            distributedKey
                .round1DataSubmissions[_round2Contribution.senderIndex]
                .sender == msg.sender
        );

        bytes32 bitChecker;
        bytes32 bitMask;
        bitChecker = bitChecker | bytes32(1 << _round2Contribution.senderIndex);
        bitMask = bitMask | bytes32(1 << n);
        for (
            uint8 i = 0;
            i < _round2Contribution.recipientIndexes.length;
            i++
        ) {
            bitChecker =
                bitChecker |
                bytes32(1 << _round2Contribution.recipientIndexes[i]);
            bitMask = bitMask | bytes32(1 << i);
        }
        require(bitChecker == bitMask);

        uint256[] memory publicInputs = new uint256[](
            IVerifier(distributedKey.verifier).getPublicInputsLength()
        );
        Round1DataSubmission memory senderSubmission = distributedKey
            .round1DataSubmissions[_round2Contribution.senderIndex - 1];
        for (
            uint8 i = 1;
            i < _round2Contribution.recipientIndexes.length;
            i++
        ) {
            Round1DataSubmission memory recipientSubmission = distributedKey
                .round1DataSubmissions[
                    _round2Contribution.recipientIndexes[i] - 1
                ];
            publicInputs[0] = _round2Contribution.recipientIndexes[i];
            publicInputs[1] = recipientSubmission.x[0];
            publicInputs[2] = recipientSubmission.y[0];
            for (uint8 j = 0; j < t; j++) {
                publicInputs[3 + j * 2] = senderSubmission.x[j];
                publicInputs[3 + j * 2 + 1] = senderSubmission.y[j];
            }
            publicInputs[3 + t * 2] = _round2Contribution.ciphers[i][0];
            publicInputs[3 + t * 2 + 1] = _round2Contribution.ciphers[i][1];
            publicInputs[3 + t * 2 + 2] = _round2Contribution.ciphers[i][2];

            require(
                _verifyProof(
                    round2Verifier,
                    _round2Contribution.proofs[i],
                    publicInputs
                )
            );

            distributedKey
                .round2DataSubmissions[_round2Contribution.recipientIndexes[i]]
                .push(
                    Round2DataSubmission(
                        _round2Contribution.senderIndex,
                        _round2Contribution.ciphers[i]
                    )
                );
        }

        distributedKey.round2Counter += 1;
        emit Round2DataSubmitted(msg.sender);
        if (distributedKey.round2Counter == n) {
            emit DistributedKeyActivated(_distributedKeyID);
        }
    }

    function startTallying(
        bytes32 _requestID,
        uint256 _distributedKeyID,
        uint256[][] memory _R,
        uint256[][] memory _M
    ) external override onlyWhitelistedDAO {
        TallyTracker storage tallyTracker = tallyTrackers[_requestID];
        require(
            tallyTracker.contributionVerifier == address(0) &&
                tallyTracker.resultVerifier == address(0)
        );
        tallyTracker.distributedKeyID = _distributedKeyID;
        tallyTracker.R = _R;
        tallyTracker.M = _M;
        uint8 dimension = distributedKeys[_distributedKeyID].dimension;
        address tallyContributionVerifier = address(
            tallyContributionVerifiers[dimension]
        );
        address resultVerifier = address(resultVerifiers[dimension]);
        require(tallyContributionVerifier != address(0));
        require(resultVerifier != address(0));
        tallyTracker.dao = msg.sender;
        tallyTracker.contributionVerifier = tallyContributionVerifier;
        tallyTracker.resultVerifier = resultVerifier;

        emit TallyStarted(_requestID);
    }

    function submitTallyContribution(
        bytes32 _requestID,
        TallyContribution calldata _tallyContribution
    ) external override onlyCommittee {
        TallyTracker storage tallyTracker = tallyTrackers[_requestID];
        DistributedKey storage distributedKey = distributedKeys[
            tallyTracker.distributedKeyID
        ];
        (, uint8 n) = IFundManager(owner).getDKGParams();
        uint8 dimension = distributedKey.dimension;

        require(
            getTallyTrackerState(_requestID) == TallyTrackerState.CONTRIBUTION
        );
        require(
            _tallyContribution.senderIndex >= 1 &&
                _tallyContribution.senderIndex <= n
        );
        require(_tallyContribution.Di.length == dimension);

        Round2DataSubmission[] memory round2DataSubmissions = distributedKey
            .round2DataSubmissions[_tallyContribution.senderIndex];
        IVerifier verifier = IVerifier(tallyTracker.contributionVerifier);
        uint[] memory publicInputs = new uint[](
            verifier.getPublicInputsLength()
        );

        n = n - 1;
        for (uint8 i; i < n; i++) {
            publicInputs[2 * i] = round2DataSubmissions[i].cipher[0];
            publicInputs[2 * i + 1] = round2DataSubmissions[i].cipher[1];
            publicInputs[2 * n + i] = round2DataSubmissions[i].cipher[2];
        }
        for (uint8 i; i < dimension; i++) {
            publicInputs[3 * n + 2 * i] = tallyTracker.R[i][0];
            publicInputs[3 * n + 2 * i + 1] = tallyTracker.R[i][1];
            publicInputs[3 * n + dimension * 2 + 2 * i] = _tallyContribution.Di[
                i
            ][0];
            publicInputs[3 * n + dimension * 2 + 2 * i + 1] = _tallyContribution
                .Di[i][1];
        }

        // Verify proof
        _verifyProof(verifier, _tallyContribution.proof, publicInputs);

        tallyTracker.tallyDataSubmissions.push(
            TallyDataSubmission(
                _tallyContribution.senderIndex,
                _tallyContribution.Di
            )
        );
        tallyTracker.tallyCounter += 1;

        emit TallyContributionSubmitted(msg.sender);
    }

    function submitTallyResult(
        bytes32 _requestID,
        uint256[] calldata _result,
        bytes calldata _proof
    ) external override {
        TallyTracker storage tallyTracker = tallyTrackers[_requestID];
        require(
            getTallyTrackerState(_requestID) ==
                TallyTrackerState.RESULT_AWAITING
        );
        DistributedKey storage distributedKey = distributedKeys[
            tallyTracker.distributedKeyID
        ];
        uint8 dimension = distributedKey.dimension;
        // Verify result
        uint256[][] memory resultVector = getTallyResultVector(_requestID);
        uint256[] memory publicInputs = new uint256[](
            IVerifier(tallyTracker.resultVerifier).getPublicInputsLength()
        );
        for (uint8 i = 0; i < dimension; i++) {
            publicInputs[i] = _result[i];
            publicInputs[dimension + 2 * i] = resultVector[i][0];
            publicInputs[dimension + 2 * i + 1] = resultVector[i][1];
        }

        require(
            _verifyProof(
                IVerifier(tallyTracker.resultVerifier),
                _proof,
                publicInputs
            )
        );

        IDKGRequest(tallyTracker.dao).submitTallyResult(_requestID, _result);
        distributedKey.usageCounter += 1;
        tallyTracker.resultSubmitted = true;

        emit TallyResultSubmitted(msg.sender, _requestID, _result);
    }

    /*==================== VIEW FUNCTION ====================*/

    function getUsageCounter(
        uint256 _distributedKeyID
    ) external view override returns (uint256) {
        return distributedKeys[_distributedKeyID].usageCounter;
    }

    function getDimension(
        uint256 _distributedKeyID
    ) external view override returns (uint8) {
        return distributedKeys[_distributedKeyID].dimension;
    }

    function getDistributedKeyState(
        uint256 _distributedKeyID
    ) public view override returns (DistributedKeyState) {
        DistributedKey storage distributedKey = distributedKeys[
            _distributedKeyID
        ];
        (, uint8 n) = IFundManager(owner).getDKGParams();
        if (distributedKey.round2Counter == n) {
            return DistributedKeyState.ACTIVE;
        }
        if (distributedKey.round1Counter == n) {
            return DistributedKeyState.CONTRIBUTION_ROUND_2;
        }
        return DistributedKeyState.CONTRIBUTION_ROUND_1;
    }

    function getType(
        uint256 _distributedKeyID
    ) external view override returns (DistributedKeyType) {
        return distributedKeys[_distributedKeyID].keyType;
    }

    function getRound1DataSubmission(
        uint256 _distributedKeyID,
        uint8 _senderIndex
    ) external view override returns (Round1DataSubmission memory) {
        return
            distributedKeys[_distributedKeyID].round1DataSubmissions[
                _senderIndex - 1
            ];
    }

    function getPublicKey(
        uint256 _distributedKeyID
    ) external view override returns (uint256, uint256) {
        DistributedKey storage distributedKey = distributedKeys[
            _distributedKeyID
        ];
        require(
            getDistributedKeyState(_distributedKeyID) ==
                DistributedKeyState.ACTIVE
        );
        return (distributedKey.publicKeyX, distributedKey.publicKeyY);
    }

    function getVerifier(
        uint256 _distributedKeyID
    ) external view override returns (IVerifier) {
        DistributedKey storage distributedKey = distributedKeys[
            _distributedKeyID
        ];
        return IVerifier(distributedKey.verifier);
    }

    function getTallyTrackerState(
        bytes32 _requestID
    ) public view returns (TallyTrackerState) {
        TallyTracker memory tallyTracker = tallyTrackers[_requestID];
        (uint8 t, ) = IFundManager(owner).getDKGParams();

        if (tallyTracker.resultSubmitted) {
            return TallyTrackerState.RESULT_SUBMITTED;
        }
        if (tallyTracker.tallyCounter == t) {
            return TallyTrackerState.RESULT_AWAITING;
        }
        return TallyTrackerState.CONTRIBUTION;
    }

    function getTallyResultVector(
        bytes32 _requestID
    ) public view override returns (uint256[][] memory) {
        TallyTracker memory tallyTracker = tallyTrackers[_requestID];
        DistributedKey storage distributedKey = distributedKeys[
            tallyTracker.distributedKeyID
        ];
        require(
            getTallyTrackerState(_requestID) ==
                TallyTrackerState.RESULT_AWAITING
        );
        uint8 dimension = distributedKey.dimension;
        (uint8 t, ) = IFundManager(owner).getDKGParams();

        uint256[] memory sumDx = new uint256[](dimension);
        uint256[] memory sumDy = new uint256[](dimension);
        uint256[][] memory M = tallyTracker.M;

        uint8[] memory listIndex = new uint8[](t);
        for (uint8 i; i < t; i++) {
            listIndex[i] = tallyTracker.tallyDataSubmissions[i].senderIndex;
        }

        uint256[] memory lagrangeCoefficient = Math.computeLagrangeCoefficient(
            listIndex,
            t
        );
        for (uint8 i; i < dimension; i++) {
            sumDx[i] = 0;
            sumDy[i] = 1;
        }
        for (uint8 i; i < t; i++) {
            TallyDataSubmission memory tallyDataSubmission = tallyTracker
                .tallyDataSubmissions[i];
            for (uint8 j; j < dimension; j++) {
                (uint256 tmpX, uint256 tmpY) = CurveBabyJubJub.pointMul(
                    tallyDataSubmission.Di[j][0],
                    tallyDataSubmission.Di[j][1],
                    lagrangeCoefficient[i]
                );
                (sumDx[j], sumDy[j]) = CurveBabyJubJub.pointAdd(
                    sumDx[j],
                    sumDy[j],
                    tmpX,
                    tmpY
                );
            }
        }

        uint256[][] memory tallyResultVector = new uint256[][](dimension);
        for (uint8 i; i < dimension; i++) {
            sumDx[i] = CurveBabyJubJub.Q - sumDx[i];
            (uint256 tmpX, uint256 tmpY) = CurveBabyJubJub.pointAdd(
                sumDx[i],
                sumDy[i],
                M[i][0],
                M[i][1]
            );
            tallyResultVector[i] = new uint256[](2);
            tallyResultVector[i][0] = tmpX;
            tallyResultVector[i][1] = tmpY;
        }

        return tallyResultVector;
    }

    /*================== INTERNAL FUNCTION ==================*/

    function _verifyProof(
        IVerifier _verifier,
        bytes calldata _proof,
        uint256[] memory _publicInputs
    ) internal view returns (bool) {
        require(_publicInputs.length == _verifier.getPublicInputsLength());
        uint256[8] memory proof = abi.decode(_proof, (uint256[8]));
        for (uint8 i = 0; i < proof.length; i++) {
            require(
                proof[i] < Math.PRIME_Q,
                "verifier-proof-element-gte-prime-q"
            );
        }
        return
            _verifier.verifyProof(
                [proof[0], proof[1]],
                [[proof[2], proof[3]], [proof[4], proof[5]]],
                [proof[6], proof[7]],
                _publicInputs
            );
    }
}
