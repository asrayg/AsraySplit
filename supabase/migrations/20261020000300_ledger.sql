-- Ledger: expenses (payments + allocations + optional items), settlements, balances.
-- Balances are never stored; they are derived from these facts by `trip_balances`.

create table public.expenses (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  description text not null check (char_length(btrim(description)) between 1 and 120),
  merchant text check (merchant is null or char_length(merchant) <= 120),
  notes text check (notes is null or char_length(notes) <= 2000),
  category text not null default 'other' check (category in
    ('food','groceries','drinks','lodging','transport','flights','activities','shopping','fees','health','other')),
  payment_method text not null default 'card' check (payment_method in ('cash','card','bank_transfer','venmo','paypal','other')),
  spent_at timestamptz not null,
  split_method text not null check (split_method in ('equal','exact','percentage','shares','adjustment','itemized')),
  original_minor bigint not null check (original_minor <> 0 and abs(original_minor) <= 10000000000000),
  original_currency char(3) not null references public.currencies(code),
  base_minor bigint not null,
  base_currency char(3) not null references public.currencies(code),
  exchange_rate numeric(24, 12) not null default 1 check (exchange_rate > 0),
  rate_provider text,
  rate_date timestamptz,
  tax_minor bigint check (tax_minor is null or tax_minor >= 0),
  service_fee_minor bigint check (service_fee_minor is null or service_fee_minor >= 0),
  tip_minor bigint check (tip_minor is null or tip_minor >= 0),
  discount_minor bigint check (discount_minor is null or discount_minor >= 0),
  revision integer not null default 1,
  idempotency_key uuid not null,
  request_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, id),
  unique (trip_id, idempotency_key)
);
create index expenses_trip_spent_idx on public.expenses(trip_id, spent_at desc, id) where deleted_at is null;
create index expenses_trip_updated_idx on public.expenses(trip_id, updated_at, id);
create index expenses_created_by_idx on public.expenses(created_by);

create table public.expense_payments (
  expense_id uuid not null,
  trip_id uuid not null,
  participant_id uuid not null,
  amount_minor bigint not null,
  base_amount_minor bigint not null,
  primary key (expense_id, participant_id),
  foreign key (trip_id, expense_id) references public.expenses(trip_id, id) on delete cascade,
  foreign key (trip_id, participant_id) references public.trip_participants(trip_id, id)
);
create index expense_payments_trip_idx on public.expense_payments(trip_id);
create index expense_payments_participant_idx on public.expense_payments(participant_id);

create table public.expense_allocations (
  expense_id uuid not null,
  trip_id uuid not null,
  participant_id uuid not null,
  amount_minor bigint not null,
  base_amount_minor bigint not null,
  input_value numeric(20, 6),
  primary key (expense_id, participant_id),
  foreign key (trip_id, expense_id) references public.expenses(trip_id, id) on delete cascade,
  foreign key (trip_id, participant_id) references public.trip_participants(trip_id, id)
);
create index expense_allocations_trip_idx on public.expense_allocations(trip_id);
create index expense_allocations_participant_idx on public.expense_allocations(participant_id);

create table public.expense_items (
  id uuid primary key,
  expense_id uuid not null,
  trip_id uuid not null,
  position integer not null,
  name text not null check (char_length(name) between 1 and 120),
  quantity numeric(12, 3) not null default 1 check (quantity > 0),
  amount_minor bigint not null,
  foreign key (trip_id, expense_id) references public.expenses(trip_id, id) on delete cascade
);
create index expense_items_expense_idx on public.expense_items(expense_id, position);
create index expense_items_trip_idx on public.expense_items(trip_id);

create table public.expense_item_assignees (
  item_id uuid not null references public.expense_items(id) on delete cascade,
  trip_id uuid not null,
  participant_id uuid not null,
  weight numeric(12, 3) not null default 1 check (weight > 0),
  primary key (item_id, participant_id),
  foreign key (trip_id, participant_id) references public.trip_participants(trip_id, id)
);
create index expense_item_assignees_trip_idx on public.expense_item_assignees(trip_id);

create table public.expense_tags (
  expense_id uuid not null,
  trip_id uuid not null,
  tag text not null check (tag ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  primary key (expense_id, tag),
  foreign key (trip_id, expense_id) references public.expenses(trip_id, id) on delete cascade
);
create index expense_tags_trip_tag_idx on public.expense_tags(trip_id, tag);

create table public.settlements (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  from_participant_id uuid not null,
  to_participant_id uuid not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor <= 10000000000000),
  currency char(3) not null references public.currencies(code),
  base_amount_minor bigint not null check (base_amount_minor > 0),
  exchange_rate numeric(24, 12) not null default 1 check (exchange_rate > 0),
  rate_provider text,
  rate_date timestamptz,
  method text not null default 'cash' check (method in ('cash','card','bank_transfer','venmo','paypal','other')),
  reference text check (reference is null or char_length(reference) <= 120),
  note text check (note is null or char_length(note) <= 500),
  settled_at timestamptz not null default now(),
  revision integer not null default 1,
  idempotency_key uuid not null,
  request_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, idempotency_key),
  check (from_participant_id <> to_participant_id),
  foreign key (trip_id, from_participant_id) references public.trip_participants(trip_id, id),
  foreign key (trip_id, to_participant_id) references public.trip_participants(trip_id, id)
);
create index settlements_trip_idx on public.settlements(trip_id, settled_at desc) where deleted_at is null;
create index settlements_trip_updated_idx on public.settlements(trip_id, updated_at, id);

