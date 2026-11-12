# airtg-collector

AIrtg collector: the AIrtg collection components packaged as one Docker image, deployed with
Docker Compose.

- **One image, one container per component**: each component runs in its own container from
  the same image, in its own directory `/opt/airtg/<component>`.
- **Built from the components' GitHub releases**: each release archive is downloaded and
  checked against its release's `SHA256SUMS`; nothing is compiled.
- **linux/amd64 and linux/arm64**, Alpine based, non-root.
- **Everything that matters lives next to `compose.yaml`**: configuration, credentials key,
  state, disk buffers and logs, in plain directories that are easy to edit and back up.
- **Released like the components**: a new version in `VERSION` pushed to `main` publishes the
  image to `ghcr.io/airtg-io/airtg-collector` and a GitHub release.

Copyright (C) 2026 AIrtg Solutions, inc. Licensed under the GNU GPL v3 (see [LICENSE](LICENSE)).

## Components

| Component | Version | Documentation |
|-----------|---------|---------------|
| snmp-poller | 0.3 | [airtg-io/snmp-poller v0.3](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md) |

Only the SNMP poller is available for now. Every option of a component is documented in its
own README: this one covers running it in Docker.

## Contents

- [Quick start](#quick-start)
- [The deployment directory](#the-deployment-directory)
- [Configuration](#configuration)
- [Connecting to databases](#connecting-to-databases)
- [Ports and network](#ports-and-network)
- [Logs](#logs)
- [Operations](#operations)
- [The image](#the-image)
- [Development](#development)

## Quick start

Requires Docker Engine 24 or later with the Compose plugin 2.24 or later. Hosts that cannot
reach `ghcr.io` [load the image from a release](#without-registry-access).

```sh
mkdir airtg-collector && cd airtg-collector
curl -fsSLO https://raw.githubusercontent.com/airtg-io/airtg-collector/v0.2/compose.yaml

# The directories the containers write to, owned by you, and the user the containers run as.
mkdir -p snmp-poller/conf.d snmp-poller/data snmp-poller/logs
printf 'AIRTG_UID=%s\nAIRTG_GID=%s\n' "$(id -u)" "$(id -g)" > .env

# The examples shipped in the image: devices and sinks.
docker compose run --rm --no-deps -T snmp-poller cat etc/conf.d/devices.yaml.example > snmp-poller/conf.d/devices.yaml
docker compose run --rm --no-deps -T snmp-poller cat etc/conf.d/sinks.yaml.example > snmp-poller/conf.d/sinks.yaml
$EDITOR snmp-poller/conf.d/devices.yaml snmp-poller/conf.d/sinks.yaml

docker compose run --rm snmp-poller snmp-poller -check   # validate, and exit
docker compose up -d                                     # start, and on every boot
docker compose logs -f snmp-poller                       # follow the logs
```

On the first start the poller generates its credentials key `snmp-poller/data/key.dat` and
encrypts the clear-text communities, passwords and tokens of `snmp-poller/conf.d` in place.
**Back that key up** (see [Backup](#backup-and-restore)): encrypted values cannot be read
without it.

## The deployment directory

```text
airtg-collector/
  compose.yaml          # the services; do not edit, override in compose.override.yaml
  .env                  # AIRTG_UID, AIRTG_GID, optional AIRTG_COLLECTOR_VERSION and TZ
  snmp-poller.env       # optional: variables for ${VAR} references of the configuration
  snmp-poller/
    conf.d/             # configuration: devices, sinks, vault (*.yaml, hot reloaded)
    data/               # key.dat (credentials key), per-device state, sink disk buffers
    logs/               # snmp-poller.log, rotated to snmp-poller-<time>.log.gz
```

| Host path | Container path | Written by the container |
|-----------|----------------|--------------------------|
| `snmp-poller/conf.d` | `/opt/airtg/snmp-poller/etc/conf.d` | Yes: credentials are encrypted in place |
| `snmp-poller/data` | `/opt/airtg/snmp-poller/data` | Yes |
| `snmp-poller/logs` | `/opt/airtg/snmp-poller/logs` | Yes |

The containers run as `AIRTG_UID:AIRTG_GID` from `.env` (`10001:10001` without it), which must
own these three directories: with your own ids, as above, the files stay yours and you edit them
without `sudo`. Create the directories before the first start: a directory Docker creates for a
missing bind mount belongs to root, and the poller cannot write to it (`permission denied` in
the logs).

| `.env` variable | Default | Use |
|-----------------|---------|-----|
| `AIRTG_UID`, `AIRTG_GID` | `10001` | User and group of the containers. |
| `AIRTG_COLLECTOR_VERSION` | The version of this `compose.yaml` | Image tag to run, e.g. to pin or roll back. |
| `TZ` | `UTC` | Time zone of the containers, for `logging.local_time: true`. |

Customize the services in a `compose.override.yaml` next to `compose.yaml` (read automatically
by `docker compose`), so a new `compose.yaml` replaces the old one without losing your changes.

## Configuration

The configuration of the poller is documented in its
[README](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#configuration-reference).
In the container, the files are:

| Container path | Holds | How to change it |
|----------------|-------|------------------|
| `etc/snmp-poller.yaml` | Main file: `global` (threads, intervals, timeouts, ...) and `logging`, with the defaults. | [Replace it](#main-configuration-file) |
| `etc/conf.d/*.yaml` | Devices, sinks, vault: everything else. | Files of `snmp-poller/conf.d` |
| `etc/capabilities.d/*.yaml` | What to poll: `system`, `interfaces`, `entity`, `host-resources`. | [Add or replace them](#capabilities) |

Paths are relative to `/opt/airtg/snmp-poller`, the working directory.

### Devices and sinks

Write any number of `*.yaml` files in `snmp-poller/conf.d` (other files, like the `.example`
files, are ignored), e.g. one per site:

```yaml
# snmp-poller/conf.d/devices.yaml
devices:
  - id: core-1
    address: 192.0.2.12
    snmp:
      version: 3
      username: poller
      security_level: authPriv
      auth_protocol: SHA256
      auth_password: change-me      # encrypted in this file on startup
      priv_protocol: AES
```

Changes apply without restart: the poller checks the files every 2 seconds, validates the new
configuration and applies it, or logs an `error` and keeps the previous one. See
[Reload](#reload).

### Credentials

Three ways, from the poller's [credentials](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#credentials-encryption)
documentation:

- **In clear text in `conf.d`**: encrypted in place (`~~HEX~~`) on startup and reload, with
  `snmp-poller/data/key.dat`.
- **Encrypted by hand**, so the clear text never touches the disk. The prompt asks twice,
  without echo:

  ```sh
  docker compose exec snmp-poller snmp-poller -encrypt
  ```

  Paste the `~~HEX~~` it prints into the file. It uses the key of the running poller; before the
  first start, use `docker compose run --rm snmp-poller snmp-poller -encrypt`, which creates it.
- **Environment variables**: `${VAR}` references are read from the container's environment and
  never rewritten. Put the variables in `snmp-poller.env` next to `compose.yaml` (keep it
  `chmod 600`):

  ```sh
  # snmp-poller.env
  INFLUXDB_TOKEN=apiv3_xxxxxxxx
  SNMP_AUTH_PASS=change-me
  ```

  Changes of `snmp-poller.env` apply on `docker compose up -d`, which recreates the container.
- **HashiCorp Vault**: a `vault:` block in a file of `conf.d`, see the poller's
  [Vault](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#vault) documentation.

### Main configuration file

The image's `etc/snmp-poller.yaml` holds the defaults (250 threads, poll every 60s, discovery
every hour, console and file logs at `info`). To change them, copy it out, edit it and mount it
in `compose.override.yaml`:

```sh
docker compose run --rm --no-deps -T snmp-poller cat etc/snmp-poller.yaml > snmp-poller/snmp-poller.yaml
```

```yaml
# compose.override.yaml
services:
  snmp-poller:
    volumes:
      - ./snmp-poller/snmp-poller.yaml:/opt/airtg/snmp-poller/etc/snmp-poller.yaml:ro
```

Then `docker compose up -d`. Keep `data_dir: data`, the log file in `logs/`, `include_dir:
conf.d` and `capabilities_dir: capabilities.d`, the paths the mounts expect. `logging` and
`global` live in this file only.

### Capabilities

A capability file (what to poll on which devices, see the poller's
[Capabilities](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#capabilities))
is added by mounting it next to the shipped ones:

```yaml
# compose.override.yaml
services:
  snmp-poller:
    volumes:
      - ./snmp-poller/capabilities.d/ucd-load.yaml:/opt/airtg/snmp-poller/etc/capabilities.d/ucd-load.yaml:ro
```

To replace them all, mount a whole directory on `/opt/airtg/snmp-poller/etc/capabilities.d`,
starting from a copy of the shipped ones:

```sh
mkdir -p snmp-poller/capabilities.d
for f in system interfaces entity host-resources; do
  docker compose run --rm --no-deps -T snmp-poller cat etc/capabilities.d/$f.yaml > snmp-poller/capabilities.d/$f.yaml
done
```

Capability files are hot reloaded too.

## Connecting to databases

The poller sends what it polls to **sinks**: Prometheus remote write and InfluxDB, configured
in a file of `snmp-poller/conf.d` (every option is in the poller's
[sinks](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#sinks) documentation).
The database is never polled: the poller connects to it, so only the database needs to accept
connections. From the container, a database is reached at:

| Where the database runs | URL host |
|-------------------------|----------|
| Another host | Its name or address, as from any host: `http://tsdb.example.net:9090` |
| The Docker host, port published or not in Docker | `host.docker.internal` (mapped to the host by `compose.yaml`): `http://host.docker.internal:9090`. The database must listen on the Docker bridge, not only on `127.0.0.1`. |
| A container of this Compose project (`compose.override.yaml`) | The service name: `http://prometheus:9090` |
| A container of another Compose project | Its service name, once both share a network, see [below](#database-in-another-compose-project). |

`localhost` is the container itself: it never reaches a database.

The poller can also send to the AIrtg analyzer (sink `type: airtg`, nothing else to set). Its
address is fixed to `127.0.0.1`: see the [AIrtg analyzer](#ports-and-network) note on networking.

### Prometheus

Prometheus accepts remote write when started with `--web.enable-remote-write-receiver`. Add
`out_of_order_time_window` so that data buffered during an outage longer than about an hour
is accepted:

```yaml
# prometheus.yml (Prometheus' own configuration)
storage:
  tsdb:
    out_of_order_time_window: 1d
```

```yaml
# snmp-poller/conf.d/sinks.yaml
sinks:
  - id: prometheus
    type: prometheus
    url: http://host.docker.internal:9090/api/v1/write
    # token: ${PROMETHEUS_TOKEN}       # Authorization: Bearer, or username/password
```

Metrics are named `snmp_<key>`: `snmp_ifInOctets_rate`, `snmp_uptime`, ... with labels
`device`, `index` and the row labels (`ifDescr`, ...).

### VictoriaMetrics, Grafana Mimir, Thanos, Cortex, Grafana Cloud

Also `type: prometheus`, with their remote write URL:

| Database | `url` |
|----------|-------|
| VictoriaMetrics (single node) | `http://victoriametrics:8428/api/v1/write` |
| VictoriaMetrics cluster | `http://vminsert:8480/insert/<tenant>/prometheus/api/v1/write` |
| Grafana Mimir | `http://mimir:8080/api/v1/push`, with `headers: { X-Scope-OrgID: <tenant> }` when multi-tenant |
| Thanos Receive | `http://thanos-receive:19291/api/v1/receive` |
| Grafana Cloud | The Prometheus remote write URL of the stack, with `username` (instance id) and `password` (access policy token) |

### InfluxDB 3

```yaml
# snmp-poller/conf.d/sinks.yaml
sinks:
  - id: influxdb
    type: influxdb
    url: http://host.docker.internal:8181   # /api/v2/write is appended
    database: snmp                          # created on the first write
    token: ${INFLUXDB_TOKEN}                # from snmp-poller.env, or the token, encrypted on startup
    tags: [device, sysName, sysLocation, index, labels]
```

Create the token with `influxdb3 create token --admin` (or a token that can write the
database). InfluxDB 2 serves the same `/api/v2/write` endpoint, `database` being the bucket:
see the poller's [InfluxDB](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#influxdb-3)
documentation.

### TLS and authentication

```yaml
# snmp-poller/conf.d/sinks.yaml
sinks:
  - id: prometheus
    type: prometheus
    url: https://tsdb.example.net/api/v1/write
    username: collector
    password: change-me                                     # encrypted on startup
    ca_cert: /opt/airtg/snmp-poller/etc/conf.d/ca.pem       # snmp-poller/conf.d/ca.pem on the host
    # client_cert: /opt/airtg/snmp-poller/etc/conf.d/client.pem   # mutual TLS
    # client_key: /opt/airtg/snmp-poller/etc/conf.d/client-key.pem
```

Public certificates need nothing: the image has the usual CA certificates. Certificate files
can live in `snmp-poller/conf.d` (only `*.yaml` files are read as configuration); use absolute
container paths.

### Database in this Compose project

For a test or a single-host setup, run the database next to the poller in
`compose.override.yaml`:

```yaml
# compose.override.yaml
services:
  prometheus:
    image: prom/prometheus:v3.5.0
    command: [--config.file=/etc/prometheus/prometheus.yml, --web.enable-remote-write-receiver]
    ports: ["9090:9090"]
    volumes: [prometheus:/prometheus]
    restart: unless-stopped
volumes:
  prometheus:
```

with `url: http://prometheus:9090/api/v1/write` in the sink.

### Database in another Compose project

Attach the poller to the other project's network (its name is in `docker network ls`, usually
`<project>_default`):

```yaml
# compose.override.yaml
services:
  snmp-poller:
    networks: [default, monitoring]
networks:
  monitoring:
    external: true
    name: monitoring_default
```

The other project's services are then reached by their service names.

### Checking delivery

Every minute, the poller logs one `sink stats` line per sink:

```sh
docker compose logs snmp-poller | grep 'sink stats'
```

`state=up` with `samples_sent` growing: data arrives. `state=down`: the destination is
unreachable or refuses the data; the `warn` line logged when it went down has the error
(connection refused, HTTP 401, ...). Meanwhile data waits in `snmp-poller/data/sinks/<id>/`
(1GB per sink by default) and is sent, in order, once the destination is back.

## Ports and network

The poller **listens on no port**: no `ports:` to publish, nothing to open inbound on the
Docker host. It only opens outbound connections:

| Destination | Protocol and port | Configured by |
|-------------|-------------------|---------------|
| Devices (SNMP agents) | UDP 161 (default), or TCP; another port per device | `global.port`, `global.transport`, devices' `port` and `transport` |
| Prometheus remote write and compatible | TCP, HTTP(S): Prometheus 9090, VictoriaMetrics 8428, Mimir 8080, ... | Sinks' `url` |
| InfluxDB | TCP, HTTP(S): InfluxDB 3 8181 | Sinks' `url` |
| HashiCorp Vault (optional) | TCP, HTTP(S) 8200 | `vault.address` |
| AIrtg analyzer (optional) | TCP, NATS 4222 on `127.0.0.1` | Fixed, see below |
| DNS | UDP/TCP 53 | The Docker host's resolver, for device and sink host names |

- **Source address**: on the default bridge network, the devices see SNMP requests coming from
  the **Docker host's address** (NAT). Their SNMP access lists (communities, `snmp-server
  community ... <acl>`, firewalls) must allow it.
- **Firewalls** between the Docker host and the devices must allow UDP 161 outbound and the
  replies (stateful). Between the host and the databases: their HTTP(S) port.
- **Many devices**: every SNMP request over UDP creates a connection tracking entry on the
  Docker host. With thousands of devices, raise `net.netfilter.nf_conntrack_max`, or bypass NAT
  with the host network:

  ```yaml
  # compose.override.yaml
  services:
    snmp-poller:
      network_mode: host
  ```

  With `network_mode: host`, `localhost` is the Docker host: a database on the host is
  `http://localhost:9090`, and the service names of other containers no longer resolve.

- **AIrtg analyzer**: snmp-poller's `airtg` sink (snmp-poller 0.3 and later)
  publishes to the analyzer's NATS server at the fixed address `nats://127.0.0.1:4222`. It
  works only when the analyzer shares the poller's network: inside the `snmp-poller` container,
  `127.0.0.1` is the container itself, not the Docker host or another container. The analyzer
  is not part of this image yet; bundling it in the same container as the poller is planned.
  Until then, run it with the poller's network namespace (`network_mode: "service:snmp-poller"`
  on the analyzer's service), or run both on the host network (`network_mode: host`).

## Logs

The poller logs to the console, read with `docker compose logs`, and to rotated files in
`snmp-poller/logs`:

```sh
docker compose logs -f snmp-poller                    # follow
docker compose logs --since 1h snmp-poller            # the last hour
docker compose logs snmp-poller | grep -E 'level=(WARN|ERROR)'
docker compose logs snmp-poller | grep 'poller stats' | tail -1   # the last stats line
tail -f snmp-poller/logs/snmp-poller.log              # the log file, on the host
zcat snmp-poller/logs/snmp-poller-*.log.gz | less     # rotated files
```

| Where | Kept | Rotation |
|-------|------|----------|
| `docker compose logs` | Until the container is removed (`docker compose down`, upgrades) | By Docker: 5 files of 10MB (`logging` of `compose.yaml`) |
| `snmp-poller/logs/` | Across upgrades and container removal | By the poller: 50MB per file, 10 files, 30 days, gzip |

What to look for (details in the poller's [Logs](https://github.com/airtg-io/snmp-poller/blob/v0.3/README.md#logs)
documentation):

- `msg="poller stats"` every minute: devices, polls ok and failed, `queued` (constantly above
  0: raise `global.threads`), `skipped` (polls longer than their interval), durations.
- `msg="sink stats"` every minute per sink: `state`, values sent and dropped, backlog.
- `level=WARN msg="poll failed" device=<id>`: once when a device starts failing, with the error
  (a timeout: wrong address, community, access list or firewall; an SNMPv3 error: wrong
  credentials). `msg="poll recovered"` when it works again.
- `level=ERROR`: a configuration change was rejected, with the reason; the previous one runs.

No line is logged per poll at `info`. To see what a device does, set `trace: true` on it in
`conf.d` (hot reloaded) and filter: `docker compose logs -f snmp-poller | grep 'device=core-1'`.
For everything, `logging.level: debug` in the [main configuration file](#main-configuration-file).
Credentials are never logged.

## Operations

### Status

```sh
docker compose ps                                   # running, restarts
docker compose exec snmp-poller snmp-poller -version
docker compose top snmp-poller
```

The poller has no health endpoint: its stats lines are its health. A container that keeps
restarting (`docker compose ps`) failed to start: the reason is the last lines of
`docker compose logs snmp-poller` (usually an invalid configuration, or a directory it cannot
write).

### Validate the configuration

```sh
docker compose run --rm snmp-poller snmp-poller -check
```

It reads `snmp-poller/conf.d` as the service does, reports every error with its file, and
never modifies anything. A running poller validates every change itself before applying it.

### Reload

Changes in `conf.d` and in capability files are applied within seconds, without restart
(`global.hot_reload`, default on). To force a reload, e.g. with `hot_reload: false`:

```sh
docker compose kill -s HUP snmp-poller
```

A change of `global.data_dir` needs a restart. Changes of `compose.yaml`,
`compose.override.yaml`, `.env` or `snmp-poller.env` apply with `docker compose up -d`.

### Start, stop, restart

```sh
docker compose up -d          # start, or apply compose changes
docker compose stop           # stop: in-flight polls get 30s, sinks send what they hold
docker compose restart snmp-poller
docker compose down           # stop and remove the container (the directories are kept)
```

`restart: unless-stopped` starts the poller on every boot of Docker, unless it was stopped
with `docker compose stop`.

On stop, data that could not be sent goes to the sinks' disk buffers in `snmp-poller/data`,
and is sent first on the next start. Device state (discovery cache, previous counter values)
is rebuilt on start: the first poll of each device after a restart rediscovers it and has no
rates yet.

### Upgrade

```sh
curl -fsSLO https://raw.githubusercontent.com/airtg-io/airtg-collector/v<version>/compose.yaml
docker compose pull
docker compose up -d
docker compose logs -f snmp-poller # check the startup lines
```

Or keep `compose.yaml` and set `AIRTG_COLLECTOR_VERSION=<version>` in `.env`. Roll back the
same way, with the previous version. The release notes list the component versions; read
the components' release notes for configuration changes.

### Backup and restore

Back up the deployment directory, at least:

| Path | Why |
|------|-----|
| `snmp-poller/data/key.dat` | **The credentials key**: without it, every `~~HEX~~` of `conf.d` is lost. |
| `snmp-poller/conf.d/` | The configuration (credentials encrypted with `key.dat`). |
| `.env`, `snmp-poller.env`, `compose.override.yaml`, your mounted files | Deployment settings and secrets. |

```sh
tar -czf airtg-collector-backup.tar.gz .env compose*.yaml *.env snmp-poller/conf.d snmp-poller/data/key.dat
```

The rest of `snmp-poller/data` is a cache rebuilt on start, plus the disk buffers of
unreachable sinks. To restore, or to move the collector to another host, extract the archive
in a new deployment directory, create `snmp-poller/logs`, and `docker compose up -d`.

Store the backup somewhere safe: with `key.dat`, the encrypted credentials of `conf.d` can be
decrypted.

### Without registry access

Each release has the image of each platform as a `docker save` archive, for hosts that cannot
reach `ghcr.io`:

```sh
sha256sum -c --ignore-missing SHA256SUMS
gunzip -c airtg-collector-0.2-linux-amd64.tar.gz | docker load   # linux-arm64 on ARM hosts
```

It loads `ghcr.io/airtg-io/airtg-collector:0.2`, the image `compose.yaml` runs. Then start as
usual; `docker compose pull` is not needed.

### Without Docker Compose

```sh
docker run -d --name snmp-poller --restart unless-stopped \
  --user "$(id -u):$(id -g)" --stop-timeout 45 \
  --add-host host.docker.internal:host-gateway \
  -v "$PWD/snmp-poller/conf.d:/opt/airtg/snmp-poller/etc/conf.d" \
  -v "$PWD/snmp-poller/data:/opt/airtg/snmp-poller/data" \
  -v "$PWD/snmp-poller/logs:/opt/airtg/snmp-poller/logs" \
  --log-opt max-size=10m --log-opt max-file=5 \
  ghcr.io/airtg-io/airtg-collector:0.2 snmp-poller
docker logs -f snmp-poller
```

### Uninstall

```sh
docker compose down --rmi all
```

Then delete the deployment directory, once its backup is no longer needed.

## The image

`ghcr.io/airtg-io/airtg-collector`, tags `<version>` (e.g. `0.2`) and `latest`, for linux/amd64
and linux/arm64.

| Path | Content |
|------|---------|
| `/opt/airtg/snmp-poller/snmp-poller` | The binary, on the `PATH`. |
| `/opt/airtg/snmp-poller/etc/` | `snmp-poller.yaml`, `conf.d/` (examples), `capabilities.d/`, from the release archive. |
| `/opt/airtg/snmp-poller/data/`, `logs/` | Empty, owned by `10001:10001`. |
| `/opt/airtg/snmp-poller/README.md`, `LICENSE` | The poller's documentation and license, from the release archive. |

- Working directory `/opt/airtg/snmp-poller`, default command `snmp-poller`, user `10001:10001`.
  No entrypoint: the command is the component and its arguments, e.g.
  `docker run --rm ghcr.io/airtg-io/airtg-collector:0.2 snmp-poller -version`.
- Alpine Linux (a shell for `docker compose exec`, CA certificates, time zones).
- Labels: `org.opencontainers.image.version` (the collector version),
  `org.opencontainers.image.revision` (its commit) and `io.airtg.snmp-poller.version`:

  ```sh
  docker image inspect -f '{{json .Config.Labels}}' ghcr.io/airtg-io/airtg-collector:0.2
  ```

## Development

Requires Docker with Buildx and Compose. The build downloads the components' release archives
from GitHub.

```sh
make              # checks, then build the image for this machine and test it
make check        # shell syntax and shellcheck of scripts/, compose.yaml, versions consistency
make build        # the image for this machine: ghcr.io/airtg-io/airtg-collector:<VERSION>
make test         # build, then scripts/test.sh: deploys it with compose.yaml and checks it
make package      # dist/airtg-collector-<version>-linux-{amd64,arm64}.tar.gz and SHA256SUMS
make push         # build both platforms and push <VERSION> and latest (CI does it on release)
make clean        # remove dist/
make help         # list targets
```

`make package` and `make push` build for both platforms on any machine without emulation: the
downloads run on the build platform and the final image only copies files. `make push` needs a
Buildx builder that can push multi-platform images (`docker buildx create --use`).

`scripts/test.sh` deploys the image like [Quick start](#quick-start): a deployment directory
with `compose.yaml`, `.env` and a device in `conf.d`, then checks the startup, the encryption of
the credentials in place (the file still owned by the deployment user), `data/key.dat`, the log
file and a clean stop.

| Path | Purpose |
|------|---------|
| `Dockerfile` | The image: component versions, downloads, layout. |
| `compose.yaml` | The deployment. |
| `scripts/test.sh` | Tests of a built image. |
| `.github/workflows/docker.yml` | CI: check, test and package every push and pull request; release new versions. |
| `VERSION` | The collector version. |

### Updating a component

1. Set its version in the `Dockerfile` (`ARG SNMP_POLLER_VERSION=...`) and in the
   [components table](#components) (`make check` verifies they match), and the links to its
   documentation in this README.
2. Bump `VERSION` and the default image tag of `compose.yaml` (`make check` verifies they
   match too), and the `0.2` examples of this README.
3. `make`, then push to `main`: CI releases the new version.

### Adding a component

Add a download stage to the `Dockerfile` copying the component to `/opt/airtg/<component>`, a
service to `compose.yaml` with its directories under `./<component>/`, its tests to
`scripts/test.sh`, and its sections to this README.

### Versions and releases

The version is in the `VERSION` file (`MAJOR.MINOR` or `MAJOR.MINOR.PATCH`, currently `0.2`),
in the image label `org.opencontainers.image.version` and its tag.

GitHub Actions (`.github/workflows/docker.yml`) runs on every push to `main` and every pull
request: `make check`, `make test`, then `make package`, with the archives kept as a build
artifact. On a push to `main`, if no tag `v<VERSION>` exists yet, it also:

1. pushes the image to `ghcr.io/airtg-io/airtg-collector:<VERSION>` and `:latest` (both
   platforms);
2. creates the tag `v<VERSION>` on the pushed commit and a GitHub release named
   `AIrtg collector v<VERSION>`, with the image name, the component versions, release notes
   generated from the commits and pull requests since the previous release, and these files:

| File | Content |
|------|---------|
| `airtg-collector-<version>-linux-amd64.tar.gz` | The image for linux/amd64 (`docker save`, gzip) |
| `airtg-collector-<version>-linux-arm64.tar.gz` | The image for linux/arm64 |
| `SHA256SUMS` | Checksums of the archives (`sha256sum -c SHA256SUMS`) |

An unchanged `VERSION` only builds and tests. Never create release tags by hand.

The first push creates the `airtg-collector` package on ghcr.io as private: make it public
once, in its package settings (Danger Zone, Change visibility).
