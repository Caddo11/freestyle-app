// Freestyle : envoie chaque ping sur les téléphones du membre (Web Push).
// Appelée par le déclencheur fs_push_trigger avec { id } du ping. Les clés VAPID sont créées
// au premier appel et gardées dans la table fermée push_config.
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const APP = "https://caddo11.github.io/freestyle-app/";

async function vapid() {
  const { data } = await sb.from("push_config").select("public_key,private_key").eq("id", 1).maybeSingle();
  if (data) return data;
  const k = webpush.generateVAPIDKeys();
  const { error } = await sb.from("push_config").insert({ id: 1, public_key: k.publicKey, private_key: k.privateKey });
  if (error) {
    const { data: d2 } = await sb.from("push_config").select("public_key,private_key").eq("id", 1).single();
    return d2!;
  }
  return { public_key: k.publicKey, private_key: k.privateKey };
}

function text(type: string, t: string) {
  const m: Record<string, string> = {
    reaction: `a réagi « ${t} » à ton post`, story_like: "a aimé ton flash", like: "a aimé ton post",
    comment: `a commenté : ${t}`, reply: `a répondu à ton commentaire : ${t}`,
    comment_like: "a aimé ton commentaire" + (t ? ` : ${t}` : ""), message: t || "t’a envoyé un message",
    follow: "s’est abonné à toi", announcement: t, partner_request: "veut être ton partenaire d’entraînement",
    partner_accept: "a accepté d’être ton partenaire d’entraînement", respect: "t’a validé",
    ann_request: `demande à publier une annonce : ${t}`, ann_accept: `a accepté ton annonce : ${t}`,
    ann_refuse: `n’a pas retenu ton annonce : ${t}`, referral: "a rejoint Freestyle grâce à toi",
  };
  return m[type] ?? "";
}

Deno.serve(async (req) => {
  const keys = await vapid();
  let body: { id?: string | number; init?: boolean } = {};
  try { body = await req.json(); } catch { /* vide */ }
  if (!body.id) return Response.json({ ok: true, key: !!keys.public_key });
  webpush.setVapidDetails(APP, keys.public_key, keys.private_key);

  const { data: n } = await sb.from("notifications").select("*").eq("id", body.id).maybeSingle();
  if (!n || n.pushed_at || Date.now() - new Date(n.created_at).getTime() > 10 * 60 * 1000) {
    return Response.json({ skipped: true });
  }
  await sb.from("notifications").update({ pushed_at: new Date().toISOString() }).eq("id", n.id);
  const { data: actor } = await sb.from("profiles").select("handle").eq("id", n.actor_id).maybeSingle();
  const { data: subs } = await sb.from("push_subscriptions").select("*").eq("user_id", n.user_id);
  const handle = actor?.handle ? "@" + actor.handle : "Freestyle";
  const payload = JSON.stringify({
    title: n.type === "announcement" ? "Freestyle · Événement" : handle,
    body: n.type === "announcement" ? `${handle} : ${text(n.type, n.text || "")}` : text(n.type, n.text || ""),
    tag: n.type === "message" ? "msg-" + n.actor_id : String(n.id),
    url: APP + (n.type === "message" ? "?chat=" + n.actor_id : "?pings=1"),
  });
  let sent = 0;
  for (const s of subs ?? []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
    }
  }
  return Response.json({ sent });
});
