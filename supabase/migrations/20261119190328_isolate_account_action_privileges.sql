-- Expose invoker wrappers only. Privileged bodies remain in the private schema
-- and retain their owner/MFA/participant checks and restricted execute grants.
alter function public.promote_platform_admin(uuid,timestamptz) set schema private;
alter function public.record_booking_action_failure(uuid,text,uuid) set schema private;
alter function public.my_logout_summary() set schema private;

create function public.promote_platform_admin(_user uuid,_expected timestamptz)
returns jsonb language sql security invoker set search_path='' as $$
 select private.promote_platform_admin(_user,_expected);
$$;
create function public.record_booking_action_failure(_booking uuid,_action text,_request uuid)
returns uuid language sql security invoker set search_path='' as $$
 select private.record_booking_action_failure(_booking,_action,_request);
$$;
create function public.my_logout_summary()
returns jsonb language sql security invoker set search_path='' as $$
 select private.my_logout_summary();
$$;
revoke all on function public.promote_platform_admin(uuid,timestamptz),public.record_booking_action_failure(uuid,text,uuid),public.my_logout_summary() from public,anon,authenticated;
grant execute on function public.promote_platform_admin(uuid,timestamptz),public.record_booking_action_failure(uuid,text,uuid),public.my_logout_summary() to authenticated;
notify pgrst,'reload schema';
