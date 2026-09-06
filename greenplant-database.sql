-- =====================================================================
--  GreenPlant — สคริปต์ติดตั้งฐานข้อมูลฉบับรวม
--
--  ระบบพาณิชย์อิเล็กทรอนิกส์ร้านต้นไม้และของแต่งสวนออนไลน์
--  จัดทำโดย นายภควัต ซามงค์  รหัสนักศึกษา 67102122140
--  สาขาวิชาคอมพิวเตอร์และดิจิทัล  มหาวิทยาลัยราชภัฏสกลนคร
--
--  ไฟล์นี้รวมสคริปต์ติดตั้งทั้งหมดไว้ในไฟล์เดียว ใช้ติดตั้งระบบใหม่ตั้งแต่ต้น
--  หรือใช้เป็นเอกสารอ้างอิงโครงสร้างฐานข้อมูล
--
--  วิธีใช้ : Supabase → SQL Editor → New query → วางทั้งหมด → Run
--  หมายเหตุ: รันซ้ำได้โดยไม่ทำให้ข้อมูลเดิมเสียหาย
--
--  สิ่งที่ติดตั้ง
--    ตาราง 13 ตาราง   profiles, products, orders, order_items, order_logs,
--                     reviews, messages, coupons, newsletter, auctions,
--                     bids, wishlist, audit_logs
--    มุมมอง 1 มุมมอง   product_ratings (คะแนนรีวิวเฉลี่ยรายสินค้า)
--    ฟังก์ชัน 20 ตัว   สั่งซื้อ ติดตาม ประมูล คูปอง และสิทธิตาม PDPA
--    ที่เก็บไฟล์ 2 ถัง  product-images (สาธารณะ) · payment-slips (ส่วนตัว)
--
--  ข้อควรทราบ
--    ส่วนที่ 6 ต้องใช้ส่วนขยาย pg_cron หากสภาพแวดล้อมไม่รองรับ ระบบจะข้ามไป
--    และแจ้งเตือน โดยส่วนอื่นยังติดตั้งได้ตามปกติ เพียงแต่ผู้ดูแลต้องกด
--    ปิดประมูลเองจากหน้าหลังร้าน
-- =====================================================================



-- ==================================================================
--  ส่วนที่ 1  ตารางหลัก สิทธิ์การเข้าถึง และฟังก์ชันพื้นฐาน
-- ==================================================================

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null default '',
  phone          text not null default '',
  address        text not null default '',
  credit_limit   numeric(10,2) not null default 2000 check (credit_limit >= 0),
  credit_used    numeric(10,2) not null default 0    check (credit_used >= 0),
  account_status text not null default 'ปกติ' check (account_status in ('ปกติ','เฝ้าระวัง','ระงับ')),
  is_admin       boolean not null default false,
  created_at     timestamptz not null default now()
);
comment on table public.profiles is 'ข้อมูลสมาชิกและวงเงินเครดิต';

-- 1.2 สินค้าในแคตตาล็อก
create table if not exists public.products (
  id          bigint generated always as identity primary key,
  sku         text not null unique,
  name        text not null,
  sci_name    text not null default '',
  category    text not null check (category in ('ไม้ฟอกอากาศ','ไม้อวบน้ำ','กระถาง','ดินและวัสดุปลูก','อุปกรณ์')),
  price       numeric(10,2) not null check (price > 0),
  old_price   numeric(10,2) not null default 0 check (old_price >= 0),
  stock       integer not null default 0 check (stock >= 0),
  size_label  text not null default '',
  light       text not null default '-',
  water       text not null default '-',
  care_level  text not null default '-',
  art_key     text not null default 'pot',   -- ภาพ SVG สำรอง เมื่อยังไม่มีรูปจริง
  image_url   text,                          -- รูปจริงจาก Storage (ถ้ามี จะใช้แทน art_key)
  description text not null default '',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists products_category_idx on public.products(category);

-- 1.3 คำสั่งซื้อ
create table if not exists public.orders (
  id             bigint generated always as identity primary key,
  code           text not null unique,
  user_id        uuid references public.profiles(id) on delete set null,  -- null = ลูกค้าทั่วไป
  receiver_name  text not null,
  phone          text not null,
  address        text not null,
  note           text not null default '',
  subtotal       numeric(10,2) not null,
  shipping_fee   numeric(10,2) not null default 0,
  total          numeric(10,2) not null,
  payment_method text not null,
  slip_url       text,                     -- สลิปโอนเงินจาก Storage
  status         text not null default 'await'
                 check (status in ('await','approved','packing','shipped','done','reject')),
  carrier        text not null default '',
  tracking_no    text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists orders_user_idx   on public.orders(user_id);
create index if not exists orders_status_idx on public.orders(status);

-- 1.4 รายการสินค้าในคำสั่งซื้อ
create table if not exists public.order_items (
  id           bigint generated always as identity primary key,
  order_id     bigint not null references public.orders(id) on delete cascade,
  product_id   bigint references public.products(id) on delete set null,
  product_name text not null,              -- เก็บชื่อ ณ เวลาที่ซื้อ เผื่อสินค้าถูกลบภายหลัง
  unit_price   numeric(10,2) not null,
  qty          integer not null check (qty > 0)
);
create index if not exists order_items_order_idx on public.order_items(order_id);

-- 1.5 ไทม์ไลน์การดำเนินการของคำสั่งซื้อ
create table if not exists public.order_logs (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references public.orders(id) on delete cascade,
  message    text not null,
  created_at timestamptz not null default now()
);
create index if not exists order_logs_order_idx on public.order_logs(order_id);

-- 1.6 รีวิวสินค้า
create table if not exists public.reviews (
  id          bigint generated always as identity primary key,
  product_id  bigint not null references public.products(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  author_name text not null,
  stars       smallint not null check (stars between 1 and 5),
  body        text not null,
  created_at  timestamptz not null default now(),
  unique (product_id, user_id)             -- หนึ่งคนรีวิวหนึ่งสินค้าได้ครั้งเดียว
);
create index if not exists reviews_product_idx on public.reviews(product_id);

-- 1.7 ข้อความติดต่อร้าน
create table if not exists public.messages (
  id         bigint generated always as identity primary key,
  name       text not null,
  email      text not null,
  topic      text not null default 'อื่น ๆ',
  body       text not null,
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);


-- ============ ส่วนที่ 2: ฟังก์ชันช่วยและทริกเกอร์ ============

-- 2.1 ตรวจว่าผู้ใช้ปัจจุบันเป็นผู้ดูแลร้านหรือไม่
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- 2.2 สร้างโปรไฟล์อัตโนมัติเมื่อมีสมาชิกใหม่สมัคร
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone, address)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(new.raw_user_meta_data->>'address', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2.3 กันไม่ให้สมาชิกแก้วงเงินเครดิตหรือยกระดับตัวเองเป็นผู้ดูแล
--     ข้อยกเว้น: ผู้ดูแลร้าน และการแก้ไขที่มาจากฟังก์ชันของระบบเอง
--     (ในฟังก์ชัน security definer ค่า current_user จะไม่ใช่ anon/authenticated)
--     ห้ามใส่ security definer ให้ฟังก์ชันนี้ มิฉะนั้น current_user จะกลายเป็นเจ้าของฟังก์ชันเสมอ
create or replace function public.guard_profile_update()
returns trigger
language plpgsql set search_path = public
as $$
begin
  if current_user not in ('anon','authenticated') or public.is_admin() then
    return new;
  end if;
  new.credit_limit   := old.credit_limit;
  new.credit_used    := old.credit_used;
  new.account_status := old.account_status;
  new.is_admin       := old.is_admin;
  return new;
end;
$$;

drop trigger if exists guard_profile_update_trg on public.profiles;
create trigger guard_profile_update_trg
  before update on public.profiles
  for each row execute function public.guard_profile_update();

-- 2.4 อัปเดตเวลาแก้ไขล่าสุดของคำสั่งซื้อ
create or replace function public.touch_order()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists touch_order_trg on public.orders;
create trigger touch_order_trg
  before update on public.orders
  for each row execute function public.touch_order();


-- ============ ส่วนที่ 3: เปิด RLS และกำหนดสิทธิ์ ============

alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;
alter table public.order_logs  enable row level security;
alter table public.reviews     enable row level security;
alter table public.messages    enable row level security;

-- 3.1 profiles: เจ้าของอ่าน/แก้ของตัวเองได้ ผู้ดูแลเห็นทั้งหมด
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update using (id = auth.uid() or public.is_admin());

-- 3.2 products: ใครก็ดูได้ แต่แก้ได้เฉพาะผู้ดูแล
drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select using (is_active or public.is_admin());

drop policy if exists products_write on public.products;
create policy products_write on public.products
  for all using (public.is_admin()) with check (public.is_admin());

-- 3.3 orders: เจ้าของและผู้ดูแลเท่านั้น (ลูกค้าทั่วไปดูผ่านฟังก์ชันติดตามพัสดุ)
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders
  for update using (public.is_admin()) with check (public.is_admin());

-- 3.4 order_items / order_logs: ตามสิทธิ์ของคำสั่งซื้อแม่
drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items
  for select using (exists (
    select 1 from public.orders o
    where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
  ));

drop policy if exists order_logs_select on public.order_logs;
create policy order_logs_select on public.order_logs
  for select using (exists (
    select 1 from public.orders o
    where o.id = order_id and (o.user_id = auth.uid() or public.is_admin())
  ));

-- 3.5 reviews: ใครก็อ่านได้ สมาชิกเขียน/แก้/ลบของตัวเองได้
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews for select using (true);

drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews
  for insert with check (user_id = auth.uid());

drop policy if exists reviews_update on public.reviews;
create policy reviews_update on public.reviews
  for update using (user_id = auth.uid() or public.is_admin());

drop policy if exists reviews_delete on public.reviews;
create policy reviews_delete on public.reviews
  for delete using (user_id = auth.uid() or public.is_admin());

-- 3.6 messages: ใครก็ส่งได้ แต่อ่านได้เฉพาะผู้ดูแล
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert with check (true);

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select using (public.is_admin());

drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages
  for update using (public.is_admin()) with check (public.is_admin());


-- ============ ส่วนที่ 4: ฟังก์ชันธุรกรรม (เรียกจากหน้าเว็บ) ============

create sequence if not exists public.order_code_seq start 12;

-- 4.1 สั่งซื้อสินค้า — ตรวจสต็อก คิดราคาและค่าส่งฝั่งเซิร์ฟเวอร์ ตัดสต็อก และออกเลขที่คำสั่งซื้อ
--     p_items ตัวอย่าง: '[{"product_id":1,"qty":2},{"product_id":12,"qty":1}]'
create or replace function public.place_order(
  p_items    jsonb,
  p_name     text,
  p_phone    text,
  p_address  text,
  p_payment  text,
  p_note     text default '',
  p_slip_url text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_item     jsonb;
  v_product  public.products%rowtype;
  v_qty      integer;
  v_subtotal numeric(10,2) := 0;
  v_ship     numeric(10,2) := 0;
  v_total    numeric(10,2);
  v_code     text;
  v_order_id bigint;
  v_left     numeric(10,2);
  v_profile  public.profiles%rowtype;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'ไม่มีสินค้าในตะกร้า';
  end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_phone),'') = '' or coalesce(trim(p_address),'') = '' then
    raise exception 'กรุณากรอกชื่อผู้รับ เบอร์โทร และที่อยู่จัดส่งให้ครบ';
  end if;

  -- ตรวจสต็อกและคิดยอดรวมจากราคาในฐานข้อมูล (กันการแก้ราคาฝั่งเบราว์เซอร์)
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::int;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::bigint and is_active for update;
    if not found then
      raise exception 'ไม่พบสินค้ารหัส %', v_item->>'product_id';
    end if;
    if v_qty <= 0 then
      raise exception 'จำนวนสินค้าไม่ถูกต้อง';
    end if;
    if v_product.stock < v_qty then
      raise exception 'สินค้า “%” คงเหลือเพียง % ชิ้น', v_product.name, v_product.stock;
    end if;
    v_subtotal := v_subtotal + v_product.price * v_qty;
  end loop;

  -- ค่าจัดส่ง: ซื้อครบ 1,000 บาทส่งฟรี / เก็บเงินปลายทางบวก 20 บาท
  v_ship  := case when v_subtotal >= 1000 then 0 else 60 end
           + case when p_payment like '%ปลายทาง%' then 20 else 0 end;
  v_total := v_subtotal + v_ship;

  -- ชำระด้วยเครดิตสมาชิก ต้องเป็นสมาชิก บัญชีไม่ถูกระงับ และวงเงินพอ
  if p_payment like '%เครดิตสมาชิก%' then
    if v_uid is null then
      raise exception 'ช่องทางเครดิตสมาชิกใช้ได้เฉพาะสมาชิกที่เข้าสู่ระบบแล้ว';
    end if;
    select * into v_profile from public.profiles where id = v_uid for update;
    if v_profile.account_status = 'ระงับ' then
      raise exception 'บัญชีของคุณถูกระงับการใช้วงเงินชั่วคราว กรุณาติดต่อร้าน';
    end if;
    v_left := v_profile.credit_limit - v_profile.credit_used;
    if v_total > v_left then
      raise exception 'วงเงินเครดิตคงเหลือ % บาท ไม่พอสำหรับยอด % บาท', v_left, v_total;
    end if;
    update public.profiles set credit_used = credit_used + v_total where id = v_uid;
  end if;

  -- ออกเลขที่คำสั่งซื้อรูปแบบ GP + ปี พ.ศ. 2 หลัก + เดือน + ลำดับ 4 หลัก
  v_code := 'GP'
          || ((to_char(now() at time zone 'Asia/Bangkok', 'YY')::int + 43)::text)
          || to_char(now() at time zone 'Asia/Bangkok', 'MM')
          || lpad((nextval('public.order_code_seq'))::text, 4, '0');

  insert into public.orders (code, user_id, receiver_name, phone, address, note,
                             subtotal, shipping_fee, total, payment_method, slip_url)
  values (v_code, v_uid, trim(p_name), trim(p_phone), trim(p_address), coalesce(p_note,''),
          v_subtotal, v_ship, v_total, p_payment, p_slip_url)
  returning id into v_order_id;

  -- บันทึกรายการและตัดสต็อก
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::int;
    select * into v_product from public.products where id = (v_item->>'product_id')::bigint;
    insert into public.order_items (order_id, product_id, product_name, unit_price, qty)
    values (v_order_id, v_product.id, v_product.name, v_product.price, v_qty);
    update public.products set stock = stock - v_qty where id = v_product.id;
  end loop;

  insert into public.order_logs (order_id, message)
  values (v_order_id, 'ระบบรับคำสั่งซื้อ รอร้านตรวจสอบและอนุมัติ');

  return jsonb_build_object(
    'code', v_code, 'order_id', v_order_id,
    'subtotal', v_subtotal, 'shipping_fee', v_ship, 'total', v_total
  );
end;
$$;

-- 4.2 ติดตามพัสดุด้วยเลขที่คำสั่งซื้อ (ลูกค้าทั่วไปที่ไม่ได้เข้าสู่ระบบก็ใช้ได้)
create or replace function public.track_order(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_order public.orders%rowtype; v_result jsonb;
begin
  select * into v_order from public.orders where code = upper(trim(p_code));
  if not found then
    return null;
  end if;
  select jsonb_build_object(
    'code', v_order.code,
    'status', v_order.status,
    'created_at', v_order.created_at,
    'receiver_name', v_order.receiver_name,
    'address', v_order.address,
    'payment_method', v_order.payment_method,
    'subtotal', v_order.subtotal,
    'shipping_fee', v_order.shipping_fee,
    'total', v_order.total,
    'carrier', v_order.carrier,
    'tracking_no', v_order.tracking_no,
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'name', i.product_name, 'price', i.unit_price, 'qty', i.qty) order by i.id), '[]'::jsonb)
              from public.order_items i where i.order_id = v_order.id),
    'logs',  (select coalesce(jsonb_agg(jsonb_build_object(
                'message', l.message, 'at', l.created_at) order by l.id), '[]'::jsonb)
              from public.order_logs l where l.order_id = v_order.id)
  ) into v_result;
  return v_result;
