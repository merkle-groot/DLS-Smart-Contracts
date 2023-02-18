// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.6.2 <0.9.0;

import {IERC20} from "./IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

contract Lotto is VRFConsumerBaseV2{
    struct LotteryTicket {
        uint256 series;
        uint256 ticketNumber;
    }
    uint256 public lastTimestamp;
    uint256 public state;
    uint256 public currentEpoch;
    uint256 public noOfTicketsBought;
    address public immutable owner;
    uint256 public constant noOfSeries = 5;
    uint256 public immutable noOfTicketsPerSeries = 2000;
    address public immutable token;
    uint256 public immutable ticketCost;
    mapping(uint256 => mapping(uint256 => address))
        public lotteryTicketToHolder;
    mapping(address => LotteryTicket) public holderToLotteryTicket;
    mapping(uint256 => uint256) public epochToPrizePool;
    mapping(uint256 => LotteryTicket) public drawnNumbers;

    // solidity
    VRFCoordinatorV2Interface immutable COORDINATOR;
    LinkTokenInterface immutable LINKTOKEN;

    uint64 immutable s_subscriptionId;
    bytes32 immutable s_keyHash;
    uint32 immutable s_callbackGasLimit = 100000;
    uint16 immutable s_requestConfirmations = 3;
    uint32 immutable s_numWords = 2;
    uint256[] public s_randomWords;
    uint256 public s_requestId;

    event Log(string message, uint data);

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

    function buyTicket(uint256 series_, uint256 ticketNumber_) external {
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

        IERC20(token).transferFrom(msg.sender, address(this), ticketCost);

        lotteryTicketToHolder[series_][ticketNumber_] = msg.sender;
        holderToLotteryTicket[msg.sender] = LotteryTicket(series_,ticketNumber_);
    }

    function transitionToCashOutPeriod() external {
        require(state == 0 && block.timestamp >= lastTimestamp + 7 days, "Time period of buying period hasn't passed yet");
        // increment state
        state++;
        lastTimestamp = block.timestamp;

        // record the pool funds
        epochToPrizePool[currentEpoch] = IERC20(token).balanceOf(address(this));

        // Request for randomness
        requestRandomWords();
    }

    function transitionToBuyPeriod() external {
        require(state == 1 && block.timestamp >= lastTimestamp + 2 days, "Time period of cash-out period hasn't passed yet");
        // increment state
        state = 0;
        lastTimestamp = block.timestamp;
        currentEpoch++;
    }

    function clawBackRemainingfunds() external {
        require(state == 2, "Invalid state");
        require(block.timestamp >= lastTimestamp + 2 days, "Time period of cash-out period hasn't passed yet");

        uint256 poolBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner, poolBalance);
    }

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
            return;
        }
        IERC20(token).transfer(msg.sender, userPayout);

        if (ownerPayout != 0) {
            IERC20(token).transfer(owner, ownerPayout);
        }

        lotteryTicketToHolder[userTicket.series][
            userTicket.ticketNumber
        ] = address(0);

        userTicket.series = 0;
        userTicket.ticketNumber = 0;
    }

    
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


    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 selectedSeries = randomWords[0] % 5;
        uint256 selectedTicketNumber = randomWords[1] % 2001;

        drawnNumbers[currentEpoch] = LotteryTicket(selectedSeries, selectedTicketNumber);
    }
}
