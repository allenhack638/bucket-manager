// Run: node --experimental-strip-types tests/fileName.test.ts
import { safeFileName } from "../src/fileName.ts";
const cases: [string, string][] = [
  ["\\\\attacker.example\\share\\Q3.pdf", "Q3.pdf"],
  ["//attacker/share/x.pdf", "x.pdf"],
  ["C:\\Windows\\evil.exe", "evil.exe"],
  ["C:evil.txt", "C_evil.txt"],
  ["report.pdf", "report.pdf"],
  ["a<b>c|d?e*.txt", "a_b_c_d_e_.txt"],
  ["trailing. ", "trailing"],
  ["CON", "_CON"],
  ["nul.txt", "_nul.txt"],
  ["\\\\", "download"],
  ["..", "download"],
  ["photos/2024/", "2024"],
  ["CONIN$", "_CONIN$"],
  ["COM\u00b9", "_COM\u00b9"],
  ["con .txt", "_con .txt"],
  ["invoice\u202efdp.exe", "invoicefdp.exe"],
  ["x".repeat(198) + "\u{1F600}\u{1F600}", "x".repeat(198) + "\u{1F600}"],
  ["x".repeat(199) + "\u{1F600}", "x".repeat(199)],
  ["a".repeat(199) + ". b", "a".repeat(199)],
  ["\u{1F600}".repeat(210), "\u{1F600}".repeat(100)],
  ["a. ", "a"],
  ["x\u061cy.txt", "xy.txt"],
  ["COM0", "_COM0"],
  ["lpt0.log", "_lpt0.log"],
];
let failed = 0;
for (const [input, expected] of cases) {
  const actual = safeFileName(input);
  if (actual !== expected) { failed++; console.log(`FAIL ${JSON.stringify(input)} -> ${actual} (want ${expected})`); }
}
console.log(failed ? `${failed} failed` : `all ${cases.length} passed`);
process.exit(failed ? 1 : 0);
