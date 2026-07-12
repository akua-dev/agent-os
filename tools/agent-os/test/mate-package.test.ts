import { Effect } from "effect";
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  type AkuaRenderer,
  renderMatePackage,
} from "../src/mate-package.ts";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) =>
      rm(directory, { force: true, recursive: true }),
    ),
  );
});

describe("agent-os mate render", () => {
  test("passes typed inputs to the Akua SDK and reports the address", async () => {
    const root = await mkdtemp(resolve(tmpdir(), "agent-os-mate-test-"));
    temporaryDirectories.push(root);
    const outDir = resolve(root, "rendered");
    let capturedInputs: unknown;
    const akua: AkuaRenderer = {
      async render(options) {
        capturedInputs = JSON.parse(
          await readFile(options.inputs ?? "", "utf8"),
        );
        return {
          files: [],
          format: "raw-manifests",
          hash: "sha256:test",
          manifests: 2,
          target: options.out ?? outDir,
        };
      },
    };

    const output = await Effect.runPromise(
      renderMatePackage(
        {
          image: "ghcr.io/akua-dev/agent-os:test",
          mateId: "scout-1",
          namespace: "agent-os-demo",
          outDir,
        },
        akua,
      ),
    );

    expect(output).toEqual({
      address:
        "/k8s/in-cluster/namespace/agent-os-demo/mate/scout-1/herdr",
      outDir,
    });
    expect(capturedInputs).toEqual({
      address:
        "/k8s/in-cluster/namespace/agent-os-demo/mate/scout-1/herdr",
      image: "ghcr.io/akua-dev/agent-os:test",
      mateId: "scout-1",
      namespace: "agent-os-demo",
    });
  });

  test("keeps unexpected SDK failures in the typed error channel", async () => {
    const akua: AkuaRenderer = {
      render: () => Promise.reject(new Error("native addon failed")),
    };
    const exit = await Effect.runPromiseExit(
      renderMatePackage({ mateId: "scout-1" }, akua),
    );

    expect(exit._tag).toBe("Failure");
    expect(String(exit)).toContain("AkuaRenderError");
    expect(String(exit)).toContain("Akua could not render the mate package");
  });
});
