# GitHub Issue to Kubernetes crewmate PR verification

Date: 2026-07-13
Kubernetes context: `orbstack`
Namespace: `agent-os-demo`
Issue: [#2 Make local rebuilds select the new Agent OS image](https://github.com/akua-dev/agent-os/issues/2)
Delivery PR: [#3 fix: select rebuilt local demo image](https://github.com/akua-dev/agent-os/pull/3)
Final review surface: [#1 feat: run Firstmate as a Kubernetes agent OS](https://github.com/akua-dev/agent-os/pull/1)

## Claim

A GitHub Issue can act as optional Agent OS intake without becoming the runtime
or communication layer. A Kubernetes-resident Firstmate can read that issue,
turn it into a precise brief, dispatch and supervise a general-purpose
crewmate, and return a tested review-ready PR. Ordinary Git, GitHub, Firstmate
files, treehouse worktrees, and Herdr terminals remain the operating substrate.

## Topology and authority

- Primary Firstmate: Pi in dedicated Herdr workspace `w6`, persistent
  `FM_HOME=/home/agent`.
- Crewmate task: `fix-local-rebuild-image-r2`, Herdr pane `w2:p9`.
- Model policy: `openai-codex/gpt-5.6-terra`, low thinking, recorded in the
  task metadata.
- Worktree:
  `/home/agent/.treehouse/agent-os-eaf3be/1/agent-os`.
- Delivery mode: `direct-PR`; no custom task service, workflow engine, or
  inter-agent protocol.
- GitHub authority came from the selected credential already persisted in the
  Firstmate home. No credential value was copied into the brief or evidence.

The evaluator initially discovered that the public Agent OS repository had
Issues disabled. It enabled only that native repository surface, then created
Issue #2 from the observed stale-image failure. No GitHub Project or additional
intake service was required.

## Parent-only supervision

The evaluator prompted only the primary Firstmate. Firstmate read Issue #2 with
`gh-axi`, registered the existing Agent OS clone, wrote the child brief, and
spawned the crewmate through:

```text
spawned fix-local-rebuild-image-r2 harness=pi kind=ship mode=direct-PR
model=openai-codex/gpt-5.6-terra effort=low
window=default:w2:p9
```

Firstmate handled the Pi trust prompt through `fm-send.sh`, polled the child's
status and pane, armed `fm-pr-check.sh`, and inspected the delivered diff. The
evaluator made read-only Herdr observations and never prompted or steered the
child directly. The primary pane was moved into its own workspace early in the
run so task-tab cleanup could not remove the supervisor.

## RED and GREEN evidence

The child first extended `tests/agent-os-local.test.sh`. Against the old helper,
the focused test failed for the missing immutable tag operation:

```text
not ok - build must assign the rebuilt image a unique local tag
(missing exact call: docker tag agent-os:dev agent-os:local-rebuilt)
RED_EXIT=1
```

Commit `761223c533de5cba5a96681cf769ec12164a267e` then:

- tags the default local image with its Docker image ID;
- updates both StatefulSet containers to that content-specific tag on deploy;
- preserves an explicit `AGENT_OS_IMAGE` without retagging it;
- documents the behavior; and
- adds hermetic stale-tag and override tests.

The child passed `tests/agent-os-local.test.sh` and shell syntax checks. Its
attempt to run `tests/agent-os-kubernetes.test.sh` correctly exposed an
environment boundary: an in-cluster Firstmate Pod has a ServiceAccount token,
so it cannot represent the test's token-free host case.

The evaluator closed that evidence gap from an isolated host worktree at the
exact child commit. All `tests/agent-os-*.test.sh` passed, including the
host-only refusal case. Focused ShellCheck, `bash -n`, and `git diff --check`
also passed. This independent result was recorded as a PR #3 comment before
integration.

## GitHub result and timings

- Issue #2 created: `2026-07-13T08:55:04Z`.
- PR #3 created: `2026-07-13T09:01:43Z`.
- Issue-to-review-ready-PR: 6 minutes 39 seconds.
- PR #3 merged into `feat/orbstack-demo`: `2026-07-13T09:05:28Z`.
- Issue-to-verified-integration: 10 minutes 24 seconds.
- Merge commit on the review branch:
  `7679bda383d044aaec6d6fae7231bb7c0fb80576`.
- Files changed by the child: `AGENTS.md`, `bin/agent-os-local.sh`,
  `docs/kubernetes.md`, and `tests/agent-os-local.test.sh`.

Pi displayed approximate subscription cost estimates of `$0.966` for the child
and `$0.815` for the primary by the end of their panes. These are UI estimates,
not provider invoices.

Three evaluator interventions occurred: move the primary into a dedicated
workspace, run the host-only verification, and merge the verified stacked PR
into the final review branch. No evaluator intervention changed the child's
implementation.

## Scope

This proves native GitHub Issue intake, parent-only same-Pod delegation, real
RED-to-GREEN implementation, a tested review-ready PR, and integration into the
single Agent OS review branch. It does not prove GitHub Projects, an
Akua-managed intelligence cluster, Akua worker lifecycle, or product-cluster
access boundaries.
