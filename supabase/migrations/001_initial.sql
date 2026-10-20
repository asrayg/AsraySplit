create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'New friend',
  avatar_url text,
  created_at timestamptz not null default now()
);
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  emoji text not null default '✨',
  color_hex text not null default '23C58A',
  created_at timestamptz not null default now()
);
create table public.group_members (
  group_id uuid references public.groups(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null default 'member' check (role in ('owner','member')),
  primary key(group_id, user_id)
);
create table public.expenses (
  id uuid primary key,
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  group_id uuid not null,
  description text not null,
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null default 'USD',
  category text not null default 'other',
  paid_by uuid not null,
  receipt_path text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table public.expense_splits (
  expense_id uuid references public.expenses(id) on delete cascade,
  user_id uuid not null,
  amount numeric(12,2) not null check (amount >= 0),
  primary key(expense_id, user_id)
);

create index groups_owner_idx on public.groups(owner_id);
create index group_members_user_idx on public.group_members(user_id);
create index expenses_owner_idx on public.expenses(owner_id);
create index expenses_group_idx on public.expenses(group_id);

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.expenses enable row level security;
alter table public.expense_splits enable row level security;

create policy "profile self read" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "profile self insert" on public.profiles for insert to authenticated with check ((select auth.uid()) = id);
create policy "profile self update" on public.profiles for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create policy "owner manages groups" on public.groups for all to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "members read groups" on public.groups for select to authenticated using (exists (select 1 from public.group_members gm where gm.group_id = id and gm.user_id = (select auth.uid())));
create policy "owner manages memberships" on public.group_members for all to authenticated using (exists (select 1 from public.groups g where g.id = group_id and g.owner_id = (select auth.uid()))) with check (exists (select 1 from public.groups g where g.id = group_id and g.owner_id = (select auth.uid())));
create policy "members read memberships" on public.group_members for select to authenticated using (user_id = (select auth.uid()) or exists (select 1 from public.groups g where g.id = group_id and g.owner_id = (select auth.uid())));
create policy "owner manages expenses" on public.expenses for all to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create policy "owner manages splits" on public.expense_splits for all to authenticated using (exists (select 1 from public.expenses e where e.id = expense_id and e.owner_id = (select auth.uid()))) with check (exists (select 1 from public.expenses e where e.id = expense_id and e.owner_id = (select auth.uid())));

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760, array['image/jpeg','image/png','image/heic'])
on conflict (id) do nothing;
create policy "users upload own receipts" on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and owner_id = (select auth.uid()));
create policy "users read own receipts" on storage.objects for select to authenticated using (bucket_id = 'receipts' and owner_id = (select auth.uid()));

create or replace function public.create_profile_for_new_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin insert into public.profiles(id, display_name) values (new.id, coalesce(new.raw_user_meta_data->>'display_name', 'New friend')); return new; end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_new_user();

