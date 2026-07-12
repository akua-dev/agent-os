FROM node:24-bookworm-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.7.3
ARG KUBECTL_VERSION=1.34.8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    procps \
    tmux \
  && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) asset=herdr-linux-x86_64; sha=043ef43ecbabda28465dcff1eec3184518150d567b8b8f20cda9c6c88770641d ;; \
    arm64) asset=herdr-linux-aarch64; sha=ea490094f2c7c39099870857d00c64c628ef7b5eba1967df4258033455ee2cb1 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/v${HERDR_VERSION}/${asset}" -o /usr/local/bin/herdr; \
  echo "$sha  /usr/local/bin/herdr" | sha256sum -c -; \
  chmod 0755 /usr/local/bin/herdr; \
  mkdir -p /usr/share/licenses/herdr; \
  curl -fsSL "https://raw.githubusercontent.com/ogulcancelik/herdr/v${HERDR_VERSION}/LICENSE" -o /usr/share/licenses/herdr/LICENSE

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha=f6249132865c13abe3c9dd5038f5da65849cb86eee1608c001831504e481aa8c ;; \
    arm64) sha=4c9fe1f717738950c638c38056130a8db5075e6413ae36d8687221a240cdf88b ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl; \
  echo "$sha  /usr/local/bin/kubectl" | sha256sum -c -; \
  chmod 0755 /usr/local/bin/kubectl

RUN npm install --global @earendil-works/pi-coding-agent@0.80.6

ENV FM_HOME=/home/agent \
    HOME=/home/agent \
    HERDR_SESSION=default

RUN mkdir -p /home/agent /opt/agent-os \
  && chown -R node:node /home/agent /opt/agent-os

COPY --chown=node:node . /opt/agent-os

USER node
WORKDIR /opt/agent-os
ENTRYPOINT ["/opt/agent-os/bin/agent-os-container-entrypoint.sh"]
