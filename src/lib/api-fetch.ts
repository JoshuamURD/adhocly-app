const apiOrigin = import.meta.env.PUBLIC_API_URL || "";

function parseBody(text: string) {
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export async function apiFetch<T>(url: string, options: RequestInit): Promise<T> {
  const response = await fetch(`${apiOrigin}${url}`, options);
  const data = parseBody(await response.text());

  if (!response.ok) throw new Error(typeof data === "string" ? data : `Request failed (${response.status})`);

  return { data, status: response.status, headers: response.headers } as T;
}
