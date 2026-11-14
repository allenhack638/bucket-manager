// Device names Windows reserves, with or without an extension. Superscript
// digits count too (COM¹), and Win32 ignores spaces before the extension.
const RESERVED = /^(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$/i;
// Bidirectional controls can disguise "invoice\u202Efdp.exe" as "invoiceexe.pdf".
const BIDI_CONTROLS = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

/**
 * Turns an object name into a bare Windows file name for the Save dialog.
 * Object keys are untrusted: a name like "\\attacker\share\a.pdf" passed as
 * defaultPath makes Windows contact that SMB server (leaking the user's NTLM
 * hash) before the dialog even opens, so separators, drive prefixes and
 * characters Windows forbids are all replaced.
 */
export function safeFileName(name: string): string {
  const lastSegment = name.split(/[\\/]/).filter(Boolean).pop() ?? "";
  const cleaned = lastSegment
    .replace(BIDI_CONTROLS, "")
    .replace(/[<>:"|?*\u0000-\u001f]/g, "_");
  let result = trimEnd(truncate(cleaned, 200));
  if (result === "" || result === "." || result === "..") result = "download";
  if (RESERVED.test(result.replace(/ +(?=\.|$)/g, ""))) result = `_${result}`;
  return result;
}

/** Windows limits names to 255 UTF-16 units; stop at whole code points so an
 * emoji is never split into a lone surrogate. */
function truncate(value: string, maxUnits: number): string {
  let result = "";
  for (const codePoint of value) {
    if (result.length + codePoint.length > maxUnits) break;
    result += codePoint;
  }
  return result;
}

/** Windows drops trailing dots and spaces, so strip them all. */
function trimEnd(value: string): string {
  return value.trim().replace(/[. ]+$/, "");
}
