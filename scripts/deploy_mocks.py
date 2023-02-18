from brownie import USDC, Lotto, accounts
from scripts.helpful_scripts import get_account


def main():
    usdc_token = USDC.deploy({'from': get_account(0)})
    Lotto.deploy(
        usdc_token.address,
        10*10**18,
        54,
        "0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625",
        "0x779877A7B0D9E8603169DdbD7836e478b4624789",
        "0x474e34a077df58807dbe9c96d3c009b23b3c6d0cce433e59bbf5b34f823bc56c",
        {'from': get_account(0)}  # Also
    )