create table public.site_contact_settings (
  id boolean primary key default true check(id),
  email text not null check(length(email)<=254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  phone text not null check(phone ~ '^\+[1-9][0-9]{7,14}$'),
  weekday_hours text not null check(length(weekday_hours) between 1 and 100),
  saturday_hours text not null check(length(saturday_hours) between 1 and 100),
  sunday_hours text not null check(length(sunday_hours) between 1 and 100),
  operator_name text not null check(length(operator_name) between 2 and 160),
  registration_number text not null default '' check(length(registration_number)<=80),
  business_address text not null default '' check(length(business_address)<=1000),
  privacy_email text not null check(length(privacy_email)<=254 and privacy_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  information_officer text not null default '' check(length(information_officer)<=160),
  version integer not null default 1,
  updated_at timestamptz not null default now()
);
insert into public.site_contact_settings(email,phone,weekday_hours,saturday_hours,sunday_hours,operator_name,privacy_email)
values('aerogentutoring@gmail.com','+27620882443','08:00–18:00','09:00–13:00','Closed','John Fele','aerogentutoring@gmail.com');
create table public.career_openings (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(btrim(title)) between 2 and 160),
  department text not null check(length(btrim(department)) between 2 and 100),
  employment_type text not null check(employment_type in ('Full-time','Part-time','Contract','Internship')),
  location text not null check(length(btrim(location)) between 2 and 160),
  salary text not null default '' check(length(salary)<=160),
  description text not null check(length(btrim(description)) between 20 and 8000),
  requirements text[] not null default '{}',
  status text not null default 'draft' check(status in ('draft','published','closed')),
  closes_on date,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(cardinality(requirements)<=30 and octet_length(array_to_string(requirements,''))<=6000)
);
create index career_openings_public on public.career_openings(created_at desc,id) where status='published';
create table public.contact_enquiries (
  id uuid primary key,
  first_name text not null check(length(btrim(first_name)) between 1 and 60),
  last_name text not null check(length(btrim(last_name)) between 1 and 60),
  email text not null check(length(email)<=254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  category text not null check(category in ('general','tutoring','billing','technical','partnership','careers','other')),
  message text not null check(length(btrim(message)) between 10 and 3500),
  status text not null default 'new' check(status in ('new','in_progress','resolved','spam')),
  internal_notes text not null default '' check(length(internal_notes)<=5000),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index contact_enquiries_inbox on public.contact_enquiries(status,created_at desc,id);
create index contact_enquiries_rate on public.contact_enquiries(email,created_at desc);
create table public.enquiry_replies (
  id uuid primary key,
  enquiry_id uuid not null references public.contact_enquiries(id) on delete cascade,
  admin_id uuid references public.profiles(id) on delete set null,
  message text not null check(length(btrim(message)) between 10 and 4000),
  delivery_status text not null default 'pending' check(delivery_status in ('pending','sent','failed','unknown')),
  provider_id text check(length(provider_id)<=500),
  created_at timestamptz not null default now()
);
create index enquiry_replies_thread on public.enquiry_replies(enquiry_id,created_at,id);

alter table public.site_contact_settings enable row level security;
alter table public.career_openings enable row level security;
alter table public.contact_enquiries enable row level security;
alter table public.enquiry_replies enable row level security;
revoke all on public.site_contact_settings,public.career_openings,public.contact_enquiries,public.enquiry_replies from public,anon,authenticated;
grant select on public.site_contact_settings,public.career_openings to anon,authenticated;
grant update on public.site_contact_settings to authenticated;
grant insert,update,delete on public.career_openings to authenticated;
grant select,update on public.contact_enquiries to authenticated;
grant select,insert,update on public.enquiry_replies to authenticated;
create policy "Public contact details" on public.site_contact_settings for select to anon,authenticated using(true);
create policy "Admins update contact details" on public.site_contact_settings for update to authenticated using((select private.is_platform_admin())) with check((select private.is_platform_admin()));
create policy "Published current openings" on public.career_openings for select to anon,authenticated using(status='published' and (closes_on is null or closes_on>=(now() at time zone 'Africa/Johannesburg')::date));
create policy "Admins manage all openings" on public.career_openings for all to authenticated using((select private.is_platform_admin())) with check((select private.is_platform_admin()));
create policy "Admins read enquiries" on public.contact_enquiries for select to authenticated using((select private.is_platform_admin()));
create policy "Admins update enquiries" on public.contact_enquiries for update to authenticated using((select private.is_platform_admin())) with check((select private.is_platform_admin()));
create policy "Admins read replies" on public.enquiry_replies for select to authenticated using((select private.is_platform_admin()));
create policy "Admins create replies" on public.enquiry_replies for insert to authenticated with check((select private.is_platform_admin()) and admin_id=(select auth.uid()));
create policy "Admins update replies" on public.enquiry_replies for update to authenticated using((select private.is_platform_admin())) with check((select private.is_platform_admin()));

create function private.version_site_record() returns trigger language plpgsql security invoker set search_path='' as $$
begin new.version=old.version+1; new.updated_at=clock_timestamp(); return new; end; $$;
revoke all on function private.version_site_record() from public,anon,authenticated;
create trigger site_contact_version before update on public.site_contact_settings for each row execute function private.version_site_record();
create trigger career_opening_version before update on public.career_openings for each row execute function private.version_site_record();
create trigger contact_enquiry_version before update on public.contact_enquiries for each row execute function private.version_site_record();

create function private.submit_contact_enquiry(_id uuid,_first_name text,_last_name text,_email text,_category text,_message text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare previous public.contact_enquiries;
begin
  if _id is null or _first_name is null or _last_name is null or _email is null or _category is null or _message is null then raise exception 'Complete the enquiry form' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(btrim(_email)),0));
  select * into previous from public.contact_enquiries where id=_id;
  if found then
    if previous.first_name=btrim(_first_name) and previous.last_name=btrim(_last_name) and previous.email=lower(btrim(_email)) and previous.category=_category and previous.message=btrim(_message)
      then return jsonb_build_object('id',_id,'created',false); end if;
    raise exception 'Start a new enquiry before changing a submitted message' using errcode='PT409';
  end if;
  if (select count(*) from public.contact_enquiries where email=lower(btrim(_email)) and created_at>now()-interval '15 minutes')>=5 then raise exception 'Too many enquiries. Please try again later.' using errcode='PT429'; end if;
  insert into public.contact_enquiries(id,first_name,last_name,email,category,message) values(_id,btrim(_first_name),btrim(_last_name),lower(btrim(_email)),_category,btrim(_message));
  return jsonb_build_object('id',_id,'created',true);
end; $$;
revoke all on function private.submit_contact_enquiry(uuid,text,text,text,text,text) from public;
grant usage on schema private to anon;
grant execute on function private.submit_contact_enquiry(uuid,text,text,text,text,text) to anon,authenticated;
create function public.submit_contact_enquiry(_id uuid,_first_name text,_last_name text,_email text,_category text,_message text)
returns jsonb language sql security invoker set search_path='' as $$ select private.submit_contact_enquiry(_id,_first_name,_last_name,_email,_category,_message); $$;
revoke all on function public.submit_contact_enquiry(uuid,text,text,text,text,text) from public;
grant execute on function public.submit_contact_enquiry(uuid,text,text,text,text,text) to anon,authenticated;

create function public.begin_enquiry_reply(_id uuid,_enquiry_id uuid,_message text,_expected_version integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare enquiry public.contact_enquiries; reply public.enquiry_replies;
begin
  if not (select private.is_platform_admin()) then raise exception 'Administrator access required' using errcode='42501'; end if;
  select * into enquiry from public.contact_enquiries where id=_enquiry_id for update;
  if not found then raise exception 'Enquiry not found' using errcode='22023'; end if;
  select * into reply from public.enquiry_replies where id=_id;
  if found then
    if reply.enquiry_id=_enquiry_id and reply.message=btrim(_message) then return jsonb_build_object('reply',to_jsonb(reply),'created',false); end if;
    raise exception 'This reply reference has already been used' using errcode='PT409';
  end if;
  if enquiry.version is distinct from _expected_version then raise exception 'This enquiry changed. Reload it before replying.' using errcode='PT409'; end if;
  if (select count(*) from public.enquiry_replies where enquiry_id=_enquiry_id and created_at>now()-interval '1 hour')>=5 then raise exception 'Too many replies. Please try later.' using errcode='PT429'; end if;
  insert into public.enquiry_replies(id,enquiry_id,admin_id,message) values(_id,_enquiry_id,(select auth.uid()),btrim(_message)) returning * into reply;
  update public.contact_enquiries set status='in_progress' where id=_enquiry_id;
  return jsonb_build_object('reply',to_jsonb(reply),'created',true);
end; $$;
revoke all on function public.begin_enquiry_reply(uuid,uuid,text,integer) from public,anon;
grant execute on function public.begin_enquiry_reply(uuid,uuid,text,integer) to authenticated;
notify pgrst,'reload schema';
