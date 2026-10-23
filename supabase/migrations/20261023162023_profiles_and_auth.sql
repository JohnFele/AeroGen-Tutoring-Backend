create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  first_name text,
  last_name text,
  email text not null,
  phone text,
  location text,
  role text not null default 'student'
    check (role in ('student', 'tutor', 'admin', 'superUser')),
  auth_provider text not null default 'email',
  bio text not null default '',
  is_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_role_idx on public.profiles (role);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_role text;
begin
  requested_role := coalesce(new.raw_user_meta_data ->> 'role', 'student');
  if requested_role not in ('student', 'tutor') then
    requested_role := 'student';
  end if;

  insert into public.profiles (
    id,
    email,
    first_name,
    last_name,
    phone,
    location,
    role,
    auth_provider,
    is_verified
  ) values (
    new.id,
    coalesce(new.email, ''),
    nullif(new.raw_user_meta_data ->> 'firstName', ''),
    nullif(new.raw_user_meta_data ->> 'lastName', ''),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    nullif(new.raw_user_meta_data ->> 'location', ''),
    requested_role,
    coalesce(new.raw_app_meta_data ->> 'provider', 'email'),
    new.email_confirmed_at is not null
  )
  on conflict (id) do update set
    email = excluded.email,
    updated_at = now();

  return new;
end;
$$;

create or replace function public.handle_auth_user_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
  set email = coalesce(new.email, ''),
      is_verified = new.email_confirmed_at is not null,
      auth_provider = coalesce(new.raw_app_meta_data ->> 'provider', auth_provider),
      updated_at = now()
  where id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

create trigger on_auth_user_updated
after update of email, email_confirmed_at, raw_app_meta_data on auth.users
for each row execute function public.handle_auth_user_update();

-- Backfill profiles for Supabase Auth users created before this migration.
insert into public.profiles (
  id,
  email,
  first_name,
  last_name,
  phone,
  location,
  role,
  auth_provider,
  is_verified
)
select
  u.id,
  coalesce(u.email, ''),
  nullif(u.raw_user_meta_data ->> 'firstName', ''),
  nullif(u.raw_user_meta_data ->> 'lastName', ''),
  nullif(u.raw_user_meta_data ->> 'phone', ''),
  nullif(u.raw_user_meta_data ->> 'location', ''),
  case when u.raw_user_meta_data ->> 'role' in ('student', 'tutor')
    then u.raw_user_meta_data ->> 'role' else 'student' end,
  coalesce(u.raw_app_meta_data ->> 'provider', 'email'),
  u.email_confirmed_at is not null
from auth.users u
on conflict (id) do nothing;

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;

create policy "Users can read their own profile"
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);
