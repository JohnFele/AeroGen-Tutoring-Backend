begin;
-- All test data and admin edits roll back; no email is sent by these database checks.
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare v integer; reply jsonb; begin
  if not private.is_platform_admin() then raise exception 'An existing administrator is required for these checks'; end if;
  insert into public.career_openings(id,title,department,employment_type,location,description,status,closes_on) values
    ('de000000-0000-4000-8000-000000000901','SQL draft test','Testing','Contract','Remote','Generated database transaction test only.','draft',null),
    ('de000000-0000-4000-8000-000000000902','SQL published test','Testing','Contract','Remote','Generated database transaction test only.','published',null),
    ('de000000-0000-4000-8000-000000000903','SQL expired test','Testing','Contract','Remote','Generated database transaction test only.','published','2020-01-01');
  select version into v from public.site_contact_settings where id;
  update public.site_contact_settings set sunday_hours='Test only' where id and version=v;
  if not exists(select 1 from public.site_contact_settings where id and version=v+1) then raise exception 'Settings version did not advance'; end if;
  update public.site_contact_settings set sunday_hours='Stale' where id and version=v;
  if found then raise exception 'Stale version unexpectedly matched'; end if;
end; $$;
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ declare receipt jsonb; begin
  if exists(select 1 from public.career_openings where id in ('de000000-0000-4000-8000-000000000901','de000000-0000-4000-8000-000000000903')) then raise exception 'Nonpublic openings leaked'; end if;
  if not exists(select 1 from public.career_openings where id='de000000-0000-4000-8000-000000000902') then raise exception 'Published opening hidden'; end if;
  if has_table_privilege('anon','public.contact_enquiries','SELECT') or has_table_privilege('anon','public.contact_enquiries','INSERT') then raise exception 'Anonymous raw enquiry access granted'; end if;
  receipt=public.submit_contact_enquiry('de000000-0000-4000-8000-000000000904','SQL','Test','site-sql@example.test','general','Generated transaction enquiry test only.');
  if not (receipt->>'created')::boolean then raise exception 'Enquiry not created'; end if;
  receipt=public.submit_contact_enquiry('de000000-0000-4000-8000-000000000904','SQL','Test','site-sql@example.test','general','Generated transaction enquiry test only.');
  if (receipt->>'created')::boolean then raise exception 'Duplicate enquiry not idempotent'; end if;
end; $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub','de000000-0000-4000-8000-000000000106','role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.contact_enquiries where id='de000000-0000-4000-8000-000000000904') then raise exception 'Student can read inbox'; end if;
  update public.site_contact_settings set email='forbidden@example.test' where id;
  if found then raise exception 'Student edited settings'; end if;
  begin perform public.begin_enquiry_reply('de000000-0000-4000-8000-000000000905','de000000-0000-4000-8000-000000000904','A private admin reply test.',1);raise exception 'Student created reply';exception when insufficient_privilege then null;end;
end; $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare response jsonb; begin
  response=public.begin_enquiry_reply('de000000-0000-4000-8000-000000000905','de000000-0000-4000-8000-000000000904','A private admin reply test.',1);
  if not (response->>'created')::boolean then raise exception 'Admin reply not created'; end if;
  response=public.begin_enquiry_reply('de000000-0000-4000-8000-000000000905','de000000-0000-4000-8000-000000000904','A private admin reply test.',1);
  if (response->>'created')::boolean then raise exception 'Reply was not idempotent'; end if;
  begin perform public.begin_enquiry_reply('de000000-0000-4000-8000-000000000906','de000000-0000-4000-8000-000000000904','A stale-version reply test.',1);raise exception 'Stale reply accepted';exception when sqlstate 'PT409' then null;end;
end; $$;
rollback;
