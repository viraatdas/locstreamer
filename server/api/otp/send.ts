import type { VercelRequest, VercelResponse } from "@vercel/node";
import { badRequest, bodyOf, json, normalizePhone } from "../../lib/http.js";
import { isDevPhone, sendCode, smsConfigured } from "../../lib/otp.js";

/** POST { phone } -> { method_id } */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return json(res, 405, { error: "POST only" });
  const phone = normalizePhone(bodyOf(req).phone);
  if (!phone) return badRequest(res, "Enter a phone number with country code, like +14155551234.");
  if (isDevPhone(phone)) return json(res, 200, { method_id: "dev" });
  if (!smsConfigured()) return json(res, 503, { error: "SMS sign-in is not configured on the server yet." });
  const result = await sendCode(phone);
  if (result.error || !result.methodId) return badRequest(res, result.error ?? "Couldn't send the code.");
  return json(res, 200, { method_id: result.methodId });
}
