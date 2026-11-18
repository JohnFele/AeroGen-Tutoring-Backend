begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('c2300000-0000-4000-8000-000000000001','chat.student@example.test','{}','{}'),
 ('c2300000-0000-4000-8000-000000000002','chat.tutor@example.test','{}','{}'),
 ('c2300000-0000-4000-8000-000000000003','chat.other@example.test','{}','{}'),
 ('c2300000-0000-4000-8000-000000000004','chat.admin@example.test','{}','{}');
update public.profiles set role='tutor' where id='c2300000-0000-4000-8000-000000000002';
update public.profiles set role='superUser' where id='c2300000-0000-4000-8000-000000000004';
insert into public.tutor_profiles(user_id,public_name,is_approved,teaching_modes,hourly_rate) values('c2300000-0000-4000-8000-000000000002','Messaging Tutor',true,array['online'],200);
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,duration_minutes,teaching_mode,session_type,hourly_rate,total_amount,status,proposed_by)
values('c2300000-0000-4000-8000-000000000005','c2300000-0000-4000-8000-000000000001','c2300000-0000-4000-8000-000000000002',now()+interval '2 days',now()+interval '2 days 1 hour',60,'online','individual',200,200,'pending','c2300000-0000-4000-8000-000000000001');
select set_config('test.chat',(select id::text from public.conversations where tutor_id='c2300000-0000-4000-8000-000000000002' and student_id='c2300000-0000-4000-8000-000000000001'),true);
set local role authenticated;
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000001',true);
do $$ declare result jsonb; key uuid:=gen_random_uuid(); begin
 if public.my_conversation(current_setting('test.chat')::uuid)->'access'->>'mode'<>'limited' then raise exception 'Pending booking opens full chat'; end if;
 for i in 1..5 loop
  result:=public.send_tutoring_message(current_setting('test.chat')::uuid,'Hello message '||i,case when i=1 then key else gen_random_uuid() end);
 end loop;
 result:=public.send_tutoring_message(current_setting('test.chat')::uuid,'Hello message 1',key);
 if (result->'access'->>'remaining')::int<>0 then raise exception 'Daily allowance or retry changed incorrectly'; end if;
 begin perform public.send_tutoring_message(current_setting('test.chat')::uuid,'Sixth message',gen_random_uuid());raise exception 'Quota bypass'; exception when sqlstate 'PT403' then null; end;
 begin perform public.send_tutoring_message(current_setting('test.chat')::uuid,'Different body',key);raise exception 'Retry collision bypass'; exception when sqlstate 'PT409' then null; end;
end; $$;
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000003',true);
do $$ begin
 begin perform public.my_conversation_messages(current_setting('test.chat')::uuid,null,null);raise exception 'Nonmember read messages'; exception when insufficient_privilege then null; end;
 if jsonb_array_length(public.my_conversations(1,'')->'conversations')<>0 then raise exception 'List leaks another account'; end if;
 if exists(select 1 from public.messages where conversation_id=current_setting('test.chat')::uuid) then raise exception 'Direct RLS read leaks another conversation'; end if;
 begin insert into public.messages(conversation_id,sender_id,body) values(current_setting('test.chat')::uuid,auth.uid(),'Forged message');raise exception 'Direct write bypasses messaging rules'; exception when insufficient_privilege then null; end;
end; $$;
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000002',true);
select set_config('test.received',(public.send_tutoring_message(current_setting('test.chat')::uuid,'Hello from your tutor',gen_random_uuid())->'message'->>'id'),true);
do $$ begin
 if public.my_conversation(current_setting('test.chat')::uuid)->'participants'->0->>'last_read_at' is null then raise exception 'Read position is unavailable to the conversation participant'; end if;
end; $$;
select public.set_conversation_block(current_setting('test.chat')::uuid,true);
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000001',true);
do $$ begin
 if public.set_conversation_block(current_setting('test.chat')::uuid,false)->>'mode'<>'blocked' then raise exception 'Unblocking overwrites the other participant block'; end if;
 begin perform public.send_tutoring_message(current_setting('test.chat')::uuid,'Blocked message',gen_random_uuid());raise exception 'Block bypass'; exception when sqlstate 'PT403' then null; end;
end; $$;
select set_config('test.report',public.report_conversation_message(current_setting('test.received')::uuid,'This message needs a careful conduct review by support.','c2300000-0000-4000-8000-000000000006')::text,true);
select public.report_conversation_message(current_setting('test.received')::uuid,'This message needs a careful conduct review by support.','c2300000-0000-4000-8000-000000000006');
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000004',true);
do $$ begin
 if public.admin_support_ticket((current_setting('test.report')::jsonb->>'id')::uuid)->'reported_message'->>'body'<>'Hello from your tutor' then raise exception 'Reported message evidence missing'; end if;
