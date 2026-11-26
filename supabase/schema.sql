-- ProntoNonni – schema del database (Supabase / PostgreSQL)
-- Da incollare in Supabase > SQL Editor > New query > Run.
-- Ogni dato appartiene a una famiglia: solo i membri di quella famiglia lo vedono.
-- Gli operatori DEXIA Service vedono solo le richieste affidate al centro servizi.

create extension if not exists pgcrypto;

-- ---------- famiglie e membri ----------
create table public.families (
  id            uuid primary key default gen_random_uuid(),
  nonno_name    text not null,                         -- es. "Nonna Lucia"
  address       text,                                  -- per DEXIA Service
  zone          text,                                  -- quartiere / zona di Roma
  created_at    timestamptz not null default now(),
  trial_ends    date not null default (current_date + 30),
  paid_until    date,                                  -- fine abbonamento pagato
  auto_service  text[] not null default array['pulizie','casa'],  -- richieste che vanno subito a DEXIA Service
  solo_on       boolean not null default false,
  solo_from     time default '14:00',
  solo_to       time default '18:00',
  solo_every    int  default 60 check (solo_every between 15 and 240),
  mail_address  text,
  mail_consent  boolean not null default false
);

create table public.family_members (
  family_id    uuid not null references public.families(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null check (role in ('nonno','familiare','admin')),
  display_name text not null,
  joined_at    timestamptz not null default now(),
  primary key (family_id, user_id)
);

create table public.family_invites (
  code        text primary key default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  family_id   uuid not null references public.families(id) on delete cascade,
  role        text not null check (role in ('nonno','familiare')),
  created_by  uuid not null references auth.users(id),
  expires_at  timestamptz not null default now() + interval '7 days',
  used_at     timestamptz
);

-- operatori del centro servizi DEXIA Service (aggiunti a mano da Diego)
create table public.service_operators (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null
);

-- ---------- dati della famiglia ----------
create table public.meds (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  name       text not null,
  dose       text not null,
  at_time    time not null,
  note       text
);

create table public.med_logs (
  family_id  uuid not null references public.families(id) on delete cascade,
  med_id     uuid not null references public.meds(id) on delete cascade,
  day        date not null default current_date,
  taken_at   timestamptz not null default now(),
  primary key (med_id, day)
);

create table public.contacts (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  name       text not null,
  rel        text,
  phone      text not null,
  sos        boolean not null default false
);

create table public.appointments (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  day        date not null,
  at_time    time not null,
  title      text not null,
  place      text,
  companion  text
);

create table public.devices (          -- telecamere / videocitofono
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families(id) on delete cascade,
  name       text not null,
  app        text not null,
  link       text check (link is null or link like 'https://%'),
  note       text
);

create table public.checkins (         -- "Sto bene"
  id         bigint generated always as identity primary key,
  family_id  uuid not null references public.families(id) on delete cascade,
  at         timestamptz not null default now()
);

create table public.messages (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  author_id   uuid references auth.users(id) on delete set null,
  author_name text not null,
  kind        text not null default 'famiglia' check (kind in ('famiglia','nonno','servizio','posta','assistente')),
  body        text check (char_length(body) <= 2000),
  media_path  text,                    -- percorso nel bucket "media"
  media_type  text check (media_type in ('image','video')),
  created_at  timestamptz not null default now()
);

create table public.requests (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  type        text not null check (type in ('spesa','farmacia','passaggio','compagnia','casa','pulizie','sos')),
  note        text,
  created_at  timestamptz not null default now(),
  status      text not null default 'aperta' check (status in ('aperta','fatta')),
  claimed_by  text,                    -- nome del familiare che "ci pensa"
  svc         text check (svc in ('richiesta','presa')),   -- stato verso DEXIA Service
  svc_eta     time,
  svc_operator uuid references auth.users(id)
);

create table public.mail_log (         -- controllo posta antitruffa
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  checked_at  timestamptz not null default now(),
  kind        text not null check (kind in ('truffa','importante','normale')),
  sender      text,
  summary     text,
  advice      text
);

create table public.ai_usage (         -- limite giornaliero assistente
  family_id  uuid not null references public.families(id) on delete cascade,
  day        date not null default current_date,
  count      int  not null default 0,
  primary key (family_id, day)
);

create index on public.messages (family_id, created_at desc);
create index on public.requests (family_id, created_at desc);
create index on public.requests (svc) where svc is not null;

-- ---------- funzioni di aiuto per i permessi ----------
create or replace function public.is_member(fid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from family_members where family_id = fid and user_id = auth.uid());
$$;

create or replace function public.is_admin(fid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from family_members where family_id = fid and user_id = auth.uid() and role = 'admin');
$$;

create or replace function public.is_operator() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from service_operators where user_id = auth.uid());
$$;

