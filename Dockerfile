FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

ARG OPENFOAM_VERSION=2306
ARG OPENFOAM_PACKAGE_VERSION=

ENV OPENFOAM_VERSION=${OPENFOAM_VERSION}
ENV OPENFOAM_DIR=/usr/lib/openfoam/openfoam${OPENFOAM_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    less \
    nano \
    rsync \
    unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://dl.openfoam.com/add-debian-repo.sh | bash \
    && apt-get update \
    && if [[ -n "${OPENFOAM_PACKAGE_VERSION}" ]]; then \
         apt-get install -y --no-install-recommends \
           "openfoam${OPENFOAM_VERSION}-default=${OPENFOAM_PACKAGE_VERSION}"; \
       else \
         apt-get install -y --no-install-recommends \
           "openfoam${OPENFOAM_VERSION}-default"; \
       fi \
    && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' "source ${OPENFOAM_DIR}/etc/bashrc" > /etc/profile.d/openfoam.sh \
    && printf '%s\n' "source ${OPENFOAM_DIR}/etc/bashrc" >> /etc/bash.bashrc

WORKDIR /cases

CMD ["bash"]
