create table public.platform_settings (
  id boolean primary key default true check(id),
  applications boolean not null default true,
  student_registration boolean not null default true,
  maintenance boolean not null default false,
  admin_email_notifications boolean not null default true,
  version integer not null default 1,
  updated_at timestamptz not null default now()
);
insert into public.platform_settings(id) values(true);
create table public.platform_settings_audit (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  previous_settings jsonb not null,
  new_settings jsonb not null,
  created_at timestamptz not null default now()
);
create index platform_settings_audit_actor on public.platform_settings_audit(actor_id,created_at desc);
alter table public.platform_settings enable row level security;
alter table public.platform_settings_audit enable row level security;
revoke all on public.platform_settings,public.platform_settings_audit from public,anon,authenticated;
revoke all on sequence public.platform_settings_audit_id_seq from public,anon,authenticated;
grant select on public.platform_settings to anon,authenticated;
grant select on public.platform_settings_audit to authenticated;
create policy "Platform status is public" on public.platform_settings for select to anon,authenticated using(true);
create policy "Admins read platform audit" on public.platform_settings_audit for select to authenticated using((select private.is_platform_admin()));

create function private.update_platform_settings(_patch jsonb,_expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare old_row public.platform_settings; new_row public.platform_settings;
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if jsonb_typeof(_patch) is distinct from 'object' or (select count(*) from jsonb_object_keys(_patch))<>4
    or exists(select 1 from jsonb_each(_patch) as f where f.key not in ('applications','student_registration','maintenance','admin_email_notifications') or jsonb_typeof(f.value)<>'boolean')
    then raise exception 'Choose all four boolean platform settings' using errcode='22023'; end if;
  select * into old_row from public.platform_settings where id for update;
  if not found or old_row.version is distinct from _expected_version then raise exception 'Platform settings changed. Reload before saving.' using errcode='PT409'; end if;
  update public.platform_settings set applications=(_patch->>'applications')::boolean,student_registration=(_patch->>'student_registration')::boolean,
    maintenance=(_patch->>'maintenance')::boolean,admin_email_notifications=(_patch->>'admin_email_notifications')::boolean,
    version=version+1,updated_at=clock_timestamp() where id returning * into new_row;
  insert into public.platform_settings_audit(actor_id,previous_settings,new_settings) values((select auth.uid()),to_jsonb(old_row)-'id',to_jsonb(new_row)-'id');
  return to_jsonb(new_row);
end; $$;
revoke all on function private.update_platform_settings(jsonb,integer) from public,anon;
grant execute on function private.update_platform_settings(jsonb,integer) to authenticated;
create function public.update_platform_settings(_patch jsonb,_expected_version integer) returns jsonb
language sql security invoker set search_path='' as $$ select private.update_platform_settings(_patch,_expected_version); $$;
revoke all on function public.update_platform_settings(jsonb,integer) from public,anon;
grant execute on function public.update_platform_settings(jsonb,integer) to authenticated;

create function private.platform_runtime_allowed() returns boolean
language sql stable security definer set search_path='' as $$
  select coalesce((select not maintenance from public.platform_settings where id),false) or private.is_platform_admin();
$$;
revoke all on function private.platform_runtime_allowed() from public;
grant execute on function private.platform_runtime_allowed() to anon,authenticated;
create function private.assert_platform_available() returns void
language plpgsql security definer set search_path='' as $$ begin
  if not private.platform_runtime_allowed() then raise exception 'AeroGen Tutoring is temporarily undergoing maintenance' using errcode='PT503'; end if;
end; $$;
revoke all on function private.assert_platform_available() from public,anon,authenticated;

-- Restrictive policies add a condition to existing access rules; they grant no new access.
do $$ declare t record; begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relrowsecurity and c.relname not in ('platform_settings','site_contact_settings','profiles') loop
    execute format('create policy platform_maintenance on public.%I as restrictive for all to anon,authenticated using((select private.platform_runtime_allowed())) with check((select private.platform_runtime_allowed()))',t.relname);
  end loop;
end; $$;
create policy platform_maintenance_read on public.profiles as restrictive for select to anon,authenticated
  using((select private.platform_runtime_allowed()) or id=(select auth.uid()));
create policy platform_maintenance_insert on public.profiles as restrictive for insert to anon,authenticated with check((select private.platform_runtime_allowed()));
create policy platform_maintenance_update on public.profiles as restrictive for update to anon,authenticated using((select private.platform_runtime_allowed())) with check((select private.platform_runtime_allowed()));
create policy platform_maintenance_delete on public.profiles as restrictive for delete to anon,authenticated using((select private.platform_runtime_allowed()));
create policy platform_maintenance on storage.objects as restrictive for all to anon,authenticated
  using((select private.platform_runtime_allowed())) with check((select private.platform_runtime_allowed()));

-- These application entry points intentionally use definer security and need explicit gates.
do $$ declare f record; definition text; changed integer:=0; begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='private' and p.proname in ('submit_tutor_application','submit_tutor_application_draft','save_tutor_application_draft','submit_contact_enquiry'))
       or (n.nspname='public' and p.proname in ('my_tutoring_workspace','send_tutoring_message')) loop
    definition=pg_get_functiondef(f.oid);
    if definition !~* '\mbegin\M' then raise exception 'Unexpected platform entry point body'; end if;
    execute regexp_replace(definition,'\mbegin\M',E'begin\n  perform private.assert_platform_available();','i');
    changed=changed+1;
  end loop;
  if changed<>6 then raise exception 'Expected six guarded user entry points, found %',changed; end if;
end; $$;

create function private.guard_tutor_applications_open() returns trigger
language plpgsql security definer set search_path='' as $$ begin
  if new.status='submitted' and not coalesce((select applications from public.platform_settings where id),false)
    then raise exception 'New tutor applications are temporarily paused' using errcode='PT403'; end if;
  return new;
end; $$;
revoke all on function private.guard_tutor_applications_open() from public,anon,authenticated;
create trigger platform_application_acceptance before insert on public.tutor_applications
  for each row execute function private.guard_tutor_applications_open();

-- Auth inserts cover email signup and first-time OAuth signup, independent of Express.
create function private.guard_platform_registration() returns trigger
language plpgsql security definer set search_path='' as $$
declare settings public.platform_settings;
begin
  select * into settings from public.platform_settings where id;
  if not found or settings.maintenance or not settings.student_registration then
    raise exception 'New account registration is temporarily paused. Existing users can still sign in.' using errcode='P0001';
  end if;
  return new;
end; $$;
revoke all on function private.guard_platform_registration() from public,anon,authenticated;
create trigger platform_registration_open before insert on auth.users for each row execute function private.guard_platform_registration();
notify pgrst,'reload schema';
