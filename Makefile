PROJECT_NAME ?= ceph-nvmeof
SUMMARY ?= Ceph NVMe over Fabrics Gateway
DESCRIPTION ?= Service to provide block storage on top of Ceph for platforms (e.g.: VMWare) without native Ceph support (RBD), replacing existing approaches (iSCSI) with a newer and more versatile standard (NVMe-oF).
URL ?= https://github.com/ceph/ceph-nvmeof
VERSION ?= 0.0.0
MAINTAINER ?= Ceph Developers <dev@ceph.io>
GIT_REPO != git remote get-url origin
GIT_BRANCH != git rev-parse --abbrev-ref HEAD
GIT_COMMIT != git rev-parse HEAD

CEPH_SPDK_BASE ?= ubi
SPDK_VERSION ?= v23.01
CEPH_VERSION ?= 17.2.6

SERVICE := ceph-nvmeof
CONTAINERS := ceph-spdk ceph-cluster $(SERVICE) $(SERVICE)-cli
PYTHON_INTERPRETER = python3
PYTHON_PACKAGE_MANAGER = pdm
DOCKER_COMPOSE = DOCKER_BUILDKIT=1 docker-compose
MAX_LOGS = 40
SERVER_ADDRESS = ceph-nvmeof
SERVER_PORT = 5500
NVMEOF_CLI := $(DOCKER_COMPOSE) run --rm $(SERVICE)-cli --server-address $(SERVER_ADDRESS) --server-port $(SERVER_PORT)

HUGEPAGES_2MB = 2048 # 4 GB
SCALE = 1
RBD_IMAGE_NAME = demo_image
RBD_IMAGE_SIZE = 10M
BDEV_NAME = demo_bdev
NQN = nqn.2016-06.io.spdk:cnode1
SERIAL = SPDK00000000000001
LISTENER_PORT = 4420

all: setup build up ps logs

build:
	$(DOCKER_COMPOSE) build \
		--build-arg NAME="$(PROJECT_NAME)" \
		--build-arg SUMMARY="$(SUMMARY)" \
		--build-arg DESCRIPTION="$(DESCRIPTION)" \
		--build-arg URL="$(URL)" \
		--build-arg VERSION="$(VERSION)" \
		--build-arg GIT_REPO="$(GIT_REPO)" \
		--build-arg GIT_BRANCH="$(GIT_BRANCH)" \
		--build-arg GIT_COMMIT="$(GIT_COMMIT)" \
		--build-arg CEPH_VERSION="$(CEPH_VERSION)" \
		--build-arg SPDK_VERSION="$(SPDK_VERSION)" \
		--force-rm \
		$(CONTAINERS)

pull:
	$(DOCKER_COMPOSE) pull

setup:
	sudo bash -c 'echo $(HUGEPAGES_2MB) > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
	cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Launch deployment
up:
	$(DOCKER_COMPOSE) up --detach --scale $(SERVICE)=$(SCALE) $(SERVICE)

ps:
	$(DOCKER_COMPOSE) ps

logs:
	$(DOCKER_COMPOSE) logs --follow --tail=$(MAX_LOGS)

# Stop deployent
stop:
	$(DOCKER_COMPOSE) stop $(SERVICE)

# Shut everything down
down:
	$(DOCKER_COMPOSE) down

alias:
	@echo alias nvmeof-cli=\"$(NVMEOF_CLI)\"

rbd:
	$(DOCKER_COMPOSE) exec ceph-cluster bash -c "rbd info $(RBD_IMAGE_NAME) || rbd create $(RBD_IMAGE_NAME) --size $(RBD_IMAGE_SIZE)"

demo: rbd
	$(NVMEOF_CLI) create_bdev --pool rbd --image $(RBD_IMAGE_NAME) --bdev $(BDEV_NAME)
	$(NVMEOF_CLI) create_subsystem --subnqn $(NQN) --serial $(SERIAL)
	$(NVMEOF_CLI) add_namespace --subnqn $(NQN) --bdev $(BDEV_NAME)
	$(NVMEOF_CLI) create_listener --subnqn $(NQN) -s $(LISTENER_PORT)
	$(NVMEOF_CLI) add_host --subnqn $(NQN) --host "*"

# Pending to implement
test:
	$(PYTHON_INTERPRETER) -m pytest

# Pending to implement
clean:
	$(PYTHON_INTERPRETER) -m $(PYTHON_PACKAGE_MANAGER) remove $(PROJECT_NAME)

.PHONY: all build pull setup up ps demo logs stop down alias rbd test clean
