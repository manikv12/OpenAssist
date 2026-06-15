import os from "node:os";

export type OllamaCatalogModelOption = {
  id: string;
  displayName: string;
  description?: string;
  sizeLabel?: string;
  performanceLabel?: string;
  isRecommended?: boolean;
  isInstalled?: boolean;
  source?: "curated" | "website";
};

type Gemma4Variant = {
  id: string;
  displayName: string;
  sizeLabel: string;
  performanceLabel: string;
  summary: string;
};

const GIB = 1_073_741_824;

const gemma4Variants: Gemma4Variant[] = [
  {
    id: "gemma4:e2b",
    displayName: "Gemma 4 E2B",
    sizeLabel: "Small",
    performanceLabel: "Very Fast",
    summary: "Best for smaller Macs or when you want the lightest local Gemma 4 option."
  },
  {
    id: "gemma4:e4b",
    displayName: "Gemma 4 E4B",
    sizeLabel: "Balanced",
    performanceLabel: "Fast",
    summary: "Best default starting point for most Macs."
  },
  {
    id: "gemma4:12b",
    displayName: "Gemma 4 12B",
    sizeLabel: "~7.6 GB",
    performanceLabel: "Balanced",
    summary: "Stronger quality than E4B while still fitting most 16–24 GB Macs."
  },
  {
    id: "gemma4:26b",
    displayName: "Gemma 4 26B",
    sizeLabel: "Large",
    performanceLabel: "Balanced",
    summary: "Better quality for machines with plenty of unified memory."
  },
  {
    id: "gemma4:31b",
    displayName: "Gemma 4 31B",
    sizeLabel: "Largest",
    performanceLabel: "Highest Quality",
    summary: "Largest local option for high-memory Macs."
  }
];

function toCatalogOption(
  variant: Gemma4Variant,
  isRecommended: boolean,
  source: "curated" | "website" = "curated"
): OllamaCatalogModelOption {
  return {
    id: variant.id,
    displayName: variant.displayName,
    description: variant.summary,
    sizeLabel: variant.sizeLabel,
    performanceLabel: variant.performanceLabel,
    isRecommended,
    source
  };
}

export function recommendedGemma4ModelID(physicalMemoryBytes?: number | null): string {
  if (!physicalMemoryBytes || physicalMemoryBytes <= 0) {
    return "gemma4:e4b";
  }
  const sixteenGiB = 16 * GIB;
  const thirtySixGiB = 36 * GIB;
  const sixtyFourGiB = 64 * GIB;
  if (physicalMemoryBytes < sixteenGiB) return "gemma4:e2b";
  if (physicalMemoryBytes < thirtySixGiB) return "gemma4:e4b";
  if (physicalMemoryBytes < sixtyFourGiB) return "gemma4:26b";
  return "gemma4:31b";
}

export function gemma4Catalog(physicalMemoryBytes?: number | null): OllamaCatalogModelOption[] {
  const recommendedID = recommendedGemma4ModelID(physicalMemoryBytes).toLowerCase();
  const ordered = [
    ...gemma4Variants.filter((variant) => variant.id.toLowerCase() === recommendedID),
    ...gemma4Variants.filter((variant) => variant.id.toLowerCase() !== recommendedID)
  ];
  return ordered.map((variant) => toCatalogOption(
    variant,
    variant.id.toLowerCase() === recommendedID
  ));
}

export function curatedOllamaCatalog(physicalMemoryBytes?: number | null): OllamaCatalogModelOption[] {
  const gemma4 = gemma4Catalog(physicalMemoryBytes);
  return dedupeCatalog([
    {
      id: "qwen2.5:3b",
      displayName: "Qwen 2.5 3B",
      sizeLabel: "~2.0 GB",
      performanceLabel: "Fast",
      description: "Best balance for rewrite quality and memory-lesson extraction on most Macs.",
      isRecommended: true,
      source: "curated"
    },
    ...gemma4,
    {
      id: "llama3.2:3b",
      displayName: "Llama 3.2 3B",
      sizeLabel: "~2.0 GB",
      performanceLabel: "Fast",
      description: "Good all-around local model with broad compatibility.",
      source: "curated"
    },
    {
      id: "gemma3:4b",
      displayName: "Gemma 3 4B",
      sizeLabel: "~8.6 GB",
      performanceLabel: "Balanced",
      description: "Newer Gemma generation with stronger quality while still fitting consumer laptops.",
      source: "curated"
    },
    {
      id: "gemma2:2b",
      displayName: "Gemma 2 2B",
      sizeLabel: "~1.6 GB",
      performanceLabel: "Very Fast",
      description: "Smallest legacy download option. Faster startup with modest quality tradeoffs.",
      source: "curated"
    }
  ]);
}

export function dedupeCatalog(catalog: OllamaCatalogModelOption[]): OllamaCatalogModelOption[] {
  const seen = new Set<string>();
  const merged: OllamaCatalogModelOption[] = [];
  for (const entry of catalog) {
    const normalized = entry.id.trim().toLowerCase();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    merged.push(entry);
  }
  return merged;
}

export function mergeCatalogWithInstalled(
  catalog: OllamaCatalogModelOption[],
  installedIDs: Iterable<string>
): OllamaCatalogModelOption[] {
  const installed = new Set(Array.from(installedIDs, (id) => id.trim().toLowerCase()).filter(Boolean));
  return catalog.map((entry) => ({
    ...entry,
    isInstalled: installed.has(entry.id.trim().toLowerCase())
  }));
}

export function mergeCatalogWithWebsiteModels(
  curated: OllamaCatalogModelOption[],
  websiteModels: OllamaCatalogModelOption[]
): OllamaCatalogModelOption[] {
  const merged = [...curated];
  const seen = new Set(merged.map((entry) => entry.id.trim().toLowerCase()));
  for (const model of websiteModels) {
    const normalized = model.id.trim().toLowerCase();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    merged.push({ ...model, source: "website" });
  }
  return merged;
}

export function sortOllamaCatalog(catalog: OllamaCatalogModelOption[]): OllamaCatalogModelOption[] {
  return [...catalog].sort((left, right) => {
    const leftRecommended = left.isRecommended ? 1 : 0;
    const rightRecommended = right.isRecommended ? 1 : 0;
    if (leftRecommended !== rightRecommended) return rightRecommended - leftRecommended;
    const leftCurated = left.source === "curated" ? 1 : 0;
    const rightCurated = right.source === "curated" ? 1 : 0;
    if (leftCurated !== rightCurated) return rightCurated - leftCurated;
    return left.displayName.localeCompare(right.displayName, undefined, { sensitivity: "base" });
  });
}

export function catalogModelByID(
  catalog: OllamaCatalogModelOption[],
  modelID: string
): OllamaCatalogModelOption | undefined {
  const normalized = modelID.trim().toLowerCase();
  if (!normalized) return undefined;
  return catalog.find((entry) => entry.id.trim().toLowerCase() === normalized);
}

export function physicalMemoryBytes(): number {
  return os.totalmem();
}

export function formatCatalogOptionLabel(option: OllamaCatalogModelOption): string {
  const parts = [
    option.displayName,
    option.isRecommended ? "Recommended" : null,
    option.performanceLabel,
    option.sizeLabel,
    option.isInstalled ? "installed" : null
  ].filter(Boolean);
  return parts.join(" · ");
}
