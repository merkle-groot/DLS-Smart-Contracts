import time
import pytest
from brownie import accounts, Lotto, convert, network, config, USDC, reverts, chain
from scripts.helpful_scripts import (
    get_account,
    get_contract,
    LOCAL_BLOCKCHAIN_ENVIRONMENTS,
    listen_for_event,
)

from scripts.vrf_scripts.create_subscription import (
    create_subscription,
    fund_subscription,
)


@pytest.fixture(scope="module")
def init_lotto():
    # Get the account 0
    account = get_account()

    # Create a subscription
    subscription_id = create_subscription()

    # Fund the subscription with Chainlink
    fund_subscription(subscription_id=subscription_id)

    # Set the gas lane
    gas_lane = config["networks"][network.show_active()][
        "gas_lane"
    ]  # Also known as keyhash

    # deploy vrf coordinator contract
    vrf_coordinator = get_contract("vrf_coordinator")
    # deployt link token contract
    link_token = get_contract("link_token")
    usdc_token = USDC.deploy({"from": get_account(0)})
    lotto = Lotto.deploy(
        usdc_token.address,
        10*10**18,
        subscription_id,
        vrf_coordinator,
        link_token,
        gas_lane,  # Also known as keyhash
        {"from": get_account(0)},
    )

    return usdc_token, lotto, vrf_coordinator


def test_buy_ticket_revert_0_usdc_balance(init_lotto):
    _, lotto, _ = init_lotto

    with reverts("ERC20: transfer amount exceeds balance"):
        lotto.buyTicket(1, 1, {"from": get_account(1)})

    result = lotto.holderToLotteryTicket(get_account(1))
    assert result == (0, 0)


def test_buy_ticket_revert_0_approval(init_lotto):
    usdc_token, lotto, _ = init_lotto

    # Mint tokens for the user
    usdc_token.mint(get_account(1), 20*10**18, {"from": get_account(0)})

    with reverts("ERC20: transfer amount exceeds allowance"):
        lotto.buyTicket(1, 1, {"from": get_account(1)})

    result = lotto.holderToLotteryTicket(get_account(1))
    assert result == (0, 0)


def test_buy_ticket_revert_invalid_series(init_lotto):
    usdc_token, lotto, _ = init_lotto

    # Set approval for the contract
    usdc_token.approve(lotto.address, 10*10**18, {"from": get_account(1)})

    with reverts("Invalid series"):
        lotto.buyTicket(0, 1, {"from": get_account(1)})

    with reverts("Invalid series"):
        lotto.buyTicket(6, 1, {"from": get_account(1)})

    result = lotto.holderToLotteryTicket(get_account(1))
    assert result == (0, 0)


def test_buy_ticket_revert_invalid_ticket_number(init_lotto):
    usdc_token, lotto, _ = init_lotto

    with reverts("Invalid ticket number"):
        lotto.buyTicket(1, 0, {"from": get_account(1)})

    with reverts("Invalid ticket number"):
        lotto.buyTicket(1, 2001, {"from": get_account(1)})

    result = lotto.holderToLotteryTicket(get_account(1))
    assert result == (0, 0)


def test_buy_ticket_successfully(init_lotto):
    _, lotto, _ = init_lotto

    lotto.buyTicket(1, 1, {"from": get_account(1)})

    ticketBought = lotto.holderToLotteryTicket(get_account(1))
    assert ticketBought == (1, 1)

    ticketOwner = lotto.lotteryTicketToHolder(1, 1)
    assert ticketOwner == get_account(1).address


def test_buy_ticket_revert_already_owned(init_lotto):
    _, lotto, _ = init_lotto

    with reverts("Ticket already bought"):
        lotto.buyTicket(1, 2, {"from": get_account(1)})

    with reverts("Ticket already bought"):
        lotto.buyTicket(1, 1, {"from": get_account(2)})

    ticketBought = lotto.holderToLotteryTicket(get_account(1))
    assert ticketBought == (1, 1)

    ticketOwner = lotto.lotteryTicketToHolder(1, 1)
    assert ticketOwner == get_account(1).address

    ticketBought = lotto.holderToLotteryTicket(get_account(2))
    assert ticketBought == (0, 0)


def test_transition_to_cash_out_period_revert(init_lotto):
    _, lotto, _ = init_lotto

    with reverts("Time period of buying period hasn't passed yet"):
        lotto.transitionToCashOutPeriod()

    assert lotto.state() == 0


def test_transition_to_cash_out_period(init_lotto):
    _, lotto, vrf_coordinator = init_lotto
    # Fast forward time
    chain.sleep(24*7*60*60)

    # Fast Forward to cash out period
    tx = lotto.transitionToCashOutPeriod()
    request_id = tx.events[0]["requestId"]
    tx1 = vrf_coordinator.fulfillRandomWords(
        request_id, lotto.address, {"from": get_account()}
    )

    assert lotto.state() == 1
    assert lotto.epochToPrizePool(0) == 10*10**18

    assert lotto.drawnNumbers(0) == (1, 735)