end;
$$;

-- 4.3 ผู้ดูแลเปลี่ยนสถานะคำสั่งซื้อ (อนุมัติ / เริ่มแพ็ก / จัดส่ง / ส่งถึง / ไม่อนุมัติ)
create or replace function public.admin_update_order(
  p_code    text,
  p_action  text,               -- 'approve' | 'packing' | 'ship' | 'deliver' | 'reject'
  p_carrier text default null,
  p_track   text default null,
  p_reason  text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_order public.orders%rowtype; v_msg text; v_new text;
begin
  if not public.is_admin() then
    raise exception 'เฉพาะผู้ดูแลร้านเท่านั้น';
  end if;

  select * into v_order from public.orders where code = upper(trim(p_code)) for update;
  if not found then raise exception 'ไม่พบคำสั่งซื้อ %', p_code; end if;

  if p_action = 'approve' then
    if v_order.status <> 'await' then raise exception 'คำสั่งซื้อนี้ผ่านการตรวจสอบไปแล้ว'; end if;
    v_new := 'approved';
    v_msg := 'ตรวจสอบการชำระเงิน/เครดิตผ่าน อนุมัติคำสั่งซื้อโดยผู้ดูแลร้าน';

  elsif p_action = 'packing' then
    v_new := 'packing';
    v_msg := 'เริ่มจัดเตรียมสินค้าและแพ็กกล่องกันกระแทก';

  elsif p_action = 'ship' then
    if coalesce(trim(p_track),'') = '' then raise exception 'กรุณากรอกเลขพัสดุ'; end if;
    v_new := 'shipped';
    v_msg := 'ส่งมอบพัสดุให้ ' || coalesce(p_carrier,'บริษัทขนส่ง') || ' เลขพัสดุ ' || p_track;
    update public.orders set carrier = coalesce(p_carrier,''), tracking_no = p_track where id = v_order.id;

  elsif p_action = 'deliver' then
    v_new := 'done';
    v_msg := 'ขนส่งยืนยันส่งถึงผู้รับเรียบร้อย';

  elsif p_action = 'reject' then
    if v_order.status in ('shipped','done') then raise exception 'พัสดุถูกส่งออกไปแล้ว ยกเลิกไม่ได้'; end if;
    v_new := 'reject';
    v_msg := 'ไม่อนุมัติคำสั่งซื้อ — ' || coalesce(nullif(trim(p_reason),''), 'ไม่ระบุเหตุผล');
    -- คืนสต็อกและคืนวงเงินเครดิต
    update public.products p set stock = p.stock + i.qty
      from public.order_items i where i.order_id = v_order.id and p.id = i.product_id;
    if v_order.payment_method like '%เครดิตสมาชิก%' and v_order.user_id is not null then
      update public.profiles set credit_used = greatest(0, credit_used - v_order.total)
        where id = v_order.user_id;
    end if;
  else
    raise exception 'คำสั่งไม่ถูกต้อง: %', p_action;
  end if;

  update public.orders set status = v_new where id = v_order.id;
  insert into public.order_logs (order_id, message) values (v_order.id, v_msg);

  return jsonb_build_object('code', v_order.code, 'status', v_new, 'message', v_msg);
end;
$$;

-- 4.4 ผู้ดูแลบันทึกการรับชำระยอดวางบิลของสมาชิก
create or replace function public.admin_clear_credit(p_user uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'เฉพาะผู้ดูแลร้านเท่านั้น'; end if;
  update public.profiles set credit_used = 0 where id = p_user;
end;
$$;

-- 4.5 มุมมองสรุปคะแนนรีวิวของสินค้า (ใช้แสดงดาวบนการ์ดสินค้า)
create or replace view public.product_ratings as
  select product_id,
         round(avg(stars)::numeric, 1) as avg_stars,
         count(*)                      as review_count
  from public.reviews group by product_id;

grant select on public.product_ratings to anon, authenticated;
grant execute on function public.place_order(jsonb,text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.track_order(text)                                to anon, authenticated;
grant execute on function public.admin_update_order(text,text,text,text,text)     to authenticated;
grant execute on function public.admin_clear_credit(uuid)                         to authenticated;


-- ============ ส่วนที่ 5: ที่เก็บไฟล์ (Storage) ============

insert into storage.buckets (id, name, public)
values ('product-images','product-images', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('payment-slips','payment-slips', false)
on conflict (id) do nothing;

-- รูปสินค้า: ใครก็ดูได้ แต่อัปโหลด/ลบได้เฉพาะผู้ดูแล
drop policy if exists product_images_read on storage.objects;
create policy product_images_read on storage.objects
  for select using (bucket_id = 'product-images');

drop policy if exists product_images_write on storage.objects;
create policy product_images_write on storage.objects
  for all using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());

-- สลิปโอนเงิน: ลูกค้าอัปโหลดได้ แต่เปิดดูได้เฉพาะผู้ดูแล
drop policy if exists payment_slips_upload on storage.objects;
create policy payment_slips_upload on storage.objects
  for insert with check (bucket_id = 'payment-slips');

drop policy if exists payment_slips_read on storage.objects;
create policy payment_slips_read on storage.objects
  for select using (bucket_id = 'payment-slips' and public.is_admin());


-- ============ ส่วนที่ 6: ข้อมูลสินค้าตั้งต้น 16 รายการ ============

insert into public.products
 (sku, name, sci_name, category, price, old_price, stock, size_label, light, water, care_level, art_key, description) values
('GP-PL-001','มอนสเตอร่า เดลิซิโอซ่า','Monstera deliciosa','ไม้ฟอกอากาศ',890,1090,14,'กระถาง 8 นิ้ว / สูง 60 ซม.','แสงรำไร','รดน้ำ 2 ครั้ง/สัปดาห์','ง่าย','monstera','ใบใหญ่แฉกสวย เป็นไม้ประดับยอดนิยมสำหรับมุมรับแขก ช่วยฟอกอากาศและทนต่อสภาพในร่มได้ดี'),
('GP-PL-002','ลิ้นมังกรทองคำ','Sansevieria trifasciata','ไม้ฟอกอากาศ',320,0,32,'กระถาง 6 นิ้ว / สูง 40 ซม.','ทนได้ทุกแสง','รดน้ำ 1 ครั้ง/สัปดาห์','ง่ายมาก','snake','ไม้มงคลปลูกเลี้ยงง่ายที่สุด คายออกซิเจนตอนกลางคืน เหมาะวางในห้องนอนและห้องทำงาน'),
('GP-PL-003','พลูด่างมาร์เบิล','Epipremnum aureum','ไม้ฟอกอากาศ',150,0,45,'กระถางแขวน 5 นิ้ว','แสงรำไร','รดน้ำ 2 ครั้ง/สัปดาห์','ง่ายมาก','pothos','เถาเลื้อยใบด่างขาวครีม ปลูกในน้ำหรือดินก็ได้ เหมาะทำสวนแนวตั้งและกระถางแขวน'),
('GP-PL-004','ยางอินเดียใบดำ','Ficus elastica','ไม้ฟอกอากาศ',750,0,9,'กระถาง 8 นิ้ว / สูง 70 ซม.','แสงแดดรำไรถึงจัด','รดน้ำ 1-2 ครั้ง/สัปดาห์','ปานกลาง','ficus','ใบหนามันวาวสีเขียวเข้มเกือบดำ ทรงต้นตั้งตรง ให้ความรู้สึกหรูหราแบบมินิมอล'),
('GP-PL-005','ไทรใบสัก','Ficus lyrata','ไม้ฟอกอากาศ',1290,1490,6,'กระถาง 10 นิ้ว / สูง 100 ซม.','แสงสว่างมาก','รดน้ำ 1 ครั้ง/สัปดาห์','ปานกลาง','ficus','ไม้ประธานของห้องนั่งเล่น ใบใหญ่รูปไวโอลิน ต้องการแสงสว่างสม่ำเสมอและไม่ชอบการย้ายที่บ่อย'),
('GP-SC-001','แอสโตรไฟตัม ดาวกระจาย','Astrophytum myriostigma','ไม้อวบน้ำ',280,0,21,'กระถาง 3 นิ้ว','แดดจัด','รดน้ำ 1 ครั้ง/2 สัปดาห์','ง่าย','cactus','กระบองเพชรทรงดาวไร้หนาม ผิวมีจุดขาวคล้ายหิมะ เหมาะตั้งโต๊ะทำงานริมหน้าต่าง'),
('GP-SC-002','ฮาโวเทีย คูเปอรี่','Haworthia cooperi','ไม้อวบน้ำ',220,0,27,'กระถาง 3 นิ้ว','แสงรำไร','รดน้ำ 1 ครั้ง/10 วัน','ง่าย','succulent','ใบอวบใสเหมือนเม็ดวุ้น สะสมน้ำได้ดี ดูแลง่าย เหมาะกับผู้เริ่มต้นเลี้ยงไม้อวบน้ำ'),
('GP-PL-006','เฟิร์นข้าหลวงหลังลาย','Asplenium nidus','ไม้ฟอกอากาศ',390,0,0,'กระถาง 6 นิ้ว','แสงรำไร ชอบความชื้น','รดน้ำ 3 ครั้ง/สัปดาห์','ปานกลาง','fern','ใบเรียงเป็นวงคล้ายรังนก ชอบความชื้นสูง เหมาะวางในห้องน้ำที่มีแสงธรรมชาติ'),
('GP-PT-001','กระถางดินเผา ทรงคลาสสิก 8 นิ้ว','Terracotta pot','กระถาง',180,0,60,'ปาก 8 นิ้ว / สูง 7 นิ้ว','-','ระบายน้ำดีเยี่ยม','-','pot','กระถางดินเผาเนื้อแน่น มีรูระบายน้ำ ช่วยระบายความชื้นรอบราก เหมาะกับไม้อวบน้ำและไม้ในร่ม'),
('GP-PT-002','กระถางเซรามิกมินิมอล ขาว 6 นิ้ว','Ceramic pot','กระถาง',260,320,38,'ปาก 6 นิ้ว พร้อมจานรอง','-','มีรูระบายน้ำ','-','pot2','เคลือบด้านสีขาวนวล พร้อมจานรองในตัว เข้ากับบ้านสไตล์มินิมอลและญี่ปุ่น'),
('GP-PT-003','กระถางปูนเปลือย ทรงสูง 10 นิ้ว','Concrete planter','กระถาง',450,0,17,'ปาก 10 นิ้ว / สูง 14 นิ้ว','-','มีรูระบายน้ำ','-','pot3','ปูนเปลือยผิวหยาบสไตล์ลอฟท์ น้ำหนักมั่นคง รองรับไม้ใหญ่อย่างไทรใบสักและยางอินเดีย'),
('GP-SL-001','ดินปลูกพรีเมียม สูตรไม้ใบ 5 ลิตร','Premium potting mix','ดินและวัสดุปลูก',120,0,80,'ถุง 5 ลิตร','-','อุ้มน้ำ ระบายน้ำดี','-','soil','ผสมพีทมอส เพอร์ไลต์ และขุยมะพร้าว โปร่ง ไม่แน่นทึบ รากเดินดี พร้อมปลูกทันที'),
('GP-SL-002','ดินอินทรีย์ผสมพร้อมปลูก 10 ลิตร','Organic soil mix','ดินและวัสดุปลูก',199,0,52,'ถุง 10 ลิตร','-','อุ้มน้ำสูง','-','soil','ดินอินทรีย์ผสมมูลไส้เดือน ให้ธาตุอาหารครบ ปลอดภัยกับผักสวนครัวและไม้กระถางทุกชนิด'),
('GP-SL-003','หินภูเขาไฟโรยหน้า 1 กก.','Volcanic rock','ดินและวัสดุปลูก',90,0,96,'ถุง 1 กิโลกรัม','-','ลดการระเหย','-','rock','โรยหน้ากระถางเพื่อความสวยงาม ลดการระเหยของน้ำ และป้องกันแมลงหวี่วางไข่บนผิวดิน'),
('GP-TL-001','ชุดอุปกรณ์ปลูกต้นไม้ 5 ชิ้น','Gardening tool set','อุปกรณ์',350,420,24,'พลั่ว ส้อมพรวน กรรไกร แปรง ถุงมือ','-','-','-','tools','สแตนเลสด้ามไม้ ครบชุดสำหรับเปลี่ยนกระถางและดูแลต้นไม้ประจำสัปดาห์'),
('GP-TL-002','บัวรดน้ำสแตนเลส 1.5 ลิตร','Watering can','อุปกรณ์',420,0,19,'ความจุ 1.5 ลิตร พวยยาว','-','-','-','can','พวยยาวควบคุมทิศทางน้ำได้แม่นยำ รดโคนต้นได้โดยไม่โดนใบ ลดปัญหาใบไหม้และเชื้อรา')
on conflict (sku) do nothing;


-- ============ ส่วนที่ 7: ตั้งบัญชีผู้ดูแลร้าน ============
-- ขั้นตอน: สมัครสมาชิกผ่านหน้าเว็บด้วยอีเมลที่จะใช้เป็นแอดมินก่อน แล้วค่อยรันคำสั่งนี้
--
--   update public.profiles set is_admin = true, full_name = 'ผู้ดูแลร้าน GreenPlant'
--   where id = (select id from auth.users where email = 'admin@greenplant.co.th');
--
-- ตรวจสอบผลลัพธ์:  select email, is_admin from auth.users u join public.profiles p on p.id = u.id;


-- ==================================================================
--  ส่วนที่ 2  อีเมลในตารางโปรไฟล์
-- ==================================================================

alter table public.profiles add column if not exists email text not null default '';

-- 2) ให้สมาชิกใหม่บันทึกอีเมลลงโปรไฟล์อัตโนมัติ
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, phone, address)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(new.raw_user_meta_data->>'address', '')
  )
  on conflict (id) do update
    set email = excluded.email
  where public.profiles.email = '';
  return new;
