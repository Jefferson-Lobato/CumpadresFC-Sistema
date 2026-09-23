-- CUMPADRES FC - PDV V2.2
-- Execute este arquivo no SQL Editor do Supabase.
-- Depois crie usuários em Authentication > Users.

create extension if not exists pgcrypto;

-- =========================
-- ENUMS
-- =========================
do $$ begin create type public.user_role as enum ('admin','caixa','cozinha'); exception when duplicate_object then null; end $$;
do $$ begin create type public.order_status as enum ('open','closed','cancelled'); exception when duplicate_object then null; end $$;
do $$ begin create type public.cash_status as enum ('open','closed'); exception when duplicate_object then null; end $$;
do $$ begin create type public.payment_method as enum ('dinheiro','pix','debito','credito','outro'); exception when duplicate_object then null; end $$;
do $$ begin create type public.kitchen_status as enum ('NEW','PREPARING','READY','DELIVERED','CANCELLED'); exception when duplicate_object then null; end $$;
do $$ begin create type public.kitchen_order_type as enum ('ORDER','CANCEL'); exception when duplicate_object then null; end $$;
do $$ begin create type public.print_job_type as enum ('KITCHEN','RECEIPT'); exception when duplicate_object then null; end $$;
do $$ begin create type public.print_job_status as enum ('pending','printing','printed','error'); exception when duplicate_object then null; end $$;
do $$ begin create type public.cash_movement_type as enum ('entry','exit'); exception when duplicate_object then null; end $$;

-- =========================
-- HELPERS
-- =========================
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.user_role not null default 'caixa',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.has_role(p_role public.user_role) returns boolean
language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role=p_role and active); $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public
as $$ select public.has_role('admin'); $$;

-- Primeiro usuário vira admin; os seguintes entram como caixa.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public
as $$
declare first_user boolean;
begin
  select not exists(select 1 from public.profiles) into first_user;
  insert into public.profiles(id,full_name,role)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''), case when first_user then 'admin'::public.user_role else 'caixa'::public.user_role end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

