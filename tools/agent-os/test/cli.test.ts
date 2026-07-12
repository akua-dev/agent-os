import { $ } from "bun";
import { describe, expect, test } from "bun:test";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));

describe("agent-os address CLI", () => {
  test("prints a Kubernetes address with in-cluster defaults", async () => {
    const output = await $`${process.execPath} ${cli} address k8s task-x`.text();

    expect(output.trim()).toBe(
      "/k8s/in-cluster/namespace/agent-os/mate/task-x/herdr",
    );
  });

  test("inspects an address as structured JSON", async () => {
    const address = "/local/mate/task-x/herdr";
    const output = await $`${process.execPath} ${cli} address inspect ${address}`.json();

    expect(output).toEqual({
      address,
      location: "local",
      mateId: "task-x",
      protocol: "herdr",
    });
  });

  test("fails closed for an invalid address", async () => {
    const result = await $`${process.execPath} ${cli} address inspect /mate/task-x`
      .quiet()
      .nothrow();

    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("Unsupported Agent OS address");
  });
});
