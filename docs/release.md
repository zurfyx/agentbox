# Release operations

## Publishing model

Version-bearing source files use the valid-SemVer `0.0.0` sentinel. It is a
development/template identity and can never be published. The release
reconciler derives the next patch version from the numerically highest stable
published tag; maintainers do not choose or commit the next version. The
renderer injects that derived version only into staged outputs after obtaining
the multi-platform OCI digest, writes `share/agentbox/VERSION`, and packages
`agentbox-VERSION.tar.gz`.

The source Homebrew formula is likewise a canonical `0.0.0` template. Release
automation renders its version, URL, and SHA-256 and copies that exact result
into the tap proposal. Vendor executables do not belong in the source tree,
runtime image, or Agentbox archive.

Every successful protected-`main` push CI run wakes the same release
reconciler, whether the commit came from a person or an App. Daily and manual
wakeups provide recovery. The reconciler publishes eligible commits in
first-parent order and safely no-ops when work is already complete. Manual
recovery may identify a source commit but never supplies a version.

Published versions after the legacy `v0.1.0` anchor must read back as immutable
before Homebrew propagation can finish. Vendor discovery runs daily, resolves
and verifies the moving Claude and Codex channels, rejects downgrades and
same-version metadata drift, and may change only `release-inputs.json` on the
stable App-owned `automation/vendor-update` branch. Merging that
protected-CI-gated proposal is an ordinary main commit; only the release
reconciler allocates its Agentbox version.

## Current publishing runbook

### Confirm repository prerequisites

Repository owners should verify these durable controls before relying on
automatic publication:

1. GitHub **Immutable releases** is enabled, and the matching Actions variable
   records that prerequisite:

   ```sh
   repo=zurfyx/agentbox
   gh api --method PUT "repos/$repo/immutable-releases"
   test "$(gh api "repos/$repo/immutable-releases" --jq .enabled)" = true
   gh variable set IMMUTABLE_RELEASES_ENABLED --repo "$repo" --body true
   ```

2. The configured Agentbox GitHub App is installed on both `agentbox` and
   `homebrew-tap`. Its installation allows `Contents: read/write`,
   `Pull requests: read/write`, and, on `agentbox`, `Workflows: read/write`.
   The `agentbox` repository has the Actions variable `AGENTBOX_APP_ID` and
   secret `AGENTBOX_APP_PRIVATE_KEY`.

3. Protected `main` requires the GitHub Actions `required` check, the `release`
   environment permits deployments from protected `main`, and tap `main` has
   its intended protections:

   ```sh
   gh api "repos/$repo/branches/main/protection" \
     --jq '{required_status_checks,enforce_admins,required_linear_history}'
   gh api "repos/$repo/environments/release" \
     --jq '{protection_rules,deployment_branch_policy}'
   gh api repos/zurfyx/homebrew-tap/branches/main/protection \
     --jq '{required_status_checks,enforce_admins,required_linear_history}'
   ```

### Publish an eligible commit

Merge a reviewed change through protected `main`. Its successful push CI wakes
the release reconciler, which processes the oldest eligible unreleased
first-parent commit and derives the next patch version. Do not edit source
version sentinels or predict a specific next version.

Watch the release workflow and use its plan output to distinguish `publish`,
`resume`, and `noop` outcomes:

```sh
gh run list --repo zurfyx/agentbox --workflow release.yml --limit 5
gh run watch RUN_ID --repo zurfyx/agentbox --exit-status
```

For a publish or resume, record the actual published version and full source
commit, then run the durable identity checks below. Do not treat workflow
success alone as proof that the release, image, and tap agree.

## Recovery

A normal recovery is a no-input dispatch. The reconciler observes durable
release, image, and tap state, then resumes the oldest eligible work or returns
a `noop` plan when nothing remains:

