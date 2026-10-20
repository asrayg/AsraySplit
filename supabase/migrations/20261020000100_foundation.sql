-- Foundation: extensions, private helper schema, currencies, profiles.
--
-- Conventions used by every migration:
--   * Money is bigint minor units + ISO 4217 code. Never float/real/double.
--   * Clients never write ledger tables directly. All mutations go through `security definer`
--     RPCs that validate membership, totals, revision, and idempotency in one transaction.
--   * Every exposed table has RLS enabled and explicit grants; Supabase's default
--     "grant all to anon, authenticated" is revoked first.
--   * Error contract (PostgREST): message = machine-readable code, hint = human text.
--       42501  -> 403 not authorized          22023 -> 400 validation failed
--       PT404  -> 404 not found               PT409 -> 409 conflict (revision, idempotency)
--       PT429  -> 429 rate limited

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;
-- Helpers are opt-in: nothing in `private` is executable by API roles unless granted explicitly.
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------------
-- Error helpers
-- ---------------------------------------------------------------------------
create or replace function private.fail(p_code text, p_message text, p_state text default '22023')
returns void language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = p_state, message = p_code, hint = p_message;
end $$;

create or replace function private.require_user() returns uuid
language plpgsql stable set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    perform private.fail('not_authenticated', 'Sign in to continue.', '42501');
  end if;
  return v_uid;
end $$;

-- ---------------------------------------------------------------------------
-- Currencies (fraction digits drive every minor-unit conversion)
-- ---------------------------------------------------------------------------
create table public.currencies (
  code char(3) primary key check (code ~ '^[A-Z]{3}$'),
  fraction_digits smallint not null check (fraction_digits between 0 and 4),
  name text not null
);

insert into public.currencies (code, fraction_digits, name) values
  ('AED',2,'UAE Dirham'),('ARS',2,'Argentine Peso'),('AUD',2,'Australian Dollar'),('BGN',2,'Bulgarian Lev'),
  ('BHD',3,'Bahraini Dinar'),('BIF',0,'Burundian Franc'),('BRL',2,'Brazilian Real'),('CAD',2,'Canadian Dollar'),
  ('CHF',2,'Swiss Franc'),('CLP',0,'Chilean Peso'),('CNY',2,'Chinese Yuan'),('COP',2,'Colombian Peso'),
  ('CRC',2,'Costa Rican Colón'),('CZK',2,'Czech Koruna'),('DJF',0,'Djiboutian Franc'),('DKK',2,'Danish Krone'),
  ('EGP',2,'Egyptian Pound'),('EUR',2,'Euro'),('GBP',2,'British Pound'),('GNF',0,'Guinean Franc'),
  ('HKD',2,'Hong Kong Dollar'),('HUF',2,'Hungarian Forint'),('IDR',2,'Indonesian Rupiah'),('ILS',2,'Israeli New Shekel'),
  ('INR',2,'Indian Rupee'),('IQD',3,'Iraqi Dinar'),('ISK',0,'Icelandic Króna'),('JOD',3,'Jordanian Dinar'),
  ('JPY',0,'Japanese Yen'),('KES',2,'Kenyan Shilling'),('KMF',0,'Comorian Franc'),('KRW',0,'South Korean Won'),
  ('KWD',3,'Kuwaiti Dinar'),('LYD',3,'Libyan Dinar'),('MAD',2,'Moroccan Dirham'),('MXN',2,'Mexican Peso'),
  ('MYR',2,'Malaysian Ringgit'),('NOK',2,'Norwegian Krone'),('NZD',2,'New Zealand Dollar'),('OMR',3,'Omani Rial'),
  ('PEN',2,'Peruvian Sol'),('PHP',2,'Philippine Peso'),('PLN',2,'Polish Złoty'),('PYG',0,'Paraguayan Guaraní'),
  ('QAR',2,'Qatari Riyal'),('RON',2,'Romanian Leu'),('RWF',0,'Rwandan Franc'),('SAR',2,'Saudi Riyal'),
  ('SEK',2,'Swedish Krona'),('SGD',2,'Singapore Dollar'),('THB',2,'Thai Baht'),('TND',3,'Tunisian Dinar'),
  ('TRY',2,'Turkish Lira'),('TWD',2,'New Taiwan Dollar'),('UGX',0,'Ugandan Shilling'),('USD',2,'US Dollar'),
  ('UYI',0,'Uruguay Peso en Unidades Indexadas'),('VND',0,'Vietnamese Đồng'),('VUV',0,'Vanuatu Vatu'),
  ('XAF',0,'Central African CFA Franc'),('XOF',0,'West African CFA Franc'),('XPF',0,'CFP Franc'),
  ('ZAR',2,'South African Rand');

alter table public.currencies enable row level security;
revoke all on public.currencies from anon, authenticated;
grant select on public.currencies to anon, authenticated;
create policy "currencies are public reference data" on public.currencies for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  avatar_emoji text check (avatar_emoji is null or char_length(avatar_emoji) <= 8),
  default_currency char(3) not null default 'USD' references public.currencies(code),
  onboarded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, avatar_emoji, default_currency, onboarded_at) on public.profiles to authenticated;

create or replace function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

create or replace function private.create_profile_for_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  v_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', '')), '');
  if v_name is null and new.email is not null then v_name := split_part(new.email, '@', 1); end if;
  insert into public.profiles (id, display_name)
  values (new.id, left(coalesce(v_name, 'Traveler'), 60))
  on conflict (id) do nothing;
  return new;
end $$;
revoke all on function private.create_profile_for_new_user() from public;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.create_profile_for_new_user();
