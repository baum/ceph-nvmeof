import pytest
import time
from control.server import GatewayServer
from control.cli import main as cli
import logging
import warnings

# Set up a logger
logger = logging.getLogger(__name__)
image = "mytestdevimage"
pool = "rbd"
bdev_prefix = "Ceph0"
subsystem_prefix = "nqn.2016-06.io.spdk:cnode"
created_resource_count = 150
get_subsys_count = 20

def create_resource_by_index(i):
    bdev = f"{bdev_prefix}_{i}"
    cli(["create_bdev", "-i", image, "-p", pool, "-b", bdev])
    subsystem = f"{subsystem_prefix}{i}"
    cli(["create_subsystem", "-n", subsystem ])
    cli(["add_namespace", "-n", subsystem, "-b", bdev])

@pytest.mark.filterwarnings("error::pytest.PytestUnhandledThreadExceptionWarning")
def test_create_get_subsys(caplog, config):
    with GatewayServer(config) as gateway:
        time.sleep(1)
        gateway.serve()

        for i in range(created_resource_count):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

        gateway.server.stop(grace=1)

    time.sleep(2)
    caplog.clear()

    # restart the gateway here
    with GatewayServer(config) as gateway:
        time.sleep(1)
        gateway.serve()

        for i in range(get_subsys_count):
            cli(["get_subsystems"])
            assert "Exception" not in caplog.text
            time.sleep(1)

        time.sleep(10)
