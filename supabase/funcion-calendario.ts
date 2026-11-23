// Supabase Edge Function "calendario": sirve las tareas como calendario de suscripción (.ics)
Deno.serve(async (req) => {
  const token = new URL(req.url).searchParams.get('t') ?? '';
  if (!/^[a-f0-9]{36}$/.test(token)) return new Response('Calendario no encontrado', { status: 404 });
  const clave = Deno.env.get('SUPABASE_ANON_KEY')!;
  const r = await fetch(`${Deno.env.get('SUPABASE_URL')}/rest/v1/rpc/ics_tareas`, {
    method: 'POST',
    headers: { apikey: clave, Authorization: `Bearer ${clave}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_token: token }),
  });
  const ics = r.ok ? await r.json() : null;
  if (!ics) return new Response('Calendario no encontrado', { status: 404 });
  return new Response(ics, {
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      'Content-Disposition': 'inline; filename="tareas-de-obra.ics"',
      'Cache-Control': 'no-cache',
    },
  });
});