end;
$$;

-- 3) เติมอีเมลให้สมาชิกที่สมัครไปก่อนหน้านี้
update public.profiles p
   set email = u.email
  from auth.users u
 where u.id = p.id and p.email = '';

-- 4) กันไม่ให้สมาชิกแก้อีเมลในโปรไฟล์เอง (ต้องเปลี่ยนผ่านระบบ auth เท่านั้น)
create or replace function public.guard_profile_update()
returns trigger
language plpgsql set search_path = public
as $$
begin
  if current_user not in ('anon','authenticated') or public.is_admin() then
    return new;
  end if;
  new.email         := old.email;
  new.credit_limit  := old.credit_limit;
  new.credit_used   := old.credit_used;
  new.account_status:= old.account_status;
  new.is_admin      := old.is_admin;
  return new;
end;
$$;

-- ตรวจสอบผลลัพธ์
select email, full_name, is_admin, credit_limit, credit_used from public.profiles;


-- ==================================================================
--  ส่วนที่ 3  คูปองส่วนลด การประมูล และการยินยอมตามกฎหมาย
-- ==================================================================

create table if not exists public.coupons (
  id            bigint generated always as identity primary key,
  code          text not null unique,
  description   text not null default '',
  discount_type text not null check (discount_type in ('percent','amount','freeship')),
  discount_value numeric(10,2) not null default 0 check (discount_value >= 0),
  min_subtotal  numeric(10,2) not null default 0,
  max_discount  numeric(10,2) not null default 0,   -- 0 = ไม่จำกัดเพดาน
  usage_limit   integer not null default 0,         -- 0 = ใช้ได้ไม่จำกัดครั้ง
  used_count    integer not null default 0,
  starts_at     timestamptz not null default now(),
  ends_at       timestamptz,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
comment on table public.coupons is 'คูปองส่งเสริมการขาย ตรวจสอบเงื่อนไขฝั่งเซิร์ฟเวอร์';

-- 5.2 ผู้สมัครรับข่าวสาร
create table if not exists public.newsletter (
  id         bigint generated always as identity primary key,
  email      text not null unique,
  created_at timestamptz not null default now()
);

-- 5.3 เพิ่มคอลัมน์ส่วนลดและการยอมรับเงื่อนไขในคำสั่งซื้อ (บทที่ 5 + บทที่ 8)
alter table public.orders add column if not exists discount       numeric(10,2) not null default 0;
alter table public.orders add column if not exists coupon_code    text;
alter table public.orders add column if not exists accepted_terms boolean not null default false;
alter table public.orders add column if not exists consent_at     timestamptz;

-- ============ บทที่ 9: การประมูลอิเล็กทรอนิกส์ (Electronic Auction) ============

-- 9.1 รายการประมูล (ประมูลแบบเพิ่มราคา / English Auction)
create table if not exists public.auctions (
  id            bigint generated always as identity primary key,
  title         text not null,
  sci_name      text not null default '',
  description   text not null default '',
  art_key       text not null default 'monstera',
  image_url     text,
  start_price   numeric(10,2) not null check (start_price > 0),
  min_increment numeric(10,2) not null default 50 check (min_increment > 0),
  current_price numeric(10,2) not null default 0,
  bid_count     integer not null default 0,
  top_bidder_id uuid references public.profiles(id) on delete set null,
  top_bidder    text not null default '',
  ends_at       timestamptz not null,
  status        text not null default 'open' check (status in ('open','closed')),
  winner_name   text not null default '',
  created_at    timestamptz not null default now()
);

-- 9.2 ประวัติการเสนอราคา
create table if not exists public.bids (
  id          bigint generated always as identity primary key,
  auction_id  bigint not null references public.auctions(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  bidder_name text not null,
  amount      numeric(10,2) not null check (amount > 0),
  created_at  timestamptz not null default now()
);
create index if not exists bids_auction_idx on public.bids(auction_id, amount desc);

-- ============ สิทธิ์การเข้าถึง ============

alter table public.coupons    enable row level security;
alter table public.newsletter enable row level security;
alter table public.auctions   enable row level security;
alter table public.bids       enable row level security;

drop policy if exists coupons_select on public.coupons;
create policy coupons_select on public.coupons for select using (is_active or public.is_admin());
drop policy if exists coupons_write on public.coupons;
create policy coupons_write on public.coupons for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists newsletter_insert on public.newsletter;
create policy newsletter_insert on public.newsletter for insert with check (true);
drop policy if exists newsletter_select on public.newsletter;
create policy newsletter_select on public.newsletter for select using (public.is_admin());

drop policy if exists auctions_select on public.auctions;
create policy auctions_select on public.auctions for select using (true);
drop policy if exists auctions_write on public.auctions;
create policy auctions_write on public.auctions for all
  using (public.is_admin()) with check (public.is_admin());

-- ประวัติการเสนอราคาเปิดให้ทุกคนดูได้ เพื่อความโปร่งใสของการประมูล
drop policy if exists bids_select on public.bids;
create policy bids_select on public.bids for select using (true);

-- ============ ฟังก์ชันธุรกรรม ============

-- ตรวจสอบคูปองและคำนวณส่วนลด (ใช้ทั้งตอนแสดงผลและตอนสั่งซื้อจริง)
create or replace function public.calc_discount(p_code text, p_subtotal numeric, p_ship numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_c public.coupons%rowtype; v_disc numeric(10,2) := 0; v_ship numeric(10,2) := p_ship;
begin
  if coalesce(trim(p_code),'') = '' then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', '');
  end if;

  select * into v_c from public.coupons where upper(code) = upper(trim(p_code));
  if not found then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'ไม่พบรหัสส่วนลดนี้');
  end if;
  if not v_c.is_active then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ถูกปิดใช้งานแล้ว');
  end if;
  if now() < v_c.starts_at then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ยังไม่เริ่มใช้งาน');
  end if;
  if v_c.ends_at is not null and now() > v_c.ends_at then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้หมดอายุแล้ว');
  end if;
  if v_c.usage_limit > 0 and v_c.used_count >= v_c.usage_limit then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ถูกใช้ครบจำนวนแล้ว');
  end if;
  if p_subtotal < v_c.min_subtotal then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship,
      'message', 'ต้องซื้อครบ ' || trim(to_char(v_c.min_subtotal,'FM999,999')) || ' บาทจึงใช้รหัสนี้ได้');
  end if;

  if v_c.discount_type = 'percent' then
    v_disc := round(p_subtotal * v_c.discount_value / 100, 2);
    if v_c.max_discount > 0 and v_disc > v_c.max_discount then v_disc := v_c.max_discount; end if;
  elsif v_c.discount_type = 'amount' then
    v_disc := least(v_c.discount_value, p_subtotal);
  elsif v_c.discount_type = 'freeship' then
    v_ship := 0;
  end if;

  return jsonb_build_object(
    'valid', true, 'discount', v_disc, 'shipping', v_ship,
    'code', v_c.code, 'description', v_c.description,
    'message', 'ใช้รหัส ' || v_c.code || ' แล้ว: ' || v_c.description
  );
end;
$$;

-- สั่งซื้อสินค้า (ฉบับปรับปรุง: รองรับคูปองและการยอมรับเงื่อนไข)
drop function if exists public.place_order(jsonb,text,text,text,text,text,text);
create or replace function public.place_order(
  p_items    jsonb,
  p_name     text,
  p_phone    text,
  p_address  text,
  p_payment  text,
  p_note     text default '',
  p_slip_url text default null,
  p_coupon   text default null,
  p_accept   boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_item     jsonb;
  v_product  public.products%rowtype;
  v_qty      integer;
  v_subtotal numeric(10,2) := 0;
  v_ship     numeric(10,2) := 0;
  v_disc     numeric(10,2) := 0;
  v_total    numeric(10,2);
  v_code     text;
  v_order_id bigint;
  v_left     numeric(10,2);
  v_profile  public.profiles%rowtype;
  v_coupon   jsonb;
  v_cname    text := null;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'ไม่มีสินค้าในตะกร้า';
  end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_phone),'') = '' or coalesce(trim(p_address),'') = '' then
    raise exception 'กรุณากรอกชื่อผู้รับ เบอร์โทร และที่อยู่จัดส่งให้ครบ';
  end if;
  -- บทที่ 8: ต้องยอมรับเงื่อนไขการใช้บริการและนโยบายความเป็นส่วนตัวก่อนสั่งซื้อ
  if not coalesce(p_accept, false) then
    raise exception 'กรุณายอมรับเงื่อนไขการใช้บริการและนโยบายความเป็นส่วนตัวก่อนยืนยันการสั่งซื้อ';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::int;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::bigint and is_active for update;
    if not found then raise exception 'ไม่พบสินค้ารหัส %', v_item->>'product_id'; end if;
    if v_qty <= 0 then raise exception 'จำนวนสินค้าไม่ถูกต้อง'; end if;
    if v_product.stock < v_qty then
      raise exception 'สินค้า “%” คงเหลือเพียง % ชิ้น', v_product.name, v_product.stock;
    end if;
    v_subtotal := v_subtotal + v_product.price * v_qty;
  end loop;

  v_ship := case when v_subtotal >= 1000 then 0 else 60 end
          + case when p_payment like '%ปลายทาง%' then 20 else 0 end;

  -- คำนวณส่วนลดจากคูปองที่เซิร์ฟเวอร์ ไม่เชื่อค่าที่ส่งมาจากเบราว์เซอร์
  if coalesce(trim(p_coupon),'') <> '' then
    v_coupon := public.calc_discount(p_coupon, v_subtotal, v_ship);
    if not (v_coupon->>'valid')::boolean then
      raise exception '%', v_coupon->>'message';
    end if;
    v_disc  := (v_coupon->>'discount')::numeric;
    v_ship  := (v_coupon->>'shipping')::numeric;
    v_cname := v_coupon->>'code';
  end if;

  v_total := v_subtotal - v_disc + v_ship;

  if p_payment like '%เครดิตสมาชิก%' then
    if v_uid is null then
      raise exception 'ช่องทางเครดิตสมาชิกใช้ได้เฉพาะสมาชิกที่เข้าสู่ระบบแล้ว';
    end if;
    select * into v_profile from public.profiles where id = v_uid for update;
    if v_profile.account_status = 'ระงับ' then
      raise exception 'บัญชีของคุณถูกระงับการใช้วงเงินชั่วคราว กรุณาติดต่อร้าน';
    end if;
    v_left := v_profile.credit_limit - v_profile.credit_used;
    if v_total > v_left then
      raise exception 'วงเงินเครดิตคงเหลือ % บาท ไม่พอสำหรับยอด % บาท', v_left, v_total;
    end if;
    update public.profiles set credit_used = credit_used + v_total where id = v_uid;
  end if;

  v_code := 'GP'
          || ((to_char(now() at time zone 'Asia/Bangkok', 'YY')::int + 43)::text)
          || to_char(now() at time zone 'Asia/Bangkok', 'MM')
          || lpad((nextval('public.order_code_seq'))::text, 4, '0');

  insert into public.orders (code, user_id, receiver_name, phone, address, note,
                             subtotal, shipping_fee, discount, coupon_code, total,
                             payment_method, slip_url, accepted_terms, consent_at)
  values (v_code, v_uid, trim(p_name), trim(p_phone), trim(p_address), coalesce(p_note,''),
          v_subtotal, v_ship, v_disc, v_cname, v_total, p_payment, p_slip_url, true, now())
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::int;
    select * into v_product from public.products where id = (v_item->>'product_id')::bigint;
    insert into public.order_items (order_id, product_id, product_name, unit_price, qty)
    values (v_order_id, v_product.id, v_product.name, v_product.price, v_qty);
    update public.products set stock = stock - v_qty where id = v_product.id;
  end loop;

  if v_cname is not null then
    update public.coupons set used_count = used_count + 1 where upper(code) = upper(v_cname);
  end if;

  insert into public.order_logs (order_id, message)
  values (v_order_id, 'ระบบรับคำสั่งซื้อ รอร้านตรวจสอบและอนุมัติ');

  return jsonb_build_object('code', v_code, 'order_id', v_order_id, 'subtotal', v_subtotal,
                            'discount', v_disc, 'shipping_fee', v_ship, 'total', v_total);
