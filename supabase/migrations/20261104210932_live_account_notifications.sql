-- Owner-only invalidation avoids publishing message text or unfilterable DELETE payloads.
create table public.workspace_signals (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.workspace_signals enable row level security;
revoke all on public.workspace_signals from public,anon,authenticated;
grant select on public.workspace_signals to authenticated;
create policy workspace_signal_owner on public.workspace_signals for select to authenticated using(user_id=(select auth.uid()));
create policy platform_maintenance on public.workspace_signals as restrictive for all to authenticated
  using((select private.platform_runtime_allowed())) with check((select private.platform_runtime_allowed()));
insert into public.workspace_signals(user_id) select id from public.profiles;
alter publication supabase_realtime add table public.workspace_signals;
create index notifications_account_history on public.notifications(user_id,created_at desc,id desc);

create function private.bump_workspace(_user uuid) returns void language sql security definer set search_path='' as $$
  insert into public.workspace_signals(user_id,version,updated_at)
    select _user,1,clock_timestamp() where exists(select 1 from public.profiles where id=_user)
    on conflict(user_id) do update set version=public.workspace_signals.version+1,updated_at=excluded.updated_at;
$$;
revoke all on function private.bump_workspace(uuid) from public,anon,authenticated;

create function private.notification_preference() returns trigger language plpgsql security definer set search_path='' as $$
declare preference public.user_notification_preferences;
begin
  select * into preference from public.user_notification_preferences where user_id=new.user_id;
  if (new.kind='message' and not coalesce(preference.push_messages,true))
    or (new.kind in ('booking','calendar') and not coalesce(preference.push_booking_updates,true))
    or (new.kind='payment' and not coalesce(preference.push_payment_updates,true)) then return null; end if;
  return new;
end; $$;
revoke all on function private.notification_preference() from public,anon,authenticated;
create trigger respect_notification_preferences before insert on public.notifications for each row execute function private.notification_preference();

create function private.notification_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and old is not distinct from new then return new; end if;
  perform private.bump_workspace(case when tg_op='DELETE' then old.user_id else new.user_id end);
  return null;
end; $$;
revoke all on function private.notification_changed() from public,anon,authenticated;
create trigger notification_workspace_changed after insert or update or delete on public.notifications for each row execute function private.notification_changed();

create function private.message_workspace_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare member record;
begin
  for member in select user_id from public.conversation_members where conversation_id=new.conversation_id order by user_id loop
    perform private.bump_workspace(member.user_id);
  end loop;
  return null;
end; $$;
revoke all on function private.message_workspace_changed() from public,anon,authenticated;
create trigger message_workspace_changed after insert on public.messages for each row execute function private.message_workspace_changed();

create function private.monotonic_read_position() returns trigger language plpgsql security invoker set search_path='' as $$
begin new.last_read_at=greatest(old.last_read_at,new.last_read_at);return new;end; $$;
revoke all on function private.monotonic_read_position() from public,anon,authenticated;
create trigger monotonic_read_position before update of last_read_at on public.conversation_members for each row execute function private.monotonic_read_position();
create function private.conversation_read() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.last_read_at is not distinct from old.last_read_at then return null; end if;
  update public.notifications set read_at=clock_timestamp() where user_id=new.user_id and kind='message' and read_at is null
    and data->>'conversationId'=new.conversation_id::text and created_at<=new.last_read_at;
  perform private.bump_workspace(new.user_id);
  return null;
end; $$;
revoke all on function private.conversation_read() from public,anon,authenticated;
create trigger conversation_notification_read after update of last_read_at on public.conversation_members for each row execute function private.conversation_read();

create function private.booking_notification() returns trigger language plpgsql security definer set search_path='' as $$
declare title text; description text;
begin
  if tg_op='UPDATE' and row(old.status,old.starts_at,old.ends_at,old.teaching_mode) is not distinct from row(new.status,new.starts_at,new.ends_at,new.teaching_mode) then return null; end if;
  title=case when tg_op='INSERT' then 'New session booking' when old.starts_at is distinct from new.starts_at or old.ends_at is distinct from new.ends_at then 'Session schedule updated' else 'Session '||replace(new.status,'_',' ') end;
  description='Your session on '||to_char(new.starts_at at time zone 'Africa/Johannesburg','DD Mon YYYY, HH24:MI')||' SAST is '||replace(new.status,'_',' ')||'.';
  perform private.bump_workspace(least(new.student_id,new.tutor_id));perform private.bump_workspace(greatest(new.student_id,new.tutor_id));
  insert into public.notifications(user_id,kind,title,body,data)
    select recipient,'booking',title,description,jsonb_build_object('tab','calendar','bookingId',new.id) from (select distinct unnest(array[new.student_id,new.tutor_id]) recipient) recipients;
  return null;
end; $$;
revoke all on function private.booking_notification() from public,anon,authenticated;
create trigger booking_account_notifications after insert or update on public.bookings for each row execute function private.booking_notification();

create function private.payment_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and old.status is not distinct from new.status then return null; end if;
  perform private.bump_workspace(least(new.payer_id,new.payee_id));perform private.bump_workspace(greatest(new.payer_id,new.payee_id));
  insert into public.notifications(user_id,kind,title,body,data)
    values(new.payer_id,'payment','Payment '||replace(new.status,'_',' '),'Payment status: '||replace(new.status,'_',' ')||'. View the related session for details.',jsonb_build_object('tab','calendar','bookingId',new.booking_id,'paymentId',new.id)),
      (new.payee_id,'payment','Payment '||replace(new.status,'_',' '),'Payment status: '||replace(new.status,'_',' ')||'. View your earnings for details.',jsonb_build_object('tab','earnings','paymentId',new.id));
  return null;
end; $$;
revoke all on function private.payment_notification() from public,anon,authenticated;
create trigger payment_account_notifications after insert or update on public.payments for each row execute function private.payment_notification();

create function private.review_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if not new.is_published then return null; end if;
  if tg_op='UPDATE' and old.is_published and row(old.rating,old.body) is not distinct from row(new.rating,new.body) then return null; end if;
  insert into public.notifications(user_id,kind,title,body,data) values(new.tutor_id,'review','Student feedback received','A student left a '||new.rating||'-star review for a completed lesson.',jsonb_build_object('tab','students','studentId',new.student_id,'bookingId',new.booking_id));
  return null;
end; $$;
revoke all on function private.review_notification() from public,anon,authenticated;
create trigger review_account_notification after insert or update on public.reviews for each row execute function private.review_notification();

create function private.enquiry_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
    select id,'enquiry','New website enquiry','A new '||new.category||' enquiry is ready in the company inbox.',jsonb_build_object('tab','enquiries','enquiryId',new.id)
    from public.profiles where role in ('admin','superUser');
  return null;
end; $$;
revoke all on function private.enquiry_notification() from public,anon,authenticated;
create trigger enquiry_admin_notifications after insert on public.contact_enquiries for each row execute function private.enquiry_notification();

notify pgrst,'reload schema';


CREATE OR REPLACE FUNCTION public.my_tutoring_workspace()
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
        'status',b.status,'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'demo',sp.demo_dataset is not null) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.payments p where caller in (p.payer_id,p.payee_id)),'[]'::jsonb),
    'conversations',coalesce((select jsonb_agg(row_data order by updated_at desc) from (
      select c.updated_at,jsonb_build_object('id',c.id,'booking_id',c.booking_id,'last_read_at',own.last_read_at,
        'participants',(select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(tp.public_name,concat_ws(' ',p.first_name,p.last_name)),'role',p.role))
          from public.conversation_members cm join public.profiles p on p.id=cm.user_id left join public.tutor_profiles tp on tp.user_id=p.id
          where cm.conversation_id=c.id and cm.user_id<>caller),
        'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from (
          select id,sender_id,body,created_at from public.messages where conversation_id=c.id and deleted_at is null order by created_at desc limit 200
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
$function$
