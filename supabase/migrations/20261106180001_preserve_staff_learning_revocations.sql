-- An explicit staff decision takes precedence over a legacy profile recheck.
alter function public.manage_learning_clearance(uuid,text,text) set schema private;
revoke all on function private.manage_learning_clearance(uuid,text,text) from public,anon,authenticated;
create function public.manage_learning_clearance(_student uuid,_action text,_reference text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  result := private.manage_learning_clearance(_student,_action,_reference);
  if _action in ('approve','revoke') then
    update private.learning_clearances set needs_profile_age=false where student_id=_student and needs_profile_age;
  end if;
  return result;
end;
$$;
revoke all on function public.manage_learning_clearance(uuid,text,text) from public,anon,authenticated;
grant execute on function public.manage_learning_clearance(uuid,text,text) to authenticated;

create or replace function public.apply_learning_action(_action text,_plan uuid,_version integer,_request uuid,_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); lesson public.bookings%rowtype;
begin
  if _action='enable' then
    perform private.assert_platform_available();
    if not exists(select 1 from public.profiles where id=actor and role='student') then
      raise exception 'A learner account is required.' using errcode='42501';
    end if;
    perform private.activate_learning_from_profile(actor);
    perform private.bump_workspace(actor);
    return jsonb_build_object('enabled',true);
  elsif _action='startPlan' then
    perform private.assert_platform_available();
    lesson := private.learning_eligible_booking(actor,(_data->>'bookingId')::uuid);
    if private.learning_age_state(lesson.student_id)<>'enabled' then
      raise exception 'The learner must complete their profile and learning authorisation before sharing a new plan.' using errcode='42501';
    end if;
  elsif _action='approveAccess' and exists (
    select 1 from private.learning_plans where id=_plan and student_id=actor
  ) and private.learning_age_state(actor)<>'enabled' then
    raise exception 'Complete your learning profile before granting new tutor access.' using errcode='42501';
  end if;
  return private.apply_learning_action(_action,_plan,_version,_request,_data);
exception when invalid_text_representation then
  raise exception 'Choose a valid lesson.' using errcode='22023';
end;
$$;
notify pgrst,'reload schema';