end;
$$;

-- เสนอราคาประมูล
create or replace function public.place_bid(p_auction bigint, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a   public.auctions%rowtype;
  v_p   public.profiles%rowtype;
  v_min numeric(10,2);
begin
  if v_uid is null then raise exception 'ต้องเข้าสู่ระบบสมาชิกก่อนจึงจะเสนอราคาได้'; end if;

  select * into v_p from public.profiles where id = v_uid;
  if v_p.account_status = 'ระงับ' then
    raise exception 'บัญชีของคุณถูกระงับ ไม่สามารถร่วมประมูลได้';
  end if;

  select * into v_a from public.auctions where id = p_auction for update;
  if not found then raise exception 'ไม่พบรายการประมูลนี้'; end if;
  if v_a.status = 'closed' or now() > v_a.ends_at then
    raise exception 'รายการนี้ปิดประมูลแล้ว';
  end if;
  if v_a.top_bidder_id = v_uid then
    raise exception 'คุณเป็นผู้เสนอราคาสูงสุดอยู่แล้ว ไม่ต้องเสนอซ้ำ';
  end if;

  v_min := case when v_a.bid_count = 0 then v_a.start_price
                else v_a.current_price + v_a.min_increment end;
  if p_amount < v_min then
    raise exception 'ต้องเสนอราคาอย่างน้อย % บาท', trim(to_char(v_min,'FM999,999'));
  end if;

  insert into public.bids (auction_id, user_id, bidder_name, amount)
  values (p_auction, v_uid, coalesce(nullif(v_p.full_name,''), v_p.email), p_amount);

  update public.auctions
     set current_price = p_amount,
         bid_count     = bid_count + 1,
         top_bidder_id = v_uid,
         top_bidder    = coalesce(nullif(v_p.full_name,''), v_p.email)
   where id = p_auction;

  return jsonb_build_object('auction_id', p_auction, 'amount', p_amount,
                            'next_min', p_amount + v_a.min_increment);
end;
$$;

-- ผู้ดูแลปิดการประมูลและประกาศผู้ชนะ
create or replace function public.close_auction(p_auction bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_a public.auctions%rowtype;
begin
  if not public.is_admin() then raise exception 'เฉพาะผู้ดูแลร้านเท่านั้น'; end if;
  select * into v_a from public.auctions where id = p_auction for update;
  if not found then raise exception 'ไม่พบรายการประมูลนี้'; end if;

  update public.auctions
     set status = 'closed',
         winner_name = case when v_a.bid_count > 0 then v_a.top_bidder else 'ไม่มีผู้เสนอราคา' end
   where id = p_auction;

  return jsonb_build_object('id', p_auction,
    'winner', case when v_a.bid_count > 0 then v_a.top_bidder else 'ไม่มีผู้เสนอราคา' end,
    'price', v_a.current_price);
end;
$$;

grant execute on function public.calc_discount(text,numeric,numeric) to anon, authenticated;
grant execute on function public.place_order(jsonb,text,text,text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.place_bid(bigint,numeric)  to authenticated;
grant execute on function public.close_auction(bigint)      to authenticated;

-- ============ ข้อมูลตั้งต้น ============

insert into public.coupons (code, description, discount_type, discount_value, min_subtotal, max_discount, usage_limit, ends_at) values
 ('GREEN10',  'ลด 10% สำหรับคำสั่งซื้อตั้งแต่ 500 บาท (สูงสุด 150 บาท)', 'percent',  10, 500, 150, 0,   now() + interval '90 days'),
 ('NEWPLANT', 'ลดทันที 100 บาท สำหรับลูกค้าใหม่ ซื้อครบ 300 บาท',        'amount',  100, 300,   0, 100, now() + interval '90 days'),
 ('FREESHIP', 'ส่งฟรีทุกยอดสั่งซื้อ ไม่มีขั้นต่ำ',                          'freeship',  0,   0,   0, 0,   now() + interval '30 days')
on conflict (code) do nothing;

-- ใส่ข้อมูลตัวอย่างเฉพาะตอนที่ยังไม่มีรายการประมูลใด ๆ เพื่อให้รันสคริปต์ซ้ำได้โดยไม่เกิดรายการซ้ำ
insert into public.auctions (title, sci_name, description, art_key, start_price, min_increment, ends_at)
select * from (values
 ('มอนสเตอร่า วาริเอเกท ด่างขาวครึ่งใบ', 'Monstera deliciosa var.',
  'ต้นสะสมหายาก ใบด่างขาวคมชัดกว่าครึ่งใบ สูง 45 ซม. มี 4 ใบสมบูรณ์ รากแข็งแรงเดินเต็มกระถาง', 'monstera',
  3500, 100, now() + interval '3 days'),
 ('ฟิโลเดนดรอน ฟลอริด้า บิวตี้', 'Philodendron Florida Beauty',
  'ไม้ด่างลายกระจายทั้งต้น เลี้ยงในโรงเรือนควบคุมความชื้น 2 ปี ทรงพุ่มสวยพร้อมโชว์', 'pothos',
  2200, 100, now() + interval '5 days'),
 ('กระบองเพชรยิมโนด่าง ทรงกลมสมบูรณ์', 'Gymnocalycium mihanovichii variegata',
  'ลายด่างสีส้มแดงตัดเขียว ทรงกลมได้สัดส่วน เส้นผ่านศูนย์กลาง 8 ซม. ปลูกจากเมล็ด', 'cactus',
  1200,  50, now() + interval '2 days')
) as seed(title, sci_name, description, art_key, start_price, min_increment, ends_at)
where not exists (select 1 from public.auctions);


-- ==================================================================
--  ส่วนที่ 4  ยืนยันตัวตนก่อนดูข้อมูลการจัดส่ง
-- ==================================================================

drop function if exists public.track_order(text);

create or replace function public.track_order(p_code text, p_phone text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_digits text;
  v_given  text;
  v_owner  boolean;
begin
  select * into v_order from public.orders where code = upper(trim(p_code));
  if not found then
    return null;
  end if;

  -- เจ้าของคำสั่งซื้อและผู้ดูแลร้านเข้าถึงได้ทันที
  -- ต้องใช้ coalesce ครอบ เพราะถ้าไม่ได้เข้าสู่ระบบ auth.uid() เป็น NULL
  -- การเทียบจะได้ค่า NULL ไม่ใช่ false ทำให้เงื่อนไขด้านล่างไม่ทำงาน
  v_owner := coalesce(v_order.user_id = auth.uid(), false) or coalesce(public.is_admin(), false);

  if not v_owner then
    -- เทียบเฉพาะตัวเลข 4 ตัวท้ายของเบอร์โทร (ตัดขีดและช่องว่างออกก่อน)
    v_digits := right(regexp_replace(coalesce(v_order.phone,''), '\D', '', 'g'), 4);
    v_given  := right(regexp_replace(coalesce(p_phone,''),      '\D', '', 'g'), 4);
    if v_given = '' or v_given <> v_digits then
      return jsonb_build_object(
        'locked', true,
        'code', v_order.code,
        'message', 'กรุณายืนยันเบอร์โทร 4 ตัวท้ายของผู้รับสินค้า เพื่อความปลอดภัยของข้อมูลส่วนบุคคล'
      );
    end if;
  end if;

  return jsonb_build_object(
    'code', v_order.code,
    'status', v_order.status,
    'created_at', v_order.created_at,
    'receiver_name', v_order.receiver_name,
    'address', v_order.address,
    'payment_method', v_order.payment_method,
    'subtotal', v_order.subtotal,
    'discount', v_order.discount,
    'coupon_code', v_order.coupon_code,
    'shipping_fee', v_order.shipping_fee,
    'total', v_order.total,
    'carrier', v_order.carrier,
    'tracking_no', v_order.tracking_no,
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'name', i.product_name, 'price', i.unit_price, 'qty', i.qty) order by i.id), '[]'::jsonb)
              from public.order_items i where i.order_id = v_order.id),
    'logs',  (select coalesce(jsonb_agg(jsonb_build_object(
                'message', l.message, 'at', l.created_at) order by l.id), '[]'::jsonb)
              from public.order_logs l where l.order_id = v_order.id)
  );
