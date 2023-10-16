import pytest
import time
import json
import logging
from control.server import GatewayServer
from control.cli import main as cli
from control.cli import GatewayClient
from control.proto import gateway_pb2 as pb2

# Set up a logger
logger = logging.getLogger(__name__)
image = "mytestdevimage"
pool = "rbd"
bdev_prefix = "Ceph0"
subsystem_prefix = "nqn.2016-06.io.spdk:cnode"
created_resource_count = 150
get_subsys_count = 1000

def get_subsystems():
    client = GatewayClient()
    parsed_args = client.cli.parser.parse_args(["get_subsystems"])
    server_address = parsed_args.server_address
    server_port = parsed_args.server_port
    client_key = parsed_args.client_key
    client_cert = parsed_args.client_cert
    server_cert = parsed_args.server_cert
    client.connect(server_address, server_port, client_key, client_cert, server_cert)
    req = pb2.get_subsystems_req()
    ret = client.stub.get_subsystems(req)
    return json.loads(ret.subsystems)

def create_resource_by_index(i):
    bdev = f"{bdev_prefix}_{i}"
    cli(["create_bdev", "-i", image, "-p", pool, "-b", bdev])
    subsystem = f"{subsystem_prefix}{i}"
    cli(["create_subsystem", "-n", subsystem ])
    cli(["add_namespace", "-n", subsystem, "-b", bdev])

@pytest.mark.filterwarnings("error::pytest.PytestUnhandledThreadExceptionWarning")
def test_create_get_subsys(caplog, config):
    with GatewayServer(config) as gateway:
        gateway.serve()

        for i in range(created_resource_count):
            create_resource_by_index(i)
            assert "Failed" not in caplog.text

    caplog.clear()

    # restart the gateway here
    with GatewayServer(config) as gateway:
        gateway.serve()
        subsystems = None

        for i in range(get_subsys_count):
            subsystems = get_subsystems()
            assert "Exception" not in caplog.text
            assert "Failed" not in caplog.text
            time.sleep(0) # yield to update thread
            nsubsystems = len(subsystems)
            logger.info(f"number of sysbsystems {nsubsystems=}")
            if nsubsystems == created_resource_count:
                break
            
        assert(len(subsystems) == created_resource_count)
