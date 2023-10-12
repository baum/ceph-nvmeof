import pytest
from control.server import GatewayServer
from control.cli import main as cli
import logging

# Set up a logger
logger = logging.getLogger(__name__)
image = "mytestdevimage"
pool = "rbd"
bdev_prefix = "Ceph0"
subsystem_prefix = "nqn.2016-06.io.spdk:cnode"

def create_resource_by_index(i):
    bdev = f"{bdev_prefix}_{i}"
    cli(["create_bdev", "-i", image, "-p", pool, "-b", bdev])
    subsystem = f"{subsystem_prefix}{i}"
    cli(["create_subsystem", "-n", subsystem ])
    cli(["add_namespace", "-n", subsystem, "-b", bdev])

def test_create_update(caplog, config):
    with GatewayServer(config) as gateway:
        gateway.serve()

        for i in range(1000):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

        gateway.server.stop(grace=1)

    # restart the gateway here
    with GatewayServer(config) as gateway:
        gateway.serve()
        for i in range(1000, 2000):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

        text_before = caplog.text
        logger.info(f"{text_before=}")
        cli_output = cli(["get_subsystems"])

        logger.info(f"{cli_output=}")
        text_after = caplog.text
        logger.info(f"{text_after=}")
