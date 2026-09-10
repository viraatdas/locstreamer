import type { VercelRequest, VercelResponse } from "@vercel/node";

export function json(res: VercelResponse, status: number, body: unknown): void {
  res.status(status).setHeader("Content-Type", "application/json").send(JSON.stringify(body));
}

export function badRequest(res: VercelResponse, message: string): void {
  json(res, 400, { error: message });
}

/** Body may arrive parsed (Vercel does this for JSON content types) or raw. */
export function bodyOf(req: VercelRequest): Record<string, unknown> {
  const body = req.body;
  if (body && typeof body === "object") return body as Record<string, unknown>;
  if (typeof body === "string" && body.length > 0) {
    try {
      return JSON.parse(body) as Record<string, unknown>;
    } catch {
      return {};
    }
  }
  return {};
}

/** Canonical E.164 form: "+" followed by digits only. Null if it isn't a phone. */
export function normalizePhone(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const digits = raw.replace(/[^0-9]/g, "");
  if (digits.length < 7 || digits.length > 15) return null;
  return `+${digits}`;
}
