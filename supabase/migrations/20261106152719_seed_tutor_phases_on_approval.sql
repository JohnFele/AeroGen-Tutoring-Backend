-- Use approved application grade ranges for new tutor accounts.
-- Later profile saves own the preference, including an explicit empty selection.
create function private.seed_teaching_levels_on_approval() returns trigger
language plpgsql security definer set search_path='' as $$
declare codes text[];
begin
  if not new.is_approved then return new; end if;
  if tg_op='UPDATE' and old.first_approved_at is not null then return new; end if;
  select array_agg(distinct m.code order by m.code) into codes
  from (values
    ('Primary School (Gr 1-3)','foundation'),('Primary School (Gr 4-7)','intermediate'),('Primary School (Gr 4-7)','senior'),
    ('High School (Gr 8-9)','senior'),('High School (Gr 10-12)','fet'),
    ('University/College','college'),('University/College','undergraduate'),('University/College','postgraduate'),('Adult Learners','adult')
  ) as m(label,code) where m.label=any(new.student_age_groups);
  if codes is not null then
    update public.profiles set teaching_level_codes=codes
    where id in (
      select p.id from public.profiles p
      where p.id=new.user_id and p.role in ('student','tutor') and cardinality(p.teaching_level_codes)=0
      for update skip locked
    );
  end if;
  return new;
end;
$$;
create trigger seed_teaching_levels_on_approval after insert or update of is_approved on public.tutor_profiles
for each row execute function private.seed_teaching_levels_on_approval();
revoke all on function private.seed_teaching_levels_on_approval() from public,anon,authenticated;
