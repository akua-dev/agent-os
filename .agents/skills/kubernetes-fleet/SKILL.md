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
- The image includes Akua's CLI and the canonical runtime template lives at `tools/agent-os/packages/firstmate/crewmate.yaml` inside the one public Firstmate package.
- The optional persistent controller package lives at `tools/agent-os/packages/firstmate/`; load `akua-intelligence-bootstrap` before using the separate Akua authorization overlay against Akua-managed infrastructure.
- Use the bundled K9s terminal UI when it makes live Kubernetes inspection faster than individual `kubectl` reads.
- Render the package with `akua render`, inspect or edit its ordinary YAML when useful, and apply it with `kubectl`.
- Treat AI credentials as explicit per-mate grants, never as ambient inheritance merely because Firstmate can read them.
- Create or select a namespace-local Kubernetes Secret only after its AI authority is explicitly authorized.
- The Secret must contain the selected provider's `auth.json` key and must be provisioned independently instead of cloning or sharing the primary credential.
- Pass only its name through `AGENT_OS_AI_SECRET` when invoking `bin/agent-os-crewmate.sh create <id>`.
- The helper never reads or discovers the Secret, and the default Role intentionally has no Secret-read permission.
- Kubernetes mounts the selected `auth.json` read-only into the child; a missing Secret or key keeps the Pod unready, makes create fail, removes the non-running Pod, and retains the PVC for an authorized retry.
- Probe the selected model route before launching work; when quota is unavailable, use another explicitly granted provider or report the capacity blocker instead of repeatedly spawning agents.
- Give every launched Herdr agent a task-unique name, close only a confirmed dead restored pane before reuse, and never replace a live agent.
- Grade completion by the promised artifact or delivered Git state; Herdr `idle` alone is not a completion signal.
- Use `bin/agent-os-crewmate.sh create <id>` to create a separate Pod and persistent home.
- Use `status` to inspect it and `delete` only after unique work is checkpointed or delivered.
- Never mount the primary home into a child Pod.
- The demo child receives no Kubernetes ServiceAccount token by default.
- A Pod with an authorized ServiceAccount gets a token-file-backed `in-cluster` kubeconfig automatically, so Firstmate does not need to copy a bearer token into a temporary kubeconfig.
- The OrbStack primary's cluster-admin binding is a local-demo trust decision, not a production-safe default.
- Pin an explicit host context for host-side `kubectl`; inside an authorized Pod use the generated `in-cluster` context.

Use ordinary `kubectl exec`, Herdr, files, and Git to supervise the child.
Do not add a custom inter-agent chat protocol or Task/Run service.
