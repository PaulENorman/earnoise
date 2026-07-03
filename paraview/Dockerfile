FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

ARG PARAVIEW_VERSION=6.1.1
ARG PARAVIEW_SERIES=6.1
ARG PARAVIEW_ARCHIVE=ParaView-6.1.1-MPI-Linux-Python3.12-x86_64.tar.gz

ENV PARAVIEW_ROOT=/opt/paraview
ENV PARAVIEW_HOME=${PARAVIEW_ROOT}/ParaView-${PARAVIEW_VERSION}
ENV PATH=${PARAVIEW_HOME}/bin:${PATH}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libgl1 \
    libglib2.0-0 \
    libglu1-mesa \
    libgomp1 \
    libsm6 \
    libxcursor1 \
    libxext6 \
    libxi6 \
    libxinerama1 \
    libxkbcommon-x11-0 \
    libxrandr2 \
    libxrender1 \
    tar \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${PARAVIEW_ROOT}" \
    && curl -fL "https://www.paraview.org/files/v${PARAVIEW_SERIES}/${PARAVIEW_ARCHIVE}" -o "/tmp/${PARAVIEW_ARCHIVE}" \
    && tar -xzf "/tmp/${PARAVIEW_ARCHIVE}" -C "${PARAVIEW_ROOT}" \
    && mv "${PARAVIEW_ROOT}/ParaView-${PARAVIEW_VERSION}-MPI-Linux-Python3.12-x86_64" "${PARAVIEW_HOME}" \
    && rm -f "/tmp/${PARAVIEW_ARCHIVE}"

WORKDIR /cases

CMD ["pvserver", "--server-port=11111"]