create table public.receipts (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  expense_id uuid references public.expenses(id) on delete set null,
  settlement_id uuid references public.settlements(id) on delete set null,
  uploaded_by uuid references auth.users(id) on delete set null,
  object_path text not null unique,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/heic', 'application/pdf')),
  byte_size integer not null check (byte_size between 1 and 10485760),
  width integer check (width is null or width between 1 and 20000),
  height integer check (height is null or height between 1 and 20000),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  perceptual_hash text check (perceptual_hash is null or perceptual_hash ~ '^[0-9a-f]{16}$'),
  scan_status text not null default 'none' check (scan_status in ('none', 'queued', 'processing', 'succeeded', 'failed')),
  scan_result jsonb,
  scan_error text,
  scan_model text,
  scanned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index receipts_trip_idx on public.receipts(trip_id, created_at desc) where deleted_at is null;
create index receipts_expense_idx on public.receipts(expense_id) where expense_id is not null;
create index receipts_settlement_idx on public.receipts(settlement_id) where settlement_id is not null;
create index receipts_trip_hash_idx on public.receipts(trip_id, sha256);
create trigger receipts_touch before update on public.receipts for each row execute function private.touch_updated_at();

alter table public.receipts enable row level security;
revoke all on public.receipts from anon, authenticated;
grant select on public.receipts to authenticated;
create policy "members read receipts" on public.receipts for select to authenticated using ((select private.is_trip_member(trip_id)));

create trigger expenses_touch before update on public.expenses for each row execute function private.touch_updated_at();
create trigger settlements_touch before update on public.settlements for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS: members read; nobody writes directly.
-- ---------------------------------------------------------------------------
alter table public.expenses enable row level security;
alter table public.expense_payments enable row level security;
alter table public.expense_allocations enable row level security;
alter table public.expense_items enable row level security;
alter table public.expense_item_assignees enable row level security;
alter table public.expense_tags enable row level security;
alter table public.settlements enable row level security;

revoke all on public.expenses, public.expense_payments, public.expense_allocations, public.expense_items,
  public.expense_item_assignees, public.expense_tags, public.settlements from anon, authenticated;
grant select on public.expense_payments, public.expense_allocations, public.expense_items,
  public.expense_item_assignees, public.expense_tags, public.settlements to authenticated;
-- request_hash is an internal idempotency detail.
grant select (id, trip_id, description, merchant, notes, category, payment_method, spent_at, split_method,
  original_minor, original_currency, base_minor, base_currency, exchange_rate, rate_provider, rate_date,
  tax_minor, service_fee_minor, tip_minor, discount_minor, revision, idempotency_key, created_by, updated_by,
  deleted_at, deleted_by, created_at, updated_at) on public.expenses to authenticated;

create policy "members read expenses" on public.expenses for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read payments" on public.expense_payments for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read allocations" on public.expense_allocations for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read items" on public.expense_items for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read item assignees" on public.expense_item_assignees for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read tags" on public.expense_tags for select to authenticated using ((select private.is_trip_member(trip_id)));
create policy "members read settlements" on public.settlements for select to authenticated using ((select private.is_trip_member(trip_id)));

-- ---------------------------------------------------------------------------
-- Money helpers (must match AsraySplit/Core/Domain/Allocation.swift exactly)
-- ---------------------------------------------------------------------------

-- Largest-remainder apportionment of p_total by non-negative integer weights (sum must be > 0).
-- Remainder units go to the largest remainders, ties by ascending id. Mirrors Apportionment.allocate.
create or replace function private.apportion(p_total bigint, p_ids uuid[], p_weights bigint[])
returns table (id uuid, amount bigint) language sql immutable set search_path = '' as $$
  with input as (
    select u.id, u.w::numeric as w from unnest(p_ids, p_weights) as u(id, w)
  ), totals as (
    select sum(w) as ws from input
  ), base as (
    select i.id, i.w, floor(abs(p_total)::numeric * i.w / t.ws) as fl, mod(abs(p_total)::numeric * i.w, t.ws) as rem
    from input i cross join totals t
  ), leftover as (
    select abs(p_total)::numeric - sum(fl) as lo from base
  ), ranked as (
    select b.id, b.fl, case when b.w > 0 then row_number() over (partition by b.w > 0 order by b.rem desc, b.id asc) end as rn
    from base b
  )
  select r.id, (sign(p_total) * (r.fl + case when r.rn is not null and r.rn <= l.lo then 1 else 0 end))::bigint
  from ranked r cross join leftover l
$$;

-- Converts minor units between currencies, rounding half away from zero.
create or replace function private.convert_minor(p_minor bigint, p_from char(3), p_to char(3), p_rate numeric)
returns bigint language sql stable set search_path = '' as $$
  select case when p_from = p_to then p_minor else
    round(p_minor::numeric * p_rate
      * power(10::numeric, (select fraction_digits from public.currencies where code = p_to))
      / power(10::numeric, (select fraction_digits from public.currencies where code = p_from)))::bigint
  end
$$;

-- Stable request fingerprint for idempotency: same key + different payload => conflict.
create or replace function private.request_hash(p_payload jsonb) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(convert_to((p_payload - 'idempotency_key')::text, 'UTF8'), 'sha256'), 'hex')
$$;

