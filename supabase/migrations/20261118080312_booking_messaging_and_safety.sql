-- One canonical private conversation per booking pair. Existing history is retained.
alter table public.conversations add column tutor_id uuid references public.profiles(id) on delete restrict,
 add column student_id uuid references public.profiles(id) on delete restrict,
 add constraint conversation_pair_complete check((tutor_id is null)=(student_id is null) and tutor_id is distinct from student_id or tutor_id is null and student_id is null);
with pairs as (
 select c.id,b.tutor_id,b.student_id,row_number() over(partition by b.tutor_id,b.student_id order by c.created_at,c.id) position
 from public.conversations c join public.bookings b on b.id=c.booking_id
)
update public.conversations c set tutor_id=p.tutor_id,student_id=p.student_id from pairs p where p.id=c.id and p.position=1;
-- Earlier demo conversations may not have a booking reference.
with pairs as (
 select c.id,t.user_id tutor_id,s.user_id student_id,row_number() over(partition by t.user_id,s.user_id order by c.created_at,c.id) position
 from public.conversations c join public.conversation_members t on t.conversation_id=c.id
 join public.profiles tp on tp.id=t.user_id and tp.role='tutor'
 join public.conversation_members s on s.conversation_id=c.id
 join public.profiles sp on sp.id=s.user_id and sp.role='student'
 where c.tutor_id is null and (select count(*) from public.conversation_members where conversation_id=c.id)=2
 and not exists(select 1 from public.conversations x where x.tutor_id=t.user_id and x.student_id=s.user_id)
)
update public.conversations c set tutor_id=p.tutor_id,student_id=p.student_id from pairs p where p.id=c.id and p.position=1;
create unique index conversation_pair_unique on public.conversations(tutor_id,student_id) where tutor_id is not null;
alter table public.messages add column client_request_id uuid,add column limited boolean not null default false;
create unique index message_retry_unique on public.messages(sender_id,client_request_id) where client_request_id is not null;
create index message_history_order on public.messages(conversation_id,created_at desc,id desc) where deleted_at is null;
create index message_daily_allowance on public.messages(conversation_id,sender_id,created_at) where limited;
create table private.messaging_blocks(
 owner uuid not null references public.profiles(id) on delete cascade,
 conversation_id uuid not null references public.conversations(id) on delete cascade,
 created_at timestamptz not null default now(),primary key(owner,conversation_id)
);
create table private.message_reports(
 ticket_id uuid primary key references public.booking_safety_cases(id) on delete restrict,
 message_id uuid not null references public.messages(id) on delete restrict,
 reporter_id uuid not null references public.profiles(id) on delete restrict,
 description text not null,created_at timestamptz not null default now()
);
alter table private.messaging_blocks enable row level security;
alter table private.message_reports enable row level security;
revoke all on private.messaging_blocks,private.message_reports from public,anon,authenticated;

