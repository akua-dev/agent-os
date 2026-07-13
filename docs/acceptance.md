# Agent OS acceptance ledger

This ledger maps the Cortex distributed-Firstmate acceptance contract to current claim-matched evidence.
Update it from real runs; planned behavior and model narration never count as proof.

| Requirement | Current evidence | State |
| --- | --- | --- |
| Portable Kubernetes core without Akua | `tools/agent-os/packages/firstmate/` and focused render/behavior tests prove a digest-required package, namespace-scoped default RBAC, persistent home, explicit lifecycle commands, and no package credential input | Render and command contracts proven; clean published-image run remains required |
| Persistent Firstmate and Herdr in Kubernetes | Canonical package render plus local lifecycle records in `docs/evidence/2026-07-12-firstmate-package.md` | Package render and local evidence proven; published-image run remains required |
| Firstmate cluster-admin limited to the intelligence cluster | Dedicated local namespace and explicit demo ClusterRoleBinding | Proven locally only |
| Direct Akua-managed KaaS and Hetzner bootstrap | Public endpoint study and `akua-intelligence-bootstrap` skill | Not yet run |
| Distinct clustered token and bootstrap-token revocation | Explicit Secret mount in the Firstmate package and handoff procedure | Not yet run |
| Firstmate-native Akua worker lifecycle | Native endpoint routing in the bootstrap skill | Not yet run |
| Replaceable usable model supply | `openai-codex/gpt-5.4-mini` completed the same-Pod task; Terra-low completed the separate-Pod and recovery tasks; the current local overlay converges direct Pi, crewmate, and Secondmate defaults to `openai-codex/gpt-5.6-terra` with low thinking | One provider with multiple models proven locally; replacement provider still unproven |
| Same-Pod general-purpose crewmate | Firstmate-supervised Pi scout, real Kubernetes test, in-cluster context check, and report in `docs/evidence/2026-07-13-same-pod-firstmate.md` | Proven locally |
| Separate persistent crewmate Pod with explicit authority | Terra-low task, explicit resources, read-only Pi Secret, no ServiceAccount token, and retained PVC in `docs/evidence/2026-07-13-separate-pod-recovery.md` | Proven locally |
| Parent-only supervision and human attach | Same-Pod and separate-Pod tasks accepted only Firstmate briefs and steers; a connected Herdr client observed the live workspaces | Proven locally |
| Real issue to tested review-ready PR | A private Cortex tracker issue became Terra-low task `fix-local-rebuild-image-r2`, tested commit `761223c`, and public PR [#3](https://github.com/akua-dev/agent-os/pull/3), then merged into review branch PR #1; see `docs/evidence/2026-07-13-github-issue-pr.md` | Proven locally |
| Parent and child restart without unique-work loss | Primary session recovery plus separate-Pod replacement with unique artifact, report, tools, and exact Pi session resumed | Proven locally |
| Separate production read-only and scoped write identity | Cortex contract only | Not yet implemented or Red-approved |
| Optional GitHub Issue/Project client | Firstmate read a private Cortex GitHub issue through `gh-axi` and delivered public PR #3 with no custom intake service; public Agent OS Issues are disabled because work tracking is private | Issue client proven locally; Project client remains optional and unproven |
| Repeatable end-to-end eval and recordable demo | Same-Pod and separate-Pod run records now capture model, time, cost estimate, interventions, resource IDs, and failures | Local agent lifecycle captured; Akua/GitHub/product path incomplete |
| Public installable image and release | Multi-architecture release workflow builds `linux/amd64` and `linux/arm64`, publishes only outside pull requests, and records the resulting digest in its job summary | Publication not yet proven |
| Herdr 0.7.3 source and notice bundle | `THIRD_PARTY_NOTICES.md`, `THIRD_PARTY_SOURCES.md`, the image documentation paths, and `tests/agent-os-container.test.sh` prove the unmodified-binary source offer and notice contract | Source and render contract proven; publication availability remains required |

## Definition of done

Agent OS is finished only when every row is backed by current external evidence and no row remains partial or unproven.
The portable Kubernetes gate and Akua integration gate are separate: the core must pass from published sources on local OrbStack without Akua, while the enhanced path separately proves Akua-managed bootstrap and guarded delivery.
The complete run must record time-to-cluster, time-to-Firstmate, time-to-crewmate, time-to-PR, recovery time, model and infrastructure cost, human interventions, immutable image digest, resource and operation IDs, and sanitized failure evidence.