-- ---------------------------------------------------------------------------
-- Expense validation + write (shared by create and update)
-- ---------------------------------------------------------------------------
create or replace function private.write_expense(p_trip_id uuid, p_expense_id uuid, p_payload jsonb, p_is_update boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_trip public.trips;
  v_total bigint := (p_payload ->> 'amount_minor')::bigint;
  v_currency char(3) := upper(p_payload ->> 'currency');
  v_rate numeric := coalesce((p_payload ->> 'exchange_rate')::numeric, 1);
  v_base_total bigint;
  v_split text := p_payload ->> 'split_method';
  v_sum bigint;
  v_count integer;
  v_bad uuid;
  v_items_sum bigint;
  v_extras bigint;
  v_tag_count integer;
begin
  select * into v_trip from public.trips where id = p_trip_id;
  if v_total is null or v_total = 0 then perform private.fail('invalid_amount', 'Enter an amount other than zero.'); end if;
  if abs(v_total) > 10000000000000 then perform private.fail('invalid_amount', 'That amount is too large.'); end if;
  if char_length(btrim(coalesce(p_payload ->> 'description', ''))) = 0 then
    perform private.fail('description_required', 'Add a short description.');
  end if;
  if not exists (select 1 from public.currencies where code = v_currency) then
    perform private.fail('unsupported_currency', 'That currency is not supported.');
  end if;
  if v_currency = v_trip.base_currency then
    v_rate := 1;
  elsif v_rate is null or v_rate <= 0 or (p_payload ->> 'exchange_rate') is null then
    perform private.fail('exchange_rate_required', 'An exchange rate is required for foreign-currency expenses.');
  end if;
  v_base_total := private.convert_minor(v_total, v_currency, v_trip.base_currency, v_rate);
  if v_base_total = 0 then perform private.fail('invalid_amount', 'The converted amount rounds to zero.'); end if;

  -- Payments and allocations: non-empty, unique participants in this trip, sign-consistent, exact sums.
  create temporary table if not exists pg_temp.expense_lines (kind text, participant_id uuid, amount bigint, input_value numeric) on commit drop;
  truncate pg_temp.expense_lines;
  insert into pg_temp.expense_lines
  select 'payment', (x ->> 'participant_id')::uuid, (x ->> 'amount_minor')::bigint, null
  from jsonb_array_elements(coalesce(p_payload -> 'payments', '[]'::jsonb)) as xi(x);
  insert into pg_temp.expense_lines
  select 'allocation', (x ->> 'participant_id')::uuid, (x ->> 'amount_minor')::bigint, (x ->> 'input_value')::numeric
  from jsonb_array_elements(coalesce(p_payload -> 'allocations', '[]'::jsonb)) as xi(x);

  if not exists (select 1 from pg_temp.expense_lines where kind = 'payment') then
    perform private.fail('payer_required', 'Choose who paid.');
  end if;
  if not exists (select 1 from pg_temp.expense_lines where kind = 'allocation') then
    perform private.fail('participants_required', 'Choose who shares this expense.');
  end if;
  if exists (select 1 from pg_temp.expense_lines group by kind, participant_id having count(*) > 1) then
    perform private.fail('duplicate_participant', 'Each person can appear only once.');
  end if;
  select l.participant_id into v_bad from pg_temp.expense_lines l
  where l.participant_id is null or l.amount is null or not exists (
    select 1 from public.trip_participants p where p.id = l.participant_id and p.trip_id = p_trip_id)
  limit 1;
  if found then perform private.fail('unknown_participant', 'Someone in this split is not part of the trip.'); end if;
  if exists (select 1 from pg_temp.expense_lines where amount <> 0 and sign(amount) <> sign(v_total)) then
    perform private.fail('mixed_signs', 'Shares must have the same sign as the total.');
  end if;
  select coalesce(sum(amount), 0) into v_sum from pg_temp.expense_lines where kind = 'payment';
  if v_sum <> v_total then perform private.fail('payments_mismatch', format('Payments total %s but the expense is %s.', v_sum, v_total)); end if;
  select coalesce(sum(amount), 0) into v_sum from pg_temp.expense_lines where kind = 'allocation';
  if v_sum <> v_total then perform private.fail('allocations_mismatch', format('Shares total %s but the expense is %s.', v_sum, v_total)); end if;

  -- Items (optional): must reconcile with extras to the total, every item assigned within the trip.
  v_extras := coalesce((p_payload ->> 'tax_minor')::bigint, 0) + coalesce((p_payload ->> 'service_fee_minor')::bigint, 0)
            + coalesce((p_payload ->> 'tip_minor')::bigint, 0) - coalesce((p_payload ->> 'discount_minor')::bigint, 0);
  select count(*), coalesce(sum((x ->> 'amount_minor')::bigint), 0) into v_count, v_items_sum
  from jsonb_array_elements(coalesce(p_payload -> 'items', '[]'::jsonb)) as xi(x);
  if v_split = 'itemized' and v_count = 0 then perform private.fail('items_required', 'Itemized expenses need at least one item.'); end if;
  if v_count > 300 then perform private.fail('too_many_items', 'An expense can have at most 300 items.'); end if;
  if v_count > 0 then
    if v_items_sum + v_extras <> v_total then
      perform private.fail('receipt_unreconciled', format('Items plus tax, fees and tip total %s but the expense is %s.', v_items_sum + v_extras, v_total));
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_payload -> 'items') as xi(x)
      where (x ->> 'amount_minor')::bigint <> 0 and jsonb_array_length(coalesce(x -> 'assignees', '[]'::jsonb)) = 0)
    then perform private.fail('unassigned_items', 'Assign every item to at least one person.'); end if;
    if exists (
      select 1 from jsonb_array_elements(p_payload -> 'items') as xi(x), jsonb_array_elements(coalesce(x -> 'assignees', '[]'::jsonb)) as ai(a)
      where not exists (select 1 from public.trip_participants p where p.id = (a ->> 'participant_id')::uuid and p.trip_id = p_trip_id))
    then perform private.fail('unknown_participant', 'Someone in this split is not part of the trip.'); end if;
  end if;

  select count(*) into v_tag_count from jsonb_array_elements_text(coalesce(p_payload -> 'tags', '[]'::jsonb)) as ti(t);
  if v_tag_count > 20 then perform private.fail('too_many_tags', 'Use at most 20 tags.'); end if;

  if p_is_update then
    delete from public.expense_payments where expense_id = p_expense_id;
    delete from public.expense_allocations where expense_id = p_expense_id;
    delete from public.expense_items where expense_id = p_expense_id;
    delete from public.expense_tags where expense_id = p_expense_id;
    update public.expenses set
      description = btrim(p_payload ->> 'description'),
      merchant = nullif(btrim(p_payload ->> 'merchant'), ''),
      notes = nullif(btrim(p_payload ->> 'notes'), ''),
      category = coalesce(p_payload ->> 'category', 'other'),
      payment_method = coalesce(p_payload ->> 'payment_method', 'card'),
      spent_at = coalesce((p_payload ->> 'spent_at')::timestamptz, spent_at),
      split_method = v_split,
      original_minor = v_total, original_currency = v_currency,
      base_minor = v_base_total, base_currency = v_trip.base_currency,
      exchange_rate = v_rate, rate_provider = p_payload ->> 'rate_provider', rate_date = (p_payload ->> 'rate_date')::timestamptz,
      tax_minor = (p_payload ->> 'tax_minor')::bigint, service_fee_minor = (p_payload ->> 'service_fee_minor')::bigint,
      tip_minor = (p_payload ->> 'tip_minor')::bigint, discount_minor = (p_payload ->> 'discount_minor')::bigint,
      revision = revision + 1, updated_by = auth.uid()
    where id = p_expense_id;
  else
    insert into public.expenses (
      id, trip_id, description, merchant, notes, category, payment_method, spent_at, split_method,
      original_minor, original_currency, base_minor, base_currency, exchange_rate, rate_provider, rate_date,
      tax_minor, service_fee_minor, tip_minor, discount_minor, idempotency_key, request_hash, created_by, updated_by)
    values (
      p_expense_id, p_trip_id, btrim(p_payload ->> 'description'), nullif(btrim(p_payload ->> 'merchant'), ''),
      nullif(btrim(p_payload ->> 'notes'), ''), coalesce(p_payload ->> 'category', 'other'),
      coalesce(p_payload ->> 'payment_method', 'card'), coalesce((p_payload ->> 'spent_at')::timestamptz, now()), v_split,
      v_total, v_currency, v_base_total, v_trip.base_currency, v_rate, p_payload ->> 'rate_provider',
      (p_payload ->> 'rate_date')::timestamptz,
      (p_payload ->> 'tax_minor')::bigint, (p_payload ->> 'service_fee_minor')::bigint,
      (p_payload ->> 'tip_minor')::bigint, (p_payload ->> 'discount_minor')::bigint,
      (p_payload ->> 'idempotency_key')::uuid, private.request_hash(p_payload), auth.uid(), auth.uid());
  end if;

  -- Base-currency shares are apportioned from the original shares so they sum exactly to base_minor.
  insert into public.expense_payments (expense_id, trip_id, participant_id, amount_minor, base_amount_minor)
  select p_expense_id, p_trip_id, l.participant_id, l.amount, a.amount
  from pg_temp.expense_lines l
  join private.apportion(v_base_total,
         array(select participant_id from pg_temp.expense_lines where kind = 'payment' order by participant_id),
         array(select abs(amount) from pg_temp.expense_lines where kind = 'payment' order by participant_id)) a
    on a.id = l.participant_id
  where l.kind = 'payment';

  insert into public.expense_allocations (expense_id, trip_id, participant_id, amount_minor, base_amount_minor, input_value)
  select p_expense_id, p_trip_id, l.participant_id, l.amount, a.amount, l.input_value
  from pg_temp.expense_lines l
  join private.apportion(v_base_total,
         array(select participant_id from pg_temp.expense_lines where kind = 'allocation' order by participant_id),
         array(select abs(amount) from pg_temp.expense_lines where kind = 'allocation' order by participant_id)) a
    on a.id = l.participant_id
  where l.kind = 'allocation';

  insert into public.expense_items (id, expense_id, trip_id, position, name, quantity, amount_minor)
  select coalesce((x ->> 'id')::uuid, gen_random_uuid()), p_expense_id, p_trip_id, ordinality::integer,
         left(btrim(coalesce(nullif(x ->> 'name', ''), 'Item')), 120), coalesce((x ->> 'quantity')::numeric, 1), (x ->> 'amount_minor')::bigint
  from jsonb_array_elements(coalesce(p_payload -> 'items', '[]'::jsonb)) with ordinality as xi(x, ordinality);

  insert into public.expense_item_assignees (item_id, trip_id, participant_id, weight)
  select (x ->> 'id')::uuid, p_trip_id, (a ->> 'participant_id')::uuid, coalesce((a ->> 'weight')::numeric, 1)
  from jsonb_array_elements(coalesce(p_payload -> 'items', '[]'::jsonb)) as xi(x),
       jsonb_array_elements(coalesce(x -> 'assignees', '[]'::jsonb)) as ai(a)
  where x ->> 'id' is not null;

  insert into public.expense_tags (expense_id, trip_id, tag)
  select distinct p_expense_id, p_trip_id, lower(btrim(t))
  from jsonb_array_elements_text(coalesce(p_payload -> 'tags', '[]'::jsonb)) as ti(t)
  where char_length(btrim(t)) > 0;

  -- Attach receipts uploaded for this trip.
  update public.receipts set expense_id = p_expense_id
  where trip_id = p_trip_id and deleted_at is null
    and id in (select (r)::uuid from jsonb_array_elements_text(coalesce(p_payload -> 'receipt_ids', '[]'::jsonb)) as ri(r));
