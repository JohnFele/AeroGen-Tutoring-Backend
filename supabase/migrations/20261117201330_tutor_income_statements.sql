create function public.my_tutor_earnings_statement(_from date, _to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  actor uuid := private.billing_account();
  issued timestamptz := statement_timestamp();
  period_start timestamptz;
  period_end timestamptz;
  result jsonb;
begin
  perform private.assert_platform_available();
  if not exists(select 1 from public.profiles where id=actor and role='tutor') then
    raise exception 'Use your own tutor account to download an earnings statement.' using errcode='42501';
  end if;
  if _from is null or _to is null or not isfinite(_from) or not isfinite(_to)
    or _from > _to or _to > (issued at time zone 'Africa/Johannesburg')::date
    or date_trunc('month',_to::timestamp) >= date_trunc('month',_from::timestamp) + interval '12 months' then
    raise exception 'Choose a valid statement period of up to 12 calendar months ending today or earlier.' using errcode='22023';
  end if;
  period_start := _from::timestamp at time zone 'Africa/Johannesburg';
  period_end := least((_to+1)::timestamp at time zone 'Africa/Johannesburg', issued);

  with ledger as materialized (
    select coalesce(f.settled_at,p.paid_at,p.created_at) as recorded_at,
      round(p.amount*100)::bigint as gross_cents,
      round(p.platform_fee*100)::bigint as fee_cents,
      round((p.amount-p.platform_fee)*100)::bigint as net_cents,
      0::bigint as payout_cents, f.settled_at is null as estimated_date
    from public.payments p join private.lesson_funds f on f.payment_id=p.id
    where p.payee_id=actor and p.status='paid' and p.currency='ZAR' and f.state='released'
      and coalesce(f.settled_at,p.paid_at,p.created_at) < period_end
    union all
    select created_at,0,0,0,amount_cents,false from private.billing_events
    where owner=actor and kind='payout' and status='succeeded' and created_at<period_end
  ), summary as (
    select
      coalesce(sum(net_cents-payout_cents) filter(where recorded_at<period_start),0) as opening_cents,
      coalesce(sum(gross_cents) filter(where recorded_at>=period_start),0) as gross_cents,
      coalesce(sum(fee_cents) filter(where recorded_at>=period_start),0) as fee_cents,
      coalesce(sum(net_cents) filter(where recorded_at>=period_start),0) as net_cents,
      coalesce(sum(payout_cents) filter(where recorded_at>=period_start),0) as payout_cents,
      coalesce(sum(net_cents-payout_cents),0) as closing_cents,
      count(*) filter(where estimated_date) as estimated_release_dates
    from ledger
  ), months as (
    select generate_series(date_trunc('month',_from::timestamp),date_trunc('month',_to::timestamp),interval '1 month') as month
  ), monthly as (
    select m.month,
      coalesce(sum(l.gross_cents),0) as gross_cents,
      coalesce(sum(l.fee_cents),0) as fee_cents,
      coalesce(sum(l.net_cents),0) as net_cents,
      coalesce(sum(l.payout_cents),0) as payout_cents
    from months m left join ledger l on l.recorded_at>=greatest(period_start,m.month at time zone 'Africa/Johannesburg')
      and l.recorded_at<least(period_end,(m.month+interval '1 month') at time zone 'Africa/Johannesburg')
    group by m.month
  ), balances as (
    select monthly.*, summary.opening_cents+sum(monthly.net_cents-monthly.payout_cents) over(order by month) as closing_cents
    from monthly cross join summary
  )
  select jsonb_build_object(
    'reference','AGS-'||to_char(issued at time zone 'Africa/Johannesburg','YYYYMMDDHH24MISS')||'-'||upper(substr(md5(actor::text||_from::text||_to::text||issued::text),1,8)),
    'issued_at',issued,'from',_from,'to',_to,'currency','ZAR','simulation',true,
    'holder',(select jsonb_build_object('account_id',id,'name',nullif(btrim(concat_ws(' ',first_name,last_name)),''),
      'email',email,'location',nullif(btrim(location),''),'member_since',created_at)
      from public.profiles where id=actor),
    'issuer',(select jsonb_build_object('operator',operator_name,'email',email,'phone',phone,
      'address',nullif(btrim(business_address),''),'registration',nullif(btrim(registration_number),''))
      from public.site_contact_settings where id),
    'summary',to_jsonb(summary),
    'months',(select jsonb_agg(jsonb_build_object('month',month::date,'gross_cents',gross_cents,'fee_cents',fee_cents,
      'net_cents',net_cents,'payout_cents',payout_cents,'closing_cents',closing_cents) order by month) from balances)
  ) into result from summary;
  return result;
end;
$$;
revoke all on function public.my_tutor_earnings_statement(date,date) from public,anon;
grant execute on function public.my_tutor_earnings_statement(date,date) to authenticated;

