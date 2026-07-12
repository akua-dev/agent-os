# Agent OS evaluation strategy

This evaluation strategy was established on 2026-07-12 from failures observed in the live OrbStack demo.

## What to measure

Agent OS must be evaluated as an operating system around agents, not as a standalone model benchmark.
The primary score is whether the requested external state and safety constraints hold after a multi-step run.
Transcripts explain failures but do not override an incorrect outcome.

The first regression set covers these observed contracts:

- a mate receives no AI credential unless a Secret reference or explicit grant is selected;
- an empty credential grant produces a mate with no AI credential mount;
- a granted Pi auth file is mounted read-only from a Kubernetes Secret;
- an in-cluster kubeconfig follows the projected token file and never embeds its contents;
- a restored dead Herdr terminal may be replaced, while an idle or working agent may not;
- completion is the declared artifact, not a transient Herdr `idle` status;
- package output still denies the mate a Kubernetes token by default.

These are deterministic code and environment graders.
The address contract runs in Bun tests, container and kubeconfig boundaries run in shell tests, package behavior is checked statically and with a direct Akua render smoke test, and the complete lifecycle is exercised in the local Kubernetes demo.

## External research

[Anthropic's agent-eval guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) recommends combining code-based, model-based, and human graders and separating capability evals from near-100-percent regression evals.
That matches Agent OS: deterministic resource and artifact assertions protect known behavior, while transcript review and later model graders evaluate ambiguous instruction-following quality.

[OpenAI's agent eval guidance](https://developers.openai.com/api/docs/guides/agent-evals) provides datasets and trace grading that can later compare prompts, skills, models, and harness versions.
It is not needed to prove Kubernetes mounts, credential boundaries, or completion files.

[Inspect](https://inspect.aisi.org.uk/) supports external agents, transcript inspection, multiple scorers, and Docker or Kubernetes sandbox extensions.
It is the strongest candidate when Agent OS needs repeatable cross-model or cross-harness capability suites.
Adding its Python runtime today would duplicate the existing deterministic test harness without improving the current regression signal.

Public benchmarks such as tau-bench and SWE-bench measure useful general capabilities but do not exercise Agent OS's parent supervision, Kubernetes isolation, credential grants, Herdr recovery, or artifact delivery contracts.
They should inform model selection, not replace product-specific evals.

## Herdr Spreader evaluation

[`yuk1ty/herdr-spreader`](https://github.com/yuk1ty/herdr-spreader) was inspected at commit `1a42aae0f0dfb3a588da0dc6895ea24189de4012`.
It uses public Herdr CLI and plugin primitives to create declarative workspace, tab, pane, command, wait, environment, and focus layouts.
It is useful when one mate Pod needs several agents or supporting processes.
It does not create Kubernetes mates, supervise parent-child delivery, reconcile an existing layout, or remove stale terminals.
Repeated apply creates more workspaces rather than converging desired state.

Do not make Herdr Spreader mandatory yet.
If repeated multi-process mate layouts emerge, add an optional trusted layout ConfigMap and invoke the spreader once after Herdr is ready.
