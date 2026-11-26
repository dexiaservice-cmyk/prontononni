-- ProntoNonni – pagamento con bonifico e attivazione abbonamento da parte dell'operatore

create table if not exists public.app_settings (
  id      int primary key default 1 check (id = 1),
  iban    text,
  holder  text not null default 'D.E.X.I.A. SRL',
  price   numeric(6,2) not null default 20
);
insert into public.app_settings (id) values (1) on conflict (id) do nothing;
alter table public.app_settings enable row level security;
create policy settings_read  on public.app_settings for select using (auth.uid() is not null);
create policy settings_write on public.app_settings for update using (is_operator()) with check (is_operator());

-- le date di abbonamento si cambiano solo dal server o dalla funzione mark_paid
create or replace function public.protect_billing() returns trigger
language plpgsql as $$
begin
  if (new.trial_ends is distinct from old.trial_ends or new.paid_until is distinct from old.paid_until)
     and coalesce(auth.role(), '') <> 'service_role'
     and coalesce(current_setting('pn.billing', true), '') <> 'on' then
    raise exception 'Le date di abbonamento non si possono modificare dall''app';
  end if;
  return new;
end $$;

-- l'operatore DEXIA Service segna un anno pagato
create or replace function public.mark_paid(p_family uuid)
returns date language plpgsql security definer set search_path = public as $$
declare nuova date;
begin
  if not is_operator() then raise exception 'Solo gli operatori DEXIA Service'; end if;
  perform set_config('pn.billing', 'on', true);
  update families
     set paid_until = greatest(current_date, coalesce(paid_until, trial_ends)) + 365
   where id = p_family
  returning paid_until into nuova;
  if nuova is null then raise exception 'Famiglia non trovata'; end if;
  return nuova;
end $$;

-- l'operatore può scrivere messaggi "servizio" a qualunque famiglia (es. conferma pagamento)
drop policy if exists msg_operator on public.messages;
create policy msg_operator on public.messages for insert with check (is_operator() and kind = 'servizio');
