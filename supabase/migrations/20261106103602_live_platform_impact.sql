-- Public figures contain fixed aggregates only. Demo accounts never contribute.
create function public.platform_impact() returns jsonb
language sql stable security definer set search_path = '' as $$
  with members as (
    select p.id,p.role,u.last_sign_in_at
    from public.profiles p join auth.users u on u.id=p.id
    where p.role in ('student','tutor') and p.demo_dataset is null
  ), tutors as (
    select t.user_id,t.is_approved,t.is_accepting_students,t.city
    from public.tutor_profiles t join members m on m.id=t.user_id and m.role='tutor'
    where t.demo_dataset is null
  ), lessons as (
    select b.id,b.student_id,b.status,b.duration_minutes
    from public.bookings b join members s on s.id=b.student_id and s.role='student'
    join tutors t on t.user_id=b.tutor_id
    where b.status in ('completed','no_show') and b.ends_at<=now()
  ), delivery as (
    select count(*) filter(where status='completed') as completed,count(*) as concluded,
      count(distinct student_id) filter(where status='completed') as students,
      coalesce(sum(duration_minutes) filter(where status='completed'),0) as minutes
    from lessons
  )
  select jsonb_build_object(
    'users',(select count(*) from members),
    'activeUsers',(select count(*) from members where last_sign_in_at>=now()-interval '30 days'),
    'registeredStudents',(select count(*) from members where role='student'),
    'studentsTutored',delivery.students,
    'activeTutors',(select count(*) from tutors t join members m on m.id=t.user_id
      where t.is_approved and m.last_sign_in_at>=now()-interval '30 days'),
    'publishedTutors',(select count(*) from tutors where is_approved and is_accepting_students),
    'tutorCities',(select count(distinct nullif(lower(btrim(city)),'')) from tutors where is_approved and is_accepting_students),
    'publishedSubjects',(select count(*) from public.subjects s
      where s.is_active and exists(select 1 from public.tutor_subjects ts join tutors t on t.user_id=ts.tutor_id
        where ts.subject_id=s.id and t.is_approved and t.is_accepting_students)),
    'averageRating',(select round(avg(r.rating),1) from public.reviews r join lessons l on l.id=r.booking_id
      where r.is_published and l.status='completed'),
    'hoursTutored',round(delivery.minutes / 60.0,1),
    'completionRate',round(delivery.completed*100.0/nullif(delivery.concluded,0),1),
    'releasedTutorEarnings',(select coalesce(sum(p.amount-p.platform_fee),0)
      from private.lesson_funds f join public.payments p on p.id=f.payment_id join lessons l on l.id=f.booking_id
      where f.state='released' and p.status='paid' and p.provider<>'demo' and l.status='completed'),
    'openPositions',(select count(*) from public.career_openings
      where status='published' and (closes_on is null or closes_on>=(now() at time zone 'Africa/Johannesburg')::date))
  ) from delivery;
$$;
revoke all on function public.platform_impact() from public,anon,authenticated;
grant execute on function public.platform_impact() to anon,authenticated;

create function public.admin_active_accounts() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  return (select jsonb_build_object(
    'live',count(*) filter (where p.demo_dataset is null),
    'all',count(*)
  ) from public.profiles p join auth.users u on u.id=p.id
  where u.last_sign_in_at>=now()-interval '30 days');
end;
$$;
revoke all on function public.admin_active_accounts() from public,anon,authenticated;
grant execute on function public.admin_active_accounts() to authenticated;

create or replace function public.my_account_billing() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype; account_role text;
begin
  perform private.assert_platform_available();
  item := private.sync_membership(actor);
  select role into account_role from public.profiles where id=actor;
  return jsonb_build_object(
    'membership',to_jsonb(item)-'owner',
    'lesson_credit_allowance_cents',case when account_role='student' then private.lesson_credit_allowance_cents() end,
    'lesson_credits',case when account_role='student' then private.lesson_credit_balance(actor) end,
    'credit_purchases',case when account_role='student' then coalesce((
      select jsonb_agg(to_jsonb(purchase) order by created_at desc,id desc) from (
        select e.id,e.created_at,e.amount_cents,e.lesson_credits_awarded as credits,p.name as plan_name
        from private.billing_events e join private.billing_plans p on p.id=e.target
        where e.owner=actor and e.lesson_credits_awarded>0 order by e.created_at desc,e.id desc limit 20
      ) purchase
    ),'[]'::jsonb) end,
    'plans',(select jsonb_agg(to_jsonb(p) order by price_cents) from private.billing_plans p where p.audience=account_role),
    'released_month_cents',case when account_role='tutor' then (
      select coalesce(sum(round((p.amount-p.platform_fee)*100)),0)
      from private.lesson_funds f join public.payments p on p.id=f.payment_id
      where p.payee_id=actor and f.state='released' and p.status='paid' and p.provider<>'demo'
        and f.settled_at>=date_trunc('month',now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg'
    ) end,
    'payout_balance_cents',case when account_role='tutor' then private.payout_balance(actor) else 0 end,
    'events',coalesce((select jsonb_agg(to_jsonb(e)-'owner'-'request_id' order by created_at desc,id desc) from
      (select * from private.billing_events where owner=actor order by created_at desc,id desc limit 50) e),'[]'::jsonb),
    'lessons',coalesce((select jsonb_agg(to_jsonb(l) order by starts_at desc) from (
      select b.id,b.starts_at,s.name as subject,b.status,f.state,p.amount,p.platform_fee,f.source,
        case when actor=b.student_id then f.top_up_cents end as top_up_cents,p.paid_at
      from public.bookings b left join public.subjects s on s.id=b.subject_id
      join private.lesson_funds f on f.booking_id=b.id join public.payments p on p.id=f.payment_id
      where actor=b.student_id or (actor=b.tutor_id and (f.top_up_cents=0 or p.paid_at is not null))
      order by b.starts_at desc,b.id limit 50
    ) l),'[]'::jsonb)
  );
end;
$$;
