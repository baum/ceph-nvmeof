# syntax = docker/dockerfile:1.4
FROM ceph/spdk-ubi9 AS base

ARG SUMMARY="" \
    DESCRIPTION="" \
    NAME="ceph-nvmeof" \
    VERSION="" \
    MAINTAINER="Ceph Developers <dev@ceph.io>" \
    UNAME=ceph \
    UID=167 \
    GID=167

LABEL summary="$SUMMARY" \
      description="$DESCRIPTION" \
      name="$NAME" \
      version="$VERSION" \
      maintainer="$MAINTAINER"

ENV PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=off \
    PYTHON_MAJOR=3 \
    PYTHON_MINOR=9 \
    PDM_ONLY_BINARY=:all:

ARG PYTHON_MODULE=control
ENV PYTHONPATH=/src/$PYTHON_MODULE/proto:/src/__pypackages__/$PYTHON_MAJOR.$PYTHON_MINOR/lib

RUN dnf install -y python3-rados

RUN groupadd -g $GID -o $UNAME
RUN useradd -m -u $UID -g $GID -d /var/lib/ceph -o -s /sbin/nologin $UNAME


#==============================================================================
FROM base AS builder

ENV PDM_SYNC_FLAGS="-v --no-isolation --no-self --no-editable"

# https://pdm.fming.dev/latest/usage/advanced/#use-pdm-in-a-multi-stage-dockerfile
RUN dnf install -y python3-pip
RUN pip install -U pip setuptools

# TODO: uncomment when SPDK supports non-hugepage (non-root)
#USER $UNAME
WORKDIR /src

RUN pip install --user pdm
#COPY --chown=ceph:ceph pyproject.toml pdm.lock pdm.toml .
COPY pyproject.toml pdm.lock pdm.toml .
#COPY --chown=ceph:ceph control/proto control/proto
COPY control/proto control/proto
RUN ~/.local/bin/pdm sync $PDM_SYNC_FLAGS
#RUN ~/.local/bin/pdm run protoc
COPY . .

#==============================================================================
FROM base AS ceph-nvmeof

# TODO: uncomment when SPDK supports non-hugepage (non-root)
#USER $UNAME
WORKDIR /src
COPY --from=builder /src .

ENTRYPOINT ["python3", "-m", "control", "-c", "ceph-nvmeof.conf"]

#==============================================================================
FROM ceph-nvmeof AS ceph-nvmeof-cli


ENTRYPOINT ["python3", "-m", "control.cli"]
