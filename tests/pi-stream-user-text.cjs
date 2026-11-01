// Read back the message a non-interactive pi json run actually delivered to its model.
//
// tests/fm-show-me-skill.test.sh needs to know whether pi injected a skill body into
// the prompt, and asking the model about its own context will not answer that: the same
// YES/NO shape confirmed a token that exists nowhere on the machine while a character
// count over the same stream tracked real context correctly. So this reads the stream.
//
// Two shapes matter, both learned by getting them wrong:
//   - The stream opens with session/prompt records that echo the raw input verbatim.
//     Only a message event whose role is user carries what the model was handed.
//   - A content array serialized with JSON.stringify leaves inner quotes escaped, so a
//     needle written plainly never matches it. Joining the text parts keeps one shape.
//
// Usage: node tests/pi-stream-user-text.cjs <stream-file> [needle]
// Prints FOUND or MISSING when a needle is given, otherwise the delivered text.

const fs = require("fs");

const [, , file, needle] = process.argv;
if (!file) {
  console.error("usage: node tests/pi-stream-user-text.cjs <stream-file> [needle]");
  process.exit(2);
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content.map((part) => (part && typeof part.text === "string" ? part.text : "")).join("");
  }
  return "";
}

let delivered = null;
for (const line of fs.readFileSync(file, "utf8").split("\n")) {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) continue;
  let event;
  try {
    event = JSON.parse(trimmed);
  } catch {
    continue;
  }
  const message = event.message;
  if (!message || message.role !== "user") continue;
  delivered = textOf(message.content);
  break;
}

if (delivered === null) {
  process.stdout.write("NOTFOUND\n");
  process.exit(0);
}

if (needle) {
  process.stdout.write(delivered.includes(needle) ? "FOUND\n" : "MISSING\n");
} else {
  process.stdout.write(`${delivered}\n`);
}
