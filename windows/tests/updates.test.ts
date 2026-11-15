// Run: node --experimental-strip-types tests/updates.test.ts
import { fetchUpdate, htmlToText, isNewer, isTrustedDownload, notesExcerpt, pickUpdate, pickUpdateFromFeed, type Release } from "../src/updates.ts";

let failed = 0;
function check(ok: boolean, label: string) {
  if (!ok) failed += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
}

check(
  isNewer("0.2.0", "0.1.4") && isNewer("1.10", "1.9.9") && !isNewer("1.0", "1.0.0") && !isNewer("0.1.3", "0.1.4") &&
    !isNewer("junk", "0.1.4"),
  "update versions compare numerically",
);

const release = (tag: string, extra: Partial<Release> = {}): Release => ({
  tag_name: tag,
  body: "",
  draft: false,
  prerelease: true,
  html_url: `https://github.com/allenhack638/bucket-manager/releases/tag/${tag}`,
  assets: [],
  ...extra,
});
const releases: Release[] = [
  release("macos-v9.0.0", { prerelease: false }),
  release("windows-v0.3.0", { draft: true }),
  release("windows-v0.2.0", {
    body: "  Faster lists.  ",
    assets: [
      { name: "SHA256SUMS.txt", browser_download_url: "https://github.com/allenhack638/bucket-manager/releases/download/windows-v0.2.0/SHA256SUMS.txt" },
      { name: "Bucket.Manager_0.2.0_x64_en-US.msi", browser_download_url: "https://github.com/allenhack638/bucket-manager/releases/download/windows-v0.2.0/a.msi" },
      { name: "Bucket.Manager_0.2.0_x64-setup.exe", browser_download_url: "https://github.com/allenhack638/bucket-manager/releases/download/windows-v0.2.0/a-setup.exe" },
    ],
  }),
  release("windows-v0.1.5"),
];
const offered = pickUpdate(releases, "0.1.4");
check(
  offered?.version === "0.2.0" && offered.notes === "Faster lists." && offered.downloadUrl.endsWith("a-setup.exe"),
  "the update is the newest published Windows release and links its installer",
);
check(pickUpdate(releases, "0.2.0") === null, "no update is offered when the installed version is the newest");
check(
  pickUpdate([release("windows-v0.2.0", { html_url: "https://evil.example/x" })], "0.1.4") === null,
  "a release page outside GitHub is never offered",
);
check(
  isTrustedDownload("https://github.com/allenhack638/bucket-manager/releases/download/x.exe") &&
    !isTrustedDownload("https://github.com/someone/else/releases/download/x.exe") &&
    !isTrustedDownload("https://raw.githubusercontent.com/allenhack638/bucket-manager/x") &&
    !isTrustedDownload("https://github.com/allenhack638/bucket-manager/../../evil/x") &&
    !isTrustedDownload("https://github.com/allenhack638/bucket-manager/%2E%2E/x") &&
    !isTrustedDownload("https://user@github.com/allenhack638/bucket-manager/x") &&
    !isTrustedDownload("http://github.com/x") &&
    !isTrustedDownload("https://github.com.evil.example/x") &&
    !isTrustedDownload("file:///C:/x.exe"),
  "update downloads only open from GitHub over HTTPS",
);

check(
  notesExcerpt("# Title\r\n\r\n\r\n## Fixed\r\n- **Bold** and `code`\n```bash\nxattr x\n```") ===
    "Title\n\nFixed\n- Bold and code\nxattr x",
  "release notes show as plain text",
);

const feedXml = String.raw`<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <link rel="alternate" type="text/html" href="https://github.com/allenhack638/bucket-manager/releases/tag/windows-v0.3.0"/>
    <content type="html">&lt;p&gt;Windows notes&lt;/p&gt;</content>
  </entry>
  <entry>
    <link rel="alternate" type="text/html" href="https://github.com/allenhack638/bucket-manager/releases/tag/macos-v1.2.0"/>
    <content type="html">&lt;h2&gt;What&amp;#39;s new&lt;/h2&gt;
&lt;ul&gt;
&lt;li&gt;&lt;strong&gt;Faster&lt;/strong&gt; lists &amp;amp; uploads&lt;/li&gt;
&lt;li&gt;Fixes&lt;/li&gt;
&lt;/ul&gt;</content>
  </entry>
  <entry>
    <link rel="alternate" type="text/html" href="https://github.com/allenhack638/bucket-manager/releases/tag/macos-v1.1.0"/>
    <content type="html">&lt;p&gt;Older&lt;/p&gt;</content>
  </entry>
  <entry>
    <link rel="alternate" type="text/html" href="https://evil.example/allenhack638/bucket-manager/releases/tag/macos-v9.0.0"/>
    <content type="html">&lt;p&gt;Not GitHub&lt;/p&gt;</content>
  </entry>
</feed>
`;
const fromFeed = pickUpdateFromFeed(feedXml, "0.2.0");
check(
  fromFeed?.version === "0.3.0" &&
    fromFeed.downloadUrl === "https://github.com/allenhack638/bucket-manager/releases/tag/windows-v0.3.0" &&
    fromFeed.notes === "Windows notes",
  "when the GitHub API is limited, the releases feed finds the newest Windows release",
);
check(pickUpdateFromFeed(feedXml, "0.3.0") === null, "the releases feed reports up to date for the newest version");
check(
  htmlToText("<h2>What&#39;s new</h2>\n<ul>\n<li><strong>Faster</strong> lists &amp; uploads</li>\n<li>Fixes</li>\n</ul>") ===
    "What's new\n- Faster lists & uploads\n- Fixes",
  "release notes from the feed show as plain text",
);

let notFeedThrows = false;
try {
  pickUpdateFromFeed("<html>Wi-Fi login</html>", "0.2.0");
} catch {
  notFeedThrows = true;
}
check(notFeedThrows, 'a page that is not the releases feed is an error, never "up to date"');
check(
  pickUpdateFromFeed(
    feedXml.replace("windows-v0.3.0", "windows-v0.3.0%E0%A4%A") +
      `<entry><link href="https://github.com/allenhack638/bucket-manager/releases/tag/windows-v0.2.5"/><content type="html"></content></entry>`,
    "0.2.0",
  )?.version === "0.2.5",
  "a malformed release name is skipped, not fatal",
);
check(
  htmlToText("<p>Click Done on the<br>\nwarning&nbsp;now &#8594; ok</p>\n<ul><li class=\"task-list-item\">One</li></ul>") ===
    "Click Done on the\nwarning now → ok\n- One",
  "feed notes keep wrapped lines together and decode entities",
);

// The whole check: API first, then the feed through the backend loader.
const realFetch = globalThis.fetch;
globalThis.fetch = (async () => new Response("", { status: 403 })) as typeof fetch;
check(
  (await fetchUpdate("0.2.0", async () => feedXml))?.version === "0.3.0",
  "when the API is rate-limited, Check for Updates uses the releases feed",
);
let surfaced = "";
try {
  await fetchUpdate("0.2.0", async () => {
    throw new Error("offline");
  });
} catch (error) {
  surfaced = (error as Error).message;
}
check(surfaced.includes("limiting requests"), "when both fail, the API's reason is shown");
surfaced = "";
try {
  await fetchUpdate("0.2.0", async () => "<html>Wi-Fi login</html>");
} catch (error) {
  surfaced = (error as Error).message;
}
check(surfaced.includes("limiting requests"), "a Wi-Fi login page instead of the feed is reported as an error");
globalThis.fetch = realFetch;

if (failed) {
  console.error(`${failed} update check(s) failed`);
  process.exit(1);
}
