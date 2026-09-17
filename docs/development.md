# Development

Node.js 22 or newer is used only for repository checks and Husky; it is not an
end-user runtime dependency. The host launcher targets macOS's `/bin/bash` 3.2.
To create and check a source checkout:

```sh
git clone https://github.com/zurfyx/agentbox.git
cd agentbox
npm ci
npm run check
```

Individual checks are available as `npm run test:unit`, `npm run test:static`,
`npm run lint`, and `npm run format:check`.

## Running from source

A checkout has reviewed release inputs, not the final digest-bound manifest
shipped in a release archive. Use the development wrapper for commands that
need a manifest:

```sh
./scripts/dev.sh setup
./scripts/dev.sh -- claude --resume
./scripts/dev.sh --no-build -- codex
```

The wrapper builds the payload-free image, inspects its immutable local image
ID, renders a temporary development manifest, and opts the launcher into
explicit development mode. `--no-build` reuses this commit's existing local
image but still inspects and records its immutable ID; a mutable tag is never
authoritative.

Plain `./bin/agentbox setup` intentionally refuses an unrendered checkout.
`./bin/agentbox --help`, `--version`, and `info` remain useful directly because
they do not prepare or launch a release.

For source-only host-bridge development:

```sh
make docker-build
./setup-host-bridge.sh --dev-image agentbox-runtime:dev
```

## Repository invariants

- Run the complete `npm run check` gate before submitting changes.
- Keep the runtime image payload-free and non-root. Do not add vendor binaries
  to the image or archive.
- Preserve exact release identities, immutable prepared state, atomic selector
  changes, credential routing, and isolated candidate validation.
- Version-bearing source files and the source Homebrew formula use the valid
  SemVer `0.0.0` sentinel. Do not bump those templates by hand.
- Update user documentation and deterministic tests with behavior changes.

See [Release operations](release.md) for the publishing model and recovery
runbook, and [Security](security.md) before changing mounts, credentials, or
container privileges.
