# syntax = docker/dockerfile:1.4

ARG SPDK_VERSION=NULL
ARG TARGET=gateway # either: 'gateway' or 'cli'
#==============================================================================
# Base image for TARGET=gateway (nvmeof-gateway)
FROM quay.io/ceph/spdk:${SPDK_VERSION?} AS base-gateway
ENV PYTHON_MODULE="control"
RUN dnf install -y python3-rados
CMD ["-c ceph-nvmeof.conf"]

#==============================================================================
# Base image for TARGET=cli (nvmeof-cli)
FROM registry.access.redhat.com/ubi9/ubi AS base-cli
ENV PYTHON_MODULE="control.cli"

#==============================================================================
# Intermediate layer for Python set-up
FROM base-$TARGET AS python-intermediate

ENV PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=off \
    PYTHON_MAJOR=3 \
    PYTHON_MINOR=9 \
    PDM_ONLY_BINARY=:all:

ARG APPDIR=/src

ARG NAME \
    SUMMARY \
    DESCRIPTION \
    URL \
    VERSION \
    MAINTAINER \
    GIT_REPO \
    GIT_BRANCH \
    GIT_COMMIT

LABEL io.ceph.component="$NAME" \
      io.ceph.summary="$SUMMARY" \
      io.ceph.description="$DESCRIPTION" \
      io.ceph.url="$URL" \
      io.ceph.version="$VERSION" \
      io.ceph.maintainer="$MAINTAINER" \
      io.ceph.git.repo="$GIT_REPO" \
      io.ceph.git.branch="$GIT_BRANCH" \
      io.ceph.git.commit="$GIT_COMMIT"

ENV PYTHONPATH=$APPDIR/control/proto:$APPDIR/__pypackages__/$PYTHON_MAJOR.$PYTHON_MINOR/lib

WORKDIR $APPDIR

#==============================================================================
FROM python-intermediate AS builder

ENV PDM_SYNC_FLAGS="-v --no-isolation --no-self --no-editable"

# https://pdm.fming.dev/latest/usage/advanced/#use-pdm-in-a-multi-stage-dockerfile
RUN dnf install -y python3-pip
RUN pip install -U pip setuptools

RUN pip install --user pdm
COPY pyproject.toml pdm.lock pdm.toml ./
COPY control/proto control/proto
RUN ~/.local/bin/pdm sync $PDM_SYNC_FLAGS

COPY . .

#==============================================================================
FROM python-intermediate
COPY --from=builder $APPDIR .
ENTRYPOINT python3 -m $PYTHON_MODULE
