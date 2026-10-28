-- Public tutor discovery and database-authorized administration.
alter table public.tutor_profiles add column is_featured boolean not null default false;
alter table public.tutor_profiles add column avatar_url text;
alter table public.tutor_profiles add constraint featured_tutors_are_published
  check (not is_featured or (is_approved and is_accepting_students));

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;
create or replace function private.is_platform_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.profiles p where p.id=(select auth.uid()) and p.role in ('admin','superUser')
  );
$$;
revoke all on function private.is_platform_admin() from public, anon;
grant execute on function private.is_platform_admin() to authenticated;

alter policy "Approved tutors are discoverable" on public.tutor_profiles
  using (is_approved and is_accepting_students);
create policy "Admins can read profiles" on public.profiles for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can read all tutor profiles" on public.tutor_profiles for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can edit tutor profiles" on public.tutor_profiles for update to authenticated
  using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
grant update(public_name,bio,city,province,qualification,institution,year_completed,certifications,years_experience,teaching_style,student_age_groups,availability_slots,teaching_modes,hourly_rate,students_per_session,is_approved,is_accepting_students,is_featured,avatar_url) on public.tutor_profiles to authenticated;
create policy "Admins can read tutor subjects" on public.tutor_subjects for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can attach tutor subjects" on public.tutor_subjects for insert to authenticated with check ((select private.is_platform_admin()));
create policy "Admins can remove tutor subjects" on public.tutor_subjects for delete to authenticated using ((select private.is_platform_admin()));
grant insert,delete on public.tutor_subjects to authenticated;
create policy "Admins can read applications" on public.tutor_applications for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can review applications" on public.tutor_applications for update to authenticated
  using ((select private.is_platform_admin())) with check ((select private.is_platform_admin()));
grant update(status,reviewer_id,reviewed_at,review_notes) on public.tutor_applications to authenticated;
create policy "Admins can read application subjects" on public.tutor_application_subjects for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can read bookings" on public.bookings for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can read payments" on public.payments for select to authenticated using ((select private.is_platform_admin()));

create table public.tutor_profile_audit (
  id bigint generated always as identity primary key,
  tutor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  before_data jsonb not null,
  after_data jsonb not null,
  created_at timestamptz not null default now()
);
create index tutor_profile_audit_tutor_idx on public.tutor_profile_audit(tutor_id,created_at desc);
create index tutor_profile_audit_actor_idx on public.tutor_profile_audit(actor_id);
alter table public.tutor_profile_audit enable row level security;
revoke all on public.tutor_profile_audit from public,anon,authenticated;
grant select,insert on public.tutor_profile_audit to authenticated;
grant usage on sequence public.tutor_profile_audit_id_seq to authenticated;
create policy "Admins can read tutor audit" on public.tutor_profile_audit for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can record their tutor edits" on public.tutor_profile_audit for insert to authenticated
  with check ((select private.is_platform_admin()) and actor_id=(select auth.uid()));

create view public.tutor_directory with (security_invoker=true) as
select tp.user_id as id,tp.public_name,tp.bio,tp.city,tp.province,tp.qualification,tp.institution,tp.year_completed,
  tp.certifications,tp.years_experience,tp.teaching_style,tp.student_age_groups,tp.availability_slots,tp.teaching_modes,
  tp.hourly_rate,tp.students_per_session,tp.is_featured,tp.avatar_url,tp.demo_dataset,tp.updated_at,
  coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'aliases',s.aliases) order by s.name)
    from public.tutor_subjects ts join public.subjects s on s.id=ts.subject_id and s.is_active where ts.tutor_id=tp.user_id),'[]'::jsonb) as subjects,
  (select count(*)::integer from public.reviews r where r.tutor_id=tp.user_id and r.is_published) as review_count,
  (select round(avg(r.rating),1) from public.reviews r where r.tutor_id=tp.user_id and r.is_published) as rating
