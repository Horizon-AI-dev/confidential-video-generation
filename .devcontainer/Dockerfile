FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Google Cloud CLI via its official apt repository.
# Everything else comes from devcontainer features or post-create.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
    # Google Cloud apt repository (gcloud)
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        google-cloud-cli \
        jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# yq (mikefarah, Go binary) - the Ubuntu "yq" apt package is a different Python tool.
ARG YQ_VERSION=v4.47.1
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" \
        -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && yq --version

RUN chsh -s /usr/bin/zsh vscode
