-- Leave previously verified accounts as they are. New and unverified accounts need review.
alter table public.profiles add column profile_setup_pending boolean not null default false;
alter table public.profiles alter column profile_setup_pending set default true;

update public.profiles set profile_setup_pending = true
where role in ('student', 'tutor') and auth_provider = 'email' and not is_verified;

-- The existing owner-only profiles update policy also applies to this column.
grant update (profile_setup_pending) on public.profiles to authenticated;

create function private.validate_profile_setup_completion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not new.profile_setup_pending and (
    not new.is_verified
    or nullif(btrim(new.first_name), '') is null
    or nullif(btrim(new.last_name), '') is null
    or nullif(btrim(new.location), '') is null
    or coalesce(new.phone, '') !~ '^\+[1-9][0-9]{8,14}$'
  ) then
    raise exception 'Verify your email and provide your name, phone number and location before completing your profile.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger validate_profile_setup_completion
before update of profile_setup_pending on public.profiles
for each row execute function private.validate_profile_setup_completion();

revoke all on function private.validate_profile_setup_completion() from public, anon, authenticated;
notify pgrst, 'reload schema';
