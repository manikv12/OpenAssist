import {
  curatedOllamaCatalog,
  gemma4Catalog,
  recommendedGemma4ModelID
} from "../dist-electron/ollamaModelCatalog.js";

const GIB = 1_073_741_824;
const gib = (value) => value * GIB;

const checks = [
  [null, "gemma4:e4b"],
  [0, "gemma4:e4b"],
  [gib(15), "gemma4:e2b"],
  [gib(16), "gemma4:e4b"],
  [gib(35), "gemma4:e4b"],
  [gib(36), "gemma4:26b"],
  [gib(63), "gemma4:26b"],
  [gib(64), "gemma4:31b"],
  [gib(96), "gemma4:31b"]
];

for (const [memory, expected] of checks) {
  const actual = recommendedGemma4ModelID(memory);
  if (actual !== expected) {
    console.error(`recommendedGemma4ModelID(${memory}) expected ${expected}, got ${actual}`);
    process.exit(1);
  }
}

const catalog = gemma4Catalog(gib(36));
if (catalog[0]?.id !== "gemma4:26b" || !catalog[0]?.isRecommended) {
  console.error("gemma4Catalog should place the RAM-recommended model first.");
  process.exit(1);
}

const curated = curatedOllamaCatalog(gib(36));
const curatedIDs = new Set(curated.map((entry) => entry.id.toLowerCase()));
for (const id of ["qwen2.5:3b", "gemma4:e2b", "gemma4:e4b", "gemma4:12b", "gemma4:26b", "gemma4:31b", "llama3.2:3b", "gemma3:4b", "gemma2:2b"]) {
  if (!curatedIDs.has(id)) {
    console.error(`curatedOllamaCatalog missing ${id}`);
    process.exit(1);
  }
}

console.log("verify-ollama-catalog: ok");