-- crea una famiglia e rende admin chi la crea
create or replace function public.create_family(p_nonno_name text, p_my_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  if auth.uid() is null then raise exception 'Accesso richiesto'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then raise exception 'Per creare una famiglia serve un accesso con email'; end if;
  insert into families (nonno_name) values (p_nonno_name) returning id into fid;
  insert into family_members (family_id, user_id, role, display_name) values (fid, auth.uid(), 'admin', p_my_name);
  return fid;
end $$;

-- entra in una famiglia con un codice d'invito
create or replace function public.join_family(p_code text, p_my_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare inv family_invites;
begin
  if auth.uid() is null then raise exception 'Accesso richiesto'; end if;
  select * into inv from family_invites
   where code = upper(trim(p_code)) and used_at is null and expires_at > now();
  if not found then raise exception 'Codice non valido o scaduto'; end if;
  insert into family_members (family_id, user_id, role, display_name)
  values (inv.family_id, auth.uid(), inv.role, p_my_name)
  on conflict (family_id, user_id) do nothing;
  update family_invites set used_at = now() where code = inv.code;
  return inv.family_id;
end $$;

-- l'abbonamento è attivo? (prova o pagato)
create or replace function public.family_active(fid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(paid_until >= current_date, false) or trial_ends >= current_date
  from families where id = fid;
$$;

-- ---------- sicurezza riga per riga ----------
alter table public.families          enable row level security;
alter table public.family_members    enable row level security;
alter table public.family_invites    enable row level security;
alter table public.service_operators enable row level security;
alter table public.meds              enable row level security;
alter table public.med_logs          enable row level security;
alter table public.contacts          enable row level security;
alter table public.appointments      enable row level security;
alter table public.devices           enable row level security;
alter table public.checkins          enable row level security;
alter table public.messages          enable row level security;
alter table public.requests          enable row level security;
alter table public.mail_log          enable row level security;
alter table public.ai_usage          enable row level security;

-- famiglie: i membri leggono; solo gli admin modificano (non le date di pagamento, gestite dal server)
create policy fam_read   on public.families for select using (is_member(id) or is_operator());
create policy fam_update on public.families for update using (is_admin(id));
-- le date di prova e pagamento le cambia solo il server (chiave di servizio), mai l'app
create or replace function public.protect_billing() returns trigger
language plpgsql as $$
begin
  if (new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until)
     and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Le date di abbonamento non si possono modificare dall''app';
  end if;
  return new;
end $$;
create trigger families_protect_billing before update on public.families
  for each row execute function public.protect_billing();

create policy mem_read   on public.family_members for select using (is_member(family_id));
create policy mem_admin  on public.family_members for delete using (is_admin(family_id));

create policy inv_read   on public.family_invites for select using (is_member(family_id));
create policy inv_create on public.family_invites for insert with check (is_member(family_id) and created_by = auth.uid() and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false));

create policy op_self on public.service_operators for select using (user_id = auth.uid());

-- tabelle della famiglia: tutti i membri leggono e scrivono
do $$
declare t text;
begin
  foreach t in array array['meds','med_logs','contacts','appointments','devices','checkins','messages','mail_log'] loop
    execute format('create policy %1$s_rw on public.%1$s for all using (is_member(family_id)) with check (is_member(family_id))', t);
  end loop;
end $$;

-- messaggi: anche DEXIA Service può scrivere un messaggio "servizio" alle famiglie con richieste affidate
create policy msg_operator on public.messages for insert
  with check (is_operator() and kind = 'servizio'
              and exists (select 1 from requests r where r.family_id = messages.family_id and r.svc is not null));

-- richieste: membri della famiglia + operatori per quelle affidate al centro servizi
create policy req_member   on public.requests for all using (is_member(family_id)) with check (is_member(family_id));
create policy req_op_read  on public.requests for select using (is_operator() and svc is not null);
create policy req_op_write on public.requests for update using (is_operator() and svc is not null);

create policy ai_read on public.ai_usage for select using (is_member(family_id));

-- ---------- tempo reale per chat e richieste ----------
alter publication supabase_realtime add table public.messages, public.requests, public.checkins, public.med_logs;

-- ---------- archivio foto e video ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 20971520)
on conflict (id) do nothing;

-- i file stanno in media/<family_id>/<nome>: solo i membri di quella famiglia li vedono
create policy media_read on storage.objects for select
  using (bucket_id = 'media' and is_member(((storage.foldername(name))[1])::uuid));
create policy media_write on storage.objects for insert
  with check (bucket_id = 'media' and is_member(((storage.foldername(name))[1])::uuid));
