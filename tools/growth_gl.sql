create table if not exists public.growth_gl_lines (
  branch  text not null default '',
  line_id text not null,
  acc     text not null,
  dt      date not null,
  doc     text not null default '',
  typ     text not null default '',
  descr   text not null default '',
  debit   numeric(16,2) not null default 0,
  credit  numeric(16,2) not null default 0,
  primary key (branch, line_id)
);
create index if not exists growth_gl_lines_acc_idx on public.growth_gl_lines (acc, dt);
alter table public.growth_gl_lines enable row level security;
revoke all on public.growth_gl_lines from anon, authenticated;

create or replace function public.growth_ingest_gl(p_rows jsonb, p_from date default null, p_reset boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; d int := 0;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 8000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if p_reset and p_from is not null then
    delete from growth_gl_lines where dt >= p_from; get diagnostics d = row_count;
  end if;
  insert into growth_gl_lines (branch, line_id, acc, dt, doc, typ, descr, debit, credit)
  select coalesce(x->>'branch', ''), x->>'line_id', x->>'acc', (x->>'dt')::date, left(coalesce(x->>'doc', ''), 40),
         left(coalesce(x->>'typ', ''), 60), left(coalesce(x->>'descr', ''), 300), coalesce((x->>'debit')::numeric, 0), coalesce((x->>'credit')::numeric, 0)
  from jsonb_array_elements(coalesce(p_rows, '[]')) x
  where coalesce(x->>'line_id', '') <> '' and coalesce(x->>'acc', '') <> '' and x->>'dt' is not null
  on conflict (branch, line_id) do update set acc = excluded.acc, dt = excluded.dt, doc = excluded.doc, typ = excluded.typ, descr = excluded.descr,
    debit = excluded.debit, credit = excluded.credit;
  get diagnostics n = row_count;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('gl', now(), n, jsonb_build_object('from', p_from, 'reset', p_reset, 'deleted', d))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'rows', n, 'deleted', d);
end $$;

create or replace function public.growth_gl_statement(p_acc text, p_from text, p_to text, p_branches text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[]; f date; t date;
begin
  if not (coalesce(is_writer(), false) or exists (select 1 from user_sections us join profiles p on p.id = us.user_id
          where us.user_id = auth.uid() and us.section in ('income', 'fin_is', 'fin_bs', 'fin_tb') and coalesce(p.active, true))) then
    raise exception 'غير مصرح';
  end if;
  bs := p_branches;
  if not coalesce(is_writer(), false) then
    bs := array(select unnest(coalesce(p_branches, my_branches())) intersect select unnest(my_branches()));
  end if;
  f := (p_from || '-01')::date; t := ((p_to || '-01')::date + interval '1 month' - interval '1 day')::date;
  return jsonb_build_object(
    'acc', (select jsonb_build_object('a', acc, 'n', name) from growth_coa where acc = p_acc),
    'opening', (select coalesce(sum(debit - credit), 0) from growth_tb where acc = p_acc and ym < p_from and (bs is null or branch = any(bs))),
    'period', (select jsonb_build_object('dr', coalesce(sum(debit), 0), 'cr', coalesce(sum(credit), 0)) from growth_tb
               where acc = p_acc and ym between p_from and p_to and (bs is null or branch = any(bs))),
    'gl_from', (select min(dt) from growth_gl_lines),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('d', dt, 'br', branch, 'doc', doc, 't', typ, 'x', descr, 'dr', debit, 'cr', credit) order by dt, line_id)
       from growth_gl_lines where acc = p_acc and dt between f and t and (bs is null or branch = any(bs))), '[]'::jsonb));
end $$;

revoke all on function public.growth_ingest_gl(jsonb, date, boolean) from public, anon;
grant execute on function public.growth_ingest_gl(jsonb, date, boolean) to authenticated;
revoke all on function public.growth_gl_statement(text, text, text, text[]) from public, anon;
grant execute on function public.growth_gl_statement(text, text, text, text[]) to authenticated;
