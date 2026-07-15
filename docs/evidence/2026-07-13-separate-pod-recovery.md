# Separate-Pod mate and recovery verification

Date: 2026-07-13
Kubernetes context: `orbstack`
Namespace: `agent-os-demo`
Package: `tools/agent-os/packages/mate/package.k`
Model policy: `openai-codex/gpt-5.6-terra`, low thinking

## Claim

Firstmate can use ordinary Akua package rendering, Kubernetes, and Herdr to create and supervise a separately resourced persistent mate Pod with explicit AI credentials and no ambient Kubernetes authority.
The mate can complete real work, survive Pod replacement without losing its unique artifact or Pi session, resume the exact persisted session, append recovery evidence, and return control to Firstmate without a custom controller or communication protocol.

## Resource and authority boundary

- Pod: `agent-os-mate-separate-eval`.
- Address: `/k8s/in-cluster/ns/agent-os-demo/pod/agent-os-mate-separate-eval`.
- Requests: `500m` CPU and `1Gi` memory.
- Limits: `2` CPU and `4Gi` memory.
- PVC: `agent-os-mate-separate-eval-home`, UID `2c141e3b-0585-4648-96e8-2bc496450a91`, retained and Bound.
- Pi Secret: `agent-os-mate-separate-eval-pi-auth`, UID `c4698208-bb08-437c-87e9-9346e8b14ed2`, retained.
- `automountServiceAccountToken`: `false`.
- No ServiceAccount token existed in the container.
- `/home/agent/.pi/agent/auth.json` was an explicit read-only Secret mount.
- The package added no privileged setting, host namespace, or host mount.

Parent-side live verification returned:

```text
NO_SA_TOKEN
/home/agent/.pi/agent/auth.json ro,relatime
{"server":"running","running":true,"socket":"/home/agent/.config/herdr/herdr.sock","compatible":true}
```

The child initially misread `/proc/mounts` and claimed that no auth material was mounted.
Firstmate caught the discrepancy and retained the authoritative parent-side `/proc/self/mountinfo` evidence above.

## Initial task

Firstmate launched `separate-eval-terra` through the mate's Herdr server with `openai-codex/gpt-5.6-terra` and low thinking.
The child created `/home/agent/unique-work.txt`:

```text
separate-eval-20260713T083121Z-b8a6ef90edac4d55
Short note: child evaluator artifact; parent-only communication.
```

Its immutable artifact hash was:

```text
2aeb922cd51230ed7b62bc40cc7ce30d41e44b4df3963911fe860030c2f7765a
```

The task ran from `2026-07-13T08:31:12Z` through `2026-07-13T08:31:35Z` and wrote `/home/agent/separate-eval-report.md`.
The child communicated only through its initial Firstmate brief and returned its result through the persistent report and Herdr pane.

## Pod and session recovery

Firstmate exited the child, preserved the PVC and Secret, deleted only the Pod, and recreated it from the same Akua-rendered manifests.

```text
Initial Pod UID:     960cc460-cd06-44d1-a8fa-da200d4384b9
Replacement Pod UID: 1cb7ff92-5e0d-4ccd-9324-38515ae9823b
```

After replacement, Firstmate verified:

```text
UNIQUE_SURVIVED
REPORT_SURVIVED
PI_SESSION_SURVIVED
/usr/local/bin/herdr
/usr/local/bin/pi
{"running":true,"socket":"/home/agent/.config/herdr/herdr.sock"}
```

The persisted Pi session was `019f5a99-f031-7f51-8cc0-156777204dc5`.
Firstmate relaunched `pi --session 019f5a99-f031-7f51-8cc0-156777204dc5` on Terra-low through the replacement Pod's Herdr server.
The resumed agent rehashed the unique artifact, confirmed Herdr health, and appended a recovery record at `2026-07-13T08:33:26Z`.
It then exited, leaving no live Terra child agent.

The approximate model cost displayed by the final recovery pane was `$0.127`; this is a Pi subscription estimate, not provider billing evidence.

## Model-policy intervention

An earlier `openai-codex/gpt-5.4-mini` child was stopped immediately when the captain changed the testing policy.
The primary was restarted on Terra-low, and `/home/agent/config/crew-dispatch.json` now pins all subsequent testing crewmates to:

```json
{
  "rules": [],
  "default": {
    "harness": "pi",
    "model": "openai-codex/gpt-5.6-terra",
    "effort": "low"
  }
}
```

The aborted pane restored as a stale Herdr entry after Pod replacement but had no live Pi process or accepted result.

The policy was then closed over all three local launch paths:

- Pi's persisted defaults are `openai-codex`, `gpt-5.6-terra`, and `low`, so a
  direct primary `pi` session uses Terra-low;
- `crew-dispatch.json` pins ordinary crewmates and scouts;
- `secondmate-harness` contains
  `pi openai-codex/gpt-5.6-terra low` for Secondmate launches.

After rebuilding and replacing the Firstmate Pod, image
`docker-pullable://agent-os@sha256:94b7eb6c435f1a226e7279c40491e49c505b30bf54c65de1cd3d5b8e0a102611`
converged all three settings and Herdr returned healthy. The retained separate
mate PVC was also updated to the same direct-Pi defaults. No child agent was
left running after verification.

## Scope

This proves the separate-Pod authority boundary, parent-only supervision, persistent home, Pod replacement, unique-work survival, persistent toolchain, and exact Pi session recovery in the local intelligence cluster.
It does not prove Akua-managed KaaS or worker lifecycle, GitHub issue-to-PR delivery, product-cluster read/write boundaries, or a second model provider.
