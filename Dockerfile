# syntax=docker/dockerfile:1
#
# AIrtg collector image: the AIrtg collector components, each from its
# GitHub release, in one image. Each component runs in its own container
# (see compose.yaml), in its own directory /opt/airtg/<component>.
#
# Components and their versions (bump the version here, then VERSION):
#   snmp-poller   SNMP_POLLER_VERSION
#
# Release archives are downloaded from the components' public GitHub
# releases and checked against the release's SHA256SUMS.

ARG ALPINE_VERSION=3.22
ARG SNMP_POLLER_VERSION=0.2

# Downloads run on the build machine whatever the target platform: nothing
# is executed for the target architecture, so multi-platform builds need no
# emulation.
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS fetch
RUN apk add --no-cache curl tzdata

# snmp-poller: binary and its etc/ (main configuration, conf.d examples,
# capabilities.d), plus empty data/ and logs/ owned by the runtime user.
FROM fetch AS snmp-poller
ARG SNMP_POLLER_VERSION
ARG TARGETOS TARGETARCH
RUN set -eu; \
    name="snmp-poller-${SNMP_POLLER_VERSION}-${TARGETOS}-${TARGETARCH}"; \
    url="https://github.com/airtg-io/snmp-poller/releases/download/v${SNMP_POLLER_VERSION}"; \
    cd /tmp; \
    curl -fsSL --retry 3 -O "${url}/${name}.tar.gz" -O "${url}/SHA256SUMS"; \
    grep "  ${name}.tar.gz\$" SHA256SUMS | sha256sum -c -; \
    tar -xzf "${name}.tar.gz"; \
    mv "${name}" /out; \
    mkdir /out/data /out/logs

FROM alpine:${ALPINE_VERSION}
ARG VERSION=dev
ARG REVISION=unknown
ARG SNMP_POLLER_VERSION
LABEL org.opencontainers.image.title="AIrtg collector" \
      org.opencontainers.image.description="AIrtg collector components: snmp-poller ${SNMP_POLLER_VERSION}" \
      org.opencontainers.image.source="https://github.com/airtg-io/airtg-collector" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      io.airtg.snmp-poller.version="${SNMP_POLLER_VERSION}"

# Time zones, for logging.local_time with TZ set.
COPY --from=fetch /usr/share/zoneinfo /usr/share/zoneinfo
# Owned by the runtime user: configuration files are encrypted in place,
# and data/ and logs/ are written.
COPY --from=snmp-poller --chown=10001:10001 /out /opt/airtg/snmp-poller

ENV PATH="/opt/airtg/snmp-poller:${PATH}"
USER 10001:10001
# Relative paths of the configuration (data_dir, log file, the default
# etc/snmp-poller.yaml) are relative to the working directory.
WORKDIR /opt/airtg/snmp-poller
CMD ["snmp-poller"]
