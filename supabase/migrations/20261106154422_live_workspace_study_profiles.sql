-- Only the study information used for tutoring is shared with a tutor who
-- has a recent lesson or request with the student.
create function private.workspace_student_study_profiles(_tutor uuid) returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_object_agg(p.id,jsonb_build_object(
    'grade',p.study_grade,'phase',phase.name,'curriculum',route.details->>'name',
    'subjects',coalesce((select jsonb_agg(s.name order by s.name)
      from public.subjects s where s.id=any(p.study_subject_ids) and s.is_active),'[]'::jsonb)
  )),'{}'::jsonb)
  from (
    select distinct b.student_id from public.bookings b
    where b.tutor_id=_tutor and b.status in ('pending','confirmed','completed','no_show')
      and b.starts_at>=now()-interval '90 days'
      and (b.status<>'pending' or coalesce(b.proposed_by,b.student_id)=b.student_id)
      and exists(select 1 from public.profiles t where t.id=_tutor and t.role='tutor')
  ) related
  join public.profiles p on p.id=related.student_id and p.role='student'
  left join public.education_levels phase on phase.code=p.study_level_code
  left join public.education_pathways route on route.code=p.curriculum_codes[1];
$$;
revoke all on function private.workspace_student_study_profiles(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.my_tutoring_workspace()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare caller uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select jsonb_build_object(
    'bookings',coalesce((select jsonb_agg(row_data order by starts_at desc) from (
      select b.starts_at,jsonb_build_object('id',b.id,'student_id',b.student_id,'tutor_id',b.tutor_id,
        'student_name',concat_ws(' ',sp.first_name,sp.last_name),'tutor_name',coalesce(tp.public_name,'Tutor'),
        'subject',s.name,'starts_at',b.starts_at,'ends_at',b.ends_at,'duration_minutes',b.duration_minutes,
        'status',b.status,'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'proposed_by',coalesce(b.proposed_by,b.student_id),'confirmed_at',b.confirmed_at,
        'special_requests',b.special_requests,'demo',sp.demo_dataset is not null) || private.lesson_billing_summary(b.id,caller) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
    'student_study_profiles',private.workspace_student_study_profiles(caller),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.payments p where caller in (p.payer_id,p.payee_id)),'[]'::jsonb),
    'conversations',coalesce((select jsonb_agg(row_data order by updated_at desc) from (
      select c.updated_at,jsonb_build_object('id',c.id,'booking_id',c.booking_id,'last_read_at',own.last_read_at,
        'participants',(select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(tp.public_name,concat_ws(' ',p.first_name,p.last_name)),'role',p.role))
          from public.conversation_members cm join public.profiles p on p.id=cm.user_id left join public.tutor_profiles tp on tp.user_id=p.id
          where cm.conversation_id=c.id and cm.user_id<>caller),
        'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from (
          select id,sender_id,body,created_at from public.messages where conversation_id=c.id and deleted_at is null order by created_at desc limit 200
        ) m),'[]'::jsonb)) row_data
      from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=caller
      order by c.updated_at desc limit 200
    ) rows),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc,n.id desc) from (select * from public.notifications where user_id=caller order by created_at desc,id desc limit 50) n),'[]'::jsonb),
    'notification_unread_count',(select count(*) from public.notifications where user_id=caller and read_at is null),
    'notification_revision',coalesce((select version from public.workspace_signals where user_id=caller),0)
  ) into result;
  return result;
end;
$function$;

-- Only owner-scoped invalidation is sent to Realtime. Study details still go
-- through the authenticated workspace query.
create function private.signal_related_profile_change() returns trigger
language plpgsql security definer set search_path='' as $$
declare changed_id uuid; tutor_side boolean; recipient uuid;
begin
  if tg_table_name='tutor_profiles' then
    changed_id := new.user_id;
    tutor_side := true;
  else
    changed_id := new.id;
    tutor_side := new.role='tutor';
  end if;
  for recipient in
    select id from (
      select changed_id as id
      union
      select b.student_id from public.bookings b
      where tutor_side and b.tutor_id=changed_id and b.starts_at>=now()-interval '90 days'
        and b.status in ('pending','confirmed','completed','no_show')
      union
      select b.tutor_id from public.bookings b
      where not tutor_side and b.student_id=changed_id and b.starts_at>=now()-interval '90 days'
        and b.status in ('pending','confirmed','completed','no_show')
    ) recipients order by id
  loop
    perform private.bump_workspace(recipient);
  end loop;
  return null;
end;
$$;
revoke all on function private.signal_related_profile_change() from public,anon,authenticated;

create trigger profile_workspace_refresh
after update of first_name,last_name,curriculum_codes,study_grade,study_level_code,study_subject_ids on public.profiles
for each row when (
  (old.first_name,old.last_name,old.curriculum_codes,old.study_grade,old.study_level_code,old.study_subject_ids)
  is distinct from (new.first_name,new.last_name,new.curriculum_codes,new.study_grade,new.study_level_code,new.study_subject_ids)
) execute function private.signal_related_profile_change();

create trigger tutor_listing_workspace_refresh
after update of public_name,bio,city,province,qualification,institution,years_experience,teaching_style,
  teaching_modes,hourly_rate,students_per_session,is_approved,is_accepting_students,updated_at on public.tutor_profiles
for each row when (old is distinct from new) execute function private.signal_related_profile_change();
notify pgrst,'reload schema';
