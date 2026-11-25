// Supabase Edge Function: gcal-meet
// Creates / updates / cancels a Google Calendar event with a Google Meet link for a meeting announcement,
// and sends e-mail invitations to every attendee (sendUpdates=all).
// Secrets: GOOGLE_SA_JSON (service-account key JSON, domain-wide delegation, scope calendar.events),
//          GOOGLE_ORGANIZER (fallback organizer mailbox, e.g. admin@cpl-inter.com), ORG_DOMAIN (default cpl-inter.com)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const J = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const TZ = "Asia/Bangkok";
const b64u = (b: ArrayBuffer | Uint8Array | string) => {
  const u = typeof b === "string" ? new TextEncoder().encode(b) : new Uint8Array(b as ArrayBuffer);
  let s = ""; u.forEach((c) => (s += String.fromCharCode(c)));
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function gToken(sub: string): Promise<string> {
  const sa = JSON.parse(Deno.env.get("GOOGLE_SA_JSON") || "{}");
  if (!sa.client_email || !sa.private_key) throw new Error("GOOGLE_SA_JSON missing");
  const now = Math.floor(Date.now() / 1000);
  const head = b64u(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64u(JSON.stringify({
    iss: sa.client_email, sub, scope: "https://www.googleapis.com/auth/calendar.events",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(head + "." + claim));
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: head + "." + claim + "." + b64u(sig) }),
  });
  const t = await r.json();
  if (!t.access_token) throw new Error("Google auth: " + (t.error_description || t.error || r.status));
  return t.access_token;
}

const addH = (d: string, t: string, h: number) => {
  const x = new Date(`${d}T${t}:00+07:00`); x.setHours(x.getHours() + h);
  const p = (n: number) => String(n).padStart(2, "0");
  const y = new Date(x.getTime() + 7 * 3600e3);
  return `${y.getUTCFullYear()}-${p(y.getUTCMonth() + 1)}-${p(y.getUTCDate())}T${p(y.getUTCHours())}:${p(y.getUTCMinutes())}:00`;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const URL_ = Deno.env.get("SUPABASE_URL")!, SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, AN = Deno.env.get("SUPABASE_ANON_KEY")!;
    const DOM = (Deno.env.get("ORG_DOMAIN") || "cpl-inter.com").toLowerCase();
    const FALL = Deno.env.get("GOOGLE_ORGANIZER") || "";
    const auth = req.headers.get("Authorization") || "";
    const uc = createClient(URL_, AN, { global: { headers: { Authorization: auth } } });
    const { data: ud } = await uc.auth.getUser();
    if (!ud?.user) return J({ error: "unauthorized" }, 401);
    const db = createClient(URL_, SR);
    const { data: me } = await db.from("profiles").select("id,name,role").eq("id", ud.user.id).maybeSingle();
    if (!me || !["admin", "marketing"].includes(me.role)) return J({ error: "forbidden" }, 403);

    const { id, action } = await req.json();
    const { data: n, error: ne } = await db.from("announcements").select("*").eq("id", id).maybeSingle();
    if (ne || !n) return J({ error: "announcement not found" }, 404);
    if (me.role !== "admin" && n.created_by && n.created_by !== me.id) return J({ error: "forbidden" }, 403);
    const m = n.meet || {};
    const cal = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

    if (action === "delete") {
      if (m.gid) {
        const tk = await gToken(m.gorg || FALL);
        const r = await fetch(`${cal}/${encodeURIComponent(m.gid)}?sendUpdates=all`, { method: "DELETE", headers: { Authorization: "Bearer " + tk } });
        if (!r.ok && r.status !== 404 && r.status !== 410) throw new Error("Google Calendar: " + (await r.text()));
        const nm = { ...m }; delete nm.gid; delete nm.gorg; delete nm.glink;
        await db.from("announcements").update({ meet: n.tag === "ประชุม" ? nm : null }).eq("id", id);
      }
      return J({ ok: true });
    }

    if (n.tag !== "ประชุม" || !n.start_date || !m.s) return J({ error: "not a meeting" }, 400);

    // attendee e-mails: names, "ทีม X", "ทุกคน", or raw e-mail addresses
    const { data: profs } = await db.from("profiles").select("*");
    const P = profs || [];
    const emails = new Map<string, string>();
    try {
      for (let page = 1; page < 20; page++) {
        const { data } = await db.auth.admin.listUsers({ page, perPage: 1000 });
        (data?.users || []).forEach((u) => u.email && emails.set(u.id, u.email));
        if (!data || data.users.length < 1000) break;
      }
    } catch (_) { /* ignore */ }
    const em = (p: any) => (p.email || emails.get(p.id) || "").toLowerCase();
    const out = new Set<string>();
    for (const x of (m.ppl || []) as string[]) {
      if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x)) out.add(x.toLowerCase());
      else if (x === "ทุกคน") P.forEach((p) => em(p) && out.add(em(p)));
      else if (x.startsWith("ทีม ")) P.filter((p) => p.team === x.slice(4)).forEach((p) => em(p) && out.add(em(p)));
      else P.filter((p) => p.name === x).forEach((p) => em(p) && out.add(em(p)));
    }
    const myMail = (ud.user.email || "").toLowerCase();
    const org = m.gorg || (myMail.endsWith("@" + DOM) ? myMail : FALL);
    if (!org) throw new Error("no organizer mailbox");
    out.delete(org);

    const ev: any = {
      summary: n.title,
      description: n.body || "",
      location: m.loc || "",
      start: { dateTime: `${n.start_date}T${m.s}:00`, timeZone: TZ },
      end: { dateTime: m.e ? `${n.start_date}T${m.e}:00` : addH(n.start_date, m.s, 1), timeZone: TZ },
      attendees: [...out].map((email) => ({ email })),
      reminders: { useDefault: true },
    };
    const tk = await gToken(org);
    let r: Response;
    if (m.gid) {
      r = await fetch(`${cal}/${encodeURIComponent(m.gid)}?sendUpdates=all&conferenceDataVersion=1`, {
        method: "PATCH", headers: { Authorization: "Bearer " + tk, "Content-Type": "application/json" }, body: JSON.stringify(ev),
      });
    } else {
      ev.conferenceData = { createRequest: { requestId: `ann-${id}-${Date.now()}`, conferenceSolutionKey: { type: "hangoutsMeet" } } };
      r = await fetch(`${cal}?sendUpdates=all&conferenceDataVersion=1`, {
        method: "POST", headers: { Authorization: "Bearer " + tk, "Content-Type": "application/json" }, body: JSON.stringify(ev),
      });
    }
    const g = await r.json();
    if (!r.ok) throw new Error("Google Calendar: " + (g.error?.message || r.status));
    const url = g.hangoutLink || (g.conferenceData?.entryPoints || []).find((e: any) => e.entryPointType === "video")?.uri || m.url || "";
    const nm = { ...m, url, gid: g.id, gorg: org, glink: g.htmlLink, sent: out.size };
    await db.from("announcements").update({ meet: nm }).eq("id", id);
    return J({ ok: true, meet: nm });
  } catch (e) {
    return J({ error: String((e as Error).message || e) }, 500);
  }
});
