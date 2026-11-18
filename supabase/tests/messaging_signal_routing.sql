begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('c2700000-0000-4000-8000-000000000001','signal.owner@example.test','{}','{}'),
 ('c2700000-0000-4000-8000-000000000002','signal.other@example.test','{}','{}');
do $$ declare initial_activity bigint; saved_message_version bigint; begin
 select coalesce(activity_version,0) into initial_activity from public.workspace_signals where user_id='c2700000-0000-4000-8000-000000000001';
 initial_activity:=coalesce(initial_activity,0);
 perform private.bump_message_signal('c2700000-0000-4000-8000-000000000001');
 if (select last_event<>'message' or activity_version<>initial_activity or message_version<1 from public.workspace_signals where user_id='c2700000-0000-4000-8000-000000000001') then raise exception 'Message signal triggered an activity refresh'; end if;
 select message_version into saved_message_version from public.workspace_signals where user_id='c2700000-0000-4000-8000-000000000001';
 perform private.bump_workspace('c2700000-0000-4000-8000-000000000001');
 if (select last_event<>'activity' or activity_version<>initial_activity+1 or message_version<>saved_message_version from public.workspace_signals where user_id='c2700000-0000-4000-8000-000000000001') then raise exception 'Activity signal lost its independent version'; end if;
end; $$;
insert into public.notifications(user_id,kind,title,body) values('c2700000-0000-4000-8000-000000000002','message','Private other message','Do not disclose');
set local role authenticated;
select set_config('request.jwt.claim.sub','c2700000-0000-4000-8000-000000000001',true);
do $$ declare summary jsonb; begin
 summary:=public.my_notification_summary();
 if exists(select 1 from jsonb_array_elements(summary->'notifications')n where n->>'user_id'<>auth.uid()::text) then raise exception 'Summary leaks another account'; end if;
 if summary ? 'bookings' or summary ? 'payments' or summary ? 'conversations' then raise exception 'Summary fetches unrelated workspace data'; end if;
end; $$;
reset role;
rollback;
