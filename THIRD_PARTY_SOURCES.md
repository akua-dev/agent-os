# Third-party source offers

This file is copied into every Agent OS image at `/usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md`.
It gives image recipients a no-account network path to the corresponding source for included copyleft software.

## Herdr 0.7.3

Agent OS conveys the upstream `herdr-linux-x86_64` or `herdr-linux-aarch64` executable from Herdr v0.7.3 as an unmodified executable.
Agent OS does not patch, link, embed, or copy Herdr source into Agent OS.
The Agent OS entrypoint executes the executable as the separate process `herdr server`.

The immutable upstream source commit is `299dd4163a96381ec2d8e5bde13d7ba6d6432373`.
The complete source archive is <https://github.com/ogulcancelik/herdr/archive/299dd4163a96381ec2d8e5bde13d7ba6d6432373.tar.gz>.
The SHA-256 of that archive is `4e4a536fff8cd74019a1f8b4f1eef7fce556042f2b3e389eb6f9a155c1a7c6d5`.
The archive contains Herdr's source, `Cargo.lock`, `Cargo.toml`, `build.rs`, and its vendored `portable-pty` patch source.

To retrieve and verify the source, run:

```bash
curl --fail --location --output herdr-v0.7.3.tar.gz \
  https://github.com/ogulcancelik/herdr/archive/299dd4163a96381ec2d8e5bde13d7ba6d6432373.tar.gz
printf '%s  %s\n' \
  4e4a536fff8cd74019a1f8b4f1eef7fce556042f2b3e389eb6f9a155c1a7c6d5 \
  herdr-v0.7.3.tar.gz | sha256sum --check
tar -xzf herdr-v0.7.3.tar.gz
cd herdr-299dd4163a96381ec2d8e5bde13d7ba6d6432373
cargo build --release
```

The source is offered under the upstream GNU Affero General Public License v3.0 or later at <https://github.com/ogulcancelik/herdr/blob/299dd4163a96381ec2d8e5bde13d7ba6d6432373/LICENSE>.
The complete distribution record and the rule for any future Herdr modification are in `docs/herdr-compliance.md`.
