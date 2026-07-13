# Agent OS acceptance ledger

This ledger maps the Cortex distributed-Firstmate acceptance contract to current claim-matched evidence.
Update it from real runs; planned behavior and model narration never count as proof.

| Requirement | Current evidence | State |
| --- | --- | --- |
| Persistent Firstmate and Herdr in Kubernetes | OrbStack demo plus generic package render and disposable-cluster run in `docs/evidence/2026-07-12-firstmate-package.md` | Proven locally |
| Firstmate cluster-admin limited to the intelligence cluster | Dedicated local namespace and explicit demo ClusterRoleBinding | Proven locally only |
| Direct Akua-managed KaaS and Hetzner bootstrap | Public endpoint study and `akua-intelligence-bootstrap` skill | Not yet run |
| Distinct clustered token and bootstrap-token revocation | Explicit Secret mount in the Firstmate package and handoff procedure | Not yet run |
| Firstmate-native Akua worker lifecycle | Native endpoint routing in the bootstrap skill | Not yet run |
| Replaceable usable model supply | `openai-codex/gpt-5.4-mini` completed the same-Pod task; Terra-low completed the separate-Pod and recovery tasks; the current local overlay converges direct Pi, crewmate, and Secondmate defaults to `openai-codex/gpt-5.6-terra` with low thinking | One provider with multiple models proven locally; replacement provider still unproven |
| Same-Pod general-purpose crewmate | Firstmate-supervised Pi scout, real Kubernetes test, in-cluster context check, and report in `docs/evidence/2026-07-13-same-pod-firstmate.md` | Proven locally |
| Separate persistent crewmate Pod with explicit authority | Terra-low task, explicit resources, read-only Pi Secret, no ServiceAccount token, and retained PVC in `docs/evidence/2026-07-13-separate-pod-recovery.md` | Proven locally |
| Parent-only supervision and human attach | Same-Pod and separate-Pod tasks accepted only Firstmate briefs and steers; a connected Herdr client observed the live workspaces | Proven locally |
| Real issue to tested review-ready PR | Issue [#2](https://github.com/akua-dev/agent-os/issues/2) became Terra-low task `fix-local-rebuild-image-r2`, tested commit `761223c`, and PR [#3](https://github.com/akua-dev/agent-os/pull/3), then merged into review branch PR #1; see `docs/evidence/2026-07-13-github-issue-pr.md` | Proven locally |
| Parent and child restart without unique-work loss | Primary session recovery plus separate-Pod replacement with unique artifact, report, tools, and exact Pi session resumed | Proven locally |
| Separate production read-only and scoped write identity | Cortex contract only | Not yet implemented or Red-approved |
| Optional GitHub Issue/Project client | Repository Issues enabled only when the native intake proof needed it; Firstmate read Issue #2 through `gh-axi` and delivered PR #3 with no custom intake service | Issue client proven locally; Project client remains optional and unproven |
| Repeatable end-to-end eval and recordable demo | Same-Pod and separate-Pod run records now capture model, time, cost estimate, interventions, resource IDs, and failures | Local agent lifecycle captured; Akua/GitHub/product path incomplete |
| Public installable image and release | Multi-architecture workflow run `29188585384` succeeded; local image only because pull-request builds do not publish | Publication not yet proven |

## Definition of done

Agent OS is finished only when every row is backed by current external evidence and no row remains partial or unproven.
The complete run must record time-to-cluster, time-to-Firstmate, time-to-crewmate, time-to-PR, recovery time, model and infrastructure cost, human interventions, immutable image digest, resource and operation IDs, and sanitized failure evidence.
