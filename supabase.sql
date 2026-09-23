-- ============================================================
-- CUMPADRES FC - SISTEMA DE COMANDAS V2
-- Supabase / PostgreSQL
-- ============================================================
create extension if not exists pgcrypto;

-- ---------- helpers ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------- profiles ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'caixa'
    check (role in ('admin','caixa','cozinha')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  first_user boolean;
begin
  select not exists(select 1 from public.profiles) into first_user;
  insert into public.profiles(id, full_name, role)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
         case when first_user then 'admin' else 'caixa' end)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- ---------- categories ----------
create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- products ----------
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  price numeric(12,2) not null default 0 check (price >= 0),
  send_to_kitchen boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------- cash ----------
create table if not exists public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  opened_by uuid references public.profiles(id),
  opening_balance numeric(12,2) not null default 0,
  opened_at timestamptz not null default now(),
  closed_by uuid references public.profiles(id),
  closing_balance numeric(12,2),
  closed_at timestamptz,
  status text not null default 'open' check(status in ('open','closed'))
);

-- ---------- commands ----------
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity unique,
  customer_name text,
  table_number text,
  status text not null default 'open'
    check(status in ('open','closed','cancelled')),
  total numeric(12,2) not null default 0,
  opened_by uuid references public.profiles(id),
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  unit_price numeric(12,2) not null default 0,
  quantity numeric(12,3) not null default 1 check(quantity >= 0),
  send_to_kitchen boolean not null default false,
  kitchen_sent_qty numeric(12,3) not null default 0,
  kitchen_cancelled_qty numeric(12,3) not null default 0,
  voided boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  method text not null check(method in ('dinheiro','pix','debito','credito','outro')),
  amount numeric(12,2) not null check(amount > 0),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

-- ---------- printers ----------
create table if not exists public.printers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check(type in ('kitchen','receipt')),
  width_mm integer not null default 58 check(width_mm in (58,80)),
  windows_printer_name text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- kitchen ----------
create table if not exists public.kitchen_orders (
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity unique,
  order_id uuid references public.orders(id) on delete set null,
  order_type text not null default 'ORDER' check(order_type in ('ORDER','CANCEL')),
  customer_name text,
  table_number text,
  status text not null default 'NEW'
    check(status in ('NEW','PREPARING','READY','DELIVERED','CANCELLED')),
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
  quantity numeric(12,3) not null check(quantity > 0),
  notes text,
  created_at timestamptz not null default now()
);

-- ---------- unified print queue ----------
create table if not exists public.print_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type text not null check(job_type in ('KITCHEN','RECEIPT')),
  reference_id uuid,
  printer_id uuid references public.printers(id) on delete set null,
  payload jsonb not null,
  status text not null default 'pending'
    check(status in ('pending','printing','printed','error')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  printed_at timestamptz
);

create index if not exists idx_orders_status on public.orders(status);
create index if not exists idx_order_items_order on public.order_items(order_id);
create index if not exists idx_kitchen_orders_status on public.kitchen_orders(status);
create index if not exists idx_print_jobs_status on public.print_jobs(status);

-- ---------- updated triggers ----------
drop trigger if exists trg_products_updated on public.products;
create trigger trg_products_updated before update on public.products
for each row execute procedure public.set_updated_at();

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles
for each row execute procedure public.set_updated_at();

drop trigger if exists trg_orders_updated on public.orders;
create trigger trg_orders_updated before update on public.orders
for each row execute procedure public.set_updated_at();

drop trigger if exists trg_order_items_updated on public.order_items;
create trigger trg_order_items_updated before update on public.order_items
for each row execute procedure public.set_updated_at();

drop trigger if exists trg_kitchen_orders_updated on public.kitchen_orders;
create trigger trg_kitchen_orders_updated before update on public.kitchen_orders
for each row execute procedure public.set_updated_at();