end;
$$;

grant execute on function public.track_order(text,text) to anon, authenticated;


-- ==================================================================
--  ส่วนที่ 5  รายการโปรดและสิทธิตาม PDPA
-- ==================================================================

create table if not exists public.wishlist (
  user_id    uuid   not null references public.profiles(id) on delete cascade,
  product_id bigint not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, product_id)
);
comment on table public.wishlist is 'สินค้าที่สมาชิกเก็บไว้พิจารณา';

alter table public.wishlist enable row level security;

drop policy if exists wishlist_select on public.wishlist;
create policy wishlist_select on public.wishlist
  for select using (user_id = auth.uid());

drop policy if exists wishlist_insert on public.wishlist;
create policy wishlist_insert on public.wishlist
  for insert with check (user_id = auth.uid());

drop policy if exists wishlist_delete on public.wishlist;
create policy wishlist_delete on public.wishlist
  for delete using (user_id = auth.uid());

-- ============ 2) สิทธิเข้าถึงข้อมูลของตนเอง (PDPA มาตรา 30) ============
create or replace function public.export_my_data()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_p public.profiles%rowtype;
begin
  if v_uid is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  select * into v_p from public.profiles where id = v_uid;

  return jsonb_build_object(
    'exported_at', now(),
    'notice', 'สำเนาข้อมูลส่วนบุคคลที่ร้าน GreenPlant จัดเก็บเกี่ยวกับท่าน ตาม พ.ร.บ.คุ้มครองข้อมูลส่วนบุคคล พ.ศ. 2562',
    'profile', jsonb_build_object(
      'email', v_p.email, 'full_name', v_p.full_name, 'phone', v_p.phone,
      'address', v_p.address, 'credit_limit', v_p.credit_limit,
      'credit_used', v_p.credit_used, 'account_status', v_p.account_status,
      'created_at', v_p.created_at),
    'orders', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'code', o.code, 'created_at', o.created_at, 'status', o.status,
        'receiver_name', o.receiver_name, 'phone', o.phone, 'address', o.address,
        'payment_method', o.payment_method, 'subtotal', o.subtotal,
        'discount', o.discount, 'shipping_fee', o.shipping_fee, 'total', o.total,
        'carrier', o.carrier, 'tracking_no', o.tracking_no,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
                    'name', i.product_name, 'price', i.unit_price, 'qty', i.qty)), '[]'::jsonb)
                  from public.order_items i where i.order_id = o.id)
      ) order by o.created_at), '[]'::jsonb)
      from public.orders o where o.user_id = v_uid),
    'reviews', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'product', p.name, 'stars', r.stars, 'body', r.body, 'created_at', r.created_at)), '[]'::jsonb)
      from public.reviews r left join public.products p on p.id = r.product_id
      where r.user_id = v_uid),
    'bids', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'auction', a.title, 'amount', b.amount, 'created_at', b.created_at)), '[]'::jsonb)
      from public.bids b left join public.auctions a on a.id = b.auction_id
      where b.user_id = v_uid),
    'wishlist', (
      select coalesce(jsonb_agg(p.name), '[]'::jsonb)
      from public.wishlist w join public.products p on p.id = w.product_id
      where w.user_id = v_uid)
  );
