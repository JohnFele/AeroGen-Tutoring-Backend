begin;
create temporary table discovery_fixture as
select tp.user_id tutor_id,s.completed_sessions,s.review_count,s.reviewed_students
from public.tutor_profiles tp join public.tutor_public_stats s on s.tutor_id=tp.user_id
where tp.demo_dataset='aerogen-live-demo-v1' and tp.is_approved order by tp.user_id limit 1;
create temporary table discovery_bookings(id uuid);
with inserted as (
  insert into public.bookings(student_id,tutor_id,subject_id,starts_at,ends_at,status,teaching_mode,session_type,duration_minutes,hourly_rate,total_amount)
  select b.student_id,f.tutor_id,b.subject_id,now()-interval '2 days'+n*interval '2 hours',now()-interval '2 days'+n*interval '2 hours'+interval '1 hour',
    'completed',b.teaching_mode,b.session_type,60,b.hourly_rate,b.hourly_rate
  from discovery_fixture f cross join generate_series(1,10) n cross join lateral
    (select * from public.bookings where tutor_id=f.tutor_id order by id limit 1) b returning id
) insert into discovery_bookings select id from inserted;
insert into public.reviews(booking_id,student_id,tutor_id,rating,body,is_published)
  select b.id,b.student_id,b.tutor_id,5,'Transaction-only ranking test',true
  from public.bookings b join discovery_bookings f on f.id=b.id;
do $$ begin
  if not exists(select 1 from discovery_fixture) then raise exception 'Demo fixture missing'; end if;
  if not exists(select 1 from discovery_fixture f join public.tutor_directory d on d.id=f.tutor_id
    where d.completed_sessions=f.completed_sessions+10 and d.review_count=f.review_count+10
      and d.reviewed_students<=f.reviewed_students+1 and not d.is_new and not d.is_top_rated)
    then raise exception 'Completion/review counters, unique students, New expiry or Top rated guard failed'; end if;
end; $$;
update public.reviews set is_published=false where booking_id in(select id from discovery_bookings);
do $$ begin
  if not exists(select 1 from discovery_fixture f join public.tutor_directory d on d.id=f.tutor_id where d.review_count=f.review_count)
    then raise exception 'Unpublishing reviews must remove their rating contribution'; end if;
end; $$;
update public.bookings set status='cancelled' where id in(select id from discovery_bookings);
do $$ begin
  if not exists(select 1 from discovery_fixture f join public.tutor_directory d on d.id=f.tutor_id where d.completed_sessions=f.completed_sessions and d.is_new)
    then raise exception 'Cancelled sessions must not count'; end if;
  if has_table_privilege('anon','public.tutor_public_stats','INSERT') or has_table_privilege('authenticated','public.tutor_public_stats','UPDATE')
    or has_function_privilege('authenticated','private.refresh_tutor_public_stats(uuid)','EXECUTE')
    then raise exception 'Clients must not write badge evidence'; end if;
end; $$;
set local role anon;
select 'Anonymous directory and public aggregates readable' as check_name,count(*) as tutors from public.tutor_directory;
rollback;
