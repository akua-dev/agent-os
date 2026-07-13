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
- The helper never reads or discovers the Secret value, and the default Role intentionally has no Secret-read permission.
- Kubernetes projects only the selected `auth.json` key into a dedicated read-only runtime directory, and the entrypoint links that file into the writable PVC-backed Pi state without copying credential bytes.
- A missing Secret or key keeps the Pod unready, makes create fail, removes the non-running Pod, and retains the PVC for an authorized retry.
- Probe the selected model route before launching work; when quota is unavailable, use another explicitly granted provider or report the capacity blocker instead of repeatedly spawning agents.
- Give every launched Herdr agent a task-unique name, close only a confirmed dead restored pane before reuse, and never replace a live agent.
- Grade completion by the promised artifact or delivered Git state; Herdr `idle` alone is not a completion signal.
- Use `bin/agent-os-crewmate.sh create <id>` to create a separate Pod and persistent home.
- Use `status` to inspect it, `stop` to remove only the Pod, and `restart` to replace only the Pod on its retained PVC.
- The ambiguous `delete` command is rejected.
- `purge <id> --yes` is the only operation that destroys a persistent home.
- Before purge, stop the owned Pod and wait for its absence, independently checkpoint or deliver unique work from the stopped home, then annotate the owned PVC with `agent-os.dev/checkpoint-state=clean` and a non-secret RFC3339 `agent-os.dev/checkpoint-at` value.
- Purge verifies exact installation and crewmate ownership, displays the target, requires its own confirmation, and records requested and completed phases in `AGENT_OS_PURGE_EVIDENCE_FILE` or `$FM_HOME/data/crewmate-purge-evidence.log`.
- Purge evidence contains only time, namespace, crewmate ID, resource names, phase, and checkpoint time.
- Never mount the primary home into a child Pod.
- The demo child receives no Kubernetes ServiceAccount token by default.
- A Pod with an authorized ServiceAccount gets a token-file-backed `in-cluster` kubeconfig automatically, so Firstmate does not need to copy a bearer token into a temporary kubeconfig.
- The OrbStack primary's cluster-admin binding is a local-demo trust decision, not a production-safe default.
- Pin an explicit host context for host-side `kubectl`; inside an authorized Pod use the generated `in-cluster` context.

For normal credential rotation, update the explicitly authorized namespace-local Secret, restart the owned Pod with the same PVC, prove a bounded request uses the replacement credential, and revoke the old credential only after that proof succeeds.
For urgent revocation, stop the owned Pod first, revoke the old credential, update or select the approved replacement Secret, and restart only when that replacement is ready.
Never print, copy, persist, or place credential values in command arguments or evidence during either flow.

Use ordinary `kubectl exec`, Herdr, files, and Git to supervise the child.
Do not add a custom inter-agent chat protocol or Task/Run service.
