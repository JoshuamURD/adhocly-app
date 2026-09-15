/** True for the browser's zoom shortcuts: Ctrl/Cmd with `+`, `-`, `=`, `_`, or `0`. */
export function isZoomShortcut(event: { key: string; ctrlKey: boolean; metaKey: boolean }): boolean {
  if (!event.ctrlKey && !event.metaKey) return false;
  return ["+", "-", "=", "_", "0"].includes(event.key);
}
