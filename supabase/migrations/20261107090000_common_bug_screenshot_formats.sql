-- Keep image contents private and preserve the existing upload quota and access checks.
alter table private.bug_report_screenshots
  drop constraint bug_report_screenshots_mime_type_check,
  add constraint bug_report_screenshots_mime_type_check
    check (mime_type in ('image/png','image/jpeg','image/webp','image/gif','image/bmp'));

create or replace function private.save_bug_screenshot(_ticket uuid,_enquiry uuid,_mime text,_base64 text)
returns void language plpgsql set search_path = '' as $$
declare bytes bytea;
begin
  if _mime is null and _base64 is null then return; end if;
  _mime := case lower(_mime)
    when 'image/jpg' then 'image/jpeg'
    when 'image/pjpeg' then 'image/jpeg'
    when 'image/jps' then 'image/jpeg'
    when 'image/x-jps' then 'image/jpeg'
    when 'image/x-png' then 'image/png'
    when 'image/x-ms-bmp' then 'image/bmp'
    else lower(_mime) end;
  if _mime is null or _mime not in ('image/png','image/jpeg','image/webp','image/gif','image/bmp')
    or coalesce(length(_base64),0) not between 4 and 2796204
    or length(_base64) % 4 <> 0 or _base64 !~ '^[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'Choose a JPG/JPEG (including JPS), PNG, WebP, GIF or BMP screenshot up to 2 MB.' using errcode = '22023';
  end if;
  bytes := decode(_base64,'base64');
  if octet_length(bytes) not between 12 and 2097152
    or replace(encode(bytes,'base64'), E'\n','') <> _base64
    or not (case _mime
      when 'image/png' then substring(bytes from 1 for 8) = decode('89504e470d0a1a0a','hex')
      when 'image/jpeg' then substring(bytes from 1 for 3) = decode('ffd8ff','hex')
      when 'image/webp' then substring(bytes from 1 for 4) = convert_to('RIFF','UTF8')
        and substring(bytes from 9 for 4) = convert_to('WEBP','UTF8')
      when 'image/gif' then substring(bytes from 1 for 6) in (convert_to('GIF87a','UTF8'),convert_to('GIF89a','UTF8'))
      when 'image/bmp' then octet_length(bytes) >= 26 and substring(bytes from 1 for 2) = convert_to('BM','UTF8')
      else false end) then
    raise exception 'The screenshot is not a supported image.' using errcode = '22023';
  end if;
  insert into private.bug_report_screenshots(ticket_id,enquiry_id,mime_type,image)
    values (_ticket,_enquiry,_mime,bytes) on conflict do nothing;
  if not found and not exists (select 1 from private.bug_report_screenshots s
      where (s.ticket_id = _ticket or s.enquiry_id = _enquiry) and s.mime_type = _mime and s.image = bytes) then
    raise exception 'A different screenshot is already attached to this report.' using errcode = 'PT409';
  end if;
end;
$$;
