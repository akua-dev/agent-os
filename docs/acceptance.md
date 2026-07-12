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
| Replaceable usable model supply | Pi auth is explicit, but the live demo has one Codex provider and current quota exhaustion | Blocked until an approved route has capacity |
| Same-Pod general-purpose crewmate | Existing Firstmate Herdr backend | Not yet captured as acceptance evidence |
| Separate persistent crewmate Pod with explicit authority | Mate package, no ServiceAccount token by default, explicit Pi Secret grant | Package proven; full task run incomplete |
| Parent-only supervision and human attach | Firstmate contract, Herdr CLI, live workspaces | Mechanism proven; distributed task trace incomplete |
| Real issue to tested review-ready PR | Existing Firstmate delivery machinery | Not yet proven through the Kubernetes fleet |
| Parent and child restart without unique-work loss | Parent PVC restart proven | Child unique-work recovery not yet proven |
| Separate production read-only and scoped write identity | Cortex contract only | Not yet implemented or Red-approved |
| Optional GitHub Issue/Project client | Cortex contract only | Deferred until terminal-native path passes |
| Repeatable end-to-end eval and recordable demo | Deterministic unit checks and local smoke evidence | Full critical-path run not yet captured |
| Public installable image and release | Multi-architecture GHCR workflow added; local image only | Publication not yet proven |

## Definition of done

Agent OS is finished only when every row is backed by current external evidence and no row remains partial or unproven.
The complete run must record time-to-cluster, time-to-Firstmate, time-to-crewmate, time-to-PR, recovery time, model and infrastructure cost, human interventions, immutable image digest, resource and operation IDs, and sanitized failure evidence.
