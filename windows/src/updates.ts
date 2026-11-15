// Finds the newest Windows release on GitHub. Only the public releases list
// is requested; nothing about the user's accounts or buckets is sent.

export const RELEASES_URL = "https://api.github.com/repos/allenhack638/bucket-manager/releases?per_page=30";
export const TAG_PREFIX = "windows-v";
export const AUTO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

export type Release = {
  tag_name: string;
  body?: string | null;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
  assets: { name: string; browser_download_url: string }[];
};

export type AvailableUpdate = {
  version: string;
  notes: string;
  /** The installer when the release has one, otherwise the release page. */
  downloadUrl: string;
};

/** "1.2.3" or "v1.2.3" as numbers; anything after "-" or "+" is ignored. */
export function versionParts(value: string): number[] | null {
  const core = value.replace(/^v/, "").split(/[-+]/)[0];
  const parts = core.split(".");
  if (!parts.length || parts.some((part) => !/^\d+$/.test(part))) return null;
  return parts.map(Number);
}

export function isNewer(candidate: string, installed: string): boolean {
  const a = versionParts(candidate);
  const b = versionParts(installed);
  if (!a || !b) return false;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const left = a[index] ?? 0;
    const right = b[index] ?? 0;
    if (left !== right) return left > right;
  }
  return false;
}

/** Update downloads only open from this project's own GitHub pages, over
 * HTTPS. GitHub redirects the browser to its file host from there. */
export const TRUSTED_DOWNLOAD_PREFIX = "https://github.com/allenhack638/bucket-manager/";

export function isTrustedDownload(url: string): boolean {
  const raw = url.toLowerCase();
  if (raw.includes("/..") || raw.includes("%2e")) return false;
  try {
    return new URL(url).href.startsWith(TRUSTED_DOWNLOAD_PREFIX);
  } catch {
    return false;
  }
}

/** Release notes as plain text (no Markdown heading or emphasis marks),
 * trimmed to fit a dialog. */
export function notesExcerpt(body: string, limit = 900): string {
  const trimmed = body
    .replace(/\r\n/g, "\n")
    .replace(/^```\w*[ \t]*\n?/gm, "")
    .replace(/^#{1,6}\s*/gm, "")
    .replace(/\*\*/g, "")
    .replace(/`/g, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return trimmed.length > limit ? `${trimmed.slice(0, limit).trim()}…` : trimmed;
}

/**
 * The newest published Windows release newer than `installed`. Windows builds
 * are still published as pre-releases, so those count; drafts never do.
 */
export function pickUpdate(releases: Release[], installed: string): AvailableUpdate | null {
  let best: { version: string; release: Release } | null = null;
  for (const release of releases) {
    if (release.draft || !release.tag_name.startsWith(TAG_PREFIX)) continue;
    const version = release.tag_name.slice(TAG_PREFIX.length);
    if (!versionParts(version)) continue;
    if (!best || isNewer(version, best.version)) best = { version, release };
  }
  if (!best || !isNewer(best.version, installed)) return null;

  const assets = best.release.assets.filter((asset) => isTrustedDownload(asset.browser_download_url));
  const installer =
    assets.find((asset) => asset.name.toLowerCase().endsWith("-setup.exe")) ??
    assets.find((asset) => asset.name.toLowerCase().endsWith(".msi"));
  const downloadUrl = installer?.browser_download_url ?? best.release.html_url;
  if (!isTrustedDownload(downloadUrl)) return null;
  return { version: best.version, notes: notesExcerpt(best.release.body ?? ""), downloadUrl };
}

export async function fetchUpdate(installed: string): Promise<AvailableUpdate | null> {
  const response = await fetch(RELEASES_URL, {
    headers: { Accept: "application/vnd.github+json" },
    cache: "no-store",
    signal: AbortSignal.timeout(15000),
  });
  if (response.status === 403 || response.status === 429) {
    throw new Error("GitHub is limiting requests right now. Try again in a few minutes.");
  }
  if (!response.ok) throw new Error(`GitHub answered with HTTP ${response.status}.`);
  return pickUpdate((await response.json()) as Release[], installed);
}
