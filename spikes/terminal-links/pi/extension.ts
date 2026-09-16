import type { ExtensionAPI, MarkdownTransformContext } from "@earendil-works/pi-coding-agent";

const LABEL = "src/target.ts:7:3";
const URL = "file:///tmp/link-spike-20260916/project/src/target.ts#L7C3";
const UNLINKED_INLINE_CODE = `\`${LABEL}\``;
const LINKED_MARKDOWN = `[${LABEL}](${URL})`;

export function linkifyKnownFixtureReference(markdown: string, context: MarkdownTransformContext): string {
  if (context.messageType !== "assistant") return markdown;
  return markdown.replaceAll(UNLINKED_INLINE_CODE, LINKED_MARKDOWN);
}

export default function (pi: ExtensionAPI): void {
  if (process.env.PI_HYPERLINKS !== "1") return;
  pi.registerMarkdownTransformer(linkifyKnownFixtureReference);
}
