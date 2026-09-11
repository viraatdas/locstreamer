/**
 * A small S3-backed sliding-window rate limiter, so the public OTP-send
 * endpoint can't be used to pump SMS (billed to the upstream Stytch account)
 * by looping over numbers. State is a JSON array of recent hit timestamps at
 * `ratelimit/<scope>/<key>.json`; shared across serverless instances, which an
 * in-memory counter would not be. One GET + one PUT per allowed call.
 */
import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

const client = new S3Client({ region: process.env.AWS_REGION ?? "us-east-1" });

function bucket(): string {
  const name = process.env.S3_BUCKET;
  if (!name) throw new Error("S3_BUCKET is not set");
  return name;
}

function safe(key: string): string {
  return key.replace(/[^A-Za-z0-9_.+-]/g, "_").slice(0, 120) || "unknown";
}

/**
 * Records a hit for `scope/key` and reports whether it is within `max` hits
 * per `windowMs`. Fails open (allows) on any storage error — the limiter must
 * never take sign-in down, only cap abuse.
 */
export async function allow(scope: string, key: string, max: number, windowMs: number): Promise<boolean> {
  const objectKey = `ratelimit/${safe(scope)}/${safe(key)}.json`;
  const now = Date.now();
  const cutoff = now - windowMs;
  try {
    let hits: number[] = [];
    try {
      const got = await client.send(new GetObjectCommand({ Bucket: bucket(), Key: objectKey }));
      const text = (await got.Body?.transformToString()) ?? "[]";
      const parsed = JSON.parse(text);
      if (Array.isArray(parsed)) hits = parsed.filter((t) => typeof t === "number" && t > cutoff);
    } catch {
      /* no prior record (or unreadable) — treat as empty */
    }
    if (hits.length >= max) return false;
    hits.push(now);
    await client.send(
      new PutObjectCommand({
        Bucket: bucket(),
        Key: objectKey,
        Body: JSON.stringify(hits),
        ContentType: "application/json",
      }),
    );
    return true;
  } catch {
    return true; // fail open
  }
}
