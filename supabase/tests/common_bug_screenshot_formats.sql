begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
select ('bc200000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,
  'screenshot.formats.' || n || '@example.test','{}'::jsonb,'{}'::jsonb from generate_series(1,8) n;

set local role authenticated;
select set_config('request.jwt.claim.sub','bc200000-0000-4000-8000-000000000001',true);
do $$
declare
  item record;
  report uuid;
  invalid_report uuid;
  image text;
  downloaded jsonb;
  fixture_number integer := 0;
begin
  -- These small signature fixtures exercise the same validation at the direct RPC boundary.
  for item in select * from (values
    ('image/jpeg','image/jpeg','ffd8ffe000104a46494600010100000100010000ffd9'),
    ('image/jps','image/jpeg','ffd8ffe000104a46494600010100000100010000ffd9'),
    ('image/jpg','image/jpeg','ffd8ffe000104a46494600010100000100010000ffd9'),
    ('image/png','image/png','89504e470d0a1a0a0000000d49484452'),
    ('image/webp','image/webp','524946460c000000574542505650384c'),
    ('image/gif','image/gif','47494638396101000100800000000000ffffff2c00000000010001000002024401003b'),
    ('image/bmp','image/bmp','424d000000000000000000000000000000000000000000000000'),
    ('image/x-ms-bmp','image/bmp','424d000000000000000000000000000000000000000000000000')
  ) as fixtures(declared_mime,expected_mime,hex) loop
    fixture_number := fixture_number + 1;
    perform set_config('request.jwt.claim.sub','bc200000-0000-4000-8000-' || lpad(fixture_number::text,12,'0'),true);
    report := gen_random_uuid();
    image := replace(encode(decode(item.hex,'hex'),'base64'), E'\n','');
    perform public.submit_member_bug_report(report,'Screenshot format test','This report tests an allowed screenshot format.',item.declared_mime,image);
    -- Retrying under the canonical MIME must not create an attachment conflict.
    perform public.submit_member_bug_report(report,'Screenshot format test','This report tests an allowed screenshot format.',item.expected_mime,image);
    downloaded := public.support_bug_screenshot(report,false,false);
    if downloaded->>'mime' <> item.expected_mime or downloaded->>'base64' <> image then
      raise exception 'The screenshot did not round-trip: %',item.declared_mime;
    end if;
  end loop;

  for item in select * from (values
    ('image/svg+xml','3c737667206f6e6c6f61643d22616c657274283129223e3c2f7376673e'),
    ('image/jpeg','89504e470d0a1a0a0000000d49484452'),
    ('image/gif','ffd8ffe000104a46494600010100000100010000ffd9'),
    ('image/bmp','424d00000000000000000000'),
    ('image/webp','52494646000000004e4f5450')
  ) as fixtures(declared_mime,hex) loop
    invalid_report := gen_random_uuid();
    begin
      perform public.submit_member_bug_report(invalid_report,'Unsupported screenshot','This report must not be saved with an invalid screenshot.',
        item.declared_mime,encode(decode(item.hex,'hex'),'base64'));
      raise exception 'An invalid screenshot was accepted: %',item.declared_mime;
    exception when invalid_parameter_value then null; end;
    begin
      perform public.my_support_ticket(invalid_report);
      raise exception 'An invalid screenshot left a partial ticket';
    exception when sqlstate 'PT404' then null; end;
  end loop;
end;
$$;
reset role;

-- Guest intake also uses the shared validator and private attachment table.
do $$
declare
  report uuid := gen_random_uuid();
  screenshot text := 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAkQBADs=';
begin
  perform public.submit_guest_bug_report(report,'Demo','Visitor','formats.guest@example.test',
    'This guest report contains a small GIF screenshot.','image/gif',screenshot);
  if not exists(select 1 from private.bug_report_screenshots where enquiry_id=report
    and mime_type='image/gif' and image=decode(screenshot,'base64')) then
    raise exception 'The guest GIF attachment was not saved';
  end if;
end;
$$;
rollback;
