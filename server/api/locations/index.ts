import type { VercelRequest, VercelResponse } from "@vercel/node";
import { phoneFromBearer } from "../../lib/auth.js";
import { badRequest, bodyOf, json } from "../../lib/http.js";
import { appendPoints, parsePoints } from "../../lib/store.js";

/** POST (Bearer device token) { points: [{ts, lat, lon, acc?, spd?}] } -> { stored, keys } */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return json(res, 405, { error: "POST only" });
  const phone = await phoneFromBearer(req);
  if (!phone) return json(res, 401, { error: "Sign in again." });
  const points = parsePoints(bodyOf(req).points);
  if (points.length === 0) return badRequest(res, "No valid points.");
  if (points.length > 5000) return badRequest(res, "Too many points in one batch (max 5000).");
  const keys = await appendPoints(phone, points);
  return json(res, 200, { stored: points.length, keys });
}
