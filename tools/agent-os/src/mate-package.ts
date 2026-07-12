import {
  Akua,
  AkuaRateLimitedError,
  AkuaUserError,
  type RenderOptions,
  type RenderSummary,
} from "@akua-dev/sdk";
import { Data, Effect } from "effect";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { formatKubernetesAgentAddress } from "./address.ts";

export interface RenderMatePackageOptions {
  cluster?: string;
  image?: string;
  mateId: string;
  namespace?: string;
  outDir?: string;
}

export interface RenderedMatePackage {
  address: string;
  outDir: string;
}

export class MatePackageInputError extends Data.TaggedError(
  "MatePackageInputError",
)<{
  readonly cause: unknown;
  readonly message: string;
}> {}

export class AkuaRenderError extends Data.TaggedError("AkuaRenderError")<{
  readonly cause: unknown;
  readonly message: string;
}> {}

export class AkuaPackageUserError extends Data.TaggedError(
  "AkuaPackageUserError",
)<{
  readonly cause: Error;
  readonly message: string;
}> {}

export class AkuaPackageRateLimitedError extends Data.TaggedError(
  "AkuaPackageRateLimitedError",
)<{
  readonly cause: Error;
  readonly message: string;
}> {}

export interface AkuaRenderer {
  render(options: RenderOptions): Promise<RenderSummary>;
}

const packageDirectory = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "../packages/mate",
);

const defaultAkua = new Akua();

function mapAkuaError(cause: unknown) {
  if (cause instanceof AkuaRateLimitedError) {
    return new AkuaPackageRateLimitedError({
      cause,
      message: "Akua rate-limited the mate package render",
    });
  }
  if (cause instanceof AkuaUserError) {
    return new AkuaPackageUserError({
      cause,
      message: cause.message,
    });
  }
  return new AkuaRenderError({
    cause,
    message: "Akua could not render the mate package",
  });
}

export const renderMatePackage = Effect.fn("agent-os.renderMatePackage")(
  function* (
    options: RenderMatePackageOptions,
    akua: AkuaRenderer = defaultAkua,
  ) {
    const cluster = options.cluster ?? "in-cluster";
    const namespace = options.namespace ?? "agent-os";
    const address = formatKubernetesAgentAddress(options.mateId, {
      cluster,
      namespace,
    });
    const outDir = resolve(
      options.outDir ?? resolve(process.cwd(), "deploy", options.mateId),
    );
    const temporaryDirectory = yield* Effect.tryPromise({
      try: () => mkdtemp(resolve(tmpdir(), "agent-os-mate-")),
      catch: (cause) =>
        new MatePackageInputError({
          cause,
          message: "Could not create temporary Akua inputs",
        }),
    });

    const render = Effect.gen(function* () {
      const inputsPath = resolve(temporaryDirectory, "inputs.json");
      yield* Effect.tryPromise({
        try: () =>
          writeFile(
            inputsPath,
            JSON.stringify(
              {
                address,
                image: options.image ?? "agent-os:dev",
                mateId: options.mateId,
                namespace,
              },
              null,
              2,
            ),
          ),
        catch: (cause) =>
          new MatePackageInputError({
            cause,
            message: "Could not write temporary Akua inputs",
          }),
      });
      yield* Effect.tryPromise({
        try: () =>
          akua.render({
            inputs: inputsPath,
            out: outDir,
            package: resolve(packageDirectory, "package.k"),
            timeout: "30s",
          }),
        catch: mapAkuaError,
      });

      return { address, outDir } satisfies RenderedMatePackage;
    });

    return yield* render.pipe(
      Effect.ensuring(
        Effect.promise(() => rm(temporaryDirectory, { force: true, recursive: true })),
      ),
    );
  },
);
