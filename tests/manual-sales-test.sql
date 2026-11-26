-- Test only, after fixture + migration. No production connection.
do $$begin
if has_function_privilege('anon','public.record_manual_sale(uuid,jsonb,jsonb,jsonb,integer,integer,text,timestamptz)','EXECUTE') then raise exception 'anon can execute'; end if;
end$$;
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000099',false);
do $$begin
  begin
    perform public.record_manual_sale('00000000-0000-4000-8000-000000000010','{"a":1}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',3250,0,'pix','2026-01-01T12:00:00Z');
    raise exception 'non-admin was accepted';
  exception when insufficient_privilege then null; end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
do $$declare a jsonb;b jsonb;begin
  begin
    perform public.record_manual_sale('00000000-0000-4000-8000-000000000011','{"a":3}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',9000,0,'pix','2026-01-01T12:00:00Z');
    raise exception 'stock oversold';
  exception when raise_exception then if sqlerrm<>'insufficient_stock' then raise; end if; end;
  begin
    perform public.record_manual_sale('00000000-0000-4000-8000-000000000012','{"a":1,"b":1}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',6501,0,'pix','2026-01-01T12:00:00Z');
    raise exception 'invalid rounding accepted';
  exception when raise_exception then if sqlerrm<>'amount_not_divisible' then raise; end if; end;
  a:=public.record_manual_sale('00000000-0000-4000-8000-000000000013','{"a":1,"b":1}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',6500,0,'pix','2026-01-01T12:00:00Z');
  b:=public.record_manual_sale('00000000-0000-4000-8000-000000000013','{"a":1,"b":1}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',6500,0,'pix','2026-01-01T12:00:00Z');
  if a->>'id' is distinct from b->>'id' or (b->>'duplicate') is distinct from 'true' then raise exception 'retry duplicated'; end if;
  begin
    perform public.record_manual_sale('00000000-0000-4000-8000-000000000013','{"a":1}','{"full_name":"Cliente Teste"}','{"method":"pickup","location":"school"}',3250,0,'cash','2026-01-01T12:00:00Z');
    raise exception 'conflicting retry accepted';
  exception when raise_exception then if sqlerrm<>'request_conflict' then raise; end if; end;
end$$;
reset role;
do $$begin
 if (select count(*) from public.orders)<>1 or (select count(*) from public.customers)<>1 then raise exception 'unexpected orders or customer records'; end if;
 if not exists(select 1 from public.orders where status='paid' and paid_at is not null and total_cents=6500 and quantity=2) then raise exception 'incorrect order'; end if;
 if (select count(*) from public.order_items)<>2 or (select count(*) from public.stock_movements)<>2 then raise exception 'missing or duplicate line items'; end if;
 if not exists(select 1 from public.payments where provider='manual_pix' and status='manual:confirmed' and amount_cents=6500) then raise exception 'wrong payment'; end if;
 if not exists(select 1 from public.products where id='a' and stock_on_hand=2 and stock_reserved=1 and available_stock=1) or not exists(select 1 from public.products where id='b' and stock_on_hand=3 and stock_reserved=1 and available_stock=2) then raise exception 'incorrect inventory'; end if;
end$$;
