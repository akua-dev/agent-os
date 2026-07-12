---
name: kubernetes-fleet
description: "Operate Agent OS crewmates as Kubernetes Pods with persistent homes and explicit authority boundaries."
user-invocable: false
metadata:
  internal: true
---

# Kubernetes fleet

Load this skill only when the current firstmate is running in Kubernetes or is explicitly managing Kubernetes-backed crewmates.

## Operating contract

- Keep every crewmate general-purpose; its brief, tools, and authority specialize it for the current task.
- A crewmate normally communicates only with its parent through its terminal, status files, reports, and delivered Git state.
- The image includes Akua's CLI for direct use and the Agent OS tool uses `@akua-dev/sdk` in process.
- Use the bundled K9s terminal UI when it makes live Kubernetes inspection faster than individual `kubectl` reads.
- Use `agent-os mate render <id>` when the prepared package is useful, then inspect or edit its ordinary YAML before applying it.
- The package is optional; direct `akua render`, raw YAML, and `kubectl` remain supported.
- Use `bin/agent-os-crewmate.sh create <id>` to create a separate Pod and persistent home.
- Use `status` to inspect it and `delete` only after unique work is checkpointed or delivered.
- Never mount the primary home into a child Pod.
- The demo child receives no Kubernetes ServiceAccount token by default.
- The OrbStack primary's cluster-admin binding is a local-demo trust decision, not a production-safe default.
- Pin an explicit host context with `AGENT_OS_CONTEXT`; the launcher refuses ambient host contexts.

Use ordinary `kubectl exec`, Herdr, files, and Git to supervise the child.
Do not add a custom inter-agent chat protocol or Task/Run service.
