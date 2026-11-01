// Freestyle : supprime les messages éphémères (vocal, photo, vidéo) de plus de 24 h,
// d'abord le fichier dans le stockage, puis la ligne dans la base.
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async () => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const now = new Date().toISOString();
  const { data, error } = await sb.from("messages").select("id,media").lt("expires_at", now).limit(500);
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  const mark = "/object/public/media/";
  const paths = (data ?? [])
    .map((m) => m.media?.url as string | undefined)
    .filter((u): u is string => !!u && u.includes(mark))
    .map((u) => decodeURIComponent(u.split(mark)[1]));
  if (paths.length) {
    const r = await sb.storage.from("media").remove(paths);
    if (r.error) return new Response(JSON.stringify({ error: r.error.message }), { status: 500 });
  }
  const ids = (data ?? []).map((m) => m.id);
  if (ids.length) {
    const d = await sb.from("messages").delete().in("id", ids);
    if (d.error) return new Response(JSON.stringify({ error: d.error.message }), { status: 500 });
  }
  return new Response(JSON.stringify({ messages: ids.length, files: paths.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
