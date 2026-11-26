-- Test fixture only. Never run in production. No real customer data.
create role anon nologin;
create role authenticated nologin;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid$$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
create table public.admins(user_id uuid primary key);
create table public.customers(id uuid primary key default gen_random_uuid(),full_name text not null,email text not null,phone text not null);
create table public.products(id text primary key,name text not null,stock_on_hand integer not null check(stock_on_hand>=0),stock_reserved integer not null check(stock_reserved>=0),available_stock integer generated always as(stock_on_hand-stock_reserved) stored,active boolean not null default true,check(stock_on_hand>=stock_reserved));
create table public.orders(
id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.customers,request_key uuid not null unique,request_fingerprint text,
status text not null default 'pending',delivery_method text not null,pickup_location text,delivery_address jsonb,quantity integer not null check(quantity>0),unit_price_cents integer not null check(unit_price_cents>=0),subtotal_cents integer not null,shipping_cents integer not null check(shipping_cents>=0),
total_cents integer generated always as(subtotal_cents+shipping_cents) stored,reserved_until timestamptz not null,paid_at timestamptz,
check(subtotal_cents=quantity*unit_price_cents),
check((delivery_method='pickup' and pickup_location in ('church','school') and delivery_address is null and shipping_cents=0) or (delivery_method='delivery' and pickup_location is null and delivery_address is not null)));
create table public.order_items(order_id uuid references public.orders,product_id text references public.products,product_name text not null,quantity integer not null check(quantity>0),unit_price_cents integer not null check(unit_price_cents>=0),primary key(order_id,product_id));
create table public.payments(id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders,provider text not null,status text not null,amount_cents integer not null check(amount_cents>=0));
create table public.stock_movements(id uuid primary key default gen_random_uuid(),order_id uuid references public.orders,product_id text references public.products,movement_type text not null,on_hand_delta integer not null,reserved_delta integer not null);
insert into public.admins values('00000000-0000-4000-8000-000000000001');
insert into public.products(id,name,stock_on_hand,stock_reserved) values('a','Produto A',3,1),('b','Produto B',4,1);
