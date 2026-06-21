FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

ARG OPENFOAM_VERSION=2506
ARG OPENFOAM_PACKAGE_VERSION=2506.260127-1

ENV OPENFOAM_DIR=/usr/lib/openfoam/openfoam${OPENFOAM_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    less \
    nano \
    rsync \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://dl.openfoam.com/add-debian-repo.sh | bash \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        openfoam${OPENFOAM_VERSION}-default=${OPENFOAM_PACKAGE_VERSION} \
    && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' "source ${OPENFOAM_DIR}/etc/bashrc" > /etc/profile.d/openfoam.sh \
    && printf '%s\n' "source ${OPENFOAM_DIR}/etc/bashrc" >> /etc/bash.bashrc

WORKDIR /cases

CMD ["bash"]
