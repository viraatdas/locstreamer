import type { VercelRequest, VercelResponse } from "@vercel/node";
import { phoneFromBearer } from "../../lib/auth.js";
import { badRequest, bodyOf, json } from "../../lib/http.js";
import { appendPoints, deleteAllPoints, parsePoints } from "../../lib/store.js";

/**
 * POST   (Bearer) { points: [{ts, lat, lon, acc?, spd?}] } -> { stored, keys }
 * DELETE (Bearer) -> { deleted }   — removes ALL of the caller's location
 *   history (in-app account deletion, Apple guideline 5.1.1(v)).
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST" && req.method !== "DELETE") return json(res, 405, { error: "POST or DELETE only" });
  const phone = await phoneFromBearer(req);
  if (!phone) return json(res, 401, { error: "Sign in again." });

  if (req.method === "DELETE") {
    const deleted = await deleteAllPoints(phone);
    return json(res, 200, { deleted });
  }
  const raw = bodyOf(req).points;
  // A missing/non-array `points` is a malformed request (400). A well-formed
  // array is accepted even if nothing survives validation (e.g. every ts is
  // out of range): reply 200 {stored: 0} so the client drops the batch instead
  // of retrying the same unstorable head forever.
  if (!Array.isArray(raw)) return badRequest(res, "Expected a points array.");
  if (raw.length > 5000) return badRequest(res, "Too many points in one batch (max 5000).");
  const points = parsePoints(raw);
  if (points.length === 0) return json(res, 200, { stored: 0, keys: [] });
  const keys = await appendPoints(phone, points);
  return json(res, 200, { stored: points.length, keys });
}