from public.tutor_profiles tp where tp.is_approved and tp.is_accepting_students;
revoke all on public.tutor_directory from public,anon,authenticated;
grant select on public.tutor_directory to anon,authenticated;

create function public.admin_update_tutor(_tutor_id uuid,_patch jsonb,_subject_ids bigint[] default null,_expected_updated_at timestamptz default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare previous public.tutor_profiles; edited public.tutor_profiles; field text; before_subjects jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if jsonb_typeof(_patch) is distinct from 'object' then raise exception 'Profile changes must be an object' using errcode='22023'; end if;
  for field in select jsonb_object_keys(_patch) loop
    if field <> all(array['public_name','bio','city','province','qualification','institution','year_completed','certifications','years_experience','teaching_style','student_age_groups','availability_slots','teaching_modes','hourly_rate','students_per_session','is_approved','is_accepting_students','is_featured','avatar_url']) then raise exception 'Unsupported tutor field: %',field using errcode='22023'; end if;
  end loop;
  select * into previous from public.tutor_profiles where user_id=_tutor_id for update;
  if not found then raise exception 'Tutor not found' using errcode='P0002'; end if;
  if _expected_updated_at is not null and previous.updated_at is distinct from _expected_updated_at then raise exception 'This tutor was changed by another administrator. Reload before saving.' using errcode='40001'; end if;
  edited := jsonb_populate_record(previous,_patch);
  edited.is_featured := edited.is_featured and edited.is_approved and edited.is_accepting_students;
  if edited.is_approved and (length(btrim(coalesce(edited.public_name,'')))<2 or coalesce(edited.hourly_rate,0)<=0) then raise exception 'Approved tutors need a public name and positive hourly rate' using errcode='22023'; end if;
  if edited.avatar_url is not null and (length(edited.avatar_url)>2048 or edited.avatar_url !~ '^https://') then raise exception 'Use an HTTPS image URL or leave it empty' using errcode='22023'; end if;
  if _subject_ids is not null and (cardinality(_subject_ids)>100 or exists(select 1 from unnest(_subject_ids) as requested(subject_id) where not exists(select 1 from public.subjects s where s.id=requested.subject_id and s.is_active))) then raise exception 'Choose valid active subjects' using errcode='22023'; end if;
  if edited.is_approved and ((_subject_ids is not null and cardinality(_subject_ids)=0) or (_subject_ids is null and not exists(select 1 from public.tutor_subjects where tutor_id=_tutor_id))) then raise exception 'Approved tutors need at least one subject' using errcode='22023'; end if;
  select coalesce(jsonb_agg(subject_id order by subject_id),'[]'::jsonb) into before_subjects from public.tutor_subjects where tutor_id=_tutor_id;
  update public.tutor_profiles set public_name=edited.public_name,bio=edited.bio,city=edited.city,province=edited.province,
    qualification=edited.qualification,institution=edited.institution,year_completed=edited.year_completed,certifications=edited.certifications,
    years_experience=edited.years_experience,teaching_style=edited.teaching_style,student_age_groups=edited.student_age_groups,
    availability_slots=edited.availability_slots,teaching_modes=edited.teaching_modes,hourly_rate=edited.hourly_rate,
    students_per_session=edited.students_per_session,is_approved=edited.is_approved,is_accepting_students=edited.is_accepting_students,
    is_featured=edited.is_featured,avatar_url=edited.avatar_url where user_id=_tutor_id returning * into edited;
  if _subject_ids is not null then
    delete from public.tutor_subjects where tutor_id=_tutor_id;
    insert into public.tutor_subjects(tutor_id,subject_id) select _tutor_id,id from (select distinct unnest(_subject_ids) as id) s;
  end if;
  if previous.is_approved is distinct from edited.is_approved then
    update public.tutor_applications set status=case when edited.is_approved then 'approved' else 'under_review' end,reviewer_id=(select auth.uid()),reviewed_at=now()
      where id=(select id from public.tutor_applications where user_id=_tutor_id order by created_at desc,id desc limit 1);
  end if;
  insert into public.tutor_profile_audit(tutor_id,actor_id,before_data,after_data)
    values(_tutor_id,(select auth.uid()),to_jsonb(previous)||jsonb_build_object('subject_ids',before_subjects),
      to_jsonb(edited)||jsonb_build_object('subject_ids',(select coalesce(jsonb_agg(subject_id order by subject_id),'[]'::jsonb) from public.tutor_subjects where tutor_id=_tutor_id)));
  return jsonb_build_object('id',edited.user_id,'updated_at',edited.updated_at);
end;
$$;
revoke all on function public.admin_update_tutor(uuid,jsonb,bigint[],timestamptz) from public,anon;
grant execute on function public.admin_update_tutor(uuid,jsonb,bigint[],timestamptz) to authenticated;

-- Initial curated homepage picks from the existing database cohort.
update public.tutor_profiles set is_featured=true where demo_dataset='aerogen-live-demo-v1' and is_approved and is_accepting_students
  and user_id in ('de000000-0000-4000-8000-000000000201','de000000-0000-4000-8000-000000000202','de000000-0000-4000-8000-000000000204');
notify pgrst,'reload schema';

-- Participant-scoped identity projection: no private emails/phones are exposed.
-- Definer access is needed to read the other participant's display name despite
-- profiles RLS. Every returned row is explicitly bound to the signed-in caller.
create function public.my_tutoring_workspace() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare caller uuid := (select auth.uid()); result jsonb;
begin
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select jsonb_build_object(
    'bookings',coalesce((select jsonb_agg(row_data order by starts_at desc) from (
      select b.starts_at,jsonb_build_object('id',b.id,'student_id',b.student_id,'tutor_id',b.tutor_id,
        'student_name',concat_ws(' ',sp.first_name,sp.last_name),'tutor_name',coalesce(tp.public_name,'Tutor'),
        'subject',s.name,'starts_at',b.starts_at,'ends_at',b.ends_at,'duration_minutes',b.duration_minutes,
        'status',b.status,'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'demo',sp.demo_dataset is not null) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
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
    'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from public.notifications n where n.user_id=caller),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;
revoke all on function public.my_tutoring_workspace() from public,anon;
grant execute on function public.my_tutoring_workspace() to authenticated;

create function public.send_tutoring_message(_conversation_id uuid,_body text) returns uuid
language plpgsql security definer set search_path='' as $$
declare caller uuid := (select auth.uid()); message_id uuid;
begin
  if caller is null or not exists(select 1 from public.conversation_members where conversation_id=_conversation_id and user_id=caller) then raise exception 'Conversation access denied' using errcode='42501'; end if;
  if _body is null or length(btrim(_body)) not between 1 and 10000 then raise exception 'Enter a message of 1 to 10000 characters' using errcode='22023'; end if;
  insert into public.messages(conversation_id,sender_id,body) values(_conversation_id,caller,btrim(_body)) returning id into message_id;
  update public.conversations set updated_at=now() where id=_conversation_id;
  update public.conversation_members set last_read_at=now() where conversation_id=_conversation_id and user_id=caller;
  insert into public.notifications(user_id,kind,title,body,data)
    select user_id,'message','New message',left(btrim(_body),160),jsonb_build_object('conversationId',_conversation_id,'messageId',message_id)
    from public.conversation_members where conversation_id=_conversation_id and user_id<>caller;
  return message_id;
end;
$$;
revoke all on function public.send_tutoring_message(uuid,text) from public,anon;
grant execute on function public.send_tutoring_message(uuid,text) to authenticated;
grant update(last_read_at) on public.conversation_members to authenticated;
create policy "Members can update own read position" on public.conversation_members for update to authenticated
  using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
grant update(read_at),delete on public.notifications to authenticated;
create policy "Users can mark own notifications read" on public.notifications for update to authenticated
  using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
create policy "Users can delete own notifications" on public.notifications for delete to authenticated using(user_id=(select auth.uid()));
notify pgrst,'reload schema';
