# Herdr 0.7.3 distribution record

This is a factual distribution record for the Agent OS image and is not legal advice.

## License and source record

Herdr v0.7.3 declares AGPL-3.0-or-later or a commercial license in its upstream `LICENSE` and README.
Agent OS uses the AGPL-3.0-or-later grant for this distribution.
The fixed upstream v0.7.3 tag resolves to commit `299dd4163a96381ec2d8e5bde13d7ba6d6432373`.
The matching source archive and its SHA-256 are recorded in [`THIRD_PARTY_SOURCES.md`](../THIRD_PARTY_SOURCES.md).
The image includes the upstream license at `/usr/share/licenses/herdr/LICENSE` and its source offer at `/usr/share/doc/agent-os/THIRD_PARTY_SOURCES.md`.

## Technical boundary

The Dockerfile downloads only Herdr's published Linux executable, verifies its release SHA-256, and marks it executable.
The Dockerfile does not patch the executable or copy Herdr source into Agent OS.
The image starts Herdr as the separate process `herdr server`.
Agent OS shell adapters invoke Herdr through its CLI and socket interfaces rather than importing, linking, or embedding Herdr code.

These facts support the AGPL section 5 aggregate condition only while Herdr remains a separate and independent work that is not an extension of, or combined into a larger program with, Agent OS.
The AGPL states that inclusion of a covered work in such an aggregate does not apply the license to the other parts of the aggregate.
Any change that patches Herdr, copies its source into Agent OS, links it with Agent OS code, or creates another derivative coupling must stop this release path and receive a fresh license review before publication.

## Conveyance obligations

AGPL section 4 requires the applicable license and notices to remain with verbatim copies.
The image preserves Herdr's upstream license and puts the recipient-facing notice and source offer in standard documentation paths.
AGPL section 6 permits network conveyance when equivalent corresponding source access is clearly directed from the object-code distribution.
The checked source URL, immutable commit, archive checksum, and build command are present both in this repository and inside the image without an Agent OS, Akua, or Herdr account requirement.
Release maintainers must keep that source path available for every published image carrying this executable.

Section 13 requires a no-charge network source offer when an operator modifies Herdr and users interact with that modified version remotely.
Agent OS conveys Herdr unmodified, so this image distribution does not rely on section 13 for the source offer.
If an operator or future release modifies Herdr, that version must prominently offer its corresponding source to remote users as section 13 requires.
