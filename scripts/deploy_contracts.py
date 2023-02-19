from brownie import USDC, Lotto, network, config
from scripts.helpful_scripts import get_account


def main():
    # deploy USDC token
    usdc_token = USDC.deploy({'from': get_account(0)})
    # deploy main lottery contract
    Lotto.deploy(
        # Token used for payment
        usdc_token.address,
        # ticket cost
        10*10**18,
        # update the sub_id here
        3382,
        # VRF coordinator
        config["networks"][network.show_active()]["vrf_coordinator"],
        # Link token
        config["networks"][network.show_active()]["link_token"],
        # keyHash
        config["networks"][network.show_active()]["keyhash"],
        {'from': get_account(0)}  # Also
    )
