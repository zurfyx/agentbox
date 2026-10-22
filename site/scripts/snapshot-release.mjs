// Refreshes the release snapshot the site falls back to when a build cannot
// reach GitHub. Run with `npm run snapshot`.

import { writeFileSync } from "node:fs";
import { fetchRelease } from "../src/lib/release.ts";

const { live, ...release } = await fetchRelease();
const target = new URL("../src/data/release-snapshot.json", import.meta.url);
writeFileSync(target, `${JSON.stringify(release, null, 2)}\n`);
console.log(`Snapshot updated to Agentbox ${release.version}.`);