create function private.ensure_lesson_conversation(_tutor uuid,_student uuid,_booking uuid,_creator uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not private.booking_pair_allowed(_tutor,_student) then return null; end if;
 perform pg_advisory_xact_lock(hashtextextended(_tutor::text||_student::text,781));
 select id into result from public.conversations where tutor_id=_tutor and student_id=_student;
 if result is null then
  insert into public.conversations(tutor_id,student_id,booking_id,created_by) values(_tutor,_student,_booking,_creator) returning id into result;
 end if;
 insert into public.conversation_members(conversation_id,user_id) values(result,_tutor),(result,_student) on conflict do nothing;
 return result;
end; $$;
create function private.booking_conversation_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in ('pending','confirmed','completed','no_show') then
  perform private.ensure_lesson_conversation(new.tutor_id,new.student_id,new.id,coalesce(new.proposed_by,new.student_id));
 end if;
 return null;
end; $$;
create trigger booking_conversation_changed after insert or update of status on public.bookings for each row execute function private.booking_conversation_changed();
do $$ declare b record; begin
 for b in select distinct on(tutor_id,student_id) * from public.bookings where status in ('pending','confirmed','completed','no_show') order by tutor_id,student_id,created_at loop
  perform private.ensure_lesson_conversation(b.tutor_id,b.student_id,b.id,coalesce(b.proposed_by,b.student_id));
 end loop;
end; $$;

create function private.conversation_access(_id uuid,_actor uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c public.conversations; chat_until timestamptz; used integer; own_block boolean; other_block boolean; active boolean;
begin
 select * into c from public.conversations where id=_id;
 if _actor is null or not found or (c.tutor_id is not null and _actor not in(c.tutor_id,c.student_id)) or not exists(select 1 from public.conversation_members where conversation_id=_id and user_id=_actor) then
  raise exception 'Conversation unavailable.' using errcode='42501'; end if;
 own_block:=exists(select 1 from private.messaging_blocks where conversation_id=_id and owner=_actor);
 other_block:=exists(select 1 from private.messaging_blocks where conversation_id=_id and owner<>_actor);
 active:=c.tutor_id is not null and private.booking_pair_allowed(c.tutor_id,c.student_id)
  and exists(select 1 from public.tutor_profiles t join public.profiles p on p.id=t.user_id where t.user_id=c.tutor_id and t.is_approved and p.role='tutor');
 select max(ends_at+interval '3 days') into chat_until from public.bookings
 where tutor_id=c.tutor_id and student_id=c.student_id and status in ('confirmed','completed','no_show')
 and confirmed_at is not null and confirmed_at<=now() and ends_at+interval '3 days'>now();
 select count(*) into used from public.messages where conversation_id=_id and sender_id=_actor and limited
 and created_at>=((now() at time zone 'Africa/Johannesburg')::date::timestamp at time zone 'Africa/Johannesburg');
 return jsonb_build_object('mode',case when not active then 'unavailable' when own_block or other_block then 'blocked' when chat_until is not null then 'open' else 'limited' end,
  'canSend',active and not own_block and not other_block and (chat_until is not null or used<5),
  'blockedByMe',own_block,'blockedByOther',other_block,'dailyLimit',5,'remaining',greatest(0,5-used),'chatUntil',chat_until,
  'resetsAt',(((now() at time zone 'Africa/Johannesburg')::date+1)::timestamp at time zone 'Africa/Johannesburg'));
end; $$;

create function public.my_conversation(_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); access jsonb; result jsonb;
begin
 perform private.assert_platform_available(); access:=private.conversation_access(_id,actor);
 select jsonb_build_object('id',c.id,'booking_id',c.booking_id,'updated_at',c.updated_at,'last_read_at',own.last_read_at,'access',access,
  'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(t.public_name,concat_ws(' ',p.first_name,p.last_name)),'role',p.role,'last_read_at',m.last_read_at)),'[]')
   from public.conversation_members m join public.profiles p on p.id=m.user_id left join public.tutor_profiles t on t.user_id=p.id where m.conversation_id=c.id and m.user_id<>actor),
  'unread_count',(select count(*) from public.messages where conversation_id=c.id and sender_id<>actor and deleted_at is null and (own.last_read_at is null or created_at>own.last_read_at)),
  'last_message',(select jsonb_build_object('id',id,'body',body,'created_at',created_at,'sender_id',sender_id) from public.messages where conversation_id=c.id and deleted_at is null order by created_at desc,id desc limit 1))
 into result from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=actor where c.id=_id;
 return result;
end; $$;
create function public.my_conversations(_page integer,_query text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); rows jsonb; total integer;
begin
 perform private.assert_platform_available();
 if actor is null then raise exception 'Sign in to view messages.' using errcode='42501'; end if;
 if _page is null or _page<1 or _page>10000 or _query is null or length(_query)>120 then raise exception 'Choose a valid conversation page.' using errcode='22023'; end if;
 select count(*) into total from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=actor
 where _query='' or exists(select 1 from public.conversation_members m join public.profiles p on p.id=m.user_id left join public.tutor_profiles t on t.user_id=p.id
 where m.conversation_id=c.id and m.user_id<>actor and position(lower(_query) in lower(coalesce(t.public_name,concat_ws(' ',p.first_name,p.last_name))))>0);
 select coalesce(jsonb_agg(public.my_conversation(id) order by updated_at desc,id desc),'[]') into rows from (
 select c.id,c.updated_at from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=actor
 where _query='' or exists(select 1 from public.conversation_members m join public.profiles p on p.id=m.user_id left join public.tutor_profiles t on t.user_id=p.id
 where m.conversation_id=c.id and m.user_id<>actor and position(lower(_query) in lower(coalesce(t.public_name,concat_ws(' ',p.first_name,p.last_name))))>0)
 order by c.updated_at desc,c.id desc offset (_page-1)*20 limit 20) selected;
 return jsonb_build_object('conversations',rows,'total',total,'page',_page,'limit',20);
end; $$;
create function public.resolve_my_conversation(_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); resolved uuid;
begin
 perform private.assert_platform_available();
 select c.id into resolved from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=actor
 where c.id=_id or exists(select 1 from public.conversation_members m where m.conversation_id=c.id and m.user_id=_id and m.user_id<>actor)
 order by (c.id=_id) desc,(c.tutor_id is not null) desc,c.updated_at desc,c.id desc limit 1;
 if resolved is null then raise exception 'No conversation is available yet. Send a lesson request first.' using errcode='PT404'; end if;
 return public.my_conversation(resolved);
end; $$;
create function public.my_conversation_messages(_id uuid,_before timestamptz,_before_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); rows jsonb; next_cursor jsonb; access jsonb;
begin
 perform private.assert_platform_available(); access:=private.conversation_access(_id,actor);
 if (_before is null)<>(_before_id is null) then raise exception 'Choose a valid message page.' using errcode='22023'; end if;
 select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at,m.id),'[]') into rows from (
 select id,sender_id,body,created_at,client_request_id from public.messages where conversation_id=_id and deleted_at is null
 and (_before is null or (created_at,id)<(_before,_before_id)) order by created_at desc,id desc limit 50) m;
 if jsonb_array_length(rows)=50 and exists(select 1 from public.messages where conversation_id=_id and deleted_at is null
  and (created_at,id)<((rows->0->>'created_at')::timestamptz,(rows->0->>'id')::uuid)) then
  next_cursor:=jsonb_build_object('at',rows->0->>'created_at','id',rows->0->>'id'); end if;
 return jsonb_build_object('messages',rows,'nextCursor',next_cursor,'access',access);
