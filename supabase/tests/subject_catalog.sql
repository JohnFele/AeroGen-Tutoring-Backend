-- Run inside a transaction after the expanded_subject_catalog migration.
do $$
begin
  if (select count(*) from public.subjects where is_active) < 444 then raise exception 'Catalogue seed is incomplete'; end if;
  if (select count(*) from public.subject_categories where is_active) < 16 then raise exception 'Missing subject categories'; end if;
  if (select count(*) from public.education_levels where is_active) < 8 then raise exception 'Missing education levels'; end if;
  if exists (select 1 from public.subjects s left join public.subject_categories c on c.name = s.category where c.slug is null) then raise exception 'Orphaned subject category'; end if;
  if exists (select 1 from public.subjects s where s.is_active and not exists (select 1 from public.subject_education_levels l where l.subject_id = s.id)) then raise exception 'Missing subject level tags'; end if;
  if exists (select 1 from pg_class where oid in ('public.subject_categories'::regclass, 'public.education_levels'::regclass, 'public.subject_education_levels'::regclass) and not relrowsecurity) then raise exception 'RLS must be enabled'; end if;
end $$;

set local role anon;
do $$
begin
  if (select count(*) from public.subjects where name = 'Phonics') <> 1 then raise exception 'Anonymous subject reads failed'; end if;
  if (select count(*) from public.subject_education_levels l join public.subjects s on s.id = l.subject_id where s.name = 'Phonics' and l.level_code = 'foundation') <> 1 then raise exception 'Anonymous level reads failed'; end if;
  if (select count(*) from public.subject_categories) < 16 then raise exception 'Anonymous category reads failed'; end if;
  if (select count(*) from public.education_levels) < 8 then raise exception 'Anonymous education level reads failed'; end if;
  if has_table_privilege('anon', 'public.subjects', 'insert') or has_table_privilege('anon', 'public.subject_categories', 'insert') or has_table_privilege('anon', 'public.subject_education_levels', 'insert') or has_table_privilege('anon', 'public.education_levels', 'insert') then raise exception 'Catalogue is writable by anonymous visitors'; end if;
end $$;
reset role;
set local role authenticated;
do $$
begin
  if (select count(*) from public.subject_education_levels) < 444 then raise exception 'Authenticated catalogue reads failed'; end if;
  if has_table_privilege('authenticated', 'public.subjects', 'update') or has_table_privilege('authenticated', 'public.subject_categories', 'update') or has_table_privilege('authenticated', 'public.subject_education_levels', 'update') or has_table_privilege('authenticated', 'public.education_levels', 'update') then raise exception 'Catalogue is writable by ordinary accounts'; end if;
end $$;
reset role;
