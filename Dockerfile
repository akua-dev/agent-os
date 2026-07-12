FROM node:24-bookworm-slim

ARG TARGETARCH
ARG HERDR_VERSION=0.7.3
ARG KUBECTL_VERSION=1.34.8
ARG GH_VERSION=2.96.0
ARG TREEHOUSE_VERSION=2.0.0
ARG NO_MISTAKES_VERSION=1.34.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fd-find \
    git \
    jq \
    openssh-client \
    procps \
    ripgrep \
    rsync \
    tmux \
  && ln -s /usr/bin/fdfind /usr/local/bin/fd \
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

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) sha=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60 ;; \
    arm64) sha=06f86ec7103d41993b76cd78072f43595c34aaa56506d971d9860e67140bf909 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  asset="gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${asset}" -o "/tmp/${asset}"; \
  echo "$sha  /tmp/${asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${asset}" -C /tmp; \
  install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/bin/gh; \
  rm -rf "/tmp/${asset}" "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"

RUN set -eu; \
  case "$TARGETARCH" in \
    amd64) treehouse_sha=b7926c19633ee94582b7f1b58369f22b304ae7228a47253c2148e3a8176f03b0; no_mistakes_sha=449d0276e1b35369ea332dae0eddb5be326c2d4fc9643270af98858cf3906536 ;; \
    arm64) treehouse_sha=91bca451bab84df685ee17975c8a9d8cf671b3e95c96b7fc6ff0121ea0aae991; no_mistakes_sha=f157df3e18350edea8abdaa065681bd115a9d321fca86f51e9a0184b3a9d8756 ;; \
    *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac; \
  treehouse_asset="treehouse-v${TREEHOUSE_VERSION}-linux-${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/kunchenguid/treehouse/releases/download/v${TREEHOUSE_VERSION}/${treehouse_asset}" -o "/tmp/${treehouse_asset}"; \
  echo "$treehouse_sha  /tmp/${treehouse_asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${treehouse_asset}" -C /usr/local/bin; \
  no_mistakes_asset="no-mistakes-v${NO_MISTAKES_VERSION}-linux-${TARGETARCH}.tar.gz"; \
  curl -fsSL "https://github.com/kunchenguid/no-mistakes/releases/download/v${NO_MISTAKES_VERSION}/${no_mistakes_asset}" -o "/tmp/${no_mistakes_asset}"; \
  echo "$no_mistakes_sha  /tmp/${no_mistakes_asset}" | sha256sum -c -; \
  tar -xzf "/tmp/${no_mistakes_asset}" -C /usr/local/bin; \
  chmod 0755 /usr/local/bin/treehouse /usr/local/bin/no-mistakes; \
  rm -f "/tmp/${treehouse_asset}" "/tmp/${no_mistakes_asset}"

RUN npm install --global \
  @earendil-works/pi-coding-agent@0.80.6 \
  gh-axi@0.1.27 \
  chrome-devtools-axi@0.1.26 \
  lavish-axi@0.1.40 \
  tasks-axi@0.2.2 \
  quota-axi@0.1.5

ENV FM_HOME=/home/agent \
    HOME=/home/agent \
    HERDR_SESSION=default

RUN mkdir -p /home/agent /opt/agent-os \
  && chown -R node:node /home/agent /opt/agent-os

COPY --chown=node:node . /opt/agent-os

USER node
WORKDIR /opt/agent-os
ENTRYPOINT ["/opt/agent-os/bin/agent-os-container-entrypoint.sh"]
