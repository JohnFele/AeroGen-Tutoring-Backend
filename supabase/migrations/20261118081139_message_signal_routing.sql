alter table public.workspace_signals add column activity_version bigint not null default 0,
 add column message_version bigint not null default 0,add column last_event text not null default 'activity' check(last_event in ('activity','message'));
create or replace function private.bump_workspace(_user uuid) returns void language sql security definer set search_path='' as $$
 insert into public.workspace_signals(user_id,version,activity_version,last_event,updated_at)
 select _user,1,1,'activity',clock_timestamp() where exists(select 1 from public.profiles where id=_user)
 on conflict(user_id) do update set version=public.workspace_signals.version+1,activity_version=public.workspace_signals.activity_version+1,last_event='activity',updated_at=excluded.updated_at;
$$;
create function private.bump_message_signal(_user uuid) returns void language sql security definer set search_path='' as $$
 insert into public.workspace_signals(user_id,version,message_version,last_event,updated_at)
 select _user,1,1,'message',clock_timestamp() where exists(select 1 from public.profiles where id=_user)
 on conflict(user_id) do update set version=public.workspace_signals.version+1,message_version=public.workspace_signals.message_version+1,last_event='message',updated_at=excluded.updated_at;
$$;
revoke all on function private.bump_message_signal(uuid) from public,anon,authenticated;
create or replace function private.notification_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare recipient uuid:=case when tg_op='DELETE' then old.user_id else new.user_id end;
begin
 if tg_op='UPDATE' and old is not distinct from new then return null; end if;
 if (case when tg_op='DELETE' then old.kind else new.kind end)='message' then perform private.bump_message_signal(recipient);
 else perform private.bump_workspace(recipient); end if;
 return null;
end; $$;
create or replace function private.message_workspace_changed() returns trigger language plpgsql security definer set search_path='' as $$
declare member record;
begin
 for member in select user_id from public.conversation_members where conversation_id=new.conversation_id order by user_id loop perform private.bump_message_signal(member.user_id); end loop;
 return null;
end; $$;
create or replace function private.conversation_read_signal() returns trigger language plpgsql security definer set search_path='' as $$
declare member record;
begin
 if new.last_read_at is not distinct from old.last_read_at then return null; end if;
 for member in select user_id from public.conversation_members where conversation_id=new.conversation_id order by user_id loop perform private.bump_message_signal(member.user_id); end loop;
 return null;
end; $$;
create function public.my_notification_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=(select auth.uid());
begin
 perform private.assert_platform_available();
 if actor is null then raise exception 'Sign in to view notifications.' using errcode='42501'; end if;
 return jsonb_build_object('notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc,n.id desc) from
 (select * from public.notifications where user_id=actor order by created_at desc,id desc limit 50)n),'[]'),
 'notification_unread_count',(select count(*) from public.notifications where user_id=actor and read_at is null),
 'notification_revision',coalesce((select version from public.workspace_signals where user_id=actor),0));
end; $$;
revoke all on function public.my_notification_summary() from public,anon,authenticated;
grant execute on function public.my_notification_summary() to authenticated;

create or replace function public.set_conversation_block(_id uuid,_blocked boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); member record;
begin
 perform private.assert_platform_available(); perform private.conversation_access(_id,actor);
 if _blocked is null then raise exception 'Choose whether to block this conversation.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,782));
 if _blocked then insert into private.messaging_blocks(owner,conversation_id) values(actor,_id) on conflict do nothing;
 else delete from private.messaging_blocks where owner=actor and conversation_id=_id; end if;
 for member in select user_id from public.conversation_members where conversation_id=_id loop perform private.bump_message_signal(member.user_id); end loop;
 return private.conversation_access(_id,actor);
end; $$;