end;
$$;

-- ============ 3) สิทธิขอให้ลบข้อมูล (PDPA มาตรา 33) ============
--  หมายเหตุ: ข้อมูลคำสั่งซื้อยังต้องเก็บไว้ตามกฎหมายภาษีอากร 5 ปี
--  จึงใช้วิธีลบข้อมูลที่ระบุตัวบุคคลออก (anonymize) แทนการลบทั้งแถว
create or replace function public.delete_my_account()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_orders int; v_tag text;
begin
  if v_uid is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  if public.is_admin() then
    raise exception 'บัญชีผู้ดูแลร้านลบผ่านหน้าเว็บไม่ได้ กรุณาติดต่อผู้ดูแลระบบ';
  end if;

  select count(*) into v_orders from public.orders
   where user_id = v_uid and status not in ('done','reject');
  if v_orders > 0 then
    raise exception 'ยังมีคำสั่งซื้อที่ดำเนินการอยู่ % รายการ กรุณารอให้เสร็จสิ้นก่อนลบบัญชี', v_orders;
  end if;

  v_tag := 'deleted-' || substr(v_uid::text, 1, 8);

  -- ลบข้อมูลที่ไม่จำเป็นต้องเก็บ
  delete from public.wishlist where user_id = v_uid;
  delete from public.reviews  where user_id = v_uid;

  -- ตัดความเชื่อมโยงระหว่างคำสั่งซื้อเดิมกับตัวบุคคล
  update public.orders
     set user_id = null,
         receiver_name = 'ผู้ใช้ที่ขอลบบัญชี',
         phone = '',
         address = '(ลบตามคำขอของเจ้าของข้อมูล)'
   where user_id = v_uid;

  update public.bids set bidder_name = 'ผู้ใช้ที่ขอลบบัญชี' where user_id = v_uid;

  update public.profiles
     set full_name = 'ผู้ใช้ที่ขอลบบัญชี',
         email = v_tag || '@removed.local',
         phone = '', address = '',
         credit_limit = 0, credit_used = 0,
         account_status = 'ระงับ'
   where id = v_uid;

  return jsonb_build_object('deleted', true,
    'message', 'ลบข้อมูลส่วนบุคคลเรียบร้อยแล้ว ข้อมูลคำสั่งซื้อถูกเก็บต่อในรูปแบบที่ระบุตัวบุคคลไม่ได้ ตามที่กฎหมายภาษีอากรกำหนด');
end;
$$;

-- ============ 4) สรุปกิจกรรมของสมาชิก ============
create or replace function public.my_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'ต้องเข้าสู่ระบบก่อน'; end if;
  return jsonb_build_object(
    'orders_total',  (select count(*) from public.orders  where user_id = v_uid),
    'orders_active', (select count(*) from public.orders  where user_id = v_uid and status in ('await','approved','packing','shipped')),
    'spent',         (select coalesce(sum(total),0) from public.orders where user_id = v_uid and status <> 'reject'),
    'reviews',       (select count(*) from public.reviews  where user_id = v_uid),
    'bids',          (select count(*) from public.bids     where user_id = v_uid),
    'auctions_won',  (select count(*) from public.auctions where top_bidder_id = v_uid and status = 'closed'),
    'wishlist',      (select count(*) from public.wishlist where user_id = v_uid)
  );
end;
$$;

grant execute on function public.export_my_data()     to authenticated;
grant execute on function public.delete_my_account()  to authenticated;
grant execute on function public.my_summary()         to authenticated;


-- ==================================================================
--  ส่วนที่ 6  ปิดประมูลอัตโนมัติเมื่อหมดเวลา
-- ==================================================================

do $$
begin
  create extension if not exists pg_cron with schema extensions;
exception when others then
  raise notice 'ข้ามการติดตั้ง pg_cron (%) — ระบบยังใช้งานได้ แต่ต้องกดปิดประมูลเอง', sqlerrm;
end $$;

-- 2) ฟังก์ชันปิดประมูลที่หมดเวลาแล้วทั้งหมด
create or replace function public.close_expired_auctions()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_count integer := 0;
begin
  with expired as (
    update public.auctions
       set status = 'closed',
           winner_name = case when bid_count > 0 then top_bidder else 'ไม่มีผู้เสนอราคา' end
     where status = 'open' and ends_at <= now()
    returning id
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

comment on function public.close_expired_auctions is
  'ปิดรายการประมูลที่หมดเวลาและประกาศผู้ชนะ เรียกโดย pg_cron ทุก 5 นาที';

-- 3) ตั้งเวลาทำงานทุก 5 นาที (ลบงานเดิมก่อนถ้ามี เพื่อให้รันซ้ำได้)
do $$
begin
  begin
    perform cron.unschedule('greenplant-close-auctions');
  exception when others then null;   -- ยังไม่เคยตั้งงานนี้ไว้
  end;

  perform cron.schedule(
    'greenplant-close-auctions',
    '*/5 * * * *',
    'select public.close_expired_auctions();'
  );
  raise notice 'ตั้งงานปิดประมูลอัตโนมัติทุก 5 นาทีเรียบร้อย';
exception when others then
  raise notice 'ตั้งงานตามเวลาไม่สำเร็จ (%) — ผู้ดูแลต้องกดปิดประมูลเองจากหน้าหลังร้าน', sqlerrm;
end $$;

-- 4) ปิดรายการที่ค้างอยู่ตั้งแต่ก่อนติดตั้งแพตช์นี้
select public.close_expired_auctions() as ปิดไปแล้วกี่รายการ;

-- 5) ตรวจสอบว่างานถูกตั้งเรียบร้อย
do $$
declare v_n integer;
begin
  execute 'select count(*) from cron.job where jobname = ''greenplant-close-auctions''' into v_n;
  raise notice 'พบงานตามเวลาที่ตั้งไว้ % รายการ', v_n;
exception when others then
  raise notice 'ตรวจสอบงานตามเวลาไม่ได้ในสภาพแวดล้อมนี้';
end $$;

-- หมายเหตุ: หากโครงการใช้แผนฟรีและถูกพักการทำงานเพราะไม่มีผู้ใช้งาน 7 วัน
-- งานตามเวลาจะหยุดไปด้วย เมื่อกลับมาใช้งานระบบจะปิดรายการที่ค้างให้ในรอบถัดไป


-- ==================================================================
--  ส่วนที่ 7  รีวิวจากผู้ซื้อจริง และคำสั่งซื้อของผู้ชนะประมูล
-- ==================================================================

