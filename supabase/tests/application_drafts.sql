begin;
create temporary table draft_fixture as select id owner_id,gen_random_uuid() draft_id,gen_random_uuid() save_id
  from public.profiles where demo_dataset='aerogen-live-demo-v1' and role='student'
    and not exists(select 1 from public.tutor_applications a where a.user_id=profiles.id and a.status in('submitted','under_review'))
  order by id desc limit 1;
grant select on draft_fixture to authenticated;
select set_config('request.jwt.claim.sub',(select owner_id::text from draft_fixture),true);
set local role authenticated;
select public.save_tutor_application_draft(draft_id,'{"firstName":"Draft test","idNumber":"TEST-ONLY","address":"Fictional address"}','[]',1,1,null,save_id) from draft_fixture;
do $$ begin
  if (select count(*) from public.tutor_application_drafts)<>1 then raise exception 'Own draft not readable'; end if;
  if has_table_privilege('authenticated','public.tutor_application_drafts','INSERT') or has_table_privilege('anon','public.tutor_application_drafts','SELECT')
    or has_function_privilege('anon','public.save_tutor_application_draft(uuid,jsonb,jsonb,integer,integer,integer,uuid)','EXECUTE')
    then raise exception 'Unsafe draft grants'; end if;
end; $$;
select public.save_tutor_application_draft(draft_id,'{"firstName":"Edited from second device"}','[]',1,1,1,gen_random_uuid()) from draft_fixture;
do $$ begin
  begin
    perform public.save_tutor_application_draft(draft_id,'{"firstName":"Stale edit"}','[]',1,1,1,gen_random_uuid()) from draft_fixture;
    raise exception 'Stale update accepted';
  exception when sqlstate 'PT409' then null; end;
  begin
    perform public.save_tutor_application_draft(draft_id,'{"role":"superUser"}','[]',1,1,2,gen_random_uuid()) from draft_fixture;
    raise exception 'Protected data accepted';
  exception when sqlstate '22023' then null; end;
end; $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where demo_dataset='aerogen-live-demo-v1' and id<>(select owner_id from draft_fixture) and role='student' limit 1),true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.tutor_application_drafts) then raise exception 'Another user can read this draft'; end if;
end; $$;
reset role;
select 'Private draft, two-device version updates and isolation checks passed' as result;
rollback;