-- =========================
-- TURNOS / CAIXA
-- =========================
create table if not exists public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  opened_by uuid not null references public.profiles(id),
  closed_by uuid references public.profiles(id),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  opening_balance numeric(12,2) not null default 0,
  closing_balance numeric(12,2),
  expected_balance numeric(12,2),
  notes_open text,
  notes_close text,
  status public.cash_status not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists one_open_cash_session on public.cash_sessions(status) where status='open';

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references public.cash_sessions(id) on delete cascade,
  type public.cash_movement_type not null,
  description text not null,
  amount numeric(12,2) not null check(amount >= 0),
  payment_method public.payment_method not null default 'dinheiro',
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.cash_adjustments (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references public.cash_sessions(id) on delete cascade,
  field_name text not null check(field_name in ('opening_balance','closing_balance')),
  old_value numeric(12,2),
  new_value numeric(12,2),
  reason text not null default '',
  changed_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

-- =========================
-- PRODUTOS / CATEGORIAS
-- =========================
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  price numeric(12,2) not null default 0 check(price >= 0),
  send_to_kitchen boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- COMANDAS
-- =========================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  number bigint generated by default as identity unique,
  shift_id uuid references public.cash_sessions(id) on delete set null,
  customer_name text not null default '',
  table_number text not null default '',
  status public.order_status not null default 'open',
  total numeric(12,2) not null default 0,
  opened_by uuid references public.profiles(id),
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  reopened_by uuid references public.profiles(id),
  reopened_at timestamptz,
  reopen_reason text,
  origin_shift_id uuid references public.cash_sessions(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(12,2) not null default 0,
  quantity integer not null default 1 check(quantity >= 0),
  send_to_kitchen boolean not null default false,
  kitchen_sent_qty integer not null default 0 check(kitchen_sent_qty >= 0),
  kitchen_cancelled_qty integer not null default 0 check(kitchen_cancelled_qty >= 0),
  voided boolean not null default false,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  method public.payment_method not null,
  amount numeric(12,2) not null check(amount > 0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

-- =========================
-- COZINHA / IMPRESSÃO
-- =========================
create table if not exists public.kitchen_orders (
  id uuid primary key default gen_random_uuid(),
  number bigint generated by default as identity unique,
  order_id uuid references public.orders(id) on delete set null,
  shift_id uuid references public.cash_sessions(id) on delete set null,
  order_type public.kitchen_order_type not null default 'ORDER',
  customer_name text not null default '',
  table_number text not null default '',
  status public.kitchen_status not null default 'NEW',
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.kitchen_order_items (
  id uuid primary key default gen_random_uuid(),
  kitchen_order_id uuid not null references public.kitchen_orders(id) on delete cascade,
  order_item_id uuid references public.order_items(id) on delete set null,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check(quantity > 0),
  notes text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.printers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type public.print_job_type not null,
  width_mm integer not null default 58 check(width_mm in (58,80)),
  windows_printer_name text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.print_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type public.print_job_type not null,
  reference_id uuid,
  printer_id uuid references public.printers(id) on delete set null,
  payload jsonb not null default '{}'::jsonb,
  status public.print_job_status not null default 'pending',
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  printed_at timestamptz
);

create table if not exists public.app_settings (
  id integer primary key default 1 check(id=1),
  bar_name text not null default 'Cumpadres FC',
  address text not null default '',
  phone text not null default '',
  logo_url text not null default '',
  updated_at timestamptz not null default now()
);
insert into public.app_settings(id) values(1) on conflict do nothing;

-- =========================
-- TRIGGERS
-- =========================
drop trigger if exists profiles_updated on public.profiles;
create trigger profiles_updated before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists categories_updated on public.categories;
create trigger categories_updated before update on public.categories for each row execute function public.set_updated_at();
drop trigger if exists products_updated on public.products;
create trigger products_updated before update on public.products for each row execute function public.set_updated_at();
drop trigger if exists orders_updated on public.orders;
create trigger orders_updated before update on public.orders for each row execute function public.set_updated_at();
drop trigger if exists order_items_updated on public.order_items;
create trigger order_items_updated before update on public.order_items for each row execute function public.set_updated_at();
drop trigger if exists cash_updated on public.cash_sessions;
create trigger cash_updated before update on public.cash_sessions for each row execute function public.set_updated_at();
drop trigger if exists kitchen_updated on public.kitchen_orders;
create trigger kitchen_updated before update on public.kitchen_orders for each row execute function public.set_updated_at();
drop trigger if exists printers_updated on public.printers;
create trigger printers_updated before update on public.printers for each row execute function public.set_updated_at();

create or replace function public.recalc_order_total() returns trigger
language plpgsql as $$ begin
  update public.orders set total=coalesce((select sum(quantity*unit_price) from public.order_items where order_id=coalesce(new.order_id,old.order_id) and not voided and quantity>0),0) where id=coalesce(new.order_id,old.order_id);
  return coalesce(new,old);
end $$;
drop trigger if exists order_total_trigger on public.order_items;
create trigger order_total_trigger after insert or update or delete on public.order_items for each row execute function public.recalc_order_total();

-- =========================
-- RPCs
-- =========================
create or replace function public.open_cash(p_opening numeric, p_notes text default '') returns public.cash_sessions
language plpgsql security definer set search_path=public
as $$ declare r public.cash_sessions; begin
  if not public.has_role('admin') and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  if exists(select 1 from public.cash_sessions where status='open') then raise exception 'Já existe um caixa aberto'; end if;
  insert into public.cash_sessions(opened_by,opening_balance,notes_open) values(auth.uid(),greatest(coalesce(p_opening,0),0),coalesce(p_notes,'')) returning * into r;
  return r;
end $$;

create or replace function public.close_cash(p_session uuid,p_closing numeric,p_notes text default '') returns public.cash_sessions
language plpgsql security definer set search_path=public
as $$ declare r public.cash_sessions; expected numeric; begin
  if not public.has_role('admin') and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  select opening_balance + coalesce((select sum(case when type='entry' then amount else -amount end) from public.cash_movements where cash_session_id=p_session),0) + coalesce((select sum(total) from public.orders where shift_id=p_session and status='closed'),0) + coalesce((select sum(amount) from public.payments p join public.orders o on o.id=p.order_id where o.shift_id=p_session),0)*0 into expected from public.cash_sessions where id=p_session;
  update public.cash_sessions set status='closed',closed_by=auth.uid(),closed_at=now(),closing_balance=coalesce(p_closing,0),expected_balance=expected,notes_close=coalesce(p_notes,'') where id=p_session and status='open' returning * into r;
  if r.id is null then raise exception 'Caixa não encontrado ou já fechado'; end if;
  return r;
end $$;

create or replace function public.add_cash_movement(p_session uuid,p_type public.cash_movement_type,p_description text,p_amount numeric,p_method public.payment_method default 'dinheiro') returns public.cash_movements
language plpgsql security definer set search_path=public
as $$ declare r public.cash_movements; begin
  if not public.has_role('admin') and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  if not exists(select 1 from public.cash_sessions where id=p_session and status='open') then raise exception 'Caixa fechado'; end if;
  insert into public.cash_movements(cash_session_id,type,description,amount,payment_method,created_by) values(p_session,p_type,p_description,p_amount,p_method,auth.uid()) returning * into r;
  return r;
end $$;

create or replace function public.update_cash_value(p_session uuid,p_field text,p_new numeric,p_reason text) returns public.cash_sessions
language plpgsql security definer set search_path=public
as $$ declare oldv numeric; r public.cash_sessions; begin
  if not public.is_admin() then raise exception 'Somente administrador'; end if;
  if p_field='opening_balance' then select opening_balance into oldv from public.cash_sessions where id=p_session; update public.cash_sessions set opening_balance=p_new where id=p_session returning * into r;
  elsif p_field='closing_balance' then select closing_balance into oldv from public.cash_sessions where id=p_session; update public.cash_sessions set closing_balance=p_new where id=p_session returning * into r;
  else raise exception 'Campo inválido'; end if;
  insert into public.cash_adjustments(cash_session_id,field_name,old_value,new_value,reason,changed_by) values(p_session,p_field,oldv,p_new,coalesce(p_reason,''),auth.uid());
  return r;
end $$;

create or replace function public.create_order(p_customer text,p_table text) returns public.orders
language plpgsql security definer set search_path=public
as $$ declare r public.orders; sid uuid; begin
  if not public.has_role('admin') and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  select id into sid from public.cash_sessions where status='open' limit 1;
  insert into public.orders(shift_id,origin_shift_id,customer_name,table_number,opened_by) values(sid,sid,coalesce(p_customer,''),coalesce(p_table,''),auth.uid()) returning * into r;
  return r;
end $$;

create or replace function public.close_order(p_order uuid,p_payments jsonb,p_print boolean default true) returns public.orders
language plpgsql security definer set search_path=public
as $$ declare r public.orders; paid numeric; p jsonb; receipt_printer uuid; begin
  if not public.has_role('admin') and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  select * into r from public.orders where id=p_order for update;
  if r.id is null then raise exception 'Comanda não encontrada'; end if;
  if r.status<>'open' then raise exception 'Comanda não está aberta'; end if;
  select coalesce(sum((x->>'amount')::numeric),0) into paid from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) x;
  if abs(paid-r.total)>0.01 then raise exception 'Pagamento diferente do total. Total: %, recebido: %',r.total,paid; end if;
  for p in select * from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) loop
    insert into public.payments(order_id,method,amount,created_by) values(p_order,(p->>'method')::public.payment_method,(p->>'amount')::numeric,auth.uid());
  end loop;
  update public.orders set status='closed',closed_by=auth.uid(),closed_at=now() where id=p_order returning * into r;
  if p_print then
    select id into receipt_printer from public.printers where type='RECEIPT' and active order by created_at limit 1;
    insert into public.print_jobs(job_type,reference_id,printer_id,payload) values('RECEIPT',r.id,receipt_printer,jsonb_build_object('order_id',r.id));
  end if;
  return r;
end $$;

create or replace function public.reopen_order(p_order uuid,p_reason text default '') returns public.orders
language plpgsql security definer set search_path=public
as $$ declare r public.orders; sid uuid; begin
  if not public.is_admin() and not public.has_role('caixa') then raise exception 'Sem permissão'; end if;
  select * into r from public.orders where id=p_order for update;
  if r.status<>'closed' then raise exception 'Somente comandas fechadas podem ser reabertas'; end if;
  select id into sid from public.cash_sessions where status='open' limit 1;
  update public.orders set status='open',closed_at=null,closed_by=null,reopened_by=auth.uid(),reopened_at=now(),reopen_reason=coalesce(p_reason,''),shift_id=sid where id=p_order returning * into r;
  return r;
end $$;

create or replace function public.create_kitchen_batch(p_order_id uuid,p_customer text,p_table text,p_items jsonb,p_type public.kitchen_order_type default 'ORDER') returns public.kitchen_orders
language plpgsql security definer set search_path=public
as $$ declare r public.kitchen_orders; x jsonb; pid uuid; qty integer; nm text; note text; printer uuid; sid uuid; begin
  if not public.has_role('admin') and not public.has_role('caixa') and not public.has_role('cozinha') then raise exception 'Sem permissão'; end if;
  select id into sid from public.cash_sessions where status='open' limit 1;
  insert into public.kitchen_orders(order_id,shift_id,order_type,customer_name,table_number,created_by) values(p_order_id,sid,p_type,coalesce(p_customer,''),coalesce(p_table,''),auth.uid()) returning * into r;
  for x in select * from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    pid=nullif(x->>'product_id','')::uuid; qty=(x->>'quantity')::integer; nm=coalesce(x->>'product_name',''); note=coalesce(x->>'notes','');
    insert into public.kitchen_order_items(kitchen_order_id,order_item_id,product_id,product_name,quantity,notes) values(r.id,nullif(x->>'order_item_id','')::uuid,pid,nm,qty,note);
    if p_type='ORDER' and nullif(x->>'order_item_id','') is not null then update public.order_items set kitchen_sent_qty=kitchen_sent_qty+qty where id=(x->>'order_item_id')::uuid;
    elsif p_type='CANCEL' and nullif(x->>'order_item_id','') is not null then update public.order_items set kitchen_cancelled_qty=kitchen_cancelled_qty+qty where id=(x->>'order_item_id')::uuid; end if;
  end loop;
  select id into printer from public.printers where type='KITCHEN' and active order by created_at limit 1;
  insert into public.print_jobs(job_type,reference_id,printer_id,payload) values('KITCHEN',r.id,printer,jsonb_build_object('kitchen_order_id',r.id));
  return r;
end $$;

create or replace function public.claim_print_job() returns public.print_jobs
language plpgsql security definer set search_path=public
as $$ declare r public.print_jobs; begin
  update public.print_jobs set status='printing',attempts=attempts+1 where id=(select id from public.print_jobs where status='pending' order by created_at for update skip locked limit 1) returning * into r; return r;
end $$;

create or replace function public.complete_print_job(p_job uuid,p_success boolean,p_error text default null) returns public.print_jobs
language plpgsql security definer set search_path=public
as $$ declare r public.print_jobs; begin
  update public.print_jobs set status=case when p_success then 'printed'::public.print_job_status else 'error'::public.print_job_status end,last_error=p_error,printed_at=case when p_success then now() else null end where id=p_job returning * into r; return r;
end $$;

create or replace function public.dashboard_summary(p_shift uuid) returns jsonb
language sql stable security definer set search_path=public
as $$
select jsonb_build_object(
 'orders_open', (select count(*) from public.orders where status='open' and (shift_id=p_shift or (shift_id is null and origin_shift_id=p_shift))),
 'orders_closed', (select count(*) from public.orders where status='closed' and shift_id=p_shift),
 'sales_orders', coalesce((select sum(total) from public.orders where status='closed' and shift_id=p_shift),0),
 'direct_kitchen', coalesce((select count(*) from public.kitchen_orders where order_id is null and shift_id=p_shift and order_type='ORDER'),0),
 'cash_entries', coalesce((select sum(amount) from public.cash_movements where cash_session_id=p_shift and type='entry'),0),
 'cash_exits', coalesce((select sum(amount) from public.cash_movements where cash_session_id=p_shift and type='exit'),0)
); $$;

-- Permissões das RPCs
revoke all on function public.open_cash(numeric,text) from public; grant execute on function public.open_cash(numeric,text) to authenticated;
revoke all on function public.close_cash(uuid,numeric,text) from public; grant execute on function public.close_cash(uuid,numeric,text) to authenticated;
revoke all on function public.add_cash_movement(uuid,public.cash_movement_type,text,numeric,public.payment_method) from public; grant execute on function public.add_cash_movement(uuid,public.cash_movement_type,text,numeric,public.payment_method) to authenticated;
revoke all on function public.update_cash_value(uuid,text,numeric,text) from public; grant execute on function public.update_cash_value(uuid,text,numeric,text) to authenticated;
revoke all on function public.create_order(text,text) from public; grant execute on function public.create_order(text,text) to authenticated;
revoke all on function public.close_order(uuid,jsonb,boolean) from public; grant execute on function public.close_order(uuid,jsonb,boolean) to authenticated;
revoke all on function public.reopen_order(uuid,text) from public; grant execute on function public.reopen_order(uuid,text) to authenticated;
revoke all on function public.create_kitchen_batch(uuid,text,text,jsonb,public.kitchen_order_type) from public; grant execute on function public.create_kitchen_batch(uuid,text,text,jsonb,public.kitchen_order_type) to authenticated;
revoke all on function public.claim_print_job() from public; grant execute on function public.claim_print_job() to authenticated;
revoke all on function public.complete_print_job(uuid,boolean,text) from public; grant execute on function public.complete_print_job(uuid,boolean,text) to authenticated;
revoke all on function public.dashboard_summary(uuid) from public; grant execute on function public.dashboard_summary(uuid) to authenticated;

-- =========================
-- RLS
-- =========================
alter table public.profiles enable row level security;
alter table public.cash_sessions enable row level security;
alter table public.cash_movements enable row level security;
alter table public.cash_adjustments enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.kitchen_orders enable row level security;
alter table public.kitchen_order_items enable row level security;
alter table public.printers enable row level security;
alter table public.print_jobs enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists profiles_read on public.profiles; create policy profiles_read on public.profiles for select to authenticated using(true);
drop policy if exists profiles_admin on public.profiles; create policy profiles_admin on public.profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists categories_read on public.categories; create policy categories_read on public.categories for select to authenticated using(true);
drop policy if exists categories_admin on public.categories; create policy categories_admin on public.categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists products_read on public.products; create policy products_read on public.products for select to authenticated using(true);
drop policy if exists products_admin on public.products; create policy products_admin on public.products for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists cash_read on public.cash_sessions; create policy cash_read on public.cash_sessions for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));
drop policy if exists cash_admin on public.cash_sessions; create policy cash_admin on public.cash_sessions for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists cash_mov_read on public.cash_movements; create policy cash_mov_read on public.cash_movements for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));
drop policy if exists cash_adj_read on public.cash_adjustments; create policy cash_adj_read on public.cash_adjustments for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists orders_read on public.orders; create policy orders_read on public.orders for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));
drop policy if exists order_items_read on public.order_items; create policy order_items_read on public.order_items for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));
drop policy if exists payments_read on public.payments; create policy payments_read on public.payments for select to authenticated using(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists kitchen_read on public.kitchen_orders; create policy kitchen_read on public.kitchen_orders for select to authenticated using(public.has_role('admin') or public.has_role('caixa') or public.has_role('cozinha'));
drop policy if exists kitchen_update on public.kitchen_orders; create policy kitchen_update on public.kitchen_orders for update to authenticated using(public.has_role('admin') or public.has_role('cozinha')) with check(public.has_role('admin') or public.has_role('cozinha'));
drop policy if exists kitchen_items_read on public.kitchen_order_items; create policy kitchen_items_read on public.kitchen_order_items for select to authenticated using(public.has_role('admin') or public.has_role('caixa') or public.has_role('cozinha'));

drop policy if exists printers_read on public.printers; create policy printers_read on public.printers for select to authenticated using(true);
drop policy if exists printers_admin on public.printers; create policy printers_admin on public.printers for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists print_read on public.print_jobs; create policy print_read on public.print_jobs for select to authenticated using(public.is_admin() or public.has_role('caixa') or public.has_role('cozinha'));
drop policy if exists settings_read on public.app_settings; create policy settings_read on public.app_settings for select to authenticated using(true);
drop policy if exists settings_admin on public.app_settings; create policy settings_admin on public.app_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

-- Realtime
alter publication supabase_realtime add table public.cash_sessions;
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_items;
alter publication supabase_realtime add table public.kitchen_orders;
alter publication supabase_realtime add table public.print_jobs;

-- Dados iniciais
insert into public.categories(name,sort_order) values
('Cervejas',1),('Bebidas',2),('Petiscos',3),('Cozinha',4)
on conflict(name) do nothing;
insert into public.printers(name,type,width_mm) select 'Cozinha 58mm','KITCHEN',58 where not exists(select 1 from public.printers where type='KITCHEN');
insert into public.printers(name,type,width_mm) select 'Caixa 58mm','RECEIPT',58 where not exists(select 1 from public.printers where type='RECEIPT');

create index if not exists idx_orders_shift_status on public.orders(shift_id,status);
create index if not exists idx_order_items_order on public.order_items(order_id);
create index if not exists idx_kitchen_status on public.kitchen_orders(status,created_at);
create index if not exists idx_print_jobs_queue on public.print_jobs(status,created_at);

-- Para promover outro usuário a administrador:
-- update public.profiles set role='admin' where id='UUID_DO_USUARIO';
