import { describe, expect, test } from "bun:test";

import {
  formatKubernetesAgentAddress,
  formatLocalAgentAddress,
  parseAgentAddress,
} from "../src/address.ts";

describe("Agent OS Multiaddrs", () => {
  test("formats and parses a co-located Herdr mate", () => {
    const address = formatLocalAgentAddress("task-x");

    expect(address).toBe("/local/mate/task-x/herdr");
    expect(parseAgentAddress(address)).toEqual({
      address,
      location: "local",
      mateId: "task-x",
      protocol: "herdr",
    });
  });

  test("defaults Kubernetes addresses to the caller's cluster", () => {
    const address = formatKubernetesAgentAddress("task-x");

    expect(address).toBe(
      "/k8s/in-cluster/namespace/agent-os/mate/task-x/herdr",
    );
    expect(parseAgentAddress(address)).toEqual({
      address,
      cluster: "in-cluster",
      location: "kubernetes",
      mateId: "task-x",
      namespace: "agent-os",
      protocol: "herdr",
    });
  });

  test("accepts explicit registered cluster and namespace aliases", () => {
    const address = formatKubernetesAgentAddress("review-7", {
      cluster: "agents-eu",
      namespace: "company-factory",
    });

    expect(address).toBe(
      "/k8s/agents-eu/namespace/company-factory/mate/review-7/herdr",
    );
  });

  test.each([
    "/k8s/in-cluster/mate/task-x/herdr",
    "/k8s/in-cluster/namespace/agent-os/herdr/mate/task-x",
    "/local/namespace/agent-os/mate/task-x/herdr",
  ])("rejects an unsupported component sequence: %s", (address) => {
    expect(() => parseAgentAddress(address)).toThrow("Unsupported Agent OS address");
  });

  test.each(["Task-X", "-task", "task/other", "--namespace"])(
    "rejects an unsafe mate ID: %s",
    (mateId) => {
      expect(() => formatLocalAgentAddress(mateId)).toThrow("mate");
    },
  );
});
