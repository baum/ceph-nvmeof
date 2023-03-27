# syntax = docker/dockerfile:1.4
ARG SPDK_RELEASE=latest
FROM ceph/spdk:$SPDK_RELEASE AS base

# TODO: Pending of SPDK no-hugepages (non-root) support
#ARG UNAME=ceph \
#    UID=167 \
#    GID=167

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

#RUN groupadd -g $GID -o $UNAME
#RUN useradd -m -u $UID -g $GID -d /var/lib/ceph -o -s /sbin/nologin $UNAME

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
COPY pyproject.toml pdm.lock pdm.toml ./
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

ENTRYPOINT ["python3", "-m", "control", "-c", "ceph-nvmeof.conf"]

#==============================================================================
FROM ceph-nvmeof AS ceph-nvmeof-cli

ENTRYPOINT ["python3", "-m", "control.cli"]