-- ---------- role helpers ----------
create or replace function public.has_role(required_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles
    where id = auth.uid() and role = required_role
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.has_role('admin');
$$;

-- ---------- total trigger ----------
create or replace function public.recalculate_order_total()
returns trigger
language plpgsql
as $$
declare
  target_order uuid;
begin
  target_order := coalesce(new.order_id, old.order_id);
  update public.orders
     set total = coalesce((
       select sum(quantity * unit_price)
       from public.order_items
       where order_id = target_order
         and voided = false
     ),0),
         updated_at = now()
   where id = target_order;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_recalculate_order_total on public.order_items;
create trigger trg_recalculate_order_total
after insert or update or delete on public.order_items
for each row execute procedure public.recalculate_order_total();

-- ---------- app settings ----------
create table if not exists public.app_settings (
  id integer primary key default 1 check(id=1),
  bar_name text not null default 'Cumpadres FC',
  address text,
  phone text,
  updated_at timestamptz not null default now()
);

insert into public.app_settings(id,bar_name)
values(1,'Cumpadres FC')
on conflict(id) do nothing;

-- ---------- kitchen RPC ----------
create or replace function public.create_kitchen_batch(
  p_order_id uuid,
  p_customer_name text,
  p_table_number text,
  p_items jsonb,
  p_order_type text default 'ORDER'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  kitchen_id uuid;
  printer_id uuid;
  it jsonb;
  item_name text;
  qty numeric;
  item_id uuid;
begin
  if not (public.has_role('admin') or public.has_role('caixa')) then
    raise exception 'Usuário sem permissão para enviar pedido à cozinha';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'Nenhum item informado';
  end if;

  insert into public.kitchen_orders(
    order_id, order_type, customer_name, table_number, created_by
  )
  values(
    p_order_id, p_order_type, nullif(trim(p_customer_name), ''),
    nullif(trim(p_table_number), ''), auth.uid()
  )
  returning id into kitchen_id;

  for it in select * from jsonb_array_elements(p_items)
  loop
    item_name := coalesce(it->>'product_name','Item');
    qty := (it->>'quantity')::numeric;
    item_id := nullif(it->>'order_item_id','')::uuid;

    if qty <= 0 then
      continue;
    end if;

    insert into public.kitchen_order_items(
      kitchen_order_id, order_item_id, product_id, product_name, quantity, notes
    )
    values(
      kitchen_id,
      item_id,
      nullif(it->>'product_id','')::uuid,
      item_name,
      qty,
      nullif(it->>'notes','')
    );

    if p_order_id is not null and p_order_type = 'ORDER' and item_id is not null then
      update public.order_items
         set kitchen_sent_qty = kitchen_sent_qty + qty
       where id = item_id;
    elsif p_order_id is not null and p_order_type = 'CANCEL' and item_id is not null then
      update public.order_items
         set kitchen_cancelled_qty = kitchen_cancelled_qty + qty
       where id = item_id;
    end if;
  end loop;

  select id into printer_id
  from public.printers
  where type='kitchen' and active=true
  order by created_at
  limit 1;

  insert into public.print_jobs(job_type,reference_id,printer_id,payload)
  values(
    'KITCHEN',
    kitchen_id,
    printer_id,
    jsonb_build_object(
      'kitchen_order_id', kitchen_id,
      'order_id', p_order_id,
      'order_type', p_order_type,
      'customer_name', p_customer_name,
      'table_number', p_table_number,
      'created_at', now(),
      'items', (
        select coalesce(jsonb_agg(
          jsonb_build_object(
            'product_name', product_name,
            'quantity', quantity,
            'notes', notes
          ) order by created_at
        ), '[]'::jsonb)
        from public.kitchen_order_items
        where kitchen_order_id=kitchen_id
      )
    )
  );

  return kitchen_id;
end;
$$;

-- ---------- close order RPC ----------
create or replace function public.close_order(
  p_order_id uuid,
  p_payments jsonb,
  p_print boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  order_total numeric;
  paid_total numeric;
  printer_id uuid;
begin
  if not (public.has_role('admin') or public.has_role('caixa')) then
    raise exception 'Sem permissão';
  end if;

  select total into order_total
  from public.orders
  where id=p_order_id and status='open'
  for update;

  if order_total is null then
    raise exception 'Comanda não encontrada ou já fechada';
  end if;

  select coalesce(sum((x->>'amount')::numeric),0)
    into paid_total
  from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) x;

  if round(paid_total,2) <> round(order_total,2) then
    raise exception 'Valor pago (R$ %) diferente do total (R$ %)', paid_total, order_total;
  end if;

  insert into public.payments(order_id,method,amount,created_by)
  select p_order_id,
         x->>'method',
         (x->>'amount')::numeric,
         auth.uid()
  from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) x;

  update public.orders
     set status='closed', closed_by=auth.uid(), closed_at=now(), updated_at=now()
   where id=p_order_id;

  if p_print then
    select id into printer_id
    from public.printers
    where type='receipt' and active=true
    order by created_at
    limit 1;

    insert into public.print_jobs(job_type,reference_id,printer_id,payload)
    select 'RECEIPT', o.id, printer_id,
      jsonb_build_object(
        'bar_name',(select bar_name from public.app_settings where id=1),
        'order_number',o.number,
        'customer_name',o.customer_name,
        'table_number',o.table_number,
        'total',o.total,
        'created_at',o.created_at,
        'items',(
          select coalesce(jsonb_agg(jsonb_build_object(
            'product_name',oi.product_name,
            'quantity',oi.quantity,
            'unit_price',oi.unit_price,
            'subtotal',oi.quantity*oi.unit_price
          ) order by oi.created_at),'[]'::jsonb)
          from public.order_items oi
          where oi.order_id=o.id and oi.voided=false
        ),
        'payments',(
          select coalesce(jsonb_agg(jsonb_build_object(
            'method',p.method,'amount',p.amount
          ) order by p.created_at),'[]'::jsonb)
          from public.payments p
          where p.order_id=o.id
        )
      )
    from public.orders o where o.id=p_order_id;
  end if;

  return true;
end;
$$;

-- ---------- print queue RPCs ----------
create or replace function public.claim_print_job()
returns setof public.print_jobs
language plpgsql
security definer
set search_path=public
as $$
begin
  return query
  with candidate as (
    select id
    from public.print_jobs
    where status='pending'
    order by created_at
    for update skip locked
    limit 1
  )
  update public.print_jobs p
     set status='printing',
         attempts=attempts+1
    from candidate c
   where p.id=c.id
  returning p.*;
end;
$$;

create or replace function public.complete_print_job(
  p_job_id uuid,
  p_success boolean,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.print_jobs
     set status=case when p_success then 'printed' else 'error' end,
         last_error=case when p_success then null else p_error end,
         printed_at=case when p_success then now() else null end
   where id=p_job_id;
end;
$$;

-- ---------- seed data ----------
insert into public.categories(name)
values ('Bebidas'),('Cervejas'),('Petiscos'),('Cozinha')
on conflict(name) do nothing;

insert into public.products(category_id,name,price,send_to_kitchen)
select c.id,'Cerveja 600ml',12.00,false from public.categories c where c.name='Cervejas'
and not exists(select 1 from public.products p where p.name='Cerveja 600ml')
union all
select c.id,'Batata Frita',25.00,true from public.categories c where c.name='Petiscos'
and not exists(select 1 from public.products p where p.name='Batata Frita')
union all
select c.id,'Calabresa Acebolada',32.00,true from public.categories c where c.name='Cozinha'
and not exists(select 1 from public.products p where p.name='Calabresa Acebolada');

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.cash_sessions enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.printers enable row level security;
alter table public.kitchen_orders enable row level security;
alter table public.kitchen_order_items enable row level security;
alter table public.print_jobs enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());

drop policy if exists profiles_admin on public.profiles;
create policy profiles_admin on public.profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated using(true);
drop policy if exists categories_admin on public.categories;
create policy categories_admin on public.categories for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated using(true);
drop policy if exists products_admin on public.products;
create policy products_admin on public.products for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists cash_all on public.cash_sessions;
create policy cash_all on public.cash_sessions for all to authenticated
using(public.has_role('admin') or public.has_role('caixa'))
with check(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists orders_all on public.orders;
create policy orders_all on public.orders for all to authenticated
using(public.has_role('admin') or public.has_role('caixa'))
with check(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists order_items_all on public.order_items;
create policy order_items_all on public.order_items for all to authenticated
using(public.has_role('admin') or public.has_role('caixa'))
with check(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists payments_all on public.payments;
create policy payments_all on public.payments for all to authenticated
using(public.has_role('admin') or public.has_role('caixa'))
with check(public.has_role('admin') or public.has_role('caixa'));

drop policy if exists printers_select on public.printers;
create policy printers_select on public.printers for select to authenticated using(true);
drop policy if exists printers_admin on public.printers;
create policy printers_admin on public.printers for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists kitchen_select on public.kitchen_orders;
create policy kitchen_select on public.kitchen_orders for select to authenticated using(true);
drop policy if exists kitchen_update on public.kitchen_orders;
create policy kitchen_update on public.kitchen_orders for update to authenticated
using(public.has_role('admin') or public.has_role('caixa') or public.has_role('cozinha'))
with check(public.has_role('admin') or public.has_role('caixa') or public.has_role('cozinha'));

drop policy if exists kitchen_items_select on public.kitchen_order_items;
create policy kitchen_items_select on public.kitchen_order_items for select to authenticated using(true);

drop policy if exists print_select on public.print_jobs;
create policy print_select on public.print_jobs for select to authenticated using(public.is_admin() or public.has_role('caixa') or public.has_role('cozinha'));

drop policy if exists settings_select on public.app_settings;
create policy settings_select on public.app_settings for select to authenticated using(true);
drop policy if exists settings_admin on public.app_settings;
create policy settings_admin on public.app_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

-- Realtime
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.order_items;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.kitchen_orders;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.print_jobs;
exception when duplicate_object then null;
end $$;

-- Depois do primeiro cadastro, se necessário:
-- update public.profiles set role='admin' where id='UUID_DO_USUARIO';