def test_transition_to_buy_period_revert(init_lotto):
    _, lotto, vrf_coordinator = init_lotto

    with reverts("Time period of cash-out period hasn't passed yet"):
        lotto.transitionToBuyPeriod()

    assert lotto.state() == 1


def test_transition_to_buy_period(init_lotto):
    _, lotto, vrf_coordinator = init_lotto

    # Fast forward time
    chain.sleep(24*2*60*60)

    # Fast Forward to cash out period
    lotto.transitionToBuyPeriod()

    assert lotto.state() == 0
    assert lotto.currentEpoch() == 1


def test_buy_ticket_successfully_1(init_lotto):
    usdc_token, lotto, _ = init_lotto

    # Mint tokens for the user
    usdc_token.mint(get_account(2), 20*10**18, {"from": get_account(0)})
    usdc_token.mint(get_account(3), 20*10**18, {"from": get_account(0)})
    usdc_token.mint(get_account(4), 20*10**18, {"from": get_account(0)})
    usdc_token.mint(get_account(5), 20*10**18, {"from": get_account(0)})

    # Set approval for the contract
    usdc_token.approve(lotto.address, 10*10**18, {"from": get_account(2)})
    usdc_token.approve(lotto.address, 10*10**18, {"from": get_account(3)})
    usdc_token.approve(lotto.address, 10*10**18, {"from": get_account(4)})
    usdc_token.approve(lotto.address, 10*10**18, {"from": get_account(5)})

    lotto.buyTicket(1, 1156, {"from": get_account(2)})
    lotto.buyTicket(2, 1156, {"from": get_account(3)})
    lotto.buyTicket(1, 156, {"from": get_account(4)})
    lotto.buyTicket(4, 348, {"from": get_account(5)})

    ticketBought1 = lotto.holderToLotteryTicket(get_account(2))
    assert ticketBought1 == (1, 1156)

    ticketBought2 = lotto.holderToLotteryTicket(get_account(3))
    assert ticketBought2 == (2, 1156)

    ticketBought3 = lotto.holderToLotteryTicket(get_account(4))
    assert ticketBought3 == (1, 156)


def test_transition_to_cash_out_period_1(init_lotto):
    _, lotto, vrf_coordinator = init_lotto
    # Fast forward time
    chain.sleep(24*7*60*60)

    # Fast Forward to cash out period
    tx = lotto.transitionToCashOutPeriod()
    request_id = tx.events[0]["requestId"]
    vrf_coordinator.fulfillRandomWords(
        request_id, lotto.address, {"from": get_account()}
    )

    assert lotto.state() == 1
    assert lotto.epochToPrizePool(0) == 10*10**18

    assert lotto.drawnNumbers(0) == (1, 735)


def test_cashouts_not_winner(init_lotto):
    usdc_token, lotto, _ = init_lotto

    assert usdc_token.balanceOf(get_account(5)) == 10*10**18

    lotto.cashOut({"from": get_account(5)})

    assert usdc_token.balanceOf(get_account(5)) == 10*10**18


def test_cashouts_4_digits_matched_winner(init_lotto):
    usdc_token, lotto, _ = init_lotto

    assert usdc_token.balanceOf(lotto) == 50*10**18
    assert usdc_token.balanceOf(get_account(3)) == 10*10**18

    lotto.cashOut({"from": get_account(3)})

    assert usdc_token.balanceOf(lotto) == 48*10**18
    assert usdc_token.balanceOf(get_account(3)) == 12*10**18


def test_cashouts_4_digits_matched_winner_again_revert(init_lotto):
    _, lotto, _ = init_lotto

    with reverts("User doesn't hold a ticket"):
        lotto.cashOut({"from": get_account(3)})


def test_cashouts_3_digits_matched_winner(init_lotto):
    usdc_token, lotto, _ = init_lotto

    assert usdc_token.balanceOf(lotto) == 48*10**18
    assert usdc_token.balanceOf(get_account(4)) == 10*10**18

    tx = lotto.cashOut({"from": get_account(4)})

    assert usdc_token.balanceOf(lotto) == 47*10**18
    assert usdc_token.balanceOf(get_account(4)) == 11*10**18


def test_cashouts_full_digits_matched_winner(init_lotto):
    usdc_token, lotto, _ = init_lotto

    assert usdc_token.balanceOf(lotto) == 47*10**18
    assert usdc_token.balanceOf(get_account(2)) == 10*10**18

    lotto.cashOut({"from": get_account(2)})

    assert usdc_token.balanceOf(lotto) == 10*10**18
    assert usdc_token.balanceOf(get_account(2)) == 45*10**18

    assert lotto.state() == 2


def test_claw_back_remaining_funds_revert_invalid_time(init_lotto):
    usdc_token, lotto, _ = init_lotto

    with reverts("Time period of cash-out period hasn't passed yet"):
        lotto.clawBackRemainingfunds()


def test_claw_back_remaining_funds(init_lotto):
    usdc_token, lotto, _ = init_lotto

    # Fast forward time
    chain.sleep(24*2*60*60)

    assert usdc_token.balanceOf(get_account(0)) == 2 * 10**18
    lotto.clawBackRemainingfunds()
    assert usdc_token.balanceOf(get_account(0)) == 12 * 10**18
