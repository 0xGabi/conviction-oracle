// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ABDKMath64x64} from "abdk-libraries-solidity/ABDKMath64x64.sol";
import "hardhat/console.sol";

// TODO: Make it a TokenManagerHook

contract ConvictionOracle is Ownable {
    using ABDKMath64x64 for int128;
    using ABDKMath64x64 for uint256;
    using SafeMath for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    uint64 public constant MAX_STAKED_PROPOSALS = 10;
    // Shift to left to leave space for decimals
    int128 private constant ONE = 1 << 64;

    struct Proposal {
        uint256 stakedTokens;
        uint256 lastRate;
        uint256 lastTime;
        bool active;
        mapping(address => uint256) voterStake;
        address trigger;
    }

    ERC20 public stakeToken;
    int128 internal decay;
    int128 internal minStakeRatio;
    uint256 public proposalCounter;
    uint256 public totalStaked;

    mapping(address => bool) internal triggers;
    mapping(uint256 => Proposal) internal proposals;
    mapping(address => uint256) internal totalVoterStake;
    mapping(address => EnumerableSet.UintSet) internal voterStakedProposals;

    event TriggerChanged(address indexed trigger, bool active);
    event SettingsChanged(uint256 decay, uint256 minStakeRatio);
    event ProposalAdded(address indexed trigger, uint256 indexed id);
    event StakeAdded(
        address indexed entity,
        uint256 indexed id,
        uint256 amount,
        uint256 tokensStaked,
        uint256 totalTokensStaked,
        uint256 lastRate
    );
    event StakeWithdrawn(
        address entity,
        uint256 indexed id,
        uint256 amount,
        uint256 tokensStaked,
        uint256 totalTokensStaked,
        uint256 lastRate
    );
    event ProposalCancelled(uint256 indexed id);

    modifier onlyTrigger() {
        require(triggers[msg.sender], "SENDER_NOT_A_TRIGGER");
        _;
    }

    modifier proposalExists(uint256 _proposalId) {
        require(proposals[_proposalId].trigger != address(0), "PROPOSAL_DOES_NOT_EXIST");
        _;
    }

    modifier activeProposal(uint256 _proposalId) {
        require(proposals[_proposalId].active, "PROPOSAL_NOT_ACTIVE");
        _;
    }

    constructor(
        ERC20 _stakeToken,
        uint256 _decay,
        uint256 _minStakeRatio,
        address[] memory _triggers
    ) {
        stakeToken = _stakeToken;

        for (uint256 i = 0; i < _triggers.length; i++) {
            setTrigger(_triggers[i], true);
        }

        setSettings(_decay, _minStakeRatio);
    }

    function setTrigger(address _trigger, bool _active) public onlyOwner {
        triggers[_trigger] = _active;

        emit TriggerChanged(_trigger, _active);
    }

    function setSettings(uint256 _decay, uint256 _minStakeRatio) public onlyOwner {
        decay = _decay.divu(1e18).add(1);
        minStakeRatio = _minStakeRatio.divu(1e18).add(1);

        emit SettingsChanged(_decay, _minStakeRatio);
    }

    function addProposal() external onlyTrigger {
        Proposal storage p = proposals[proposalCounter];
        p.active = true;
        p.trigger = msg.sender;

        emit ProposalAdded(msg.sender, proposalCounter);
        proposalCounter++;
    }

    function cancelProposal(uint256 _proposalId) external activeProposal(_proposalId) {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.trigger == msg.sender || owner() == msg.sender, "SENDER_CANNOT_CANCEL");
        proposal.active = false;

        emit ProposalCancelled(_proposalId);
    }

    // TODO: Only allow triggers to update the stakes?

    function setStake(uint256 _proposalId, uint256 _newAmount) external activeProposal(_proposalId) {
        uint256 currentAmount = getProposalVoterStake(_proposalId, msg.sender);
        if (_newAmount > currentAmount) {
            _stakeToProposal(_proposalId, _newAmount.sub(currentAmount), msg.sender);
        } else if (_newAmount < currentAmount) {
            _withdrawFromProposal(_proposalId, currentAmount.sub(_newAmount), msg.sender);
        }
    }

    function stakeToProposal(uint256 _proposalId, uint256 _amount) external activeProposal(_proposalId) {
        _stakeToProposal(_proposalId, _amount, msg.sender);
    }

    function withdrawFromProposal(uint256 _proposalId, uint256 _amount) external proposalExists(_proposalId) {
        _withdrawFromProposal(_proposalId, _amount, msg.sender);
    }

    /**
     * @dev Withdraw all staked tokens from proposals.
     * @param _voter Account to withdraw from.
     * @param _onlyCancelled If true withdraw only from cancelled proposals.
     */
    function withdrawStake(address _voter, bool _onlyCancelled) external {
        _withdrawStake(_voter, _onlyCancelled);
    }

    /**
     * @notice Get stake of voter `_voter` on proposal #`_proposalId`
     * @param _proposalId Proposal id
     * @param _voter Voter address
     * @return Proposal voter stake
     */
    function getProposalVoterStake(uint256 _proposalId, address _voter) public view returns (uint256) {
        return proposals[_proposalId].voterStake[_voter];
    }

    /**
     * @notice Get the total stake of voter `_voter` on all proposals
     * @param _voter Voter address
     * @return Total voter stake
     */
    function getTotalVoterStake(address _voter) public view returns (uint256) {
        return totalVoterStake[_voter];
    }

    function getSettings() public view returns (uint256 _decay, uint256 _minStakeRatio) {
        return (decay.mulu(1e18), minStakeRatio.mulu(1e18));
    }

    /**
     * @dev Get proposal details
     * @param _proposalId Proposal id
     * @return stakedTokens Current total stake of tokens on this proposal
     * @return lastRate Last rate this proposal had last checkpoint
     * @return lastTime Last time we saved a checkpoint
     * @return active True if proposal has already been executed
     * @return trigger Trigger of the proposal
     */
    function getProposal(uint256 _proposalId)
        public
        view
        returns (
            uint256 stakedTokens,
            uint256 lastRate,
            uint256 lastTime,
            bool active,
            address trigger
        )
    {
        Proposal storage proposal = proposals[_proposalId];
        return (proposal.stakedTokens, proposal.lastRate, proposal.lastTime, proposal.active, proposal.trigger);
    }

    function minStake() public view returns (uint256) {
        return minStakeRatio.mulu(totalStaked);
    }

    // TODO: Better understand how the rate is calculated. Is allright to remove the maxRatio?

    /**
     * @dev targetRate = (1 - sqrt(minStake / min(staked, minStake)))
     */
    function calculateTargetRate(uint256 _stake) public view returns (uint256 _targetRate) {
        if (_stake == 0) {
            _targetRate = 0;
        } else {
            uint256 _minStake = minStake();
            _targetRate = ONE.sub(_minStake.divu(_stake > _minStake ? _stake : _minStake).sqrt());
        }
    }

    function targetRate(uint256 _proposalId) public view returns (uint256) {
        Proposal storage proposal = proposals[_proposalId];
        return calculateTargetRate(proposal.stakedTokens);
    }

    /**
     * @notice Get current
     * @dev rate = (alpha ^ time * lastRate + _targetRate * (1 - alpha ^ time)
     */
    function calculateRate(
        uint256 _timePassed,
        uint256 _lastRate,
        uint256 _targetRate
    ) public view returns (uint256) {
        int128 at = decay.pow(_timePassed);
        return at.mulu(_lastRate).add(ONE.sub(at).mulu(_targetRate));
    }

    function rate(uint256 _proposalId) public view returns (uint256 _rate) {
        Proposal storage proposal = proposals[_proposalId];
        assert(proposal.lastTime <= block.timestamp);
        return
            _rate = calculateRate(
                block.timestamp - proposal.lastTime, // we assert it doesn't overflow above
                proposal.lastRate,
                targetRate(_proposalId)
            );
    }

    /**
     * @dev Calculate rate and store it on the proposal
     * @param _proposalId Proposal
     */
    function _saveCheckpoint(uint256 _proposalId) internal {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.lastTime == block.timestamp) {
            return; // Rate already stored
        }
        // calculateRate and store it
        proposal.lastRate = rate(_proposalId);
        proposal.lastTime = block.timestamp;
    }

    function _updateVoterStakedProposals(
        uint256 _proposalId,
        address _from,
        uint256 _amount,
        bool _support
    ) internal {
        Proposal storage proposal = proposals[_proposalId];
        EnumerableSet.UintSet storage voterStakedProposalsSet = voterStakedProposals[_from];

        if (_support) {
            stakeToken.safeTransferFrom(msg.sender, address(this), _amount);
            proposal.stakedTokens = proposal.stakedTokens.add(_amount);
            proposal.voterStake[_from] = proposal.voterStake[_from].add(_amount);
            totalVoterStake[_from] = totalVoterStake[_from].add(_amount);
            totalStaked = totalStaked.add(_amount);

            if (!voterStakedProposalsSet.contains(_proposalId)) {
                require(voterStakedProposalsSet.length() < MAX_STAKED_PROPOSALS, "MAX_PROPOSALS_REACHED");
                voterStakedProposalsSet.add(_proposalId);
            }
        } else {
            stakeToken.safeTransfer(msg.sender, _amount);
            proposal.stakedTokens = proposal.stakedTokens.sub(_amount);
            proposal.voterStake[_from] = proposal.voterStake[_from].sub(_amount);
            totalVoterStake[_from] = totalVoterStake[_from].sub(_amount);
            totalStaked = totalStaked.sub(_amount);

            if (proposal.voterStake[_from] == 0) {
                voterStakedProposalsSet.remove(_proposalId);
            }
        }
    }

    /**
     * @dev Withdraw an amount of tokens from a proposal
     * @param _proposalId Proposal id
     * @param _amount Amount of withdrawn tokens
     * @param _from Account to withdraw from
     */
    function _withdrawFromProposal(
        uint256 _proposalId,
        uint256 _amount,
        address _from
    ) internal {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.voterStake[_from] >= _amount, "WITHDRAW_MORE_THAN_STAKED");
        require(_amount > 0, "AMOUNT_CAN_NOT_BE_ZERO");

        if (proposal.active) {
            _saveCheckpoint(_proposalId);
        }

        _updateVoterStakedProposals(_proposalId, _from, _amount, false);

        emit StakeWithdrawn(
            _from,
            _proposalId,
            _amount,
            proposal.voterStake[_from],
            proposal.stakedTokens,
            proposal.lastRate
        );
    }

    function _withdrawStake(address _voter, bool _onlyCancelled) internal {
        uint256 amount;
        uint256 i;
        uint256 len = voterStakedProposals[_voter].length();
        uint256[] memory voterStakedProposalsCopy = new uint256[](len);
        for (i = 0; i < len; i++) {
            voterStakedProposalsCopy[i] = voterStakedProposals[_voter].at(i);
        }
        for (i = 0; i < len; i++) {
            uint256 proposalId = voterStakedProposalsCopy[i];
            Proposal storage proposal = proposals[proposalId];
            if (!_onlyCancelled || !proposal.active) {
                // if _onlyCancelled = true, then do not withdraw from active proposals
                amount = proposal.voterStake[_voter];
                if (amount > 0) {
                    _withdrawFromProposal(proposalId, amount, _voter);
                }
            }
        }
    }

    /**
     * @dev Support with an amount of tokens on a proposal
     * @param _proposalId Proposal id
     * @param _amount Amount of staked tokens
     * @param _from Account from which we stake
     */
    function _stakeToProposal(
        uint256 _proposalId,
        uint256 _amount,
        address _from
    ) internal {
        Proposal storage proposal = proposals[_proposalId];
        require(_amount > 0, "AMOUNT_CAN_NOT_BE_ZERO");

        uint256 unstakedAmount = stakeToken.balanceOf(_from).sub(totalVoterStake[_from]);
        if (_amount > unstakedAmount) {
            _withdrawStake(_from, true);
        }

        require(totalVoterStake[_from].add(_amount) <= stakeToken.balanceOf(_from), "STAKING_MORE_THAN_AVAILABLE");

        if (proposal.lastTime == 0) {
            proposal.lastTime = block.timestamp;
        } else {
            _saveCheckpoint(_proposalId);
        }

        _updateVoterStakedProposals(_proposalId, _from, _amount, true);

        emit StakeAdded(
            _from,
            _proposalId,
            _amount,
            proposal.voterStake[_from],
            proposal.stakedTokens,
            proposal.lastRate
        );
    }
}
