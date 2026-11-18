-- RLS and privileged RPCs must enforce the same assurance level as the API.
create or replace function private.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
    and coalesce((select auth.jwt()->>'aal') = 'aal2', false)
    and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.role in ('admin','superUser'));
$$;

-- This superuser-only path previously checked the role directly.
create or replace function private.manage_learning_clearance(_student uuid, _action text, _reference text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); c private.learning_clearances%rowtype; recipient record;
begin
  if not private.is_platform_admin() or not exists(select 1 from public.profiles where id=actor and role='superUser') then
    raise exception 'Verified superuser access required.' using errcode='42501';
  end if;
  if not exists(select 1 from public.profiles where id=_student and role='student') then
    raise exception 'Learner unavailable.' using errcode='PT404';
  end if;
  if _action='approve' then
    if char_length(coalesce(btrim(_reference),'')) not between 4 and 120 then
      raise exception 'Enter the reference for the documented authorisation.' using errcode='22023';
    end if;
    insert into private.learning_clearances(student_id,basis,recorded_by,reference) values(_student,'documented_authorisation',actor,btrim(_reference))
      on conflict(student_id) do update set basis=excluded.basis,recorded_by=actor,reference=excluded.reference,recorded_at=now(),revoked_at=null;
  elsif _action='revoke' then
    update private.learning_clearances set revoked_at=now() where student_id=_student and revoked_at is null;
    if not found then raise exception 'There is no active authorisation.' using errcode='PT409'; end if;
    for recipient in update private.learning_access a set status='revoked',updated_at=now() from private.learning_plans p
      where p.id=a.plan_id and p.student_id=_student and a.status in ('pending','active') returning a.tutor_id
    loop perform private.bump_workspace(recipient.tutor_id); end loop;
  elsif _action is distinct from 'view' then
    raise exception 'Choose a valid authorisation action.' using errcode='22023';
  end if;
  if _action<>'view' then perform private.bump_workspace(_student); end if;
  select * into c from private.learning_clearances where student_id=_student;
  return jsonb_build_object('enabled',c.student_id is not null and c.revoked_at is null,'basis',c.basis,'reference',c.reference);
end;
$$;

create or replace function private.tutor_library_account() returns uuid
language plpgsql stable set search_path='' as $$
declare actor uuid := (select auth.uid());
begin
  if actor is null or not exists(select 1 from public.profiles p where p.id=actor and
    ((p.role in ('admin','superUser') and private.is_platform_admin()) or
     (p.role='tutor' and exists(select 1 from public.tutor_profiles t where t.user_id=actor and t.is_approved)))) then
    raise exception 'Approved tutor or verified administrator access required.' using errcode='42501';
  end if;
  perform private.assert_platform_available();
  return actor;
end;
$$;

-- Replacements retain existing ACLs. Explicitly deny default PUBLIC grants.
revoke all on function private.is_platform_admin() from public, anon;
grant execute on function private.is_platform_admin() to authenticated;
notify pgrst, 'reload schema';
