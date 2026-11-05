begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
values
  ('ac000000-0000-4000-8000-000000000001','signup-review@example.test','{"firstName":"Test","lastName":"Learner","phone":"+27821234567","location":"Johannesburg"}','{"provider":"email"}'),
  ('ac000000-0000-4000-8000-000000000002','signup-other@example.test','{}','{"provider":"email"}');

set local role authenticated;
select set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',true);
do $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and profile_setup_pending) then
    raise exception 'New profiles must review even if prefilled';
  end if;
  begin
    update public.profiles set profile_setup_pending=false where id=auth.uid();
    raise exception 'An unverified account skipped profile review';
  exception when sqlstate '22023' then null;
  end;
  update public.profiles set profile_setup_pending=false where id='ac000000-0000-4000-8000-000000000002';
  if found then raise exception 'An account changed another account’s review status'; end if;
end;
$$;

reset role;
update auth.users set email_confirmed_at=now() where id='ac000000-0000-4000-8000-000000000001';
set local role authenticated;
do $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and is_verified and profile_setup_pending) then
    raise exception 'Verification should preserve the outstanding review';
  end if;
  begin
    update public.profiles set phone=null,profile_setup_pending=false where id=auth.uid();
    raise exception 'A review was completed without the required details';
  exception when sqlstate '22023' then null;
  end;
  update public.profiles set profile_setup_pending=false where id=auth.uid();
  if not exists(select 1 from public.profiles where id=auth.uid() and not profile_setup_pending) then
    raise exception 'A verified owner could not complete profile review';
  end if;
end;
$$;

rollback;
