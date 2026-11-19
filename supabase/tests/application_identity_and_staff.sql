begin;
select set_config('request.jwt.claims',jsonb_build_object('aal','aal2','amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from now())::bigint)))::text,true);
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('d4100000-0000-4000-8000-000000000001','workflow.one@example.test','{}','{}'),
 ('d4100000-0000-4000-8000-000000000002','workflow.two@example.test','{}','{}'),
 ('d4100000-0000-4000-8000-000000000003','workflow.tutor@example.test','{}','{}'),
 ('d4100000-0000-4000-8000-000000000004','workflow.admin@example.test','{}','{}'),
 ('d4100000-0000-4000-8000-000000000005','workflow.super@example.test','{}','{}');
update public.profiles set role='tutor' where id='d4100000-0000-4000-8000-000000000003';
update public.profiles set role='admin' where id='d4100000-0000-4000-8000-000000000004';
update public.profiles set role='superUser' where id='d4100000-0000-4000-8000-000000000005';
insert into public.tutor_profiles(user_id,public_name,hourly_rate,online_hourly_rate,in_person_hourly_rate,is_approved,is_accepting_students,teaching_modes)
 values('d4100000-0000-4000-8000-000000000003','Workflow Tutor',250,250,400,true,true,array['online','in-person']);
insert into public.tutor_applications(id,user_id,status,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots)
 values('d4100000-0000-4000-8000-000000000011','d4100000-0000-4000-8000-000000000001','rejected','WORK-FLOW-ONE','+27620000000','Example address','Johannesburg','Gauteng','BSc','Example university',2025,2,'Explain and assess',250,array['online'],array['High school'],array['Weekday Evenings']);
do $$ begin
 begin
  insert into public.tutor_applications(user_id,status,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots)
  select 'd4100000-0000-4000-8000-000000000002','rejected','work flow one',phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots from public.tutor_applications where id='d4100000-0000-4000-8000-000000000011';
  raise exception 'Another account reused the same normalised identity';
 exception when sqlstate 'PT422' then null;end;
 insert into public.tutor_applications(user_id,status,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots)
 select user_id,'rejected',id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots from public.tutor_applications where id='d4100000-0000-4000-8000-000000000011';
 if (select count(*) from private.tutor_identity_claims where owner='d4100000-0000-4000-8000-000000000001')<>1 then raise exception 'Revision created duplicate claims';end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','d4100000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.promote_platform_admin('d4100000-0000-4000-8000-000000000002',now());raise exception 'Student promoted another account';exception when insufficient_privilege then null;end;
 if public.my_logout_summary()->'stats'->0->>'value'<>'0' then raise exception 'Logout summary used another account’s lessons';end if;
 if public.save_tutor_application_draft('d4100000-0000-4000-8000-000000000031','{"onlineHourlyRate":"250","inPersonHourlyRate":"400"}','[]',1,1,null,'d4100000-0000-4000-8000-000000000032')->'application'->>'inPersonHourlyRate'<>'400' then raise exception 'Draft lost the physical lesson rate';end if;
 begin update public.profiles set identity_correction_required=false where id=auth.uid();raise exception 'User cleared the identity flag';exception when insufficient_privilege then null;end;
end $$;
reset role;
-- Existing identity values stay in application history while an owner corrects
-- their details. Approval must be repeated before teaching can resume.
insert into public.tutor_applications(user_id,status,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots)
 select 'd4100000-0000-4000-8000-000000000003','approved','WORKFLOW-OLD-TUTOR',phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots from public.tutor_applications where id='d4100000-0000-4000-8000-000000000011';
update public.profiles set identity_correction_required=true where id='d4100000-0000-4000-8000-000000000003';
insert into public.tutor_applications(user_id,status,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots)
 select 'd4100000-0000-4000-8000-000000000003','submitted','WORKFLOW-CORRECTED-TUTOR',phone,street_address,city,province,highest_qualification,institution,year_completed,years_experience,teaching_style,hourly_rate,teaching_modes,student_age_groups,availability_slots from public.tutor_applications where id='d4100000-0000-4000-8000-000000000011';
do $$ begin
 if not exists(select 1 from public.tutor_applications where user_id='d4100000-0000-4000-8000-000000000003' and id_number='WORKFLOW-OLD-TUTOR' and status='approved') then raise exception 'Historical identity information was overwritten';end if;
 if exists(select 1 from public.profiles where id='d4100000-0000-4000-8000-000000000003' and identity_correction_required) then raise exception 'Corrected owner remains blocked';end if;
 if exists(select 1 from public.tutor_profiles where user_id='d4100000-0000-4000-8000-000000000003' and (is_approved or is_accepting_students)) then raise exception 'Identity correction bypassed application review';end if;
end $$;
select set_config('test.promotion_stamp',(select updated_at::text from public.profiles where id='d4100000-0000-4000-8000-000000000002'),true);
select set_config('request.jwt.claim.sub','d4100000-0000-4000-8000-000000000004',true);
set local role authenticated;
select public.promote_platform_admin('d4100000-0000-4000-8000-000000000002',current_setting('test.promotion_stamp')::timestamptz);
select public.promote_platform_admin('d4100000-0000-4000-8000-000000000002',current_setting('test.promotion_stamp')::timestamptz);
do $$ begin
 if (select role from public.profiles where id='d4100000-0000-4000-8000-000000000002')<>'admin' then raise exception 'Admin promotion failed';end if;
 begin perform public.promote_platform_admin('d4100000-0000-4000-8000-000000000005',now());raise exception 'Superuser access was modified';exception when insufficient_privilege then null;end;
 begin perform public.promote_platform_admin('d4100000-0000-4000-8000-000000000003',now()-interval '1 day');raise exception 'Stale promotion accepted';exception when sqlstate 'PT409' then null;end;
end $$;
reset role;
do $$ begin
 if (select count(*) from private.staff_role_audit where target='d4100000-0000-4000-8000-000000000002')<>1 then raise exception 'Promotion audit was duplicated';end if;
end $$;
select set_config('test.failure_booking',(select id::text from public.bookings where student_id<>tutor_id order by created_at limit 1),true);
select set_config('request.jwt.claim.sub',(select student_id::text from public.bookings where id=current_setting('test.failure_booking')::uuid),true);
set local role authenticated;
select public.record_booking_action_failure(current_setting('test.failure_booking')::uuid,'accept','d4100000-0000-4000-8000-000000000022');
select public.record_booking_action_failure(current_setting('test.failure_booking')::uuid,'accept','d4100000-0000-4000-8000-000000000022');
do $$ begin if (select count(*) from public.notifications where id='d4100000-0000-4000-8000-000000000022')<>1 then raise exception 'Failure notification was lost or duplicated';end if;end $$;
-- Support remains available to staff without MFA and to unapproved tutors.
select set_config('request.jwt.claims','{"aal":"aal1"}',true);
do $$ declare actor uuid; ticket uuid; result jsonb; begin
 foreach actor in array array['d4100000-0000-4000-8000-000000000001'::uuid,'d4100000-0000-4000-8000-000000000003'::uuid,'d4100000-0000-4000-8000-000000000004'::uuid,'d4100000-0000-4000-8000-000000000005'::uuid] loop
  perform set_config('request.jwt.claim.sub',actor::text,true);
  ticket:=gen_random_uuid();
  result:=public.create_detailed_support_ticket('account',null,'Help with my account','Please help me update my account information safely.',ticket);
  if (result->>'id')::uuid<>ticket then raise exception 'Support did not create a ticket';end if;
  if public.my_support_ticket(ticket)->>'subject'<>'Help with my account' then raise exception 'Owner cannot read their support ticket';end if;
  perform public.reply_support_ticket(ticket,'Additional information for support.',gen_random_uuid());
  perform public.resolve_support_ticket(ticket);
  if public.my_support_ticket(ticket)->>'status'<>'resolved' then raise exception 'Owner cannot resolve their support ticket';end if;
 end loop;
end $$;
rollback;
