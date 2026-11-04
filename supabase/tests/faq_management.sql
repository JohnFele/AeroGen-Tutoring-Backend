begin;
-- Generated records and all updates are rolled back. Existing FAQs are not edited.
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  if not private.is_platform_admin() then raise exception 'An existing administrator is required'; end if;
  insert into public.site_faqs(id,category,question,answer,status) values
    ('de000000-0000-4000-8000-000000000911','Transaction test','A draft question for testing?','This is a generated draft answer.','draft'),
    ('de000000-0000-4000-8000-000000000912','Transaction test','A public question for testing?','This is a generated public answer.','published');
end; $$;
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ begin
  if exists(select 1 from public.site_faqs where id='de000000-0000-4000-8000-000000000911') then raise exception 'Draft leaked to visitors'; end if;
  if not exists(select 1 from public.site_faqs where id='de000000-0000-4000-8000-000000000912') then raise exception 'Published FAQ hidden'; end if;
  begin insert into public.site_faqs(category,question,answer) values('Forbidden','A forbidden question?','This write must be denied.');raise exception 'Anonymous insert allowed';exception when insufficient_privilege then null;end;
  begin update public.site_faqs set answer='Forbidden overwrite' where id='de000000-0000-4000-8000-000000000912';raise exception 'Anonymous update allowed';exception when insufficient_privilege then null;end;
  begin delete from public.site_faqs where id='de000000-0000-4000-8000-000000000912';raise exception 'Anonymous delete allowed';exception when insufficient_privilege then null;end;
end; $$;
reset role;
select set_config('request.jwt.claims','{"sub":"de000000-0000-4000-8000-000000000106","role":"authenticated"}',true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.site_faqs where id='de000000-0000-4000-8000-000000000911') then raise exception 'Student can read draft'; end if;
  begin insert into public.site_faqs(category,question,answer) values('Forbidden','A forbidden question?','This write must be denied.');raise exception 'Student insert allowed';exception when insufficient_privilege then null;end;
  update public.site_faqs set answer='Forbidden student overwrite' where id='de000000-0000-4000-8000-000000000912';if found then raise exception 'Student update allowed'; end if;
  delete from public.site_faqs where id='de000000-0000-4000-8000-000000000912';if found then raise exception 'Student delete allowed'; end if;
end; $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin
  update public.site_faqs set status='published' where id='de000000-0000-4000-8000-000000000911' and version=1;
  if not found then raise exception 'Admin publish failed'; end if;
  if not exists(select 1 from public.site_faqs where id='de000000-0000-4000-8000-000000000911' and version=2) then raise exception 'FAQ version did not advance'; end if;
  update public.site_faqs set answer='Stale edit must not save' where id='de000000-0000-4000-8000-000000000911' and version=1;if found then raise exception 'Stale edit matched'; end if;
  update public.site_faqs set status='draft' where id='de000000-0000-4000-8000-000000000911' and version=2;
end; $$;
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ begin if exists(select 1 from public.site_faqs where id='de000000-0000-4000-8000-000000000911') then raise exception 'Unpublished FAQ still public'; end if;end; $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ begin delete from public.site_faqs where id='de000000-0000-4000-8000-000000000911' and version=3;if not found then raise exception 'Admin delete failed'; end if;end; $$;
rollback;
