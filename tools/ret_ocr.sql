create table if not exists public.ret_ocr_log (id bigint generated always as identity primary key, code text not null, at timestamptz not null default now());
alter table public.ret_ocr_log enable row level security;
revoke all on public.ret_ocr_log from anon, authenticated;

create or replace function public.ret_ocr_ok(p_branch text, p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_code text;
begin
  begin v_code := ret_pin(p_branch, p_pin); exception when others then return jsonb_build_object('ok', false, 'message', sqlerrm); end;
  if (select count(*) from ret_ocr_log where code = v_code and at > now() - interval '1 hour') >= 40 then
    return jsonb_build_object('ok', false, 'message', 'قراءة الفواتير وصلت حدها — اكتب البيانات يدوياً');
  end if;
  insert into ret_ocr_log (code) values (v_code);
  delete from ret_ocr_log where at < now() - interval '2 days';
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.ret_ocr_ok(text, text) from public;
grant execute on function public.ret_ocr_ok(text, text) to anon, authenticated;

select 'تم: قراءة الفاتورة من الصورة جاهزة' as result;
