// Any failure falls back to the committed snapshot rather than breaking the
// build; `npm run snapshot` refreshes it.

import snapshot from "../data/release-snapshot.json";
import { fetchRelease, type Release } from "./release";

export async function getRelease(): Promise<Release> {
  try {
    return await fetchRelease();
  } catch (error) {
    console.warn(`[release] using the committed snapshot: ${(error as Error).message}`);
    return { ...(snapshot as Omit<Release, "live">), live: false };
  }
}
