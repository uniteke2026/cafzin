-- CAFZIN: additive manual-sale RPC. Apply as one transaction, never during checkout changes.
begin;
set local lock_timeout = '2s';
set local statement_timeout = '15s';
create schema if not exists cafzin_internal;
revoke all on schema cafzin_internal from public, anon, authenticated;
grant usage on schema cafzin_internal to authenticated;

create function cafzin_internal.record_manual_sale(
 p_key uuid, p_cart jsonb, p_customer jsonb, p_delivery jsonb,
 p_subtotal integer, p_shipping integer, p_method text, p_paid_at timestamptz
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.orders%rowtype; p public.products%rowtype; r record;
  cid uuid; q integer := 0; price integer; fp text;
  nm text; em text; ph text; method text; loc text; addr jsonb;
begin
  if auth.uid() is null or not exists(select 1 from public.admins a where a.user_id=auth.uid()) then
    raise exception 'admin_required' using errcode='42501';
  end if;
  if p_key is null or jsonb_typeof(p_cart) is distinct from 'object'
    or jsonb_typeof(p_customer) is distinct from 'object'
    or jsonb_typeof(p_delivery) is distinct from 'object'
    or p_subtotal is null or p_subtotal not between 1 and 10000000
    or p_shipping is null or p_shipping not between 0 and 1000000
    or p_method is null or p_method not in ('pix','card','cash','other')
    or p_paid_at is null or p_paid_at > now() + interval '5 minutes' then
    raise exception 'invalid_request';
  end if;
  nm := trim(coalesce(p_customer->>'full_name',''));
  em := lower(trim(coalesce(p_customer->>'email','')));
  ph := regexp_replace(coalesce(p_customer->>'phone',''),'[^0-9]','','g');
  if length(nm) not between 3 and 150 or length(em)>254
    or (em<>'' and em !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
    or (ph<>'' and ph !~ '^[0-9]{10,13}$') then raise exception 'invalid_customer'; end if;
  method := p_delivery->>'method'; loc := p_delivery->>'location'; addr := p_delivery->'address';
  if method='pickup' and loc in ('school','church') and p_shipping=0 then
    addr:=null;
  elsif method='delivery' and jsonb_typeof(addr)='object'
    and length(trim(coalesce(addr->>'city','')))>=2
    and length(trim(coalesce(addr->>'street','')))>=3
    and length(trim(coalesce(addr->>'number','')))>=1
    and length(trim(coalesce(addr->>'district','')))>=2
    and coalesce(addr->>'cep','') ~ '^[0-9]{8}$'
    and upper(coalesce(addr->>'state','')) in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then
    loc:=null;
  else raise exception 'invalid_delivery'; end if;
  if (select count(*) from jsonb_each(p_cart)) not between 1 and 50 then raise exception 'invalid_cart'; end if;
  -- Same lock namespace and deterministic product order as the existing checkout.
  perform pg_advisory_xact_lock(hashtextextended(p_key::text,0));
  fp := 'manual:' || md5(jsonb_build_array(p_cart,p_customer,p_delivery,p_subtotal,p_shipping,p_method,p_paid_at)::text);
  select * into o from public.orders where request_key=p_key for update;
  if found then
    if o.request_fingerprint is distinct from fp or o.status<>'paid' then raise exception 'request_conflict'; end if;
    return jsonb_build_object('id',o.id,'total_cents',o.total_cents,'duplicate',true);
  end if;
  for r in select key,value from jsonb_each_text(p_cart) order by key loop
    if r.value is null or r.value !~ '^[1-9][0-9]?$' then raise exception 'invalid_quantity'; end if;
    q:=q+r.value::integer;
    select * into p from public.products where id=r.key for update;
    if not found or not p.active or p.available_stock<r.value::integer then raise exception 'insufficient_stock'; end if;
  end loop;
  if q not between 1 and 50 then raise exception 'invalid_quantity'; end if;
  -- Preserve existing orders subtotal = quantity * unit_price invariant.
  if p_subtotal % q <> 0 then raise exception 'amount_not_divisible'; end if;
  price:=p_subtotal/q;
  insert into public.customers(full_name,email,phone) values(nm,em,ph) returning id into cid;
  insert into public.orders(customer_id,request_key,request_fingerprint,status,delivery_method,pickup_location,delivery_address,quantity,unit_price_cents,subtotal_cents,shipping_cents,reserved_until,paid_at)
    values(cid,p_key,fp,'paid',method,loc,addr,q,price,p_subtotal,p_shipping,now(),p_paid_at) returning * into o;
  for r in select key,value from jsonb_each_text(p_cart) order by key loop
    update public.products set stock_on_hand=stock_on_hand-r.value::integer where id=r.key returning * into p;
    insert into public.order_items(order_id,product_id,product_name,quantity,unit_price_cents)
      values(o.id,p.id,p.name,r.value::integer,price);
    insert into public.stock_movements(product_id,order_id,movement_type,on_hand_delta,reserved_delta)
      values(p.id,o.id,'sale',-r.value::integer,0);
  end loop;
  insert into public.payments(order_id,provider,status,amount_cents)
    values(o.id,'manual_'||p_method,'manual:confirmed',o.total_cents);
  return jsonb_build_object('id',o.id,'total_cents',o.total_cents,'duplicate',false);
end;
$$;
revoke all on function cafzin_internal.record_manual_sale(uuid,jsonb,jsonb,jsonb,integer,integer,text,timestamptz) from public, anon, authenticated;
grant execute on function cafzin_internal.record_manual_sale(uuid,jsonb,jsonb,jsonb,integer,integer,text,timestamptz) to authenticated;

create function public.record_manual_sale(
 p_key uuid, p_cart jsonb, p_customer jsonb, p_delivery jsonb,
 p_subtotal integer, p_shipping integer, p_method text, p_paid_at timestamptz
) returns jsonb language sql security invoker set search_path = '' as $$
 select cafzin_internal.record_manual_sale(p_key,p_cart,p_customer,p_delivery,p_subtotal,p_shipping,p_method,p_paid_at);
$$;
revoke all on function public.record_manual_sale(uuid,jsonb,jsonb,jsonb,integer,integer,text,timestamptz) from public, anon, authenticated;
grant execute on function public.record_manual_sale(uuid,jsonb,jsonb,jsonb,integer,integer,text,timestamptz) to authenticated;
commit;
