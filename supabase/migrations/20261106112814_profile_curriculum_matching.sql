alter table public.profiles add column curriculum_codes text[] not null default '{}';
grant update (curriculum_codes) on public.profiles to authenticated;

create function private.validate_profile_curricula() returns trigger
language plpgsql set search_path = '' as $$
begin
  if cardinality(new.curriculum_codes) > 20
    or (new.role = 'student' and cardinality(new.curriculum_codes) > 1)
    or (new.role not in ('student','tutor') and cardinality(new.curriculum_codes) > 0)
    or cardinality(new.curriculum_codes) <> (
      select count(distinct p.code) from public.education_pathways p
      where p.code = any(new.curriculum_codes)
    ) then
    raise exception 'Choose valid curricula for your profile.' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger validate_profile_curricula
before update of curriculum_codes on public.profiles
for each row execute function private.validate_profile_curricula();
revoke all on function private.validate_profile_curricula() from public, anon, authenticated;

-- Student selections remain private. Only discoverable tutors' declared codes
-- are projected into the directory, with the same demo audience boundary.
create function private.directory_tutor_curricula(tutor_id uuid) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select p.curriculum_codes
    from public.profiles p
    join public.tutor_profiles tp on tp.user_id = p.id
    where p.id = tutor_id and p.role = 'tutor' and tp.is_approved and tp.is_accepting_students
      and ((tp.demo_dataset is null and p.demo_dataset is null)
        or tp.demo_dataset = (select viewer.demo_dataset from public.profiles viewer where viewer.id = (select auth.uid())))
  ), '{}'::text[]);
$$;
revoke all on function private.directory_tutor_curricula(uuid) from public, anon, authenticated;
grant execute on function private.directory_tutor_curricula(uuid) to anon, authenticated;

create or replace view public.tutor_directory with (security_invoker=true) as
select tp.user_id as id,tp.public_name,tp.bio,tp.city,tp.province,tp.qualification,tp.institution,tp.year_completed,
  tp.certifications,tp.years_experience,tp.teaching_style,tp.student_age_groups,tp.availability_slots,tp.teaching_modes,
  tp.hourly_rate,tp.students_per_session,tp.is_featured,tp.avatar_url,tp.demo_dataset,tp.updated_at,
  coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'aliases',s.aliases) order by s.name)
    from public.tutor_subjects ts join public.subjects s on s.id=ts.subject_id and s.is_active where ts.tutor_id=tp.user_id),'[]'::jsonb) as subjects,
  coalesce(stats.review_count,0) as review_count,round(stats.average_rating,1) as rating,
  coalesce(stats.completed_sessions,0) as completed_sessions,coalesce(stats.reviewed_students,0) as reviewed_students,
  tp.first_approved_at,
  coalesce(stats.average_rating>=4.8 and stats.reviewed_students>=5 and stats.completed_sessions>=10
    and tp.first_approved_at<=now()-interval '30 days',false) as is_top_rated,
  coalesce(tp.first_approved_at>now()-interval '90 days' and coalesce(stats.completed_sessions,0)<10,false) as is_new,
  private.directory_tutor_curricula(tp.user_id) as curriculum_codes
from public.tutor_profiles tp left join public.tutor_public_stats stats on stats.tutor_id=tp.user_id
where tp.is_approved and tp.is_accepting_students;
notify pgrst,'reload schema';
