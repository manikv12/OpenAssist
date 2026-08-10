import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const plannerDocumentSchemaVersion = 2;

export type PlannerValidationIssue = {
  code: string;
  message: string;
  line?: number;
  path?: string;
};

export type PlannerDocument<TItem extends { id: string }> = {
  schemaVersion: number;
  containerID: string;
  revision: string;
  markdown: string;
  scaffold: string;
  items: TItem[];
};

export type PlannerConflict = {
  id: string;
  containerID: string;
  itemID?: string;
  path: string;
  baseValue: unknown;
  mineValue: unknown;
  newerValue: unknown;
  message: string;
};

export type PlannerOperation<TItem extends { id: string }> =
  | { type: "create_item"; item: TItem; index?: number }
  | { type: "update_item"; itemID: string; path: string; previousValue: unknown; value: unknown }
  | { type: "delete_item"; itemID: string; previousItem: TItem }
  | { type: "reorder_items"; previousOrder: string[]; order: string[] }
  | { type: "create_step"; itemID: string; step: Record<string, unknown> & { id: string }; index?: number }
  | { type: "update_step"; itemID: string; stepID: string; path: string; previousValue: unknown; value: unknown }
  | { type: "delete_step"; itemID: string; stepID: string; previousStep: Record<string, unknown> & { id: string } }
  | { type: "reorder_steps"; itemID: string; previousOrder: string[]; order: string[] }
  | { type: "move_item"; itemID: string; fromContainerID: string; toContainerID: string; previousItem: TItem; item?: TItem; index?: number }
  | {
      type: "move_step";
      stepID: string;
      fromContainerID: string;
      fromItemID: string;
      toContainerID: string;
      toItemID: string;
      previousStep: Record<string, unknown> & { id: string };
      index?: number;
    };

export type PlannerMutationBatch<TItem extends { id: string }> = {
  mutationID: string;
  containerID: string;
  baseRevision: string;
  baseRevisions?: Record<string, string>;
  operations: PlannerOperation<TItem>[];
};

export type PlannerEditorMutation = {
  mutationID: string;
  containerID: string;
  baseRevision: string;
  baseMarkdown: string;
  markdown: string;
};

export type PlannerConflictResolution = PlannerEditorMutation & {
  newerRevision: string;
  choices: Record<string, "mine" | "newer">;
};

export type PlannerApplyResult<TItem extends { id: string }> =
  | { status: "applied"; document: PlannerDocument<TItem>; documents?: PlannerDocument<TItem>[] }
  | { status: "conflict"; document: PlannerDocument<TItem>; conflicts: PlannerConflict[] }
  | { status: "invalid"; document: PlannerDocument<TItem>; issues: PlannerValidationIssue[] }
  | { status: "failed"; document?: PlannerDocument<TItem>; error: string };

export type PlannerStoreAdapter<TItem extends { id: string }> = {
  filePath(containerID: string): string;
  read(containerID: string): string;
  parse(containerID: string, markdown: string): { scaffold: string; items: TItem[]; issues?: PlannerValidationIssue[] };
  render(containerID: string, scaffold: string, items: TItem[]): string;
  canonicalize(containerID: string, markdown: string): string;
  snapshot(containerID: string, markdown: string): void;
  onCommitted?(containerID: string): void;
};

type PlannerJournalEntry = {
  transactionID: string;
  state: "prepared" | "committed";
  writes: Array<{ containerID: string; filePath: string; before: string; after: string }>;
};

function normalizedMarkdown(value: string) {
  return String(value ?? "").replace(/\r\n/g, "\n");
}

export function plannerRevision(markdown: string) {
  return createHash("sha256").update(normalizedMarkdown(markdown)).digest("hex");
}

function normalizedPlannerTimestamp(value: unknown) {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) return null;
  const date = new Date(text);
  return Number.isFinite(date.getTime()) ? date.toISOString() : null;
}

export function plannerCompletionTimestamp(input: {
  nextCompleted: boolean;
  previouslyCompleted?: boolean;
  existingCompletedAt?: unknown;
  suppliedCompletedAt?: unknown;
  now?: string;
}) {
  if (!input.nextCompleted) return null;
  const existing = normalizedPlannerTimestamp(input.existingCompletedAt);
  const supplied = normalizedPlannerTimestamp(input.suppliedCompletedAt);
  if (input.previouslyCompleted) return existing ?? supplied;
  return supplied ?? normalizedPlannerTimestamp(input.now) ?? new Date().toISOString();
}