end; $$;
reset role;
update public.bookings set status='confirmed',confirmed_at=now() where id='c2300000-0000-4000-8000-000000000005';
set local role authenticated;
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000002',true);
select public.set_conversation_block(current_setting('test.chat')::uuid,false);
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000001',true);
do $$ begin
 if public.my_conversation(current_setting('test.chat')::uuid)->'access'->>'mode'<>'open' then raise exception 'Accepted booking did not open full chat'; end if;
 perform public.send_tutoring_message(current_setting('test.chat')::uuid,'Full chat after acceptance',gen_random_uuid());
end; $$;
reset role;
update public.bookings set status='completed',starts_at=now()-interval '2 days 1 hour',ends_at=now()-interval '2 days',confirmed_at=now()-interval '3 days' where id='c2300000-0000-4000-8000-000000000005';
do $$ begin
 if private.conversation_access(current_setting('test.chat')::uuid,'c2300000-0000-4000-8000-000000000001')->>'mode'<>'open' then raise exception 'Three-day grace period missing'; end if;
end; $$;
update public.bookings set starts_at=now()-interval '4 days 1 hour',ends_at=now()-interval '4 days',confirmed_at=now()-interval '5 days' where id='c2300000-0000-4000-8000-000000000005';
do $$ begin
 if private.conversation_access(current_setting('test.chat')::uuid,'c2300000-0000-4000-8000-000000000001')->>'mode'<>'limited' then raise exception 'Chat window never expired'; end if;
 if (select count(*) from public.conversations where tutor_id='c2300000-0000-4000-8000-000000000002' and student_id='c2300000-0000-4000-8000-000000000001')<>1 then raise exception 'Booking updates duplicated conversations'; end if;
 if (select count(*) from private.message_reports where reporter_id='c2300000-0000-4000-8000-000000000001')<>1 then raise exception 'Retries duplicated tickets'; end if;
end; $$;
-- A future cancelled lesson cannot keep full messaging open.
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,duration_minutes,teaching_mode,session_type,hourly_rate,total_amount,status,proposed_by,confirmed_at)
values('c2300000-0000-4000-8000-000000000008','c2300000-0000-4000-8000-000000000001','c2300000-0000-4000-8000-000000000002',now()+interval '4 days',now()+interval '4 days 1 hour',60,'online','individual',200,200,'confirmed','c2300000-0000-4000-8000-000000000001',now());
update public.bookings set status='cancelled' where id='c2300000-0000-4000-8000-000000000008';
update public.messages set created_at=(((now() at time zone 'Africa/Johannesburg')::date)::timestamp at time zone 'Africa/Johannesburg')-interval '1 minute'
where sender_id='c2300000-0000-4000-8000-000000000001' and limited;
do $$ declare access jsonb; begin
 access:=private.conversation_access(current_setting('test.chat')::uuid,'c2300000-0000-4000-8000-000000000001');
 if access->>'mode'<>'limited' or (access->>'remaining')::int<>5 then raise exception 'Cancellation or SAST daily reset is incorrect'; end if;
end; $$;
insert into public.messages(conversation_id,sender_id,body,created_at)
select current_setting('test.chat')::uuid,'c2300000-0000-4000-8000-000000000002','Older history '||i,now()-interval '1 day' from generate_series(1,101)i;
set local role authenticated;
select set_config('request.jwt.claim.sub','c2300000-0000-4000-8000-000000000001',true);
do $$ declare first jsonb; second jsonb; begin
 first:=public.my_conversation_messages(current_setting('test.chat')::uuid,null,null);
 second:=public.my_conversation_messages(current_setting('test.chat')::uuid,(first->'nextCursor'->>'at')::timestamptz,(first->'nextCursor'->>'id')::uuid);
 if jsonb_array_length(first->'messages')<>50 or jsonb_array_length(second->'messages')<>50 then raise exception 'History is not bounded'; end if;
 if exists(select 1 from jsonb_array_elements(first->'messages')a join jsonb_array_elements(second->'messages')b on a->>'id'=b->>'id') then raise exception 'Tied timestamps duplicated history'; end if;
 if (select jsonb_array_length(item->'messages') from jsonb_array_elements(public.my_tutoring_workspace(true)->'conversations')item where item->>'id'=current_setting('test.chat'))<>1 then raise exception 'Workspace preview loads full chat history'; end if;
 if (select jsonb_array_length(item->'messages') from jsonb_array_elements(public.my_tutoring_workspace()->'conversations')item where item->>'id'=current_setting('test.chat'))<50 then raise exception 'Legacy workspace clients lost message history'; end if;
end; $$;
reset role;
rollback;