```sh
gh workflow run release.yml --repo zurfyx/agentbox --ref main
gh run list --repo zurfyx/agentbox --workflow release.yml --limit 5
gh run watch RUN_ID --repo zurfyx/agentbox --exit-status
```

To target an already eligible source explicitly, use its full commit SHA:

```sh
gh workflow run release.yml --repo zurfyx/agentbox --ref main \
  -f recovery_source_commit=0123456789abcdef0123456789abcdef01234567
```

`recovery_source_commit` cannot skip an older eligible commit. The destructive
orphan option is narrower still: it requires the matching recovery SHA and is
valid only for a mismatched, unpublished next-version image with no Git tag or
GitHub release. Inspect the reported digest and source first, then dispatch:

```sh
gh workflow run release.yml --repo zurfyx/agentbox --ref main \
  -f recovery_source_commit=0123456789abcdef0123456789abcdef01234567 \
  -f replace_unpublished_image=true
```

Tap repair always has priority. If tap `main` does not yet contain the latest
published release, the run repairs or resumes the App-owned tap proposal first;
a requested source or orphan recovery is deferred. Wait for exact tap readback,
then dispatch the requested recovery again.

## Verify durable release identities

Set the values from the actual publish or recovery result. `VERSION` is the
published version without the `v` prefix; `SOURCE_COMMIT` is its expected full
40-character source SHA. The guards intentionally prevent copying an example
version into a live verification:

```sh
repo=zurfyx/agentbox
version="${VERSION:?set VERSION to the actual published version without v}"
source="${SOURCE_COMMIT:?set SOURCE_COMMIT to the expected full source SHA}"
release=$(gh api "repos/$repo/releases/tags/v$version")
jq -e --arg version "$version" '
  .draft == false and .prerelease == false and .immutable == true and
  ([.assets[].name] | sort) == [
    "agentbox-" + $version + ".provenance.json",
    "agentbox-" + $version + ".tar.gz",
    "agentbox-" + $version + ".tar.gz.sha256"
  ] and all(.assets[]; .digest | test("^sha256:[0-9a-f]{64}$"))
' <<<"$release"

verify_dir=$(mktemp -d)
gh release download "v$version" --repo "$repo" --dir "$verify_dir"
(cd "$verify_dir" && shasum -a 256 -c "agentbox-$version.tar.gz.sha256")
jq -e --arg version "$version" --arg source "$source" '
  .agentbox_version == $version and .source_commit == $source and
  .archive == ("agentbox-" + $version + ".tar.gz") and
  (.archive_sha256 | test("^[0-9a-f]{64}$")) and
  (.runtime_image | test("@sha256:[0-9a-f]{64}$"))
' "$verify_dir/agentbox-$version.provenance.json"
docker buildx imagetools inspect \
  "$(jq -r .runtime_image "$verify_dir/agentbox-$version.provenance.json")" >/dev/null

tag=$(gh api "repos/$repo/git/ref/tags/v$version")
tag_type=$(jq -r .object.type <<<"$tag")
tag_source=$(jq -r .object.sha <<<"$tag")
if test "$tag_type" = tag; then
  tag_source=$(gh api "repos/$repo/git/tags/$tag_source" --jq .object.sha)
fi
test "$tag_source" = "$source"

archive_sha=$(jq -r .archive_sha256 "$verify_dir/agentbox-$version.provenance.json")
tap_formula=$(gh api \
  "repos/zurfyx/homebrew-tap/contents/Formula/agentbox.rb?ref=main" \
  --jq .content | base64 -D)
grep -Fx "  version \"$version\"" <<<"$tap_formula"
grep -Fx "  sha256 \"$archive_sha\"" <<<"$tap_formula"
grep -Fx "  url \"https://github.com/$repo/releases/download/v$version/agentbox-$version.tar.gz\"" \
  <<<"$tap_formula"
```

Remove the temporary verification directory when finished. Docker Desktop
integration and real vendor authentication are separate manual release checks.
CI uses fixtures and must not consume personal credentials.
