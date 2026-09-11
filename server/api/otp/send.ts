import type { VercelRequest, VercelResponse } from "@vercel/node";
import { badRequest, bodyOf, json, normalizePhone } from "../../lib/http.js";
import { isDevPhone, sendCode, smsConfigured } from "../../lib/otp.js";
import { allow } from "../../lib/ratelimit.js";

/** POST { phone } -> { method_id } */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return json(res, 405, { error: "POST only" });
  const phone = normalizePhone(bodyOf(req).phone);
  if (!phone) return badRequest(res, "Enter a phone number with country code, like +14155551234.");
  if (isDevPhone(phone)) return json(res, 200, { method_id: "dev" });
  if (!smsConfigured()) return json(res, 503, { error: "SMS sign-in is not configured on the server yet." });

  // Cap SMS sends so the endpoint can't be used to pump texts on the upstream
  // account: at most 5 per number per hour and 20 per client IP per hour.
  const ip = (req.headers["x-forwarded-for"] as string | undefined)?.split(",")[0]?.trim() || "unknown";
  const [phoneOk, ipOk] = await Promise.all([
    allow("send-phone", phone, 5, 3_600_000),
    allow("send-ip", ip, 20, 3_600_000),
  ]);
  if (!phoneOk || !ipOk) return json(res, 429, { error: "Too many code requests. Try again later." });

  const result = await sendCode(phone);
  if (result.error || !result.methodId) return badRequest(res, result.error ?? "Couldn't send the code.");
  return json(res, 200, { method_id: result.methodId });
}
