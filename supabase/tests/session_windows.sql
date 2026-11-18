begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('c3300000-0000-4000-8000-000000000001','session.admin@example.test','{}','{}'),
 ('c3300000-0000-4000-8000-000000000002','session.student@example.test','{}','{}'),
 ('c3300000-0000-4000-8000-000000000003','session.demo@example.test','{}','{}');
update public.profiles set role='superUser' where id='c3300000-0000-4000-8000-000000000001';
update public.profiles set role='tutor',demo_dataset='session-visibility-test' where id='c3300000-0000-4000-8000-000000000003';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,demo_dataset)
 values('c3300000-0000-4000-8000-000000000003','Invisible demo tutor',true,true,200,'session-visibility-test');
insert into auth.sessions(id,user_id,created_at,updated_at,aal) values
 ('c3300000-0000-4000-8000-000000000011','c3300000-0000-4000-8000-000000000001',now()-interval '2 days',now(),'aal2'),
 ('c3300000-0000-4000-8000-000000000012','c3300000-0000-4000-8000-000000000001',now()-interval '31 days',now(),'aal2'),
 ('c3300000-0000-4000-8000-000000000013','c3300000-0000-4000-8000-000000000002',now(),now(),'aal1');

set local role anon;
do $$ begin
 if exists(select 1 from public.tutor_directory where demo_dataset is not null) then raise exception 'Demo tutors remain public'; end if;
 begin perform public.my_session_security();raise exception 'Anonymous session lookup allowed';exception when insufficient_privilege then null;end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','c3300000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims',jsonb_build_object('sub','c3300000-0000-4000-8000-000000000001','session_id','c3300000-0000-4000-8000-000000000011','aal','aal2','amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from now()-interval '6 days')::bigint)))::text,true);
do $$ declare state jsonb:=public.my_session_security();begin
 if not (state->>'valid')::boolean or not (state->>'admin_verified')::boolean or not private.is_platform_admin() then raise exception 'Remembered session or recent MFA rejected';end if;
 if (state->>'expires_at')::timestamptz <> now()+interval '28 days' then raise exception 'Refresh extended the original 30-day session';end if;
end $$;
select set_config('request.jwt.claims',jsonb_set(auth.jwt(),'{amr}',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from now()-interval '8 days')::bigint)))::text,true);
do $$ begin
 if (public.my_session_security()->>'admin_verified')::boolean or private.is_platform_admin() then raise exception 'Stale MFA was trusted';end if;
 if not (public.my_session_security()->>'valid')::boolean then raise exception 'MFA renewal must not sign out a valid primary session';end if;
end $$;
select set_config('request.jwt.claims',jsonb_set(auth.jwt(),'{session_id}','"c3300000-0000-4000-8000-000000000012"')::text,true);
do $$ begin if (public.my_session_security()->>'valid')::boolean then raise exception 'A 31-day session remained valid';end if;end $$;
select set_config('request.jwt.claims',jsonb_set(auth.jwt(),'{session_id}','"c3300000-0000-4000-8000-000000000013"')::text,true);
do $$ begin if (public.my_session_security()->>'valid')::boolean then raise exception 'Another users session was accepted';end if;end $$;
select set_config('request.jwt.claims',jsonb_set(auth.jwt(),'{session_id}','"c3300000-0000-4000-8000-000000000099"')::text,true);
do $$ begin if (public.my_session_security()->>'valid')::boolean then raise exception 'A removed session remained valid';end if;end $$;
rollback;
