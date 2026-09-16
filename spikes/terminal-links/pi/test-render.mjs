import { readFile } from "node:fs/promises";

process.env.PI_HYPERLINKS = "1";
const packageRoot = process.env.PI_PACKAGE_ROOT ?? "/Users/slu/.n/lib/node_modules/@earendil-works/pi-coding-agent";
const { AssistantMessageComponent, getMarkdownTheme, initTheme } = await import(`file://${packageRoot}/dist/index.js`);
initTheme("dark", false);
const { default: extension, linkifyKnownFixtureReference } = await import("./extension.ts");

let transformer;
extension({ registerMarkdownTransformer(candidate) { transformer = candidate; } });
if (!transformer) throw new Error("transformer was not registered");

const raw = "Known reference: `src/target.ts:7:3`";
const transformed = transformer(raw, { messageType: "assistant", isStreaming: false, availableWidth: 120 });
if (transformed !== "Known reference: [src/target.ts:7:3](file:///tmp/link-spike-20260916/project/src/target.ts#L7C3)") {
  throw new Error(`unexpected Markdown: ${transformed}`);
}

const message = {
  role: "assistant",
  content: [{ type: "text", text: raw }],
  api: "fixture",
  provider: "fixture",
  model: "fixture",
  usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  stopReason: "stop",
  timestamp: Date.now(),
};
const beforeRender = JSON.stringify(message);
const rendered = new AssistantMessageComponent(message, false, getMarkdownTheme(), "Thinking...", 1, [transformer]).render(120).join("\n");
if (JSON.stringify(message) !== beforeRender) throw new Error("render mutated message");
const osc8Open = "\x1b]8;;file:///tmp/link-spike-20260916/project/src/target.ts#L7C3\x1b\\";
const osc8Close = "\x1b]8;;\x1b\\";
if (!rendered.includes(osc8Open) || !rendered.includes("src/target.ts:7:3") || !rendered.includes(osc8Close)) {
  throw new Error(`OSC8 hyperlink missing: ${JSON.stringify(rendered)}`);
}

const session = (await readFile("./fixture.jsonl", "utf8")).split("\n").filter(Boolean).map(JSON.parse);
const storedText = session.find((entry) => entry.type === "message")?.message.content[0].text;
if (storedText !== raw) throw new Error(`stored assistant text changed: ${storedText}`);
if (storedText.includes("file:///")) throw new Error("stored assistant text contains link URL");
if ((await readFile("./fixture.jsonl", "utf8")).includes("file:///")) throw new Error("fixture transcript was rewritten");
console.log("PASS: standalone AssistantMessageComponent emitted OSC8; stored assistant text stayed unlinked");
