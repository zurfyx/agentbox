# Contributor agent guidance

- Read `README.md` and the relevant file under `docs/` before changing behavior.
- Keep the user path direct: installation followed by `agentbox claude` or
  `agentbox codex`; do not make `setup` or `doctor` prerequisites.
- Preserve the payload-free, non-root runtime, exact manifest identities,
  immutable prepared snapshots, atomic activation, isolated validation, and
  documented credential routing.
- Treat `0.0.0` as the source/template sentinel. Release automation owns
  published versions, URLs, and checksums.
- Use `scripts/dev.sh` for agent launches from a checkout. Never add vendor
  executables to the repository, runtime image, or release archive.
- Keep public behavior, docs, completions, packaging, and deterministic tests in
  sync. Run `npm run check` before handing off a change.
