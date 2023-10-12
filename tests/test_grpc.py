import pytest
import time
from control.server import GatewayServer
from control.state import OmapGatewayState
from control.cli import main as cli
import logging

# Set up a logger
logger = logging.getLogger(__name__)
image = "mytestdevimage"
pool = "rbd"
bdev_prefix = "Ceph0"
subsystem_prefix = "nqn.2016-06.io.spdk:cnode"

@pytest.fixture
def cleanup_omap_state(config):
    logger.info("Delete omap state before test.")
    OmapGatewayState(config).delete_state()

    yield

    logger.info("Delete omap state after test.")
    OmapGatewayState(config).delete_state()

def create_resource_by_index(i):
    bdev = f"{bdev_prefix}_{i}"
    cli(["create_bdev", "-i", image, "-p", pool, "-b", bdev])
    subsystem = f"{subsystem_prefix}{i}"
    cli(["create_subsystem", "-n", subsystem ])
    cli(["add_namespace", "-n", subsystem, "-b", bdev])

# should be uncommented when omap exclusive_lock is implemented
# def test_create_update(cleanup_omap_state, caplog, config):
#     with GatewayServer(config) as gateway:
#         gateway.serve()

#         for i in range(1000):
#             create_resource_by_index(i)
#             assert "Failed" not in caplog.text

#     # restart the gateway here
#     with GatewayServer(config) as gateway:
#         gateway.serve()
#         for i in range(1000, 2000):
#             create_resource_by_index(i)
#             assert "Failed" not in caplog.text

#         text_before = caplog.text
#         logger.info(f"{text_before=}")
#         cli_output = cli(["get_subsystems"])

#         logger.info(f"{cli_output=}")
#         text_after = caplog.text
#         logger.info(f"{text_after=}")

def test_create_wait_update(cleanup_omap_state, caplog, config):
    with GatewayServer(config) as gateway:
        gateway.serve()

        for i in range(1000):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

    # restart the gateway here
    with GatewayServer(config) as gateway:
        gateway.serve()
        # wait, to allow omap update
        time.sleep(60)
        for i in range(1000, 2000):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

        for i in range(1000):
            text_before = caplog.text
            logger.info(f"{text_before=}")
            cli_output = cli(["get_subsystems"])
            assert "Failed" not in caplog.text

            logger.info(f"{cli_output=}")
            text_after = caplog.text
            logger.info(f"{text_after=}")

def test_create_check(cleanup_omap_state, caplog, config):
    with GatewayServer(config) as gateway:
        gateway.serve()

        for i in range(1000):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

    # restart the gateway here
    with GatewayServer(config) as gateway:
        gateway.serve()

        for i in range(1000):
            text_before = caplog.text
            logger.info(f"{text_before=}")
            cli_output = cli(["get_subsystems"])
            assert "Failed" not in caplog.text

            logger.info(f"{cli_output=}")
            text_after = caplog.text
            logger.info(f"{text_after=}")
