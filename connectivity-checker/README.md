# Connectivity Checker

This package provides a small utility that executes ping and HTTP checks defined
per node. Results are printed as JSON records so Promtail can forward them to
Loki. Checks are defined via:

- an inventory file (`nodes.inventory.yml`) listing nodes with their address and
  profile name
- reusable profile templates (`profiles/*.yml`) that describe the probes

Environment variables allow overriding paths and runtime settings.

Place node inventory and profiles in a writeable location outside version control
before running the stack. On remote nodes, templates may interpolate
`NETWORKNODE_IP` to avoid per-node edits.

