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

function decodeEntities(text: string): string {
  return text
    .replace(/&nbsp;/g, " ")
    .replace(/&#([0-9]{1,6});/g, (whole, digits: string) => {
      const value = Number(digits);
      return value === 38 || value > 0x10ffff ? whole : String.fromCodePoint(value);
    })
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");
}

/** Release notes HTML as plain lines: list items keep a "- " marker. */
export function htmlToText(html: string): string {
  const text = html
    .replace(/<li[^>]*>/g, "- ")
    .replace(/<br\s*\/?>\n?|<\/(p|li|h[1-6]|ul|ol|pre|div)>/g, "\n")
    .replace(/<[^>]+>/g, "");
  return decodeEntities(text)
    .replace(/\n\s*\n(?=- )/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * The newest Windows release in GitHub's Atom releases feed, newer than
 * `installed`. The feed has no asset list, so Download opens the release
 * page, where the installers are. It lists only the ten newest releases of
 * both apps. Throws when the body is not a releases feed (a Wi-Fi login
 * page, say), so that is never mistaken for "up to date".
 */
export function pickUpdateFromFeed(xml: string, installed: string): AvailableUpdate | null {
  if (!xml.includes("<feed") || !xml.includes("/releases/tag/")) {
    throw new Error("GitHub's releases page could not be read.");
  }
  let best: { version: string; page: string; notes: string } | null = null;
  for (const entry of xml.split("<entry>").slice(1)) {
    const href = /<link[^>]*href="([^"]+)"/.exec(entry)?.[1];
    if (!href) continue;
    const page = decodeEntities(href);
    if (!isTrustedDownload(page) || !page.includes("/releases/tag/")) continue;
    let tag: string;
    try {
      tag = decodeURIComponent(page.split("/").pop() ?? "");
    } catch {
      continue;
    }
    if (!tag.startsWith(TAG_PREFIX)) continue;
    const version = tag.slice(TAG_PREFIX.length);
    if (!versionParts(version)) continue;
    if (best && !isNewer(version, best.version)) continue;
    const content = /<content[^>]*>([\s\S]*?)<\/content>/.exec(entry)?.[1] ?? "";
    best = { version, page, notes: htmlToText(decodeEntities(content)) };
  }
  if (!best || !isNewer(best.version, installed)) return null;
  return { version: best.version, notes: notesExcerpt(best.notes), downloadUrl: best.page };
}

async function fetchFromApi(installed: string): Promise<AvailableUpdate | null> {
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

/**
 * Asks the GitHub API first; if that fails (GitHub allows 60 API requests an
 * hour per network, which offices and VPNs use up), falls back to GitHub's
 * releases feed, which the backend downloads (`loadFeed`) because github.com
 * does not allow the web view to fetch it directly.
 */
export async function fetchUpdate(
  installed: string,
  loadFeed: () => Promise<string>,
): Promise<AvailableUpdate | null> {
  try {
    return await fetchFromApi(installed);
  } catch (apiError) {
    try {
      return pickUpdateFromFeed(await loadFeed(), installed);
    } catch {
      // Report the API's reason, e.g. GitHub limiting requests.
      throw apiError;
    }
  }
}