end $$;

-- Canonical expense representation. security definer (request_hash is not client-readable), so it
-- re-checks membership itself.
create or replace function public.expense_json(p_expense_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select (to_jsonb(e) - 'request_hash') || jsonb_build_object(
    'payments', coalesce((select jsonb_agg(jsonb_build_object('participant_id', p.participant_id, 'amount_minor', p.amount_minor, 'base_amount_minor', p.base_amount_minor) order by p.participant_id)
                          from public.expense_payments p where p.expense_id = e.id), '[]'::jsonb),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('participant_id', a.participant_id, 'amount_minor', a.amount_minor, 'base_amount_minor', a.base_amount_minor, 'input_value', a.input_value) order by a.participant_id)
                          from public.expense_allocations a where a.expense_id = e.id), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'quantity', i.quantity, 'amount_minor', i.amount_minor,
                          'assignees', coalesce((select jsonb_agg(jsonb_build_object('participant_id', ia.participant_id, 'weight', ia.weight) order by ia.participant_id)
                                                 from public.expense_item_assignees ia where ia.item_id = i.id), '[]'::jsonb)) order by i.position)
                      from public.expense_items i where i.expense_id = e.id), '[]'::jsonb),
    'tags', coalesce((select jsonb_agg(t.tag order by t.tag) from public.expense_tags t where t.expense_id = e.id), '[]'::jsonb),
    'receipt_ids', coalesce((select jsonb_agg(r.id order by r.created_at) from public.receipts r where r.expense_id = e.id and r.deleted_at is null), '[]'::jsonb))
  from public.expenses e where e.id = p_expense_id and private.is_trip_member(e.trip_id)