create or replace function public.has_purchased(p_product bigint, p_user uuid default auth.uid())
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
      from public.orders o
      join public.order_items i on i.order_id = o.id
     where o.user_id = p_user
       and i.product_id = p_product
       and o.status in ('shipped','done')
  );
$$;

-- บังคับกติกาที่ฐานข้อมูล ไม่ใช่แค่ซ่อนปุ่มในหน้าเว็บ
drop policy if exists reviews_insert on public.reviews;
create policy reviews_insert on public.reviews
  for insert with check (
    user_id = auth.uid() and public.has_purchased(product_id, auth.uid())
  );

-- ============ 2) ผู้ชนะประมูลได้รับคำสั่งซื้ออัตโนมัติ ============

alter table public.auctions add column if not exists order_code text;

-- ออกคำสั่งซื้อให้ผู้ชนะของรายการประมูลหนึ่งรายการ
create or replace function public.issue_auction_order(p_auction bigint)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_a     public.auctions%rowtype;
  v_p     public.profiles%rowtype;
  v_code  text;
  v_id    bigint;
begin
  select * into v_a from public.auctions where id = p_auction for update;
  if not found then return null; end if;
  if v_a.order_code is not null then return v_a.order_code; end if;      -- ออกไปแล้ว
  if v_a.bid_count = 0 or v_a.top_bidder_id is null then return null; end if;

  select * into v_p from public.profiles where id = v_a.top_bidder_id;
  if not found then return null; end if;

  v_code := 'GP'
          || ((to_char(now() at time zone 'Asia/Bangkok', 'YY')::int + 43)::text)
          || to_char(now() at time zone 'Asia/Bangkok', 'MM')
          || lpad((nextval('public.order_code_seq'))::text, 4, '0');

  -- ของประมูลราคาสูง จัดส่งฟรีและต้องชำระด้วยการโอนเท่านั้น
  insert into public.orders (code, user_id, receiver_name, phone, address, note,
                             subtotal, shipping_fee, discount, total,
                             payment_method, status, accepted_terms, consent_at)
  values (v_code, v_a.top_bidder_id,
          coalesce(nullif(v_p.full_name,''), v_p.email),
          coalesce(v_p.phone,''), coalesce(v_p.address,''),
          'คำสั่งซื้อจากการชนะประมูลรายการ #' || v_a.id,
          v_a.current_price, 0, 0, v_a.current_price,
          'โอนผ่านธนาคาร / พร้อมเพย์', 'await', true, now())
  returning id into v_id;

  insert into public.order_items (order_id, product_id, product_name, unit_price, qty)
  values (v_id, null, v_a.title || ' (ชนะประมูล)', v_a.current_price, 1);

  insert into public.order_logs (order_id, message)
  values (v_id, 'ระบบออกคำสั่งซื้อจากการชนะประมูล รอผู้ชนะโอนเงินและแนบสลิป');

  update public.auctions set order_code = v_code where id = p_auction;
  return v_code;
end;
$$;

