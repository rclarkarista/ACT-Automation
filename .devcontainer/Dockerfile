FROM mcr.microsoft.com/devcontainers/python:1-3.12-bookworm

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime tools used by generate.sh and onboard.sh, plus ShellCheck for
# editor diagnostics. Graphviz is optional at runtime but enables topology
# PNG generation, so it is included in the development environment.
RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        gawk \
        graphviz \
        grep \
        jq \
        openssh-client \
        sed \
        shellcheck \
        sshpass \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Python clients requested for CloudVision and Arista Cloud Test automation.
RUN python -m pip install --no-cache-dir \
        cvprac==2.3.0 \
        actrac==1.2.0 \
        PyYAML==6.0.3

# Keep the image running when used by tools that do not inject the standard
# Dev Containers keep-alive command.
CMD ["sleep", "infinity"]
