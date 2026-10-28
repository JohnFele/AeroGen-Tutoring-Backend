CREATE OR REPLACE FUNCTION public.admin_update_tutor(_tutor_id uuid, _patch jsonb, _subject_ids bigint[] DEFAULT NULL::bigint[], _expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare previous public.tutor_profiles; edited public.tutor_profiles; field text; before_subjects jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if jsonb_typeof(_patch) is distinct from 'object' then raise exception 'Profile changes must be an object' using errcode='22023'; end if;
  for field in select jsonb_object_keys(_patch) loop
    if field <> all(array['public_name','bio','city','province','qualification','institution','year_completed','certifications','years_experience','teaching_style','student_age_groups','availability_slots','teaching_modes','hourly_rate','students_per_session','is_approved','is_accepting_students','is_featured','avatar_url']) then raise exception 'Unsupported tutor field: %',field using errcode='22023'; end if;
  end loop;
  select * into previous from public.tutor_profiles where user_id=_tutor_id for update;
  if not found then raise exception 'Tutor not found' using errcode='P0002'; end if;
  if _expected_updated_at is not null and previous.updated_at is distinct from _expected_updated_at then raise exception 'This tutor was changed by another administrator. Reload before saving.' using errcode='PT409'; end if;
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
$function$

;
notify pgrst,'reload schema';