$$;

-- Creates an expense in one transaction. Replays with the same idempotency key return the original
-- record; reusing a key with a different payload is a conflict.
create or replace function public.create_expense(p_trip_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_key uuid := (p_payload ->> 'idempotency_key')::uuid;
  v_id uuid := (p_payload ->> 'id')::uuid;
  v_existing public.expenses;
begin
  perform private.require_role(p_trip_id, 'member', false);
  if v_key is null or v_id is null then perform private.fail('idempotency_key_required', 'Missing request identifiers.'); end if;

  select * into v_existing from public.expenses where trip_id = p_trip_id and idempotency_key = v_key;
  if found then
    if v_existing.request_hash <> private.request_hash(p_payload) then
      perform private.fail('idempotency_key_reused', 'This request was already used for a different expense.', 'PT409');
    end if;
    return public.expense_json(v_existing.id);
  end if;
  if exists (select 1 from public.expenses where id = v_id) then
    perform private.fail('id_conflict', 'This expense ID is already in use.', 'PT409');
  end if;

  perform private.write_expense(p_trip_id, v_id, p_payload, false);
  perform private.log_activity(p_trip_id, 'expense_created', v_id, jsonb_build_object(
    'description', btrim(p_payload ->> 'description'), 'amount_minor', (p_payload ->> 'amount_minor')::bigint,
    'currency', upper(p_payload ->> 'currency')));
  return public.expense_json(v_id);
end $$;

-- Replaces an expense's financial facts if p_expected_revision still matches (optimistic concurrency).
create or replace function public.update_expense(p_expense_id uuid, p_expected_revision integer, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_expense public.expenses;
begin
  select * into v_expense from public.expenses where id = p_expense_id for update;
  if not found then perform private.fail('not_found', 'This expense no longer exists.', 'PT404'); end if;
  perform private.require_role(v_expense.trip_id, 'member', false);
  if v_expense.deleted_at is not null then perform private.fail('expense_deleted', 'This expense was deleted.', 'PT409'); end if;
  if v_expense.revision <> p_expected_revision then
    raise exception using errcode = 'PT409', message = 'revision_conflict',
      hint = 'Someone else edited this expense. Review their changes before saving yours.',
      detail = jsonb_build_object('current_revision', v_expense.revision)::text;
  end if;
  perform private.write_expense(v_expense.trip_id, p_expense_id, p_payload, true);
  perform private.log_activity(v_expense.trip_id, 'expense_updated', p_expense_id, jsonb_build_object(
    'description', btrim(p_payload ->> 'description'),
    'amount_minor', (p_payload ->> 'amount_minor')::bigint, 'currency', upper(p_payload ->> 'currency'),
    'previous_amount_minor', v_expense.original_minor, 'previous_description', v_expense.description));
  return public.expense_json(p_expense_id);
end $$;

-- Soft-deletes so history stays explainable; balances ignore deleted expenses.
create or replace function public.delete_expense(p_expense_id uuid, p_expected_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_expense public.expenses;
begin
  select * into v_expense from public.expenses where id = p_expense_id for update;
  if not found then perform private.fail('not_found', 'This expense no longer exists.', 'PT404'); end if;
  perform private.require_role(v_expense.trip_id, 'member', false);
  if v_expense.deleted_at is not null then return public.expense_json(p_expense_id); end if;
  if v_expense.revision <> p_expected_revision then
    raise exception using errcode = 'PT409', message = 'revision_conflict',
      hint = 'Someone else edited this expense. Review it before deleting.',
      detail = jsonb_build_object('current_revision', v_expense.revision)::text;
  end if;
  update public.expenses set deleted_at = now(), deleted_by = auth.uid(), revision = revision + 1, updated_by = auth.uid()
  where id = p_expense_id;
  perform private.log_activity(v_expense.trip_id, 'expense_deleted', p_expense_id, jsonb_build_object(
    'description', v_expense.description, 'amount_minor', v_expense.original_minor, 'currency', v_expense.original_currency));
  return public.expense_json(p_expense_id);
end $$;

create or replace function public.restore_expense(p_expense_id uuid, p_expected_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_expense public.expenses;
begin
  select * into v_expense from public.expenses where id = p_expense_id for update;
  if not found then perform private.fail('not_found', 'This expense no longer exists.', 'PT404'); end if;
  perform private.require_role(v_expense.trip_id, 'member', false);
  if v_expense.deleted_at is null then return public.expense_json(p_expense_id); end if;
  if v_expense.revision <> p_expected_revision then
    perform private.fail('revision_conflict', 'This expense changed. Refresh and try again.', 'PT409');
  end if;
  update public.expenses set deleted_at = null, deleted_by = null, revision = revision + 1, updated_by = auth.uid()
  where id = p_expense_id;
  perform private.log_activity(v_expense.trip_id, 'expense_restored', p_expense_id, jsonb_build_object(
    'description', v_expense.description, 'amount_minor', v_expense.original_minor, 'currency', v_expense.original_currency));
  return public.expense_json(p_expense_id);
end $$;

-- ---------------------------------------------------------------------------
-- Settlements
-- ---------------------------------------------------------------------------
create or replace function public.record_settlement(p_trip_id uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_trip public.trips;
  v_key uuid := (p_payload ->> 'idempotency_key')::uuid;
  v_id uuid := (p_payload ->> 'id')::uuid;
  v_amount bigint := (p_payload ->> 'amount_minor')::bigint;
  v_currency char(3) := upper(coalesce(p_payload ->> 'currency', ''));
  v_rate numeric := coalesce((p_payload ->> 'exchange_rate')::numeric, 1);
  v_from uuid := (p_payload ->> 'from_participant_id')::uuid;
  v_to uuid := (p_payload ->> 'to_participant_id')::uuid;
  v_existing public.settlements;
  v_base bigint;
begin
  perform private.require_role(p_trip_id, 'member', false);
  select * into v_trip from public.trips where id = p_trip_id;
  if v_key is null or v_id is null then perform private.fail('idempotency_key_required', 'Missing request identifiers.'); end if;
  select * into v_existing from public.settlements where trip_id = p_trip_id and idempotency_key = v_key;
  if found then
    if v_existing.request_hash <> private.request_hash(p_payload) then
      perform private.fail('idempotency_key_reused', 'This request was already used for a different payment.', 'PT409');
    end if;
    return to_jsonb(v_existing) - 'request_hash';
  end if;
  if exists (select 1 from public.settlements where id = v_id) then perform private.fail('id_conflict', 'This payment ID is already in use.', 'PT409'); end if;
  if v_amount is null or v_amount <= 0 then perform private.fail('invalid_amount', 'Enter an amount greater than zero.'); end if;
  if v_from is null or v_to is null or v_from = v_to then perform private.fail('invalid_parties', 'Choose two different people.'); end if;
  if (select count(*) from public.trip_participants where trip_id = p_trip_id and id in (v_from, v_to)) <> 2 then
    perform private.fail('unknown_participant', 'Both people must be part of the trip.');
  end if;
  if not exists (select 1 from public.currencies where code = v_currency) then perform private.fail('unsupported_currency', 'That currency is not supported.'); end if;
  if v_currency = v_trip.base_currency then v_rate := 1;
  elsif (p_payload ->> 'exchange_rate') is null or v_rate <= 0 then
    perform private.fail('exchange_rate_required', 'An exchange rate is required for foreign-currency payments.');
  end if;
  v_base := private.convert_minor(v_amount, v_currency, v_trip.base_currency, v_rate);
  if v_base <= 0 then perform private.fail('invalid_amount', 'The converted amount rounds to zero.'); end if;

  insert into public.settlements (id, trip_id, from_participant_id, to_participant_id, amount_minor, currency, base_amount_minor,
    exchange_rate, rate_provider, rate_date, method, reference, note, settled_at, idempotency_key, request_hash, created_by)
  values (v_id, p_trip_id, v_from, v_to, v_amount, v_currency, v_base, v_rate, p_payload ->> 'rate_provider',
    (p_payload ->> 'rate_date')::timestamptz, coalesce(p_payload ->> 'method', 'cash'), nullif(btrim(p_payload ->> 'reference'), ''),
    nullif(btrim(p_payload ->> 'note'), ''), coalesce((p_payload ->> 'settled_at')::timestamptz, now()), v_key,
    private.request_hash(p_payload), auth.uid())
  returning * into v_existing;

  update public.receipts set settlement_id = v_id
  where trip_id = p_trip_id and deleted_at is null
    and id in (select (r)::uuid from jsonb_array_elements_text(coalesce(p_payload -> 'receipt_ids', '[]'::jsonb)) as ri(r));

  perform private.log_activity(p_trip_id, 'settlement_recorded', v_id, jsonb_build_object(
    'from_participant_id', v_from, 'to_participant_id', v_to, 'amount_minor', v_amount, 'currency', v_currency));
  return to_jsonb(v_existing) - 'request_hash';
end $$;

create or replace function public.delete_settlement(p_settlement_id uuid, p_expected_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row public.settlements;
begin
  select * into v_row from public.settlements where id = p_settlement_id for update;
  if not found then perform private.fail('not_found', 'This payment no longer exists.', 'PT404'); end if;
  perform private.require_role(v_row.trip_id, 'member', false);
  if v_row.deleted_at is null then
    if v_row.revision <> p_expected_revision then
      perform private.fail('revision_conflict', 'This payment changed. Refresh and try again.', 'PT409');
    end if;
    update public.settlements set deleted_at = now(), deleted_by = auth.uid(), revision = revision + 1
    where id = p_settlement_id returning * into v_row;
    perform private.log_activity(v_row.trip_id, 'settlement_deleted', p_settlement_id, jsonb_build_object(
      'from_participant_id', v_row.from_participant_id, 'to_participant_id', v_row.to_participant_id,
      'amount_minor', v_row.amount_minor, 'currency', v_row.currency));
  end if;
  return to_jsonb(v_row) - 'request_hash';
end $$;

-- ---------------------------------------------------------------------------
-- Derived balances (security invoker: RLS limits results to the caller's trips)
-- ---------------------------------------------------------------------------
create or replace function public.trip_balances(p_trip_id uuid)
returns table (participant_id uuid, paid_minor bigint, owed_minor bigint, sent_minor bigint, received_minor bigint, net_minor bigint)
language sql stable security invoker set search_path = '' as $$
  with facts as (
    select p.participant_id, p.base_amount_minor as paid, 0::bigint as owed, 0::bigint as sent, 0::bigint as received
      from public.expense_payments p join public.expenses e on e.id = p.expense_id
      where e.trip_id = p_trip_id and e.deleted_at is null
    union all
    select a.participant_id, 0, a.base_amount_minor, 0, 0
      from public.expense_allocations a join public.expenses e on e.id = a.expense_id
      where e.trip_id = p_trip_id and e.deleted_at is null
    union all
    select s.from_participant_id, 0, 0, s.base_amount_minor, 0 from public.settlements s
      where s.trip_id = p_trip_id and s.deleted_at is null
    union all
    select s.to_participant_id, 0, 0, 0, s.base_amount_minor from public.settlements s
      where s.trip_id = p_trip_id and s.deleted_at is null
  )
  select tp.id,
         coalesce(sum(f.paid), 0)::bigint, coalesce(sum(f.owed), 0)::bigint,
         coalesce(sum(f.sent), 0)::bigint, coalesce(sum(f.received), 0)::bigint,
         (coalesce(sum(f.paid), 0) - coalesce(sum(f.owed), 0) + coalesce(sum(f.sent), 0) - coalesce(sum(f.received), 0))::bigint
  from public.trip_participants tp
  left join facts f on f.participant_id = tp.id
  where tp.trip_id = p_trip_id
  group by tp.id
  order by tp.id
$$;

-- Greedy simplification identical to Ledger.simplify in Swift: largest debtor pays largest creditor,
-- ties by ascending participant id.
create or replace function public.suggested_settlements(p_trip_id uuid)
returns table (from_participant_id uuid, to_participant_id uuid, amount_minor bigint)
language plpgsql stable security invoker set search_path = '' as $$
declare
  v_ids uuid[];
  v_nets bigint[];
  v_creditor integer;
  v_debtor integer;
  v_amount bigint;
  i integer;
begin
  select array_agg(b.participant_id order by b.participant_id), array_agg(b.net_minor order by b.participant_id)
    into v_ids, v_nets
  from public.trip_balances(p_trip_id) b where b.net_minor <> 0;
  if v_ids is null then return; end if;
  loop
    v_creditor := null; v_debtor := null;
    for i in 1..array_length(v_ids, 1) loop
      if v_nets[i] > 0 and (v_creditor is null or v_nets[i] > v_nets[v_creditor]) then v_creditor := i; end if;
      if v_nets[i] < 0 and (v_debtor is null or v_nets[i] < v_nets[v_debtor]) then v_debtor := i; end if;
    end loop;
    exit when v_creditor is null or v_debtor is null;
    v_amount := least(v_nets[v_creditor], -v_nets[v_debtor]);
    from_participant_id := v_ids[v_debtor]; to_participant_id := v_ids[v_creditor]; amount_minor := v_amount;
    return next;
    v_nets[v_creditor] := v_nets[v_creditor] - v_amount;
    v_nets[v_debtor] := v_nets[v_debtor] + v_amount;
  end loop;
end $$;

-- Aggregates for the trip overview, insights and exports. All values in base-currency minor units.
create or replace function public.trip_summary(p_trip_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with live as (
    select e.id, e.category, e.spent_at, e.base_minor from public.expenses e where e.trip_id = p_trip_id and e.deleted_at is null
  ), trip as (
    select t.* from public.trips t where t.id = p_trip_id
  )
  select jsonb_build_object(
    'trip_id', p_trip_id,
    'base_currency', (select base_currency from trip),
    'budget_minor', (select budget_minor from trip),
    'total_spent_minor', coalesce((select sum(base_minor) from live), 0),
    'expense_count', (select count(*) from live),
    'by_category', coalesce((select jsonb_agg(jsonb_build_object('category', category, 'total_minor', total, 'count', n) order by total desc, category)
                             from (select category, sum(base_minor) total, count(*) n from live group by category) c), '[]'::jsonb),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'total_minor', total) order by day)
                        from (select (spent_at at time zone (select timezone from trip))::date as day, sum(base_minor) total from live group by 1) d), '[]'::jsonb),
    'by_participant', coalesce((select jsonb_agg(jsonb_build_object('participant_id', participant_id, 'consumed_minor', consumed, 'paid_minor', paid) order by participant_id)
                        from (select b.participant_id, b.owed_minor consumed, b.paid_minor paid from public.trip_balances(p_trip_id) b) x), '[]'::jsonb),
    'generated_at', now())
  where exists (select 1 from trip)
$$;

-- Leaving requires a transferred ownership and either a zero balance or explicit acknowledgement.
create or replace function public.leave_trip(p_trip_id uuid, p_acknowledge_unsettled boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_participant uuid;
  v_net bigint;
begin
  v_role := private.require_role(p_trip_id, 'member');
  if v_role = 'owner' then
    perform private.fail('owner_must_transfer', 'Transfer ownership or delete the trip before leaving.', 'PT409');
  end if;
  select participant_id into v_participant from public.trip_members where trip_id = p_trip_id and user_id = auth.uid();
  select b.net_minor into v_net from public.trip_balances(p_trip_id) b where b.participant_id = v_participant;
  if coalesce(v_net, 0) <> 0 and not p_acknowledge_unsettled then
    raise exception using errcode = 'PT409', message = 'unsettled_balance',
      hint = 'You still have an unsettled balance in this trip.', detail = jsonb_build_object('net_minor', v_net)::text;
  end if;
  update public.trip_members set status = 'left', status_changed_at = now() where trip_id = p_trip_id and user_id = auth.uid();
  perform private.log_activity(p_trip_id, 'member_left', v_participant, jsonb_build_object('participant_id', v_participant));
end $$;

revoke all on function public.create_expense(uuid, jsonb), public.update_expense(uuid, integer, jsonb),
  public.delete_expense(uuid, integer), public.restore_expense(uuid, integer),
  public.record_settlement(uuid, jsonb), public.delete_settlement(uuid, integer),
  public.trip_balances(uuid), public.suggested_settlements(uuid), public.trip_summary(uuid),
  public.expense_json(uuid), public.leave_trip(uuid, boolean)
  from public, anon;
grant execute on function public.create_expense(uuid, jsonb), public.update_expense(uuid, integer, jsonb),
  public.delete_expense(uuid, integer), public.restore_expense(uuid, integer),
  public.record_settlement(uuid, jsonb), public.delete_settlement(uuid, integer),
  public.trip_balances(uuid), public.suggested_settlements(uuid), public.trip_summary(uuid),
  public.expense_json(uuid), public.leave_trip(uuid, boolean)
  to authenticated;
