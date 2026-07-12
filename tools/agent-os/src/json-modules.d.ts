declare module "*.json" {
  const value: { readonly $defs: Readonly<Record<string, unknown>> };
  export default value;
}
