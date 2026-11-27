import type { Admin } from "./auth.ts";

// Private progress photos. The bucket is not public. anon and authenticated are
// blocked by restrictive RLS. This module runs with the service role (it bypasses
// RLS) after the Edge Function has checked who is calling, and it only ever returns
// a short-lived signed URL to the client. `user` is the signed-in account id, or null
// for the owner (passcode or bot token); the SQL functions only touch that user's rows.

export const PROGRESS_BUCKET = "progress-photos";
const SIGNED_SECONDS = 60 * 60 * 12;
const PATH_RE =
  /^[0-9]{4}\/[0-9]{2}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/;


export function isProgressPhotoAction(action: string): boolean {
  return action === "progress_photo_sign" ||
    action === "progress_photo_save" ||
    action === "progress_photo_delete";
}

function localDay(d: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(d);
}

function absoluteSigned(url: string, supabaseUrl: string): string {
  if (url.startsWith("http://") || url.startsWith("https://")) return url;
  const base = supabaseUrl.replace(/\/$/, "");
  if (url.startsWith("/storage/v1")) return base + url;
  if (url.startsWith("/object/")) return base + "/storage/v1" + url;
  return base + (url.startsWith("/") ? url : `/${url}`);
}

async function objectExists(admin: Admin, path: string): Promise<boolean> {
  try {
    const found = await admin.storage.from(PROGRESS_BUCKET).exists(path);
    if (found.data === true) return true;
  } catch (err) {
    console.error("progress_photo_exists", err);
  }
  const slash = path.lastIndexOf("/");
  const folder = slash >= 0 ? path.slice(0, slash) : "";
  const name = path.slice(slash + 1);
  const listed = await admin.storage.from(PROGRESS_BUCKET).list(folder, {
    limit: 20,
    search: name,
  });
  return (listed.data ?? []).some((row) => row.name === name);
}

async function objectReady(admin: Admin, path: string): Promise<boolean> {
  for (let i = 0; i < 3; i++) {
    if (await objectExists(admin, path)) return true;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

export async function handleProgressPhoto(
  admin: Admin,
  action: string,
  payload: Record<string, unknown>,
  supabaseUrl: string,
  user: string | null,
  timeZone = "America/Chicago",
): Promise<Record<string, unknown>> {
  if (action === "progress_photo_sign") {
    const takenRaw = typeof payload.taken_at === "string" ? payload.taken_at : "";
    const taken = takenRaw ? new Date(takenRaw) : new Date();
    const when = Number.isNaN(taken.getTime()) ? new Date() : taken;
    let day: string;
    try { day = localDay(when, timeZone); } catch { day = localDay(when, "America/Chicago"); }
    const [year, month] = day.split("-");
    const path = `${year}/${month}/${crypto.randomUUID()}.jpg`;
    const { data, error } = await admin.storage
      .from(PROGRESS_BUCKET)
      .createSignedUploadUrl(path, { upsert: false });
    if (error || !data?.signedUrl) {
      console.error("progress_photo_sign", error?.message);
      return { ok: false, error: "sign_failed" };
    }
    return {
      ok: true,
      action,
      path: data.path || path,
      signed_url: absoluteSigned(data.signedUrl, supabaseUrl),
      token: data.token,
    };
  }

  if (action === "progress_photo_save") {
    const path = typeof payload.path === "string" ? payload.path : "";
    if (!PATH_RE.test(path)) {
      return { ok: false, error: "invalid_path", field: "path" };
    }
    if (!await objectReady(admin, path)) {
      return { ok: false, error: "upload_missing", field: "path" };
    }
    const { data, error } = await admin.rpc("log_progress_photo_save_for", {
      p_user: user,
      p_payload: payload,
    });
    if (error) {
      console.error("progress_photo_save", error.message);
      return { ok: false, error: "query_failed" };
    }
    return (data ?? { ok: false, error: "empty_result" }) as Record<string, unknown>;
  }

  const { data, error } = await admin.rpc("log_progress_photo_delete_for", {
    p_user: user,
    p_payload: payload,
  });
  if (error) {
    console.error("progress_photo_delete", error.message);
    return { ok: false, error: "query_failed" };
  }
  const result = (data ?? { ok: false, error: "empty_result" }) as Record<string, unknown>;
  const storagePath = result.storage_path;
  if (result.ok && typeof storagePath === "string" && storagePath) {
    const removed = await admin.storage.from(PROGRESS_BUCKET).remove([storagePath]);
    if (removed.error) console.error("progress_photo_remove", removed.error.message);
  }
  delete result.storage_path;
  return result;
}

// Adds progress_photos with a signed url on each row. On error, leaves the payload
// alone so the rest of the dashboard still loads.
export async function attachProgressPhotos(admin: Admin, payload: unknown, user: string | null): Promise<void> {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return;
  const body = payload as Record<string, unknown>;
  const { data, error } = await admin.rpc("log_progress_photos_for", { p_user: user });
  if (error) {
    console.error("log_progress_photos", error.message);
    return;
  }
  const photos = Array.isArray(data) ? data as Record<string, unknown>[] : [];
  const paths = photos
    .map((p) => (typeof p.storage_path === "string" ? p.storage_path : ""))
    .filter((p) => p.length > 0);
  const urls = new Map<string, string>();
  for (let i = 0; i < paths.length; i += 100) {
    const chunk = paths.slice(i, i + 100);
    const signed = await admin.storage.from(PROGRESS_BUCKET).createSignedUrls(chunk, SIGNED_SECONDS);
    if (signed.error || !signed.data) {
      console.error("progress_photo_urls", signed.error?.message);
      continue;
    }
    signed.data.forEach((row, index) => {
      if (row.signedUrl) urls.set(chunk[index], row.signedUrl);
    });
  }
  body.progress_photos = photos.map((p) => {
    const path = typeof p.storage_path === "string" ? p.storage_path : "";
    return {
      id: p.id,
      taken_at: p.taken_at,
      day: p.day,
      weight_lb: p.weight_lb,
      weight_id: p.weight_id,
      notes: p.notes,
      url: path ? urls.get(path) ?? null : null,
    };
  });
}
