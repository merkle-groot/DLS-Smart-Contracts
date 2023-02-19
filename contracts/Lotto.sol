// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract Lotto is VRFConsumerBaseV2{
    struct LotteryTicket {
        uint64 series;
        uint192 ticketNumber;
    }

    // Addresses
    address public immutable owner;
    address public immutable token;

    // Lotto config
    uint256 public immutable ticketCost;
    uint64 public constant noOfSeries = 5;
    uint192 public constant noOfTicketsPerSeries = 2000;

    // Lotto state
    uint256 public lastTimestamp;
    uint64 public state;
    uint192 public currentEpoch;

    mapping(uint64 => mapping(uint192 => address))
        public lotteryTicketToHolder;
    mapping(address => LotteryTicket) public holderToLotteryTicket;
    mapping(uint256 => uint256) public epochToPrizePool;
    mapping(uint256 => LotteryTicket) public drawnNumbers;

    // Interfaces to interact with chainlink
    VRFCoordinatorV2Interface immutable COORDINATOR;
    LinkTokenInterface immutable LINKTOKEN;

    // Chainlink config
    uint64 immutable s_subscriptionId;
    bytes32 immutable s_keyHash;
    uint32 constant s_callbackGasLimit = 100000;
    uint16 constant s_requestConfirmations = 3;
    uint32 constant s_numWords = 2;
    uint256 public s_requestId;

    constructor(address token_, uint256 ticketCost_,  uint64 _subscriptionId, address _vrfCoordinator, address _linkToken, bytes32 _keyhash
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        lastTimestamp = block.timestamp;
        owner = msg.sender;
        token = token_;
        ticketCost = ticketCost_;

        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        LINKTOKEN = LinkTokenInterface(_linkToken);
        s_keyHash = _keyhash;
        s_subscriptionId = _subscriptionId;
    }

    /// @notice Buys a ticket of the given series and ticketNumber
    /// @dev It reverts if it's in a wrong state, invalid series/ticketNumber provided or 
    ///      the ticket is already bought/user already has another ticket
    /// @param series_ The series of the ticket to be bought
    /// @param ticketNumber_ The ticketNumber to be bought
    function buyTicket(uint64 series_, uint192 ticketNumber_) external {
        require(state == 0, "Invalid state");
        require(series_ < noOfSeries && series_ != 0, "Invalid series");
        require(
            ticketNumber_ < noOfTicketsPerSeries && ticketNumber_ != 0,
            "Invalid ticket number"
        );
        require(
            lotteryTicketToHolder[series_][ticketNumber_] == address(0) &&
                holderToLotteryTicket[msg.sender].ticketNumber == 0,
            "Ticket already bought"
        );
        // Collect the ticketCost from the user
        IERC20(token).transferFrom(msg.sender, address(this), ticketCost);

        // Update state
        lotteryTicketToHolder[series_][ticketNumber_] = msg.sender;
        holderToLotteryTicket[msg.sender] = LotteryTicket(series_,ticketNumber_);
    }
    /// @notice Function to switch to cashoutPeriod after a buyPeriod
    /// @dev This function is to be called after the 7 days of buyPeriod
    function transitionToCashOutPeriod() external {
        require(state == 0 && block.timestamp >= lastTimestamp + 7 days, "Time period of buying period hasn't passed yet");
        // increment state
        state++;

        // update the last timestamp
        lastTimestamp = block.timestamp;
        // record the pool funds
        epochToPrizePool[currentEpoch] = IERC20(token).balanceOf(address(this));

        // Request for randomness
        requestRandomWords();
    }

    /// @notice Function to switch to BuyPeriod after a cashoutPeriod
    /// @dev This function is to be called if there isn't a full match in a cashoutPeriod; It restarts the lottery process
    function transitionToBuyPeriod() external {
        require(state == 1 && block.timestamp >= lastTimestamp + 2 days, "Time period of cash-out period hasn't passed yet");
        // Reset the state
        state = 0;
        // update lastTimestamp and epoch
        lastTimestamp = block.timestamp;
        currentEpoch++;
    }


    /// @notice Function to be called after the contract reaches state 2, i.e there's a full match and the lottery process is over;
    /// @dev It sends the unclaimed funds back to the owner
    function clawBackRemainingfunds() external {
        require(state == 2, "Invalid state");
        require(block.timestamp >= lastTimestamp + 2 days, "Time period of cash-out period hasn't passed yet");
        
        // Get the pool balance
        uint256 poolBalance = IERC20(token).balanceOf(address(this));
        // Send the entire funds to the owner
        IERC20(token).transfer(owner, poolBalance);
    }

    /// @notice Function to be called by a lottery holder to claim their winnings
    /// @dev If the user isn't eligible for winning; the function reverts
    function cashOut() external {
        // Get the winning ticket and user ticket of the current epoch
        LotteryTicket memory seriesWinner = drawnNumbers[currentEpoch];
        LotteryTicket storage userTicket = holderToLotteryTicket[msg.sender];
        require(state == 1 || state == 2, "Invalid state");
        require(seriesWinner.ticketNumber != 0, "Winner not drawn yet");
        require(userTicket.ticketNumber != 0, "User doesn't hold a ticket");
        
        uint256 totalPrizePool = epochToPrizePool[currentEpoch];
        uint256 userPayout = 0;
        uint256 ownerPayout = 0;
        if (seriesWinner.ticketNumber == userTicket.ticketNumber) {
            if (seriesWinner.series == userTicket.series) {
                // If the tickets match fully
                state = 2;
                // Give user 70% of the pool
                userPayout = (totalPrizePool * 70) / 100;
                // Give the owner 4% of the pool
                ownerPayout = (totalPrizePool * 4) / 100;
            } else {
                // If the last four numbers match
                // Give user 4% of the pool
                userPayout = (totalPrizePool * 4) / 100;
            }
        } else if (
            seriesWinner.ticketNumber % 1000 == userTicket.ticketNumber % 1000
        ) {
            // If the last three numbers match
            // Give user 2% of the pool
            userPayout = uint(totalPrizePool * 2) / 100;
        } else {
            // If no numbers match
            revert("Not eligible");
        }
        // Send the funds won by the user
        IERC20(token).transfer(msg.sender, userPayout);

        // If it's a full match send 4% to the owner
        if (ownerPayout != 0) {
            IERC20(token).transfer(owner, ownerPayout);
        }

        // Remove the lottery from user's holding
        lotteryTicketToHolder[userTicket.series][
            userTicket.ticketNumber
        ] = address(0);

        userTicket.series = 0;
        userTicket.ticketNumber = 0;
    }

    /// @notice Internal function called by the cashoutPeriod() to request randomness from chainlink
    function requestRandomWords() internal {
        // Will revert if subscription is not set and funded.
        s_requestId = COORDINATOR.requestRandomWords(
            s_keyHash,
            s_subscriptionId,
            s_requestConfirmations,
            s_callbackGasLimit,
            s_numWords
        );
    }

    /// @notice Internal function called by the ChainLink contracts to select the winning ticket
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint64 selectedSeries = uint64(randomWords[0] % 5);
        uint192 selectedTicketNumber = uint192(randomWords[1] % 2001);

        drawnNumbers[currentEpoch] = LotteryTicket(selectedSeries, selectedTicketNumber);
    }
}


