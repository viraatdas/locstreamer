import type { VercelRequest, VercelResponse } from "@vercel/node";
import { hasReadApiKey, phoneFromBearer } from "../../lib/auth.js";
import { badRequest, json, normalizePhone } from "../../lib/http.js";
import { readPoints } from "../../lib/store.js";

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/**
 * GET /api/locations/<phone>?from=YYYY-MM-DD&to=YYYY-MM-DD[&format=csv]
 * Auth: `x-api-key: <READ_API_KEY>` for any phone, or the device's own Bearer token.
 * Dates are UTC; both default to today.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "GET") return json(res, 405, { error: "GET only" });
  const phone = normalizePhone(req.query.phone);
  if (!phone) return badRequest(res, "Bad phone number.");
  const bearerPhone = await phoneFromBearer(req);
  if (!hasReadApiKey(req) && bearerPhone !== phone) return json(res, 401, { error: "Unauthorized." });

  const today = new Date().toISOString().slice(0, 10);
  const from = typeof req.query.from === "string" ? req.query.from : today;
  const to = typeof req.query.to === "string" ? req.query.to : from;
  if (!DAY.test(from) || !DAY.test(to) || from > to) return badRequest(res, "Dates must be YYYY-MM-DD with from <= to.");
  if ((Date.parse(to) - Date.parse(from)) / 86_400_000 > 92) return badRequest(res, "Range too large (max 93 days).");

  const points = await readPoints(phone, from, to);
  if (req.query.format === "csv") {
    const lines = ["ts,iso,lat,lon,acc,spd"];
    for (const p of points) lines.push(`${p.ts},${new Date(p.ts).toISOString()},${p.lat},${p.lon},${p.acc ?? ""},${p.spd ?? ""}`);
    return res.status(200).setHeader("Content-Type", "text/csv").send(lines.join("\n") + "\n");
  }
  return json(res, 200, { phone, from, to, count: points.length, points });
}
