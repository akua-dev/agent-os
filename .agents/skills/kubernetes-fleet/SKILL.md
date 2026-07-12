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
- The image includes Akua's CLI and the prepared mate package lives at `tools/agent-os/packages/mate/`.
- The optional persistent controller package lives at `tools/agent-os/packages/firstmate/`; load `akua-intelligence-bootstrap` before using it against Akua-managed infrastructure.
- Use the bundled K9s terminal UI when it makes live Kubernetes inspection faster than individual `kubectl` reads.
- Render the package with `akua render`, inspect or edit its ordinary YAML when useful, and apply it with `kubectl`.
- Treat AI credentials as explicit per-mate grants, never as ambient inheritance merely because Firstmate can read them.
- Create or select a Kubernetes Secret only after the grant is authorized, then pass its name as the package's `piAuthSecret` input.
- Give every launched Herdr agent a task-unique name, close only a confirmed dead restored pane before reuse, and never replace a live agent.
- Grade completion by the promised artifact or delivered Git state; Herdr `idle` alone is not a completion signal.
- The package is optional; direct `akua render`, raw YAML, and `kubectl` remain supported.
- Use `bin/agent-os-crewmate.sh create <id>` to create a separate Pod and persistent home.
- Use `status` to inspect it and `delete` only after unique work is checkpointed or delivered.
- Never mount the primary home into a child Pod.
- The demo child receives no Kubernetes ServiceAccount token by default.
- A Pod with an authorized ServiceAccount gets a token-file-backed `in-cluster` kubeconfig automatically, so Firstmate does not need to copy a bearer token into a temporary kubeconfig.
- The OrbStack primary's cluster-admin binding is a local-demo trust decision, not a production-safe default.
- Pin an explicit host context for host-side `kubectl`; inside an authorized Pod use the generated `in-cluster` context.

Use ordinary `kubectl exec`, Herdr, files, and Git to supervise the child.
Do not add a custom inter-agent chat protocol or Task/Run service.
