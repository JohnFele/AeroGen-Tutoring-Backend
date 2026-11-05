alter table private.billing_events add column subscription_details jsonb;

create function public.confirm_membership_change(
  _plan text, _succeeds boolean, _request uuid, _expected_owner uuid, _expected_plan text, _expected_next_plan text,
  _expected_period_end timestamptz, _expected_due_cents integer, _expected_renewal_cents integer
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := private.billing_account();
  membership private.memberships%rowtype;
  target private.billing_plans%rowtype;
  current_name text;
  amount_due integer;
  result jsonb;
  action text;
  effective_at timestamptz;
  renewal_at timestamptz;
begin
  if actor is distinct from _expected_owner then
    raise exception 'Sign in to the account that reviewed this subscription.' using errcode = '42501';
  end if;
  perform private.assert_platform_available();
  perform private.billing_lock(actor);
  result := private.billing_replay(actor, _request, 'subscription', _plan);
  if result is not null then
    if not exists (
      select 1 from private.billing_events
      where owner = actor and request_id = _request and subscription_details is not null
    ) then
      raise exception 'This request key belongs to an earlier plan change.' using errcode = 'PT409';
    end if;
    return result;
  end if;

  select p.* into target
  from private.billing_plans p
  join public.profiles u on u.role = p.audience
  where p.id = _plan and u.id = actor
  for share of p;
  if not found or _succeeds is null then
    raise exception 'Choose a plan and payment option for your account.' using errcode = '22023';
  end if;

  membership := private.sync_membership(actor);
  amount_due := case when membership.period_end is null then target.price_cents else 0 end;
  if row(membership.plan_id, membership.next_plan_id, membership.period_end, amount_due, target.price_cents)
      is distinct from row(_expected_plan, _expected_next_plan, _expected_period_end, _expected_due_cents, _expected_renewal_cents) then
    raise exception 'Your plan or price changed. Review the updated details before confirming.' using errcode = 'PT409';
  end if;
  if (membership.plan_id = target.id and membership.next_plan_id is null) or membership.next_plan_id = target.id then
    raise exception 'This plan is already active or scheduled.' using errcode = 'PT409';
  end if;

  select name into current_name from private.billing_plans where id = membership.plan_id;
  action := case
    when membership.period_end is null then 'purchase'
    when target.price_cents = 0 then 'cancel'
    when target.id = membership.plan_id then 'keep'
    else 'change'
  end;

  result := public.change_membership(_plan, _succeeds, _request);
  if result->>'status' = 'succeeded' then
    effective_at := now();
    renewal_at := now() + interval '30 days';
  elsif result->>'status' = 'scheduled' then
    effective_at := membership.period_end;
    if target.price_cents > 0 then renewal_at := membership.period_end; end if;
  end if;

  update private.billing_events
  set subscription_details = jsonb_build_object(
    'action', action, 'plan_id', target.id, 'plan_name', target.name, 'previous_plan_name', current_name,
    'effective_at', effective_at, 'renewal_at', renewal_at, 'renewal_cents', target.price_cents
  )
  where owner = actor and id = (result->>'id')::uuid;

  return result;
end;
$$;

create function public.my_subscription_receipt(_receipt uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor uuid := private.billing_account();
  entry private.billing_events%rowtype;
begin
  select * into entry from private.billing_events
  where id = _receipt and owner = actor and kind = 'subscription' and subscription_details is not null;
  if not found then
    raise exception 'This subscription receipt is unavailable.' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'id', entry.id, 'status', entry.status, 'amount_cents', entry.amount_cents,
    'created_at', entry.created_at, 'details', entry.subscription_details
  );
end;
$$;

revoke execute on function public.confirm_membership_change(text, boolean, uuid, uuid, text, text, timestamptz, integer, integer) from public, anon;
revoke execute on function public.my_subscription_receipt(uuid) from public, anon;
grant execute on function public.confirm_membership_change(text, boolean, uuid, uuid, text, text, timestamptz, integer, integer) to authenticated;
grant execute on function public.my_subscription_receipt(uuid) to authenticated;
