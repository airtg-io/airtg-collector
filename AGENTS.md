# AIrtg collector - agent memory

Docker image of the AIrtg collector components (GPLv3), deployed with Docker Compose.
User-facing docs live in `README.md`; keep both current.

## Hard requirements (do not regress)

- **Components come from their public GitHub releases**, never built from source: `Dockerfile`
  downloads the linux archive from `releases/download/v<version>/` (plain URLs, no token, no
  API rate limit) and checks it against the release's `SHA256SUMS`. Versions: one global `ARG <COMPONENT>_VERSION` in the Dockerfile. Current:
  snmp-poller 0.3.
- **No emulation**: download stages run on `$BUILDPLATFORM`; the final stage only COPYs (no RUN),
  so both platforms (linux/amd64, linux/arm64) build anywhere.
- **Layout**: `/opt/airtg/<component>` is the working directory of its service (relative paths
  of its config are relative to it), binary on PATH, no ENTRYPOINT, image user `10001:10001`.
  One container per component, all from the same image.
- **Deployment** (`compose.yaml`): bind mounts `./<component>/{conf.d,data,logs}`, container
  user `AIRTG_UID:AIRTG_GID` from `.env` so files stay the operator's (snmp-poller rewrites
  conf.d files when encrypting credentials: the new file belongs to the container user). The
  default image tag equals `VERSION`; the README components table equals the Dockerfile
  versions (`make check`).
- **Version and releases**: `VERSION` (MAJOR.MINOR[.PATCH]). CI (`.github/workflows/docker.yml`)
  checks, tests (`scripts/test.sh`, deploys with compose.yaml) and packages every push/PR; a
  push to main whose version has no tag `v<version>` pushes `ghcr.io/airtg-io/airtg-collector:
  <version>` and `:latest`, creates the tag and a GitHub release with the `docker save`
  archives + SHA256SUMS. Never create release tags by hand. The ghcr.io package is public (set
  once by the user in its Package settings: GitHub creates packages private, and a workflow
  cannot change it); a new package, e.g. for another image, must be made public the same way.
- **AIrtg analyzer**: snmp-poller's `airtg` sink (0.3+) publishes to the fixed
  `nats://127.0.0.1:4222`; the analyzer is not in the image yet (bundling it in the poller's
  container is planned), so it must share the poller's network namespace (README "Ports and
  network").
- **Updating a component**: Dockerfile ARG, README components table and links, bump VERSION and
  the compose.yaml default tag (see README "Updating a component").

## Testing notes

- `make` = check + build + test (needs Docker).
- End-to-end testing, with Docker or approximated without it: the `e2e` skill,
  `.claude/skills/e2e/SKILL.md`.