function sameValue(left: unknown, right: unknown) {
  if (Object.is(left, right)) return true;
  return JSON.stringify(left) === JSON.stringify(right);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isIDArray(value: unknown): value is Array<Record<string, unknown> & { id: string }> {
  return Array.isArray(value)
    && value.every((entry) => isRecord(entry) && typeof entry.id === "string" && entry.id.trim().length > 0);
}

function valueAtPath(target: unknown, fieldPath: string) {
  return fieldPath.split(".").filter(Boolean).reduce<unknown>((current, key) => (
    isRecord(current) ? current[key] : undefined
  ), target);
}

function setValueAtPath<T>(target: T, fieldPath: string, value: unknown): T {
  const keys = fieldPath.split(".").filter(Boolean);
  if (!keys.length) return value as T;
  const root = structuredClone(target) as unknown as Record<string, unknown>;
  let current = root;
  for (const key of keys.slice(0, -1)) {
    const existing = current[key];
    current[key] = isRecord(existing) ? { ...existing } : {};
    current = current[key] as Record<string, unknown>;
  }
  current[keys[keys.length - 1]] = value;
  return root as T;
}

function mergeValue(
  containerID: string,
  itemID: string | undefined,
  fieldPath: string,
  baseValue: unknown,
  mineValue: unknown,
  newerValue: unknown,
  conflicts: PlannerConflict[],
  choices: Record<string, "mine" | "newer"> = {}
): unknown {
  if (sameValue(mineValue, baseValue)) return newerValue;
  if (sameValue(newerValue, baseValue) || sameValue(mineValue, newerValue)) return mineValue;

  // These fields describe the save operation, not the user's content. They
  // should never turn two otherwise independent edits into a false conflict.
  if (fieldPath.endsWith(".updatedAt")) {
    return String(mineValue ?? "") > String(newerValue ?? "") ? mineValue : newerValue;
  }
  if (fieldPath.endsWith(".order") || fieldPath === "itemOrder") return newerValue;

  if (isRecord(baseValue) && isRecord(mineValue) && isRecord(newerValue)) {
    const merged: Record<string, unknown> = {};
    const keys = new Set([...Object.keys(baseValue), ...Object.keys(mineValue), ...Object.keys(newerValue)]);
    for (const key of keys) {
      const childPath = fieldPath ? `${fieldPath}.${key}` : key;
      merged[key] = mergeValue(
        containerID,
        itemID,
        childPath,
        baseValue[key],
        mineValue[key],
        newerValue[key],
        conflicts,
        choices
      );
    }
    return merged;
  }

  if (isIDArray(baseValue) && isIDArray(mineValue) && isIDArray(newerValue)) {
    const baseMap = new Map(baseValue.map((entry) => [entry.id, entry]));
    const mineMap = new Map(mineValue.map((entry) => [entry.id, entry]));
    const newerMap = new Map(newerValue.map((entry) => [entry.id, entry]));
    const order = [...new Set([...mineValue.map((entry) => entry.id), ...newerValue.map((entry) => entry.id)])];
    const merged: Array<Record<string, unknown> & { id: string }> = [];
    for (const id of order) {
      const baseEntry = baseMap.get(id);
      const mineEntry = mineMap.get(id);
      const newerEntry = newerMap.get(id);
      const entryPath = `${fieldPath}[${id}]`;
      if (!baseEntry) {
        if (mineEntry && newerEntry && !sameValue(mineEntry, newerEntry)) {
          if (choices[entryPath]) {
            const selected = choices[entryPath] === "mine" ? mineEntry : newerEntry;
            if (selected) merged.push(selected);
            continue;
          }
          conflicts.push({
            id: randomUUID(), containerID, itemID, path: entryPath,
            baseValue: undefined, mineValue: mineEntry, newerValue: newerEntry,
            message: "This entry was created differently in two places."
          });
          merged.push(newerEntry);
        } else if (mineEntry || newerEntry) {
          merged.push((mineEntry ?? newerEntry)!);
        }
        continue;
      }
      if (!mineEntry) {
        if (sameValue(newerEntry, baseEntry) || newerEntry === undefined) continue;
        if (choices[entryPath]) {
          if (choices[entryPath] === "newer" && newerEntry) merged.push(newerEntry);
          continue;
        }
        conflicts.push({
          id: randomUUID(), containerID, itemID, path: entryPath,
          baseValue: baseEntry, mineValue: undefined, newerValue: newerEntry,
          message: "This entry was deleted here but changed elsewhere."
        });
        merged.push(newerEntry);
        continue;
      }
      if (!newerEntry) {
        if (sameValue(mineEntry, baseEntry)) continue;
        if (choices[entryPath]) {
          if (choices[entryPath] === "mine") merged.push(mineEntry);
          continue;
        }
        conflicts.push({
          id: randomUUID(), containerID, itemID, path: entryPath,
          baseValue: baseEntry, mineValue: mineEntry, newerValue: undefined,
          message: "This entry was changed here but deleted elsewhere."
        });
        continue;
      }
      merged.push(mergeValue(containerID, itemID, entryPath, baseEntry, mineEntry, newerEntry, conflicts, choices) as Record<string, unknown> & { id: string });
    }
    return merged;
  }

  if (choices[fieldPath]) return choices[fieldPath] === "mine" ? mineValue : newerValue;
  conflicts.push({
    id: randomUUID(),
    containerID,
    itemID,
    path: fieldPath || "document",
    baseValue,
    mineValue,
    newerValue,
    message: "This field changed in two places."
  });
  return newerValue;
}

function validateStableIDs<TItem extends { id: string }>(items: TItem[]) {
  const issues: PlannerValidationIssue[] = [];
  const itemIDs = new Set<string>();
  const allStepIDs = new Set<string>();
  for (const [index, item] of items.entries()) {
    const itemID = String(item.id ?? "").trim();
    if (!itemID || itemID.startsWith("plain:")) {
      issues.push({ code: "missing_item_id", message: "Planner item is missing a permanent ID.", path: `items[${index}].id` });
    } else if (itemIDs.has(itemID)) {
      issues.push({ code: "duplicate_item_id", message: `Planner item ID ${itemID} is duplicated.`, path: `items[${index}].id` });
    }
    itemIDs.add(itemID);

    const steps = (item as Record<string, unknown>).steps;
    if (!Array.isArray(steps)) continue;
    const stepIDs = new Set<string>();
    for (const [stepIndex, step] of steps.entries()) {
      const stepID = isRecord(step) ? String(step.id ?? "").trim() : "";
      if (!stepID) {
        issues.push({ code: "missing_step_id", message: "Planner step is missing a permanent ID.", path: `items[${index}].steps[${stepIndex}].id` });
      } else if (stepIDs.has(stepID) || allStepIDs.has(stepID)) {
        issues.push({ code: "duplicate_step_id", message: `Planner step ID ${stepID} is duplicated.`, path: `items[${index}].steps[${stepIndex}].id` });
      }
      stepIDs.add(stepID);
      allStepIDs.add(stepID);
    }
  }
  return issues;
}

export class PlannerStore<TItem extends { id: string }> {
  private readonly mutationResults = new Map<string, PlannerApplyResult<TItem>>();
  private readonly lockedContainers = new Set<string>();

  constructor(
    private readonly adapter: PlannerStoreAdapter<TItem>,
    private readonly journalRoot: string
  ) {
    this.recoverJournals();
  }

  load(containerID: string): PlannerDocument<TItem> {
    const markdown = normalizedMarkdown(this.adapter.read(containerID));
    return this.document(containerID, markdown);
  }

  prepare(containerID: string, markdown: string): PlannerApplyResult<TItem> {
    try {
      const document = this.document(containerID, this.adapter.canonicalize(containerID, markdown));
      const issues = this.validate(document);
      if (issues.length) return { status: "invalid", document: this.load(containerID), issues };
      return { status: "applied", document };
    } catch (error) {
      return {
        status: "failed",
        document: this.load(containerID),
        error: error instanceof Error ? error.message : "Planner document preparation failed."
      };
    }
  }

  applyEditorMutation(input: PlannerEditorMutation): PlannerApplyResult<TItem> {
    const cached = this.mutationResults.get(input.mutationID);
    if (cached) return cached;
    try {
      const result = this.withLocks([input.containerID], () => {
        const current = this.load(input.containerID);
        const canonicalMine = this.adapter.canonicalize(input.containerID, input.markdown);
        const mine = this.document(input.containerID, canonicalMine);
        const issues = this.validate(mine);
        if (issues.length) return { status: "invalid", document: current, issues } as PlannerApplyResult<TItem>;

        if (!input.baseRevision || current.revision === input.baseRevision) {
          return { status: "applied", document: this.commit(mine) } as PlannerApplyResult<TItem>;
        }

        const base = this.document(input.containerID, this.adapter.canonicalize(input.containerID, input.baseMarkdown));
        const conflicts: PlannerConflict[] = [];
        const merged = this.mergeDocuments(base, mine, current, conflicts);
        if (conflicts.length) {
          return { status: "conflict", document: merged, conflicts } as PlannerApplyResult<TItem>;
        }
        return { status: "applied", document: this.commit(merged) } as PlannerApplyResult<TItem>;
      });
      this.rememberMutation(input.mutationID, result);
      return result;
    } catch (error) {
      const result: PlannerApplyResult<TItem> = {
        status: "failed",
        error: error instanceof Error ? error.message : "Planner mutation failed."
      };
      this.rememberMutation(input.mutationID, result);
      return result;
    }
  }

  applyOperations(batch: PlannerMutationBatch<TItem>): PlannerApplyResult<TItem> {
    if (batch.operations.some((operation) => operation.type === "move_item" || operation.type === "move_step")) {
      return this.applyMoveOperations(batch);
    }
    const cached = this.mutationResults.get(batch.mutationID);
    if (cached) return cached;
    try {
      const result = this.withLocks([batch.containerID], () => {
        const current = this.load(batch.containerID);
        let items = structuredClone(current.items);
        const conflicts: PlannerConflict[] = [];
        for (const operation of batch.operations) {
          if (operation.type === "create_item") {
            if (items.some((item) => item.id === operation.item.id)) {
              if (!sameValue(items.find((item) => item.id === operation.item.id), operation.item)) {
                conflicts.push({
                  id: randomUUID(), containerID: batch.containerID, itemID: operation.item.id,
                  path: "item", baseValue: undefined, mineValue: operation.item,
                  newerValue: items.find((item) => item.id === operation.item.id),
                  message: "An item with this ID already exists."
                });
              }
              continue;
            }
            const index = Math.max(0, Math.min(operation.index ?? items.length, items.length));
            items.splice(index, 0, structuredClone(operation.item));
          } else if (operation.type === "update_item") {
            const index = items.findIndex((item) => item.id === operation.itemID);
            if (index < 0) {
              conflicts.push({
                id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                path: operation.path, baseValue: operation.previousValue, mineValue: operation.value,
                newerValue: undefined, message: "The item was deleted before this change arrived."
              });
              continue;
            }
            const actual = valueAtPath(items[index], operation.path);
            if (operation.path === "updatedAt") {
              const latest = String(actual ?? "") > String(operation.value ?? "") ? actual : operation.value;
              items[index] = setValueAtPath(items[index], operation.path, latest);
              continue;
            }
            if (!sameValue(actual, operation.previousValue) && !sameValue(actual, operation.value)) {
              conflicts.push({
                id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                path: operation.path, baseValue: operation.previousValue, mineValue: operation.value,
                newerValue: actual, message: "This field changed before this update arrived."
              });
              continue;
            }
            items[index] = setValueAtPath(items[index], operation.path, operation.value);
          } else if (operation.type === "delete_item") {
            const existing = items.find((item) => item.id === operation.itemID);
            if (!existing) continue;
            if (!sameValue(existing, operation.previousItem)) {
              conflicts.push({
                id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                path: "item", baseValue: operation.previousItem, mineValue: undefined,
                newerValue: existing, message: "The item changed before it was deleted."
              });
              continue;
            }
            items = items.filter((item) => item.id !== operation.itemID);
          } else if (operation.type === "reorder_items") {
            const actualOrder = items.map((item) => item.id);
            if (!sameValue(actualOrder, operation.previousOrder) && !sameValue(actualOrder, operation.order)) {
              conflicts.push({
                id: randomUUID(), containerID: batch.containerID, path: "itemOrder",
                baseValue: operation.previousOrder, mineValue: operation.order,
                newerValue: actualOrder, message: "The item order changed in another editor."
              });
              continue;
            }
            const orderIndex = new Map(operation.order.map((id, index) => [id, index]));
            items.sort((left, right) => (orderIndex.get(left.id) ?? Number.MAX_SAFE_INTEGER) - (orderIndex.get(right.id) ?? Number.MAX_SAFE_INTEGER));
          } else if (operation.type !== "move_item" && operation.type !== "move_step") {
            const itemIndex = items.findIndex((item) => item.id === operation.itemID);
            if (itemIndex < 0) {
              conflicts.push({
                id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                path: "steps", baseValue: undefined, mineValue: operation,
                newerValue: undefined, message: "The task was deleted before its step could be changed."
              });
              continue;
            }
            const item = structuredClone(items[itemIndex]) as TItem & { steps?: Array<Record<string, unknown> & { id: string }> };
            const steps = Array.isArray(item.steps) ? [...item.steps] : [];
            if (operation.type === "create_step") {
              const existing = steps.find((step) => step.id === operation.step.id);
              if (existing && !sameValue(existing, operation.step)) {
                conflicts.push({
                  id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                  path: `steps[${operation.step.id}]`, baseValue: undefined,
                  mineValue: operation.step, newerValue: existing,
                  message: "A different step with this ID already exists."
                });
              } else if (!existing) {
                const index = Math.max(0, Math.min(operation.index ?? steps.length, steps.length));
                steps.splice(index, 0, structuredClone(operation.step));
              }
            } else if (operation.type === "update_step") {
              const stepIndex = steps.findIndex((step) => step.id === operation.stepID);
              const step = steps[stepIndex];
              const actual = step ? valueAtPath(step, operation.path) : undefined;
              if (!step || (!sameValue(actual, operation.previousValue) && !sameValue(actual, operation.value))) {
                conflicts.push({
                  id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                  path: `steps[${operation.stepID}].${operation.path}`,
                  baseValue: operation.previousValue, mineValue: operation.value, newerValue: actual,
                  message: step ? "This step changed before this update arrived." : "This step was deleted before this update arrived."
                });
              } else {
                steps[stepIndex] = setValueAtPath(step, operation.path, operation.value);
              }
            } else if (operation.type === "delete_step") {
              const stepIndex = steps.findIndex((step) => step.id === operation.stepID);
              if (stepIndex >= 0 && !sameValue(steps[stepIndex], operation.previousStep)) {
                conflicts.push({
                  id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                  path: `steps[${operation.stepID}]`, baseValue: operation.previousStep,
                  mineValue: undefined, newerValue: steps[stepIndex],
                  message: "This step changed before it was deleted."
                });
              } else if (stepIndex >= 0) steps.splice(stepIndex, 1);
            } else {
              const actualOrder = steps.map((step) => step.id);
              if (!sameValue(actualOrder, operation.previousOrder) && !sameValue(actualOrder, operation.order)) {
                conflicts.push({
                  id: randomUUID(), containerID: batch.containerID, itemID: operation.itemID,
                  path: "steps", baseValue: operation.previousOrder,
                  mineValue: operation.order, newerValue: actualOrder,
                  message: "The step order changed in another editor."
                });
              } else {
                const orderIndex = new Map(operation.order.map((id, index) => [id, index]));
                steps.sort((left, right) => (orderIndex.get(left.id) ?? Number.MAX_SAFE_INTEGER) - (orderIndex.get(right.id) ?? Number.MAX_SAFE_INTEGER));
              }
            }
            item.steps = steps;
            items[itemIndex] = item;
          }
        }
        const markdown = this.adapter.render(batch.containerID, current.scaffold, items);
        const next = this.document(batch.containerID, markdown);
        if (conflicts.length) return { status: "conflict", document: next, conflicts } as PlannerApplyResult<TItem>;
        const issues = this.validate(next);
        if (issues.length) return { status: "invalid", document: current, issues } as PlannerApplyResult<TItem>;
        return { status: "applied", document: this.commit(next) } as PlannerApplyResult<TItem>;
      });
      this.rememberMutation(batch.mutationID, result);
      return result;
    } catch (error) {
      const result: PlannerApplyResult<TItem> = { status: "failed", error: error instanceof Error ? error.message : "Planner operation failed." };
      this.rememberMutation(batch.mutationID, result);
      return result;
    }
  }

  resolveEditorConflicts(input: PlannerConflictResolution): PlannerApplyResult<TItem> {
    const cached = this.mutationResults.get(input.mutationID);
    if (cached) return cached;
    try {
      const result = this.withLocks([input.containerID], () => {
        const current = this.load(input.containerID);
        if (current.revision !== input.newerRevision) {
          return {
            status: "failed",
            document: current,
            error: "The planner changed again while conflicts were being reviewed. Review the newest changes before saving."
          } as PlannerApplyResult<TItem>;
        }
        const base = this.document(input.containerID, this.adapter.canonicalize(input.containerID, input.baseMarkdown));
        const mine = this.document(input.containerID, this.adapter.canonicalize(input.containerID, input.markdown));
        const conflicts: PlannerConflict[] = [];
        const merged = this.mergeDocuments(base, mine, current, conflicts, input.choices);
        if (conflicts.length) {
          return { status: "conflict", document: merged, conflicts } as PlannerApplyResult<TItem>;
        }
        const issues = this.validate(merged);
        if (issues.length) return { status: "invalid", document: current, issues } as PlannerApplyResult<TItem>;
        return { status: "applied", document: this.commit(merged) } as PlannerApplyResult<TItem>;
      });
      this.rememberMutation(input.mutationID, result);
      return result;
    } catch (error) {
      const result: PlannerApplyResult<TItem> = {
        status: "failed",
        error: error instanceof Error ? error.message : "Planner conflict resolution failed."
      };
      this.rememberMutation(input.mutationID, result);
      return result;
    }
  }

  commitTransaction(writes: PlannerDocument<TItem>[], transactionID = randomUUID()) {
    const containerIDs = writes.map((write) => write.containerID);
    if (new Set(containerIDs).size !== containerIDs.length) {
      throw new Error("A planner transaction cannot write the same container more than once.");
    }
    return this.withLocks(containerIDs, () => this.commitTransactionUnlocked(writes, transactionID));
  }

  private applyMoveOperations(batch: PlannerMutationBatch<TItem>): PlannerApplyResult<TItem> {
    const cached = this.mutationResults.get(batch.mutationID);
    if (cached) return cached;
    if (batch.operations.some((operation) => operation.type !== "move_item" && operation.type !== "move_step")) {
      const result: PlannerApplyResult<TItem> = { status: "failed", error: "Move batches cannot mix move and single-container operations." };
      this.rememberMutation(batch.mutationID, result);
      return result;
    }
    const containerIDs = [...new Set(batch.operations.flatMap((operation) => (
      operation.type === "move_item" || operation.type === "move_step"
        ? [operation.fromContainerID, operation.toContainerID]
        : []
    )))];
    try {
      const result = this.withLocks(containerIDs, () => {
        const current = new Map(containerIDs.map((containerID) => [containerID, this.load(containerID)]));
        const itemsByContainer = new Map(containerIDs.map((containerID) => [
          containerID,
          structuredClone(current.get(containerID)!.items)
        ]));
        const conflicts: PlannerConflict[] = [];

        for (const operation of batch.operations) {
          if (operation.type === "move_item") {
            const sourceItems = itemsByContainer.get(operation.fromContainerID)!;
            const targetItems = itemsByContainer.get(operation.toContainerID)!;
            const sourceIndex = sourceItems.findIndex((item) => item.id === operation.itemID);
            const existingTarget = targetItems.find((item) => item.id === operation.itemID);
            if (sourceIndex < 0) {
              if (existingTarget) continue;
              conflicts.push({
                id: randomUUID(), containerID: operation.fromContainerID, itemID: operation.itemID,
                path: "item", baseValue: operation.previousItem, mineValue: undefined,
                newerValue: undefined, message: "The item was deleted before it could be moved."
              });
              continue;
            }
            if (existingTarget) {
              conflicts.push({
                id: randomUUID(), containerID: operation.toContainerID, itemID: operation.itemID,
                path: "item", baseValue: undefined, mineValue: sourceItems[sourceIndex],
                newerValue: existingTarget, message: "The destination already has an item with this ID."
              });
              continue;
            }
            const [sourceItem] = sourceItems.splice(sourceIndex, 1);
            const desiredItem = operation.item ?? (isRecord(sourceItem)
              ? ({ ...sourceItem, dayID: operation.toContainerID } as TItem)
              : sourceItem);
            const movedItem = mergeValue(
              operation.fromContainerID,
              operation.itemID,
              `items[${operation.itemID}]`,
              operation.previousItem,
              desiredItem,
              sourceItem,
              conflicts
            ) as TItem;
            const index = Math.max(0, Math.min(operation.index ?? targetItems.length, targetItems.length));
            targetItems.splice(index, 0, movedItem);
          } else if (operation.type === "move_step") {
            const sourceItems = itemsByContainer.get(operation.fromContainerID)!;
            const targetItems = itemsByContainer.get(operation.toContainerID)!;
            const sourceItem = sourceItems.find((item) => item.id === operation.fromItemID) as TItem & { steps?: Array<Record<string, unknown> & { id: string }> } | undefined;
            const targetItem = targetItems.find((item) => item.id === operation.toItemID) as TItem & { steps?: Array<Record<string, unknown> & { id: string }> } | undefined;
            const sourceSteps = Array.isArray(sourceItem?.steps) ? [...sourceItem.steps] : [];
            const targetSteps = Array.isArray(targetItem?.steps) ? [...targetItem.steps] : [];
            const sourceIndex = sourceSteps.findIndex((step) => step.id === operation.stepID);
            const existingTarget = targetSteps.find((step) => step.id === operation.stepID);
            if (!sourceItem || !targetItem || sourceIndex < 0) {
              if (existingTarget) continue;
              conflicts.push({
                id: randomUUID(), containerID: operation.fromContainerID, itemID: operation.fromItemID,
                path: `steps[${operation.stepID}]`, baseValue: operation.previousStep,
                mineValue: undefined, newerValue: undefined,
                message: "The step or its task was deleted before it could be moved."
              });
              continue;
            }
            if (existingTarget) {
              conflicts.push({
                id: randomUUID(), containerID: operation.toContainerID, itemID: operation.toItemID,
                path: `steps[${operation.stepID}]`, baseValue: undefined,
                mineValue: sourceSteps[sourceIndex], newerValue: existingTarget,
                message: "The destination already has a step with this ID."
              });
              continue;
            }
            const [step] = sourceSteps.splice(sourceIndex, 1);
            const index = Math.max(0, Math.min(operation.index ?? targetSteps.length, targetSteps.length));
            targetSteps.splice(index, 0, step);
            sourceItem.steps = sourceSteps;
            targetItem.steps = targetSteps;
          }
        }

        const primary = current.get(batch.containerID) ?? current.values().next().value;
        if (!primary) return { status: "failed", error: "The planner move did not name a container." } as PlannerApplyResult<TItem>;
        const writes = containerIDs.map((containerID) => this.document(
          containerID,
          this.adapter.render(containerID, current.get(containerID)!.scaffold, itemsByContainer.get(containerID)!)
        ));
        if (conflicts.length) {
          const latestPrimary = writes.find((write) => write.containerID === primary.containerID) ?? writes[0];
          return { status: "conflict", document: latestPrimary, conflicts } as PlannerApplyResult<TItem>;
        }
        for (const document of writes) {
          const issues = this.validate(document);
          if (issues.length) return { status: "invalid", document: primary, issues } as PlannerApplyResult<TItem>;
        }
        const committed = this.commitTransactionUnlocked(writes, batch.mutationID);
        const document = committed.find((entry) => entry.containerID === batch.containerID) ?? committed[0];
        return { status: "applied", document, documents: committed } as PlannerApplyResult<TItem>;
      });
      this.rememberMutation(batch.mutationID, result);
      return result;
    } catch (error) {
      const result: PlannerApplyResult<TItem> = {
        status: "failed",
        error: error instanceof Error ? error.message : "Planner move failed."
      };
      this.rememberMutation(batch.mutationID, result);
      return result;
    }
  }

  private commitTransactionUnlocked(writes: PlannerDocument<TItem>[], transactionID: string) {
    for (const write of writes) {
      const issues = this.validate(write);
      if (issues.length) throw new Error(issues.map((issue) => issue.message).join(" "));
    }
    const entry: PlannerJournalEntry = {
      transactionID,
      state: "prepared",
      writes: writes.map((write) => ({
        containerID: write.containerID,
        filePath: this.adapter.filePath(write.containerID),
        before: this.adapter.read(write.containerID),
        after: write.markdown
      }))
    };
    fs.mkdirSync(this.journalRoot, { recursive: true });
    const journalPath = path.join(this.journalRoot, `${transactionID}.json`);
    this.atomicWrite(journalPath, `${JSON.stringify(entry, null, 2)}\n`, false);
    try {
      for (const write of writes) this.commit(write, false);
      entry.state = "committed";
      this.atomicWrite(journalPath, `${JSON.stringify(entry, null, 2)}\n`, false);
      fs.rmSync(journalPath, { force: true });
    } catch (error) {
      let rollbackError: unknown;
      for (const write of entry.writes) {
        try {
          const current = fs.existsSync(write.filePath) ? fs.readFileSync(write.filePath, "utf8") : "";
          if (current !== write.before) this.atomicWrite(write.filePath, write.before, false);
        } catch (candidate) {
          rollbackError ??= candidate;
        }
      }
      if (!rollbackError) fs.rmSync(journalPath, { force: true });
      const message = error instanceof Error ? error.message : "Planner transaction failed.";
      if (rollbackError) {
        const rollbackMessage = rollbackError instanceof Error ? rollbackError.message : "rollback failed";
        throw new Error(`${message} Automatic rollback also failed (${rollbackMessage}); the recovery journal was kept.`);
      }
      throw error;
    }
    for (const write of writes) this.adapter.onCommitted?.(write.containerID);
    return writes.map((write) => this.load(write.containerID));
  }

  private document(containerID: string, markdown: string): PlannerDocument<TItem> {
    const normalized = normalizedMarkdown(markdown);
    const parsed = this.adapter.parse(containerID, normalized);
    return {
      schemaVersion: plannerDocumentSchemaVersion,
      containerID,
      revision: plannerRevision(normalized),
      markdown: normalized,
      scaffold: parsed.scaffold,
      items: parsed.items
    };
  }

  private validate(document: PlannerDocument<TItem>) {
    const parsed = this.adapter.parse(document.containerID, document.markdown);
    return [...(parsed.issues ?? []), ...validateStableIDs(document.items)];
  }

  private mergeDocuments(
    base: PlannerDocument<TItem>,
    mine: PlannerDocument<TItem>,
    newer: PlannerDocument<TItem>,
    conflicts: PlannerConflict[],
    choices: Record<string, "mine" | "newer"> = {}
  ) {
    const scaffold = mergeValue(base.containerID, undefined, "scaffold", base.scaffold, mine.scaffold, newer.scaffold, conflicts, choices) as string;
    const baseMap = new Map(base.items.map((item) => [item.id, item]));
    const mineMap = new Map(mine.items.map((item) => [item.id, item]));
    const newerMap = new Map(newer.items.map((item) => [item.id, item]));
    const order = [...new Set([...mine.items.map((item) => item.id), ...newer.items.map((item) => item.id)])];
    const items: TItem[] = [];
    for (const itemID of order) {
      const baseItem = baseMap.get(itemID);
      const mineItem = mineMap.get(itemID);
      const newerItem = newerMap.get(itemID);
      if (!baseItem) {
        if (mineItem && newerItem && !sameValue(mineItem, newerItem)) {
          if (choices[`items[${itemID}]`]) {
            const selected = choices[`items[${itemID}]`] === "mine" ? mineItem : newerItem;
            if (selected) items.push(selected);
            continue;
          }
          conflicts.push({
            id: randomUUID(), containerID: base.containerID, itemID, path: `items[${itemID}]`,
            baseValue: undefined, mineValue: mineItem, newerValue: newerItem,
            message: "This item was created differently in two places."
          });
          items.push(newerItem);
        } else if (mineItem || newerItem) items.push((mineItem ?? newerItem)!);
        continue;
      }
      if (!mineItem) {
        if (sameValue(newerItem, baseItem) || !newerItem) continue;
        if (choices[`items[${itemID}]`]) {
          if (choices[`items[${itemID}]`] === "newer") items.push(newerItem);
          continue;
        }
        conflicts.push({
          id: randomUUID(), containerID: base.containerID, itemID, path: `items[${itemID}]`,
          baseValue: baseItem, mineValue: undefined, newerValue: newerItem,
          message: "This item was deleted here but changed elsewhere."
        });
        items.push(newerItem);
        continue;
      }
      if (!newerItem) {
        if (sameValue(mineItem, baseItem)) continue;
        if (choices[`items[${itemID}]`]) {
          if (choices[`items[${itemID}]`] === "mine") items.push(mineItem);
          continue;
        }
        conflicts.push({
          id: randomUUID(), containerID: base.containerID, itemID, path: `items[${itemID}]`,
          baseValue: baseItem, mineValue: mineItem, newerValue: undefined,
          message: "This item was changed here but deleted elsewhere."
        });
        continue;
      }
      items.push(mergeValue(base.containerID, itemID, `items[${itemID}]`, baseItem, mineItem, newerItem, conflicts, choices) as TItem);
    }
    return this.document(base.containerID, this.adapter.render(base.containerID, scaffold, items));
  }

  private commit(document: PlannerDocument<TItem>, notify = true) {
    const issues = this.validate(document);
    if (issues.length) throw new Error(issues.map((issue) => issue.message).join(" "));
    const filePath = this.adapter.filePath(document.containerID);
    const previous = fs.existsSync(filePath) ? normalizedMarkdown(fs.readFileSync(filePath, "utf8")) : "";
    if (previous !== document.markdown) this.adapter.snapshot(document.containerID, previous);
    this.atomicWrite(filePath, document.markdown, true, document.containerID);
    if (notify) this.adapter.onCommitted?.(document.containerID);
    return this.load(document.containerID);
  }

  private atomicWrite(filePath: string, content: string, validatePlanner: boolean, plannerContainerID?: string) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const tempPath = path.join(path.dirname(filePath), `.${path.basename(filePath)}.${process.pid}.${randomUUID()}.tmp`);
    try {
      fs.writeFileSync(tempPath, content, "utf8");
      const readBack = fs.readFileSync(tempPath, "utf8");
      if (readBack !== content) throw new Error("Planner temporary-file read-back did not match the requested write.");
      if (validatePlanner) {
        const containerID = plannerContainerID ?? path.basename(filePath, path.extname(filePath));
        const parsed = this.adapter.parse(containerID, readBack);
        if ((parsed.issues ?? []).length) throw new Error(parsed.issues!.map((issue) => issue.message).join(" "));
      }
      fs.renameSync(tempPath, filePath);
    } finally {
      fs.rmSync(tempPath, { force: true });
    }
  }

  private withLocks<TResult>(containerIDs: string[], run: () => TResult): TResult {
    const uniqueIDs = [...new Set(containerIDs)].sort();
    const busy = uniqueIDs.find((containerID) => this.lockedContainers.has(containerID));
    if (busy) throw new Error(`Planner container ${busy} is already being changed.`);
    uniqueIDs.forEach((containerID) => this.lockedContainers.add(containerID));
    try {
      return run();
    } finally {
      uniqueIDs.forEach((containerID) => this.lockedContainers.delete(containerID));
    }
  }

  private rememberMutation(mutationID: string, result: PlannerApplyResult<TItem>) {
    this.mutationResults.set(mutationID, result);
    while (this.mutationResults.size > 500) {
      const oldest = this.mutationResults.keys().next().value;
      if (typeof oldest !== "string") break;
      this.mutationResults.delete(oldest);
    }
  }

  private recoverJournals() {
    if (!fs.existsSync(this.journalRoot)) return;
    for (const fileName of fs.readdirSync(this.journalRoot)) {
      if (!fileName.endsWith(".json")) continue;
      const journalPath = path.join(this.journalRoot, fileName);
      try {
        const entry = JSON.parse(fs.readFileSync(journalPath, "utf8")) as PlannerJournalEntry;
        for (const write of entry.writes ?? []) {
          const current = fs.existsSync(write.filePath) ? fs.readFileSync(write.filePath, "utf8") : "";
          if (entry.state === "committed") {
            if (current !== write.after) this.atomicWrite(write.filePath, write.after, false);
          } else if (current !== write.before) {
            this.atomicWrite(write.filePath, write.before, false);
          }
        }
        fs.rmSync(journalPath, { force: true });
      } catch {
        // Leave a malformed journal untouched for manual recovery.
      }
    }
  }
}
