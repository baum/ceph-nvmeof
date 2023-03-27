PROJECT_NAME = ceph-nvmeof
PYTHON_INTERPRETER = python3
PYTHON_PACKAGE_MANAGER = pdm
HUGEPAGES_2MB = 2048 # 4 GB
DOCKER_COMPOSE = DOCKER_BUILDKIT=1 docker-compose
MAX_LOGS = 40
SERVICE = ceph-nvmeof
SCALE = 1
NVMEOF_CLI = $(DOCKER_COMPOSE) run $(SERVICE)-cli

all: setup build up

build:
	$(DOCKER_COMPOSE) build ceph-spdk ceph-cluster $(SERVICE) $(SERVICE)-cli

setup:
	sudo bash -c 'echo $(HUGEPAGES_2MB) > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages'
	cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
	alias nvmeof-cli="$(DOCKER_COMPOSE) run $(SERVICE)-cli"

# Launch deployment
up:
	$(DOCKER_COMPOSE) up --detach --scale $(SERVICE)=$(SCALE) $(SERVICE)

demo:
	$(DOCKER_COMPOSE) exec ceph-cluster rbd create demo_image --size 10M
	$(NVMEOF_CLI) create_bdev -p rbd -i demo_image

logs:
	$(DOCKER_COMPOSE) logs --follow --tail=$(MAX_LOGS)

# Stop deployent
stop:
	$(DOCKER_COMPOSE) stop $(SERVICE)

# Shut everything down
down:
	$(DOCKER_COMPOSE) down

# Pending to implement
test:
	$(PYTHON_INTERPRETER) -m pytest

# Pending to implement
clean:
	$(PYTHON_INTERPRETER) -m $(PYTHON_PACKAGE_MANAGER) remove $(PROJECT_NAME)

.PHONY: all build setup up demo logs stop down test clean