end; $$;
create function public.send_tutoring_message(_conversation_id uuid,_body text,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); access jsonb; msg public.messages;
begin
 perform private.assert_platform_available();
 if actor is null or _request is null or _body is null or length(btrim(_body)) not between 1 and 10000 then raise exception 'Enter a message of 1 to 10,000 characters and a retry key.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,782));
 access:=private.conversation_access(_conversation_id,actor);
 select * into msg from public.messages where sender_id=actor and client_request_id=_request;
 if found then
  if msg.conversation_id<>_conversation_id or msg.body<>btrim(_body) then raise exception 'This retry key belongs to another message.' using errcode='PT409'; end if;
  return jsonb_build_object('message',jsonb_build_object('id',msg.id,'sender_id',actor,'body',msg.body,'created_at',msg.created_at,'client_request_id',_request),'access',access);
 end if;
 if not (access->>'canSend')::boolean then
  raise exception '%',case access->>'mode' when 'blocked' then 'Messaging is blocked for this conversation.' when 'limited' then 'Your five-message daily allowance has been used. It resets at midnight SAST.' else 'Messaging is unavailable for this relationship.' end using errcode='PT403'; end if;
 if (select count(*) from public.messages where sender_id=actor and created_at>now()-interval '1 minute')>=30 then raise exception 'Please slow down and retry in a minute.' using errcode='PT429'; end if;
 insert into public.messages(conversation_id,sender_id,body,client_request_id,limited) values(_conversation_id,actor,btrim(_body),_request,access->>'mode'='limited') returning * into msg;
 update public.conversations set updated_at=now() where id=_conversation_id;
 update public.conversation_members set last_read_at=msg.created_at where conversation_id=_conversation_id and user_id=actor;
 insert into public.notifications(user_id,kind,title,body,data)
 select user_id,'message','New message',left(msg.body,160),jsonb_build_object('conversationId',_conversation_id,'messageId',msg.id)
 from public.conversation_members where conversation_id=_conversation_id and user_id<>actor;
 return jsonb_build_object('message',jsonb_build_object('id',msg.id,'sender_id',actor,'body',msg.body,'created_at',msg.created_at,'client_request_id',_request),'access',private.conversation_access(_conversation_id,actor));