-- ปิดประมูลด้วยตนเอง (ฉบับปรับปรุง: ออกคำสั่งซื้อให้ผู้ชนะด้วย)
create or replace function public.close_auction(p_auction bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_a public.auctions%rowtype; v_code text;
begin
  if not public.is_admin() then raise exception 'เฉพาะผู้ดูแลร้านเท่านั้น'; end if;
  select * into v_a from public.auctions where id = p_auction for update;
  if not found then raise exception 'ไม่พบรายการประมูลนี้'; end if;

  update public.auctions
     set status = 'closed',
         winner_name = case when v_a.bid_count > 0 then v_a.top_bidder else 'ไม่มีผู้เสนอราคา' end
   where id = p_auction;

  v_code := public.issue_auction_order(p_auction);

  return jsonb_build_object(
    'id', p_auction,
    'winner', case when v_a.bid_count > 0 then v_a.top_bidder else 'ไม่มีผู้เสนอราคา' end,
    'price', v_a.current_price,
    'order_code', v_code);
end;
$$;

-- ปิดประมูลอัตโนมัติ (ฉบับปรับปรุง: ออกคำสั่งซื้อให้ผู้ชนะด้วย)
create or replace function public.close_expired_auctions()
returns integer
language plpgsql security definer set search_path = public
as $$
declare v_id bigint; v_count integer := 0;
begin
  for v_id in
    select id from public.auctions where status = 'open' and ends_at <= now()
  loop
    update public.auctions
       set status = 'closed',
           winner_name = case when bid_count > 0 then top_bidder else 'ไม่มีผู้เสนอราคา' end
     where id = v_id;
    perform public.issue_auction_order(v_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

grant execute on function public.has_purchased(bigint, uuid) to anon, authenticated;


-- ==================================================================
--  ส่วนที่ 8  ลูกค้ายกเลิกคำสั่งซื้อเอง
-- ==================================================================

create or replace function public.cancel_my_order(p_code text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_o public.orders%rowtype;
begin
  if auth.uid() is null then
    raise exception 'ต้องเข้าสู่ระบบก่อนจึงจะยกเลิกคำสั่งซื้อได้';
  end if;

  select * into v_o from public.orders
   where code = upper(trim(p_code)) for update;
  if not found then
    raise exception 'ไม่พบคำสั่งซื้อ %', p_code;
  end if;

  -- ยกเลิกได้เฉพาะคำสั่งซื้อของตนเอง
  if v_o.user_id is distinct from auth.uid() then
    raise exception 'ยกเลิกได้เฉพาะคำสั่งซื้อของตนเองเท่านั้น';
  end if;

  -- ยกเลิกได้เฉพาะช่วงที่ร้านยังไม่เริ่มดำเนินการ
  if v_o.status <> 'await' then
    raise exception 'ร้านเริ่มดำเนินการคำสั่งซื้อนี้แล้ว กรุณาติดต่อร้านเพื่อขอยกเลิก';
  end if;

  -- คืนจำนวนสินค้าเข้าคลัง
  update public.products p
     set stock = p.stock + i.qty
    from public.order_items i
   where i.order_id = v_o.id and p.id = i.product_id;

  -- คืนวงเงินเครดิตหากชำระแบบวางบิล
  if v_o.payment_method like '%เครดิตสมาชิก%' then
    update public.profiles
       set credit_used = greatest(0, credit_used - v_o.total)
     where id = v_o.user_id;
  end if;

  -- คืนสิทธิ์การใช้คูปอง
  if v_o.coupon_code is not null then
    update public.coupons
       set used_count = greatest(0, used_count - 1)
     where upper(code) = upper(v_o.coupon_code);
  end if;

  update public.orders set status = 'reject' where id = v_o.id;

  insert into public.order_logs (order_id, message)
  values (v_o.id, 'ลูกค้ายกเลิกคำสั่งซื้อด้วยตนเอง — ' ||
                  coalesce(nullif(trim(p_reason),''), 'ไม่ระบุเหตุผล'));

  return jsonb_build_object('code', v_o.code, 'status', 'reject',
    'message', 'ยกเลิกคำสั่งซื้อเรียบร้อย ระบบคืนสินค้าเข้าคลังและคืนวงเงินให้แล้ว');
end;
$$;

grant execute on function public.cancel_my_order(text, text) to authenticated;


-- ==================================================================
--  ส่วนที่ 9  บันทึกประวัติการทำงานของผู้ดูแล
-- ==================================================================

create table if not exists public.audit_logs (
  id         bigint generated always as identity primary key,
  actor_id   uuid references public.profiles(id) on delete set null,
  actor_name text not null default '',
  action     text not null,              -- ชื่อการกระทำ เช่น แก้ไขสินค้า
  target     text not null default '',   -- สิ่งที่ถูกกระทำ เช่น ชื่อสินค้า
  detail     text not null default '',   -- รายละเอียดการเปลี่ยนแปลง
  created_at timestamptz not null default now()
);
create index if not exists audit_created_idx on public.audit_logs(created_at desc);

alter table public.audit_logs enable row level security;

-- อ่านได้เฉพาะผู้ดูแล และไม่มีใครแก้หรือลบได้ เพื่อให้บันทึกเชื่อถือได้
drop policy if exists audit_select on public.audit_logs;
create policy audit_select on public.audit_logs
  for select using (public.is_admin());

-- บันทึกเหตุการณ์ (เรียกจากหน้าเว็บฝั่งผู้ดูแล)
create or replace function public.log_action(p_action text, p_target text default '', p_detail text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare v_p public.profiles%rowtype;
begin
  if not public.is_admin() then
    raise exception 'เฉพาะผู้ดูแลร้านเท่านั้น';
  end if;
  select * into v_p from public.profiles where id = auth.uid();
  insert into public.audit_logs (actor_id, actor_name, action, target, detail)
  values (auth.uid(), coalesce(nullif(v_p.full_name,''), v_p.email), p_action, coalesce(p_target,''), coalesce(p_detail,''));
end;
$$;

-- บันทึกอัตโนมัติเมื่อมีการแก้ไขสินค้า ไม่ต้องพึ่งหน้าเว็บเรียก
create or replace function public.audit_product_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_name text; v_act text; v_detail text := '';
begin
  select coalesce(nullif(full_name,''), email) into v_name from public.profiles where id = auth.uid();
  if auth.uid() is null then return coalesce(new, old); end if;   -- ไม่ใช่การกระทำผ่านหน้าเว็บ

  if TG_OP = 'INSERT' then
    v_act := 'เพิ่มสินค้าใหม่';
    v_detail := 'ราคา ' || new.price || ' บาท · สต็อก ' || new.stock;
  elsif TG_OP = 'DELETE' then
    v_act := 'ลบสินค้า';
    v_detail := 'รหัส ' || old.sku;
  else
    v_act := 'แก้ไขสินค้า';
    if new.price <> old.price then v_detail := v_detail || 'ราคา ' || old.price || ' → ' || new.price || ' '; end if;
    if new.stock <> old.stock then v_detail := v_detail || 'สต็อก ' || old.stock || ' → ' || new.stock || ' '; end if;
    if new.is_active <> old.is_active then
      v_detail := v_detail || (case when new.is_active then 'เปิดขาย' else 'ปิดขาย' end) || ' ';
    end if;
    if v_detail = '' then return new; end if;    -- ไม่มีอะไรเปลี่ยนที่ต้องบันทึก
  end if;

  insert into public.audit_logs (actor_id, actor_name, action, target, detail)
  values (auth.uid(), coalesce(v_name,''), v_act,
          coalesce(new.name, old.name), trim(v_detail));
  return coalesce(new, old);
end;
$$;

drop trigger if exists audit_product_trg on public.products;
create trigger audit_product_trg
  after insert or update or delete on public.products
  for each row execute function public.audit_product_change();

-- บันทึกอัตโนมัติเมื่อผู้ดูแลปรับวงเงินหรือสถานะบัญชีของสมาชิก
create or replace function public.audit_profile_change()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_name text; v_detail text := '';
begin
  if auth.uid() is null or auth.uid() = new.id then return new; end if;  -- แก้ข้อมูลตัวเองไม่ต้องบันทึก
  if not public.is_admin() then return new; end if;

  if new.credit_limit <> old.credit_limit then
    v_detail := v_detail || 'วงเงิน ' || old.credit_limit || ' → ' || new.credit_limit || ' ';
  end if;
  if new.account_status <> old.account_status then
    v_detail := v_detail || 'สถานะ ' || old.account_status || ' → ' || new.account_status || ' ';
  end if;
  if new.credit_used <> old.credit_used and new.credit_used = 0 then
    v_detail := v_detail || 'บันทึกรับชำระ ' || old.credit_used || ' บาท ';
  end if;
  if v_detail = '' then return new; end if;

  select coalesce(nullif(full_name,''), email) into v_name from public.profiles where id = auth.uid();
  insert into public.audit_logs (actor_id, actor_name, action, target, detail)
  values (auth.uid(), coalesce(v_name,''), 'ปรับข้อมูลสมาชิก',
          coalesce(nullif(new.full_name,''), new.email), trim(v_detail));
  return new;
end;
$$;

drop trigger if exists audit_profile_trg on public.profiles;
create trigger audit_profile_trg
  after update on public.profiles
  for each row execute function public.audit_profile_change();

grant execute on function public.log_action(text,text,text) to authenticated;


-- ==================================================================
--  ส่วนที่ 10 รูปสินค้าหลายรูป
-- ==================================================================

alter table public.products
  add column if not exists images text[] not null default '{}';

comment on column public.products.images is
  'รูปสินค้าทั้งหมด รูปแรกคือรูปหลัก · คอลัมน์ image_url เก็บรูปหลักไว้เพื่อความเข้ากันได้กับข้อมูลเดิม';

-- ย้ายรูปเดิมที่มีอยู่แล้วเข้าไปในอาร์เรย์ เพื่อให้ข้อมูลชุดเดิมยังใช้ได้
update public.products
   set images = array[image_url]
 where image_url is not null
   and image_url <> ''
   and cardinality(images) = 0;

-- ให้รูปหลักตรงกับรูปแรกในอาร์เรย์เสมอ ไม่ว่าจะแก้ผ่านทางไหน
create or replace function public.sync_primary_image()
returns trigger
language plpgsql
as $$
begin
  if new.images is not null and cardinality(new.images) > 0 then
    new.image_url := new.images[1];
  elsif new.image_url is not null and new.image_url <> '' then
    new.images := array[new.image_url];
  end if;
  return new;
end;
$$;

drop trigger if exists sync_primary_image_trg on public.products;
create trigger sync_primary_image_trg
  before insert or update on public.products
  for each row execute function public.sync_primary_image();

select sku, name, cardinality(images) as จำนวนรูป from public.products order by id limit 5;


-- ==================================================================
--  ส่วนที่ 11 ต่อเวลาประมูลและคูปองจำกัดต่อคน
-- ==================================================================

alter table public.auctions
  add column if not exists extend_seconds integer not null default 120;

comment on column public.auctions.extend_seconds is
  'ถ้ามีการเสนอราคาเมื่อเหลือเวลาน้อยกว่าค่านี้ ระบบจะต่อเวลาออกไปอีกเท่ากับค่านี้ (0 = ไม่ต่อเวลา)';

create or replace function public.place_bid(p_auction bigint, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_a   public.auctions%rowtype;
  v_p   public.profiles%rowtype;
  v_min numeric(10,2);
  v_extended boolean := false;
  v_new_end timestamptz;
begin
  if v_uid is null then raise exception 'ต้องเข้าสู่ระบบสมาชิกก่อนจึงจะเสนอราคาได้'; end if;

  select * into v_p from public.profiles where id = v_uid;
  if v_p.account_status = 'ระงับ' then
    raise exception 'บัญชีของคุณถูกระงับ ไม่สามารถร่วมประมูลได้';
  end if;

  select * into v_a from public.auctions where id = p_auction for update;
  if not found then raise exception 'ไม่พบรายการประมูลนี้'; end if;
  if v_a.status = 'closed' or now() > v_a.ends_at then
    raise exception 'รายการนี้ปิดประมูลแล้ว';
  end if;
  if v_a.top_bidder_id = v_uid then
    raise exception 'คุณเป็นผู้เสนอราคาสูงสุดอยู่แล้ว ไม่ต้องเสนอซ้ำ';
  end if;

  v_min := case when v_a.bid_count = 0 then v_a.start_price
                else v_a.current_price + v_a.min_increment end;
  if p_amount < v_min then
    raise exception 'ต้องเสนอราคาอย่างน้อย % บาท', trim(to_char(v_min,'FM999,999'));
  end if;

  -- เสนอราคาช่วงท้าย ให้ต่อเวลาออกไปเพื่อความเป็นธรรมกับผู้ร่วมประมูลคนอื่น
  v_new_end := v_a.ends_at;
  if v_a.extend_seconds > 0
     and (v_a.ends_at - now()) < make_interval(secs => v_a.extend_seconds) then
    v_new_end := now() + make_interval(secs => v_a.extend_seconds);
    v_extended := true;
  end if;

  insert into public.bids (auction_id, user_id, bidder_name, amount)
  values (p_auction, v_uid, coalesce(nullif(v_p.full_name,''), v_p.email), p_amount);

  update public.auctions
     set current_price = p_amount,
         bid_count     = bid_count + 1,
         top_bidder_id = v_uid,
         top_bidder    = coalesce(nullif(v_p.full_name,''), v_p.email),
         ends_at       = v_new_end
   where id = p_auction;

  return jsonb_build_object('auction_id', p_auction, 'amount', p_amount,
                            'next_min', p_amount + v_a.min_increment,
                            'extended', v_extended, 'ends_at', v_new_end);
end;
$$;

-- ============ 2) จำกัดการใช้คูปองต่อคน ============
alter table public.coupons
  add column if not exists per_user_limit integer not null default 0;

comment on column public.coupons.per_user_limit is
  'จำนวนครั้งสูงสุดที่ลูกค้าหนึ่งคนใช้คูปองใบนี้ได้ (0 = ไม่จำกัด)';

-- นับว่าลูกค้าคนนี้เคยใช้คูปองใบนี้ไปกี่ครั้ง (ไม่นับรายการที่ถูกยกเลิก)
create or replace function public.coupon_used_by(p_code text, p_user uuid default auth.uid())
returns integer
language sql stable security definer set search_path = public
as $$
  select count(*)::int from public.orders
   where user_id = p_user
     and upper(coalesce(coupon_code,'')) = upper(trim(p_code))
     and status <> 'reject';
$$;

create or replace function public.calc_discount(p_code text, p_subtotal numeric, p_ship numeric)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_c public.coupons%rowtype; v_disc numeric(10,2) := 0; v_ship numeric(10,2) := p_ship;
begin
  if coalesce(trim(p_code),'') = '' then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', '');
  end if;

  select * into v_c from public.coupons where upper(code) = upper(trim(p_code));
  if not found then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'ไม่พบรหัสส่วนลดนี้');
  end if;
  if not v_c.is_active then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ถูกปิดใช้งานแล้ว');
  end if;
  if now() < v_c.starts_at then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ยังไม่เริ่มใช้งาน');
  end if;
  if v_c.ends_at is not null and now() > v_c.ends_at then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้หมดอายุแล้ว');
  end if;
  if v_c.usage_limit > 0 and v_c.used_count >= v_c.usage_limit then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship, 'message', 'รหัสส่วนลดนี้ถูกใช้ครบจำนวนแล้ว');
  end if;
  if v_c.per_user_limit > 0 and auth.uid() is not null
     and public.coupon_used_by(v_c.code, auth.uid()) >= v_c.per_user_limit then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship,
      'message', 'คุณใช้รหัสนี้ครบ ' || v_c.per_user_limit || ' ครั้งแล้ว');
  end if;
  if p_subtotal < v_c.min_subtotal then
    return jsonb_build_object('valid', false, 'discount', 0, 'shipping', p_ship,
      'message', 'ต้องซื้อครบ ' || trim(to_char(v_c.min_subtotal,'FM999,999')) || ' บาทจึงใช้รหัสนี้ได้');
  end if;

  if v_c.discount_type = 'percent' then
    v_disc := round(p_subtotal * v_c.discount_value / 100, 2);
    if v_c.max_discount > 0 and v_disc > v_c.max_discount then v_disc := v_c.max_discount; end if;
  elsif v_c.discount_type = 'amount' then
    v_disc := least(v_c.discount_value, p_subtotal);
  elsif v_c.discount_type = 'freeship' then
    v_ship := 0;
  end if;

  return jsonb_build_object(
    'valid', true, 'discount', v_disc, 'shipping', v_ship,
    'code', v_c.code, 'description', v_c.description,
    'message', 'ใช้รหัส ' || v_c.code || ' แล้ว: ' || v_c.description
  );
end;
$$;

grant execute on function public.coupon_used_by(text, uuid) to authenticated;

-- ตั้งค่าตัวอย่าง: คูปองลูกค้าใหม่ให้ใช้ได้คนละครั้งเดียว
update public.coupons set per_user_limit = 1 where code = 'NEWPLANT';
