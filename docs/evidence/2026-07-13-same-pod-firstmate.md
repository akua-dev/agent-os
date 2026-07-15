# Same-Pod Firstmate verification

Date: 2026-07-13
Kubernetes context: `orbstack`
Namespace: `agent-os-demo`
Pod: `agent-os-firstmate-0`
Image ID: `docker-pullable://agent-os@sha256:1e6696938aafcec21748b83e3d68773d8b3cf1ccb967974f2cfbeda0c4fbed65`
Herdr: 0.7.3, protocol 16
Pi: 0.80.6

## Claim

A persistent Firstmate running in Herdr inside the Kubernetes Pod can create, supervise, recover, and finish a general-purpose Pi crewmate in another Herdr task pane in the same Pod.
The crewmate receives work only from Firstmate, runs real verification commands, writes its report to the persistent Firstmate home, and remains observable through Herdr.

## Topology

- Primary Firstmate: Herdr workspace `w3`, pane `w3:p1`, persistent `FM_HOME=/home/agent`.
- Crewmate task: `aeval-p4`, Herdr endpoint `default:w2:p6`.
- Model: `openai-codex/gpt-5.4-mini`, medium thinking.
- Worktree: `/home/agent/.treehouse/agent-os-eval-f1de56/2/agent-os-eval`.
- Report: `/home/agent/data/aeval-p4/report.md`.
- Both agents ran in `agent-os-firstmate-0`; no separate task service or communication protocol was used.

## Task evidence

Firstmate created a minimal local-only evaluation repository, registered it, scaffolded a scout brief, and dispatched the crewmate through `fm-spawn.sh` with the Herdr backend.
The successful spawn recorded:

```text
spawned aeval-p4 harness=pi kind=scout mode=local-only yolo=off window=default:w2:p6 worktree=/home/agent/.treehouse/agent-os-eval-f1de56/2/agent-os-eval
```

The crewmate ran the real kubeconfig regression test:

```sh
bash /opt/agent-os/tests/agent-os-kubeconfig.test.sh
```

```text
ok - Agent OS creates a rotation-safe in-cluster kubeconfig without exposing token contents
```

It also checked the active Kubernetes context:

```text
CURRENT   NAME         CLUSTER      AUTHINFO     NAMESPACE
*         in-cluster   in-cluster   in-cluster   agent-os-demo
```

The task status reached:

```text
working: inspecting project and kube integration
resolved: recovered with provider-qualified openai-codex/gpt-5.4-mini
done: report written with verification and evidence
```

The recorded task interval was `2026-07-13T08:18:30Z` to `2026-07-13T08:20:47Z`, or 2 minutes 17 seconds.
Pi displayed an approximate crewmate-session cost of `$0.195`; this is a model UI estimate, not a provider invoice.

## Parent-only supervision and human observation

The child received its initial brief from `fm-spawn.sh` and later steers through Firstmate's `fm-send.sh` path.
The external evaluator made only read-only Herdr observations of the child pane and never sent a prompt or command directly to the child.
Herdr server logs recorded a connected client while the fleet was live, proving that a human could attach and observe the same workspaces.

## Failure and recovery evidence

The first spawn used the unqualified model name `gpt-5.4-mini`.
Pi resolved it to the unauthenticated `azure-openai-responses` provider and failed with:

```text
Error: No API key found for azure-openai-responses.
```

Firstmate preserved the task brief, state, report path, and worktree allocation, then respawned the same task id with `openai-codex/gpt-5.4-mini`.
The qualified route completed successfully.

A connected Herdr client also closed the original primary workspace during the run.
The primary Pi session, persistent Firstmate home, task metadata, brief, and status survived.
A resumed primary reacquired the fleet through `bin/fm-session-start.sh` and supervised the task to completion.
The resumed primary had to remain in its own Herdr workspace; placing it inside the task tab made ordinary dead-task replacement close the supervisor with that tab.

Three operator interventions were required: qualify the provider route, restart the primary after its workspace closed, and move the resumed primary into a dedicated workspace.
Firstmate then handled child steering, report acceptance, and agent exit itself.

## Lessons promoted into the system

- Operational state must always resolve through `$FM_HOME`; repo-relative `data/` and `projects/` created non-persistent duplicates during the first attempt.
- Pi dispatch must use a provider-qualified model id when authentication depends on the provider route.
- A primary Firstmate Herdr pane must not share a task tab that the backend may replace during recovery.

## Scope

This proves the same-Pod task path, parent-only task communication, human observation, provider-qualified model recovery, and primary-session recovery locally.
It does not prove a separately resourced crewmate Pod, unique child work surviving a Pod restart, Akua-managed infrastructure, GitHub delivery, or production access boundaries.
