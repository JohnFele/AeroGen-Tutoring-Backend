begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('be000000-0000-4000-8000-000000000001','desk.student@example.test','{}','{}'),
  ('be000000-0000-4000-8000-000000000002','desk.tutor@example.test','{}','{}'),
  ('be000000-0000-4000-8000-000000000003','desk.admin@example.test','{}','{}'),
  ('be000000-0000-4000-8000-000000000004','desk.other.admin@example.test','{}','{}');
update public.profiles set role='tutor' where id='be000000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id in ('be000000-0000-4000-8000-000000000003','be000000-0000-4000-8000-000000000004');

set local role authenticated;
select set_config('request.jwt.claim.sub','be000000-0000-4000-8000-000000000001',true);
do $$
declare
  request uuid := gen_random_uuid();
  result jsonb;
  legacy jsonb;
begin
  result := public.create_detailed_support_ticket('billing','subscription','Subscription question','Please help me understand my subscription.',request);
  if result->>'case_reference' !~ ('^BIL-STU-SUB-'||to_char(now() at time zone 'UTC','YYYYMMDD"T"HH24MISS"Z"')||'-[0-9]+$')
    or result->>'reference' not like 'AG-%' or result->>'category_reference' not like 'BIL-%'
    or result is distinct from public.create_detailed_support_ticket('billing','subscription','Subscription question','Please help me understand my subscription.',request)
    or public.my_support_ticket(request)->>'reporter_kind' is distinct from 'student'
    or public.my_support_ticket(request)->>'issue_code' is distinct from 'SUB' then
    raise exception 'Student reference, classification, or replay is incorrect';
  end if;
  legacy := public.create_support_ticket('billing','General billing','This legacy request has no issue type.',gen_random_uuid());
  if legacy->>'case_reference' not like 'BIL-STU-GEN-%' then raise exception 'Legacy support guessed a specific issue'; end if;
  begin
    perform public.create_detailed_support_ticket('billing','payout','Payout question','Please help me understand my tutor payout.',gen_random_uuid());
    raise exception 'A student selected the tutor payout issue';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_detailed_support_ticket('billing','bug','Invalid issue','This issue does not belong under billing.',gen_random_uuid());
    raise exception 'An invalid issue was accepted for the category';
  exception when invalid_parameter_value then null; end;
  if exists(select id from public.booking_safety_cases) then raise exception 'Participant bypassed the private support API'; end if;
  perform set_config('test.desk_ticket',request::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','be000000-0000-4000-8000-000000000002',true);
do $$
declare result jsonb;
begin
  result := public.create_detailed_support_ticket('account','access','Access question','Please help me with access to my account.',gen_random_uuid());
  if result->>'case_reference' not like 'ACC-TUT-ACC-%' then raise exception 'Tutor reference is incorrect'; end if;
  begin
    perform public.my_support_ticket(current_setting('test.desk_ticket')::uuid);
    raise exception 'Tutor could read another participant’s ticket';
  exception when sqlstate 'PT404' then null; end;
end;
$$;
reset role;

set local role anon;
do $$
declare enquiry_id uuid := gen_random_uuid(); result jsonb;
begin
  result := public.submit_contact_enquiry(enquiry_id,'Test','Visitor','visitor@example.test','tutoring','I would like information about tutoring.');
  if result->>'case_reference' not like 'TUT-GST-ENQ-%'
    or public.submit_contact_enquiry(enquiry_id,'Test','Visitor','visitor@example.test','tutoring','I would like information about tutoring.')->>'created' is distinct from 'false' then
    raise exception 'Prospect reference or submission deduplication failed';
  end if;
  perform set_config('test.desk_enquiry',enquiry_id::text,true);
  begin
    perform id from public.contact_enquiries;
    raise exception 'A guest could read the enquiry inbox';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','be000000-0000-4000-8000-000000000003',true);
do $$
declare
  enquiry_id uuid := current_setting('test.desk_enquiry')::uuid;
  reply_id uuid := gen_random_uuid();
  version_after_update integer;
  result jsonb;
begin
  update public.contact_enquiries set status='in_progress', internal_notes='Private intake note'
    where id=enquiry_id returning version into version_after_update;
  if version_after_update is distinct from 2 then raise exception 'Admin status/notes update did not persist'; end if;
  result := public.begin_enquiry_reply(reply_id,enquiry_id,'Thanks for your enquiry. We are happy to help.',version_after_update);
  if result->>'created' is distinct from 'true'
    or public.begin_enquiry_reply(gen_random_uuid(),enquiry_id,'Thanks for your enquiry. We are happy to help.',version_after_update)->>'created' is distinct from 'false' then
    raise exception 'A duplicate email was queued';
  end if;
  update public.enquiry_replies set delivery_status='sent', provider_id='test-delivery' where id=reply_id;
  if not found then raise exception 'Admin could not record provider acceptance'; end if;
  if public.begin_enquiry_reply(gen_random_uuid(),enquiry_id,'Thanks for your enquiry. We are happy to help.',version_after_update)->'reply'->>'delivery_status' is distinct from 'sent' then
    raise exception 'A retry lost the existing delivery result';
  end if;
  begin
    update public.contact_enquiries set email='changed@example.test' where id=enquiry_id;
    raise exception 'Admin could alter the original sender address directly';
  exception when insufficient_privilege then null; end;
  if not exists(select id from public.booking_safety_cases where id=current_setting('test.desk_ticket')::uuid
    and reporter_kind='student' and issue_code='SUB' and case_reference like 'BIL-STU-SUB-%') then
    raise exception 'Admin could not search the structured ticket metadata';
  end if;
end;
$$;
reset role;

do $$
begin
  if not exists (select 1 from public.notifications where kind='enquiry' and title like 'New website enquiry · TUT-GST-ENQ-%'
    and data->>'enquiryId'=current_setting('test.desk_enquiry')) then
    raise exception 'New enquiry did not generate a reference-linked admin notification';
  end if;
end;
$$;

rollback;
