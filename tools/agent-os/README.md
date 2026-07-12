# Agent OS operating tool

This directory contains the Bun and TypeScript operating tool that will gradually absorb Firstmate's complex fleet mechanics.
The root agent distro remains instructions, skills, trusted CLIs, and durable local files.

The first implemented contract is a self-describing Agent OS profile over [Multiaddr](https://github.com/multiformats/multiaddr).

```text
/local/mate/task-x/herdr
/k8s/in-cluster/namespace/agent-os/mate/task-x/herdr
```

The Kubernetes form names the cluster alias, namespace, stable mate ID, and terminal protocol without encoding an ephemeral Pod or IP.
The resolver may later find a raw Pod or an Agent Sandbox without changing the stored address.

## Development

The tool pins the latest stable Bun release in `.bun-version` and `package.json`.

```sh
bun install
bun run check
bun run src/cli.ts address local task-x
bun run src/cli.ts address k8s task-x
bun run src/cli.ts address inspect /k8s/in-cluster/namespace/agent-os/mate/task-x/herdr
```

See `AGENTS.md` in this directory for the tool-specific development rules.
