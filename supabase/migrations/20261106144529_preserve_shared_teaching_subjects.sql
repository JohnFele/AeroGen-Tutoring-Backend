-- DBE, IEB and SACAI draw their NSC subjects from the same official source.
-- Preserve legacy assignments shared by equivalent routes the tutor already selected.
with equivalent_matches as (
  select ts.tutor_id,ts.subject_id,array_agg(o.curriculum_code order by o.curriculum_code) as codes
  from public.tutor_subjects ts
  join public.profiles p on p.id=ts.tutor_id and p.role='tutor'
  join public.teaching_subject_options o on o.subject_id=ts.subject_id and o.curriculum_code=any(p.curriculum_codes)
  join public.education_pathways route on route.code=o.curriculum_code
  where cardinality(ts.curriculum_codes)=0
  group by ts.tutor_id,ts.subject_id
  having count(distinct coalesce(route.details->>'subjectSource',route.code))=1
)
update public.tutor_subjects ts set curriculum_codes=m.codes
from equivalent_matches m where ts.tutor_id=m.tutor_id and ts.subject_id=m.subject_id
  and cardinality(ts.curriculum_codes)=0;

create or replace function private.assign_tutor_subject_curriculum() returns trigger
language plpgsql security definer set search_path='' as $$
declare codes text[];
begin
  select array_agg(o.curriculum_code order by o.curriculum_code) into codes
  from public.profiles p
  join public.teaching_subject_options o on o.curriculum_code=any(p.curriculum_codes)
  join public.education_pathways route on route.code=o.curriculum_code
  where p.id=new.tutor_id and p.role='tutor' and o.subject_id=new.subject_id
  having count(distinct coalesce(route.details->>'subjectSource',route.code))=1;
  new.curriculum_codes := coalesce(codes,'{}');
  return new;
end;
$$;
