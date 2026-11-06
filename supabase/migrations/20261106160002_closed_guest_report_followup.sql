-- An email follow-up must not reopen the support side of a developer report.
create or replace function public.begin_enquiry_reply(_id uuid,_enquiry_id uuid,_message text,_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare enquiry public.contact_enquiries%rowtype; reply public.enquiry_replies%rowtype;
begin
  if not (select private.is_platform_admin()) then raise exception 'Administrator access required.' using errcode='42501'; end if;
  if _id is null or coalesce(char_length(btrim(_message)),0) not between 10 and 4000 then
    raise exception 'Enter a valid reply.' using errcode='22023';
  end if;
  select * into enquiry from public.contact_enquiries where id=_enquiry_id for update;
  if not found then raise exception 'Enquiry not found.' using errcode='PT404'; end if;
  select * into reply from public.enquiry_replies where id=_id;
  if found then
    if reply.enquiry_id=_enquiry_id and reply.message=btrim(_message) then
      return jsonb_build_object('reply',to_jsonb(reply),'created',false);
    end if;
    raise exception 'This reply reference has already been used.' using errcode='PT409';
  end if;
  if enquiry.status='spam' then raise exception 'Change the status before replying to spam.' using errcode='PT409'; end if;
  select * into reply from public.enquiry_replies
    where enquiry_id=_enquiry_id and message=btrim(_message) and delivery_status in ('pending','unknown','sent')
    order by created_at desc,id limit 1;
  if found then return jsonb_build_object('reply',to_jsonb(reply),'created',false); end if;
  if enquiry.version is distinct from _expected_version then raise exception 'This enquiry changed. Reload it before replying.' using errcode='PT409'; end if;
  if (select count(*) from public.enquiry_replies where enquiry_id=_enquiry_id and created_at>now()-interval '1 hour')>=5 then
    raise exception 'Too many replies. Please try later.' using errcode='PT429';
  end if;
  insert into public.enquiry_replies(id,enquiry_id,admin_id,message) values(_id,_enquiry_id,(select auth.uid()),btrim(_message))
    returning * into reply;
  update public.contact_enquiries set status = case when developer_status is null then 'in_progress' else status end
    where id = _enquiry_id;
  return jsonb_build_object('reply',to_jsonb(reply),'created',true);
end;
$$;
