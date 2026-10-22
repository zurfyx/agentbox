# Agentbox website

The landing page, built with [Astro](https://astro.build) as a single static
page and deployed on Vercel with `site/` as the project root.

```sh
cd site
npm install
npm run dev       # http://localhost:4321
npm run build     # static output in dist/
```

## Release data

Version numbers, digests, sizes, and checksums are never typed into the page.
At build time `src/lib/release.ts` reads the version the Homebrew tap serves,
that release's provenance record, and `release-inputs.json` at the release's
source commit. None of those requests use the rate-limited GitHub API.

If any request fails or returns something unexpected, the build falls back to
`src/data/release-snapshot.json` and logs a warning instead of failing. Refresh
the snapshot with `npm run snapshot`.

The page only changes when it is rebuilt, so a new release appears after the
next deployment.

## Copy

The page restates `README.md` and `docs/`. When public behavior changes there,
update the matching copy in `src/pages/index.astro`. The `agentbox info`
transcript in `src/components/Transcript.astro` mirrors the format printed by
`libexec/host.sh`.
