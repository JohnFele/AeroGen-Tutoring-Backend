begin;

insert into auth.users(id, email, raw_user_meta_data, raw_app_meta_data) values
  ('bc000000-0000-4000-8000-000000000001', 'checkout.student@example.test', '{}', '{}'),
  ('bc000000-0000-4000-8000-000000000002', 'checkout.tutor@example.test', '{}', '{}'),
  ('bc000000-0000-4000-8000-000000000003', 'checkout.admin@example.test', '{}', '{}');
update public.profiles set role = 'tutor' where id = 'bc000000-0000-4000-8000-000000000002';
update public.profiles set role = 'admin' where id = 'bc000000-0000-4000-8000-000000000003';

set local role authenticated;
select set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000001', true);
do $$
declare
  purchase_key uuid := gen_random_uuid();
  result jsonb;
  purchase jsonb;
  receipt jsonb;
  cycle_end timestamptz;
begin
  begin
    perform public.confirm_membership_change('learning', true, gen_random_uuid(), gen_random_uuid(), 'payg', null, null, 179900, 179900);
    raise exception 'A different account confirmed the reviewed purchase';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.confirm_membership_change('learning', true, gen_random_uuid(), auth.uid(), 'payg', null, null, 100, 100);
    raise exception 'A stale purchase price was accepted';
  exception when sqlstate 'PT409' then null;
  end;

  result := public.confirm_membership_change('learning', false, gen_random_uuid(), auth.uid(), 'payg', null, null, 179900, 179900);
  receipt := public.my_subscription_receipt((result->>'id')::uuid);
  if receipt->>'status' is distinct from 'failed'
    or receipt->'details'->>'effective_at' is not null
    or public.my_account_billing()->'membership'->>'plan_id' is distinct from 'payg' then
    raise exception 'A declined checkout changed the membership';
  end if;

  purchase := public.confirm_membership_change('learning', true, purchase_key, auth.uid(), 'payg', null, null, 179900, 179900);
  cycle_end := (public.my_account_billing()->'membership'->>'period_end')::timestamptz;
  receipt := public.my_subscription_receipt((purchase->>'id')::uuid);
  if receipt->>'status' is distinct from 'succeeded'
    or (receipt->'details'->>'renewal_at')::timestamptz is distinct from cycle_end
    or public.confirm_membership_change('learning', true, purchase_key, auth.uid(), 'payg', null, null, 179900, 179900) is distinct from purchase then
    raise exception 'The payment receipt or replay is incorrect';
  end if;
  perform set_config('test.checkout_receipt', purchase->>'id', true);

  result := public.confirm_membership_change('premium', true, gen_random_uuid(), auth.uid(), 'learning', null, cycle_end, 0, 349900);
  if public.my_subscription_receipt((result->>'id')::uuid)->'details'->>'action' is distinct from 'change' then
    raise exception 'The scheduled change receipt is incorrect';
  end if;
  begin
    perform public.confirm_membership_change('payg', true, gen_random_uuid(), auth.uid(), 'learning', null, cycle_end, 0, 0);
    raise exception 'A cancellation quote overwrote a newer change';
  exception when sqlstate 'PT409' then null;
  end;
  result := public.confirm_membership_change('learning', true, gen_random_uuid(), auth.uid(), 'learning', 'premium', cycle_end, 0, 179900);
  if public.my_subscription_receipt((result->>'id')::uuid)->'details'->>'action' is distinct from 'keep' then
    raise exception 'The receipt for removing the scheduled change is incorrect';
  end if;

  result := public.confirm_membership_change('payg', true, gen_random_uuid(), auth.uid(), 'learning', null, cycle_end, 0, 0);
  receipt := public.my_subscription_receipt((result->>'id')::uuid);
  if receipt->'details'->>'action' is distinct from 'cancel'
    or (receipt->'details'->>'effective_at')::timestamptz is distinct from cycle_end
    or receipt->'details'->>'renewal_at' is not null
    or public.my_account_billing()->'membership'->>'plan_id' is distinct from 'learning'
    or public.my_account_billing()->'membership'->>'next_plan_id' is distinct from 'payg' then
    raise exception 'Cancellation changed paid access early or recorded the wrong dates';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000002', true);
do $$
declare result jsonb;
begin
  begin
    perform public.my_subscription_receipt(current_setting('test.checkout_receipt')::uuid);
    raise exception 'A different account read the receipt';
  exception when sqlstate 'PT404' then null;
  end;
  result := public.confirm_membership_change('pro', true, gen_random_uuid(), auth.uid(), 'basic', null, null, 19900, 19900);
  if public.my_subscription_receipt((result->>'id')::uuid)->'details'->>'plan_name' is distinct from 'Pro Tutor' then
    raise exception 'Tutor checkout recorded the wrong plan';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'bc000000-0000-4000-8000-000000000003', true);
do $$
begin
  perform public.confirm_membership_change('learning', true, gen_random_uuid(), auth.uid(), 'payg', null, null, 179900, 179900);
  raise exception 'An admin was allowed to confirm a membership';
exception when insufficient_privilege then null;
end;
$$;

rollback;
