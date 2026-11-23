-- ============================================================
--  CONTROL DE OBRAS · Estructura de la base de datos (Supabase)
--  Cómo usarlo: Supabase › SQL Editor › New query › pegar todo › Run
--  Se puede ejecutar varias veces sin romper nada.
-- ============================================================

-- ---------- OBRAS ----------
create table if not exists public.obras (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  numero        text not null,
  nombre        text not null,
  fecha_inicio  date,
  fecha_fin     date,
  estado        text not null default 'En curso'
                check (estado in ('En curso', 'Parada', 'Terminada')),
  presupuesto   numeric(14,2),
  created_at    timestamptz not null default now()
);

-- ---------- PERSONAL ----------
create table if not exists public.personal (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre      text not null,
  apellidos   text not null default '',
  dni         text,
  categoria   text,
  empresa     text,
  created_at  timestamptz not null default now()
);

-- ---------- MAQUINARIA ----------
create table if not exists public.maquinaria (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nombre      text not null,
  tipo        text,
  empresa     text,
  created_at  timestamptz not null default now()
);

-- ---------- PARTES DIARIOS ----------
create table if not exists public.partes (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null default auth.uid() references auth.users(id) on delete cascade,
  obra_id                 uuid not null references public.obras(id) on delete cascade,
  fecha                   date not null default current_date,
  trabajos                text,
  hay_incidencia          boolean not null default false,
  incidencia_tipo         text check (incidencia_tipo in ('Rotura', 'Accidente', 'Otra')),
  incidencia_descripcion  text,
  created_at              timestamptz not null default now()
);

-- Personal presente en cada parte
create table if not exists public.parte_personal (
  parte_id     uuid not null references public.partes(id) on delete cascade,
  personal_id  uuid not null references public.personal(id) on delete cascade,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  primary key (parte_id, personal_id)
);

-- Maquinaria utilizada en cada parte
create table if not exists public.parte_maquinaria (
  parte_id    uuid not null references public.partes(id) on delete cascade,
  maquina_id  uuid not null references public.maquinaria(id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  primary key (parte_id, maquina_id)
);

-- ---------- TAREAS PENDIENTES ----------
create table if not exists public.tareas (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  texto       text not null,
  fecha       date not null default current_date,
  obra_id     uuid references public.obras(id) on delete set null,
  hecha       boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------- VISITAS ----------
create table if not exists public.visitas (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  obra_id     uuid not null references public.obras(id) on delete cascade,
  fecha       date not null default current_date,
  notas       text not null,
  created_at  timestamptz not null default now()
);
create index if not exists visitas_user_fecha_idx on public.visitas (user_id, fecha desc);
create index if not exists visitas_obra_idx on public.visitas (obra_id);

-- ---------- ÍNDICES ----------
create index if not exists obras_user_idx       on public.obras (user_id);
create index if not exists personal_user_idx    on public.personal (user_id);
create index if not exists maquinaria_user_idx  on public.maquinaria (user_id);
create index if not exists partes_user_fecha_idx on public.partes (user_id, fecha desc);
create index if not exists partes_obra_idx      on public.partes (obra_id);
create index if not exists tareas_user_fecha_idx on public.tareas (user_id, fecha);

-- ---------- SEGURIDAD: cada usuario solo ve y toca lo suyo ----------
do $$
declare t text;
begin
  foreach t in array array['obras','personal','maquinaria','partes','parte_personal','parte_maquinaria','tareas','visitas']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "solo_propietario" on public.%I', t);
    execute format(
      'create policy "solo_propietario" on public.%I for all to authenticated
         using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
  end loop;
end $$;
-- ---------- CALENDARIO: dirección privada para suscribirse a las tareas ----------
create table if not exists public.calendario_tokens (
  user_id     uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  token       text not null unique default encode(extensions.gen_random_bytes(18), 'hex'),
  created_at  timestamptz not null default now()
);
alter table public.calendario_tokens enable row level security;
drop policy if exists "solo_propietario" on public.calendario_tokens;
create policy "solo_propietario" on public.calendario_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Genera el calendario (formato iCalendar) con las tareas pendientes del dueño del token
create or replace function public.ics_tareas(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid;
  ics text;
  ahora text := to_char(now() at time zone 'utc', 'YYYYMMDD"T"HH24MISS"Z"');
begin
  if p_token is null or p_token !~ '^[a-f0-9]{36}$' then return null; end if;
  select user_id into uid from calendario_tokens where token = p_token;
  if uid is null then return null; end if;

  select string_agg(
           'BEGIN:VEVENT' || E'\r\n' ||
           'UID:' || t.id || '@control-obras' || E'\r\n' ||
           'DTSTAMP:' || ahora || E'\r\n' ||
           'DTSTART;VALUE=DATE:' || to_char(t.fecha, 'YYYYMMDD') || E'\r\n' ||
           'DTEND;VALUE=DATE:' || to_char(t.fecha + 1, 'YYYYMMDD') || E'\r\n' ||
           'SUMMARY:' || replace(replace(replace(replace(replace(t.texto, '\', '\\'), ';', '\;'), ',', '\,'), E'\r', ''), E'\n', '\n') || E'\r\n' ||
           case when o.id is not null then
             'DESCRIPTION:' || replace(replace(replace(('Obra ' || o.numero || ' · ' || o.nombre), '\', '\\'), ';', '\;'), ',', '\,') || E'\r\n'
           else '' end ||
           'TRANSP:TRANSPARENT' || E'\r\n' ||
           'END:VEVENT' || E'\r\n', '' order by t.fecha)
    into ics
    from tareas t
    left join obras o on o.id = t.obra_id
   where t.user_id = uid and not t.hecha;

  return 'BEGIN:VCALENDAR' || E'\r\n' ||
         'VERSION:2.0' || E'\r\n' ||
         'PRODID:-//Control de Obras//ES' || E'\r\n' ||
         'CALSCALE:GREGORIAN' || E'\r\n' ||
         'METHOD:PUBLISH' || E'\r\n' ||
         'X-WR-CALNAME:Tareas de obra' || E'\r\n' ||
         'X-WR-TIMEZONE:Europe/Madrid' || E'\r\n' ||
         'REFRESH-INTERVAL;VALUE=DURATION:PT1H' || E'\r\n' ||
         'X-PUBLISHED-TTL:PT1H' || E'\r\n' ||
         coalesce(ics, '') ||
         'END:VCALENDAR' || E'\r\n';
end;
$$;
revoke all on function public.ics_tareas(text) from public;
grant execute on function public.ics_tareas(text) to anon, authenticated;
