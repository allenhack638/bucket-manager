// Run: node --experimental-strip-types tests/updates.test.ts
import { isNewer, isTrustedDownload, notesExcerpt, pickUpdate, type Release } from "../src/updates.ts";

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

if (failed) {
  console.error(`${failed} update check(s) failed`);
  process.exit(1);
}