end; $$;
create or replace function public.send_tutoring_message(_conversation_id uuid,_body text) returns uuid language plpgsql security definer set search_path='' as $$
begin return (public.send_tutoring_message(_conversation_id,_body,gen_random_uuid())->'message'->>'id')::uuid; end; $$;
create function public.set_conversation_block(_id uuid,_blocked boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); member record;
begin
 perform private.assert_platform_available(); perform private.conversation_access(_id,actor);
 if _blocked is null then raise exception 'Choose whether to block this conversation.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,782));
 if _blocked then insert into private.messaging_blocks(owner,conversation_id) values(actor,_id) on conflict do nothing;
 else delete from private.messaging_blocks where owner=actor and conversation_id=_id; end if;
 for member in select user_id from public.conversation_members where conversation_id=_id loop perform private.bump_workspace(member.user_id); end loop;
 return private.conversation_access(_id,actor);
end; $$;
create function public.report_conversation_message(_message uuid,_description text,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=private.billing_account(); msg public.messages; report private.message_reports; item public.booking_safety_cases;
begin
 perform private.assert_platform_available();
 if _request is null or _description is null or length(btrim(_description)) not between 20 and 1800 then raise exception 'Describe the concern in 20 to 1,800 characters.' using errcode='22023'; end if;
 select * into msg from public.messages where id=_message and deleted_at is null;
 if not found or msg.sender_id=actor then raise exception 'Choose a received message.' using errcode='42501'; end if;
 perform private.conversation_access(msg.conversation_id,actor);
 perform pg_advisory_xact_lock(hashtextextended(actor::text,287));
 select * into report from private.message_reports where ticket_id=_request;
 if found then
  if report.reporter_id<>actor or report.message_id<>_message or report.description<>btrim(_description) then raise exception 'This request key belongs to a different report.' using errcode='PT409'; end if;
  select * into item from public.booking_safety_cases where id=report.ticket_id;
 else
  if exists(select 1 from public.booking_safety_cases where id=_request) then raise exception 'This request key belongs to another ticket.' using errcode='PT409'; end if;
  if (select count(*) from public.booking_safety_cases where reporter_id=actor and created_at>now()-interval '15 minutes')>=8 then raise exception 'Too many reports. Please wait before trying again.' using errcode='PT429'; end if;
  insert into public.booking_safety_cases(id,reporter_id,category,issue_code,subject,description)
  values(_request,actor,'conduct','MSG','Message conduct report',btrim(_description)) returning * into item;
  insert into private.message_reports(ticket_id,message_id,reporter_id,description) values(item.id,msg.id,actor,btrim(_description));
  perform private.billing_notice(actor,'Ticket '||item.case_reference||' received','Support has received your message report.','tickets',item.id);
 end if;
 return jsonb_build_object('id',item.id,'reference',item.case_reference);
end; $$;

alter function public.admin_support_ticket(uuid) rename to admin_support_ticket_before_messaging;
create function public.admin_support_ticket(_ticket uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=public.admin_support_ticket_before_messaging(_ticket);
 return result||jsonb_build_object('reported_message',(select jsonb_build_object('id',m.id,'sender',concat_ws(' ',p.first_name,p.last_name),'body',m.body,'created_at',m.created_at)
 from private.message_reports r join public.messages m on m.id=r.message_id join public.profiles p on p.id=m.sender_id
 join public.booking_safety_cases ticket on ticket.id=r.ticket_id where r.ticket_id=_ticket and
 (ticket.assigned_to=(select auth.uid()) or exists(select 1 from public.profiles where id=(select auth.uid()) and role='superUser'))));
end; $$;
revoke all on function public.admin_support_ticket_before_messaging(uuid) from public,anon,authenticated;
revoke all on function private.ensure_lesson_conversation(uuid,uuid,uuid,uuid),private.booking_conversation_changed(),private.conversation_access(uuid,uuid) from public,anon,authenticated;
revoke all on function public.my_conversation(uuid),public.my_conversations(integer,text),public.my_conversation_messages(uuid,timestamptz,uuid),
 public.send_tutoring_message(uuid,text,uuid),public.set_conversation_block(uuid,boolean),public.report_conversation_message(uuid,text,uuid),public.admin_support_ticket(uuid) from public,anon,authenticated;
grant execute on function public.my_conversation(uuid),public.my_conversations(integer,text),public.my_conversation_messages(uuid,timestamptz,uuid),
 public.send_tutoring_message(uuid,text,uuid),public.set_conversation_block(uuid,boolean),public.report_conversation_message(uuid,text,uuid),public.admin_support_ticket(uuid) to authenticated;
revoke all on function public.resolve_my_conversation(uuid) from public,anon,authenticated;
grant execute on function public.resolve_my_conversation(uuid) to authenticated;
create index support_stage_due_page on public.booking_safety_cases(status,response_due_at,created_at desc,id);
create index support_developer_page on public.booking_safety_cases(developer_status,created_at desc,id) where developer_status is not null;
create index guest_developer_page on public.contact_enquiries(developer_status,created_at desc,id) where developer_status is not null;
create index guest_support_page on public.contact_enquiries(status,created_at desc,id);

-- Workspace navigation needs only conversation previews; chat history is paginated separately.
CREATE FUNCTION public.my_tutoring_workspace(_conversation_previews boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare caller uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select jsonb_build_object(
    'bookings',coalesce((select jsonb_agg(row_data order by starts_at desc) from (
      select b.starts_at,jsonb_build_object('id',b.id,'student_id',b.student_id,'tutor_id',b.tutor_id,
        'student_name',concat_ws(' ',sp.first_name,sp.last_name),'tutor_name',coalesce(tp.public_name,'Tutor'),
        'subject',s.name,'starts_at',b.starts_at,'ends_at',b.ends_at,'duration_minutes',b.duration_minutes,
        'series_id',b.series_id,'recurrence_frequency',b.recurrence_frequency,'series_occurrence',b.series_occurrence,'status',case when b.status='pending' and b.starts_at<=now() then 'declined' else b.status end,
        'invitation_expired_at',coalesce(b.invitation_expired_at,case when b.status='pending' and b.starts_at<=now() then b.starts_at end),
        'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'proposed_by',coalesce(b.proposed_by,b.student_id),'confirmed_at',b.confirmed_at,
        'special_requests',b.special_requests,'demo',sp.demo_dataset is not null,
        'attendance_ticket_id',(select c.id from public.booking_safety_cases c where c.booking_id=b.id
          and c.reporter_id=caller and c.attendance_decision='pending' limit 1)
      ) || private.lesson_billing_summary(b.id,caller) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
    'student_study_profiles',private.workspace_student_study_profiles(caller),
    'lesson_rating_prompts',private.lesson_rating_prompts(caller),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.payments p where caller in (p.payer_id,p.payee_id)),'[]'::jsonb),
    'conversations',coalesce((select jsonb_agg(row_data order by updated_at desc) from (
      select c.updated_at,jsonb_build_object('id',c.id,'booking_id',c.booking_id,'last_read_at',own.last_read_at,'unread_count',(select count(*) from public.messages unread where unread.conversation_id=c.id and unread.sender_id<>caller and unread.deleted_at is null and (own.last_read_at is null or unread.created_at>own.last_read_at)),
        'participants',(select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(tp.public_name,concat_ws(' ',p.first_name,p.last_name)),'role',p.role))
          from public.conversation_members cm join public.profiles p on p.id=cm.user_id left join public.tutor_profiles tp on tp.user_id=p.id
          where cm.conversation_id=c.id and cm.user_id<>caller),
        'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from (
          select id,sender_id,body,created_at from public.messages where conversation_id=c.id and deleted_at is null order by created_at desc limit (case when _conversation_previews then 1 else 200 end)
        ) m),'[]'::jsonb)) row_data
      from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=caller
      order by c.updated_at desc limit 200
    ) rows),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc,n.id desc) from (select * from public.notifications where user_id=caller order by created_at desc,id desc limit 50) n),'[]'::jsonb),
    'notification_unread_count',(select count(*) from public.notifications where user_id=caller and read_at is null),
    'notification_revision',coalesce((select version from public.workspace_signals where user_id=caller),0)
  ) into result;
  return result;
end;
$function$;

revoke all on function public.my_tutoring_workspace(boolean) from public,anon,authenticated;
grant execute on function public.my_tutoring_workspace(boolean) to authenticated;
create index message_sender_recent on public.messages(sender_id,created_at desc);
create function private.conversation_read_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare member record;
begin
 if new.last_read_at is not distinct from old.last_read_at then return null; end if;
 for member in select user_id from public.conversation_members where conversation_id=new.conversation_id order by user_id loop
  perform private.bump_workspace(member.user_id);
 end loop;
 return null;
end; $$;
revoke all on function private.conversation_read_signal() from public,anon,authenticated;
create trigger conversation_read_signal after update of last_read_at on public.conversation_members for each row execute function private.conversation_read_signal();
