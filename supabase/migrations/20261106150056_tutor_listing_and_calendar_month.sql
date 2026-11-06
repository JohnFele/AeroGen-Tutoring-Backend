-- Owner-only edits to the mutable public teaching profile.
create function public.save_my_tutor_listing(_details jsonb,_expected_updated_at timestamptz)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); current_listing public.tutor_profiles; edited public.tutor_profiles;
begin
  perform private.assert_platform_available();
  perform 1 from public.profiles where id=actor and role='tutor' for update;
  if not found then raise exception 'Tutor access required.' using errcode='42501'; end if;
  select * into current_listing from public.tutor_profiles where user_id=actor for update;
  if not found or not current_listing.is_approved then raise exception 'Tutor approval required.' using errcode='42501'; end if;
  if _expected_updated_at is distinct from current_listing.updated_at then
    raise exception 'Your teaching profile changed. Reload it before saving.' using errcode='PT409';
  end if;
  if jsonb_typeof(_details) is distinct from 'object' then
    raise exception 'Enter valid teaching details.' using errcode='22023';
  end if;
  if exists (select 1 from jsonb_object_keys(_details) as field(key) where key not in
    ('public_name','bio','city','province','teaching_style','years_experience','teaching_modes','hourly_rate','students_per_session')) then
    raise exception 'Only public teaching details can be changed here.' using errcode='22023';
  end if;
  edited := jsonb_populate_record(current_listing,_details);
  if length(btrim(coalesce(edited.public_name,''))) not between 2 and 120
    or edited.bio is null or length(edited.bio)>2000 or length(coalesce(edited.teaching_style,''))>2000
    or length(coalesce(edited.city,''))>150
    or edited.hourly_rate is null or edited.hourly_rate <= 0 or edited.hourly_rate::text in ('NaN','Infinity','-Infinity')
    or (edited.years_experience is not null and (edited.years_experience not between 0 and 99.9 or edited.years_experience::text='NaN'))
    or coalesce(edited.students_per_session,'') not in ('1','2-4','5-8','9+')
    or coalesce(cardinality(edited.teaching_modes),0) not between 1 and 2
    or not (edited.teaching_modes <@ array['online','in-person']::text[])
    or cardinality(edited.teaching_modes) <> (select count(distinct mode) from unnest(edited.teaching_modes) as modes(mode))
    or (edited.province is not null and edited.province not in ('Eastern Cape','Free State','Gauteng','KwaZulu-Natal','Limpopo','Mpumalanga','Northern Cape','North West','Western Cape'))
    or ('in-person'=any(edited.teaching_modes) and (nullif(btrim(edited.city),'') is null or edited.province is null)) then
    raise exception 'Check your public name, lesson rate, formats, group size and teaching area.' using errcode='22023';
  end if;
  update public.tutor_profiles
  set public_name=btrim(edited.public_name),bio=btrim(edited.bio),city=nullif(btrim(edited.city),''),
      province=edited.province,teaching_style=nullif(btrim(edited.teaching_style),''),
      years_experience=edited.years_experience,teaching_modes=edited.teaching_modes,
      hourly_rate=edited.hourly_rate,students_per_session=edited.students_per_session
  where user_id=actor returning updated_at into edited.updated_at;
  return edited.updated_at;
exception
  when data_exception then
    if sqlstate='22023' then raise; end if;
    raise exception 'Enter valid teaching details.' using errcode='22023';
end;
$$;
revoke all on function public.save_my_tutor_listing(jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.save_my_tutor_listing(jsonb,timestamptz) to authenticated;

-- Fetch a single calendar month without making a request for each date.
create function public.my_booking_month(_month date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := private.billing_account(); tutor boolean; month_start date; month_end date;
begin
  perform private.assert_platform_available();
  if _month is null or not isfinite(_month) then raise exception 'Choose a valid month.' using errcode='22023'; end if;
  select role='tutor' into tutor from public.profiles where id=actor;
  month_start := date_trunc('month',_month::timestamp)::date;
  month_end := (month_start+interval '1 month')::date;
  return coalesce((select jsonb_agg(jsonb_build_object('date',d.day,'mode',
    case when o.day is null then 'weekly' when o.start_minute is null then 'closed' else 'custom' end,
    'hours',to_jsonb(h)) order by d.day)
    from (select month_start+i as day from generate_series(0,month_end-month_start-1) as g(i)) d
    left join private.booking_day_overrides o on o.owner=actor and o.day=d.day
    left join lateral private.booking_day_hours(actor,d.day,tutor) h on true),'[]'::jsonb);
end;
$$;
revoke all on function public.my_booking_month(date) from public,anon,authenticated;
grant execute on function public.my_booking_month(date) to authenticated;
notify pgrst,'reload schema';
