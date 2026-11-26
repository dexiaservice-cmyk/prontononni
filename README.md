# ProntoNonni

Sito e app di **prontononni.it** — un servizio di DEXIA S.r.l.

- `public/` — sito (home, privacy, grazie) e app in `public/app/`
- `public/app/config.js` — indirizzo Supabase e chiave pubblica (anon). Mai la chiave service_role.
- `supabase/schema.sql` — database: da eseguire nell'SQL Editor di Supabase.

Netlify pubblica automaticamente la cartella `public/` a ogni modifica su `main`.
