import type { MetadataField, Project } from "./api/generated";

/** Field id → stored value for a single project. */
export function valuesFor(project: Project | undefined): Map<string, string> {
  return new Map((project?.metadata ?? []).map((value) => [value.fieldId, value.value]));
}

export function valueFor(project: Project | undefined, fieldId: string): string {
  return project?.metadata.find((value) => value.fieldId === fieldId)?.value ?? "";
}

/**
 * Client-side mirror of the server's `validate_value` (server/src/projects.rs), so a value the API
 * would reject is never sent. Numbers are a little looser here; the API stays the authority.
 */
export function isValidValue(field: MetadataField, value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return true; // blank clears the value
  if (field.kind === "number") return Number.isFinite(Number(trimmed));
  if (field.kind === "choice") return field.options.includes(trimmed);
  return true;
}

/** Client copy of the server's `normalize_options`: trimmed, no blanks, no duplicates. */
export function normalizeOptions(options: string[]): string[] {
  return [...new Set(options.map((option) => option.trim()).filter(Boolean))];
}

/**
 * What Enter/Backspace does in the option editor, kept DOM-free so it can be tested on its own.
 * `append` opens a row after the last one, `next` steps to an existing row, `back` deletes an empty
 * row and steps up.
 */
export function optionKey(
  key: string,
  value: string,
  index: number,
  count: number,
): "append" | "next" | "back" | null {
  if (key === "Enter") return index === count - 1 ? "append" : "next";
  if (key === "Backspace" && !value && count > 1) return "back";
  return null;
}

/** Options plus the stored value when it is no longer one of them, so edits cannot hide data. */
export function choiceOptions(field: MetadataField, current: string): string[] {
  return current && !field.options.includes(current) ? [...field.options, current] : field.options;
}
