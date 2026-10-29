-- Public aggregates only: never expose booking/student records to visitors.
alter table public.tutor_profiles add column first_approved_at timestamptz;
update public.tutor_profiles set first_approved_at=created_at where is_approved;
create function private.track_tutor_first_approval() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if TG_OP='INSERT' then
    new.first_approved_at:=case when new.is_approved then now() else null end;
  else
    new.first_approved_at:=coalesce(old.first_approved_at,case when new.is_approved then now() end);
  end if;
  return new;
end; $$;
revoke all on function private.track_tutor_first_approval() from public,anon,authenticated;
create trigger tutor_first_approval before insert or update on public.tutor_profiles
  for each row execute function private.track_tutor_first_approval();

create table public.tutor_public_stats (
  tutor_id uuid primary key references public.tutor_profiles(user_id) on delete cascade,
  completed_sessions integer not null default 0,
  review_count integer not null default 0,
  reviewed_students integer not null default 0,
  average_rating numeric,
  updated_at timestamptz not null default now()
);
alter table public.tutor_public_stats enable row level security;
revoke all on public.tutor_public_stats from public,anon,authenticated;
grant select on public.tutor_public_stats to anon,authenticated;
create policy "Discoverable tutor aggregates are public" on public.tutor_public_stats for select to anon,authenticated
  using(exists(select 1 from public.tutor_profiles tp where tp.user_id=tutor_id and tp.is_approved and tp.is_accepting_students));

create function private.refresh_tutor_public_stats(_id uuid) returns void
language sql security definer set search_path='' as $$
  insert into public.tutor_public_stats(tutor_id,completed_sessions,review_count,reviewed_students,average_rating)
  select tp.user_id,
    (select count(*)::int from public.bookings b where b.tutor_id=tp.user_id and b.status='completed'),
    count(r.id)::int,count(distinct r.student_id)::int,avg(r.rating)
  from public.tutor_profiles tp
  left join (public.reviews r join public.bookings b on b.id=r.booking_id and b.tutor_id=r.tutor_id
    and b.student_id=r.student_id and b.status='completed') on r.tutor_id=tp.user_id and r.is_published
  where tp.user_id=_id group by tp.user_id
  on conflict(tutor_id) do update set completed_sessions=excluded.completed_sessions,
    review_count=excluded.review_count,reviewed_students=excluded.reviewed_students,
    average_rating=excluded.average_rating,updated_at=now();
$$;
revoke all on function private.refresh_tutor_public_stats(uuid) from public,anon,authenticated;
create function private.on_tutor_stats_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- Serialize recalculation per tutor to prevent concurrent events losing counts.
  if TG_OP<>'DELETE' then
    perform 1 from public.tutor_profiles where user_id=new.tutor_id for update;
    perform private.refresh_tutor_public_stats(new.tutor_id);
  end if;
  if TG_OP<>'INSERT' then
    if TG_OP='DELETE' or old.tutor_id is distinct from new.tutor_id then
      perform 1 from public.tutor_profiles where user_id=old.tutor_id for update;
      perform private.refresh_tutor_public_stats(old.tutor_id);
    end if;
  end if;
  return null;
end; $$;
revoke all on function private.on_tutor_stats_change() from public,anon,authenticated;
create trigger booking_public_stats after insert or update or delete on public.bookings
  for each row execute function private.on_tutor_stats_change();
create trigger review_public_stats after insert or update or delete on public.reviews
  for each row execute function private.on_tutor_stats_change();
do $$ declare tutor_id uuid; begin
  for tutor_id in select user_id from public.tutor_profiles loop
    perform private.refresh_tutor_public_stats(tutor_id);
  end loop;
end; $$;

create or replace view public.tutor_directory with (security_invoker=true) as
select tp.user_id as id,tp.public_name,tp.bio,tp.city,tp.province,tp.qualification,tp.institution,tp.year_completed,
  tp.certifications,tp.years_experience,tp.teaching_style,tp.student_age_groups,tp.availability_slots,tp.teaching_modes,
  tp.hourly_rate,tp.students_per_session,tp.is_featured,tp.avatar_url,tp.demo_dataset,tp.updated_at,
  coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'aliases',s.aliases) order by s.name)
    from public.tutor_subjects ts join public.subjects s on s.id=ts.subject_id and s.is_active where ts.tutor_id=tp.user_id),'[]'::jsonb) as subjects,
  coalesce(stats.review_count,0) as review_count,round(stats.average_rating,1) as rating,
  coalesce(stats.completed_sessions,0) as completed_sessions,coalesce(stats.reviewed_students,0) as reviewed_students,
  tp.first_approved_at,
  coalesce(stats.average_rating>=4.8 and stats.reviewed_students>=5 and stats.completed_sessions>=10
    and tp.first_approved_at<=now()-interval '30 days',false) as is_top_rated,
  coalesce(tp.first_approved_at>now()-interval '90 days' and coalesce(stats.completed_sessions,0)<10,false) as is_new
from public.tutor_profiles tp left join public.tutor_public_stats stats on stats.tutor_id=tp.user_id
where tp.is_approved and tp.is_accepting_students;
notify pgrst,'reload schema';
