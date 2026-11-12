---
name: e2e
description: Test the AIrtg collector image end to end, deployed with compose.yaml as the README describes it, or approximate it without Docker from the component's release archive. Use it after a change to the Dockerfile, compose.yaml, scripts or a component update.
---

# End-to-end testing of the AIrtg collector

## With Docker

`make` runs check + build + test: `scripts/test.sh IMAGE` deploys the built image with
`compose.yaml` as the README describes it (version, non-root user, shipped configuration valid,
credentials encrypted in place, `data/` and `logs/` written as the deployment user, clean stop).

## Without Docker

The image can be approximated:

1. Build the component's release archive from its tag: `git worktree add <scratch> v<version>`
   in the component's repository (`../snmp-poller`), then `make package` there.
2. Extract the archive in the session scratchpad, `mkdir data logs`.
3. Run the scenario of `scripts/test.sh` from that directory, step by step.

Say in the report that Docker was not available and the image itself was not tested. Remove the
worktree afterwards (`git worktree remove <scratch>`).
