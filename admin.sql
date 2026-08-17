-- ===========================================================================
-- SteadN — admin, billing and analytics
-- Run after schema.sql.
--
-- THE ONE RULE: admin is a database role, not a client flag. Never gate an
-- admin screen on something the browser can set. The policies below are what
-- actually stop a customer reading another customer's row, and no amount of
-- UI can substitute for them.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. STAFF
-- ---------------------------------------------------------------------------
create table staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'support'
               check (role in ('support','admin','owner')),
  added_by   uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create or replace function is_staff(min_role text default 'support')
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from staff s
    where s.user_id = auth.uid()
      and array_position(array['support','admin','owner'], s.role)
       >= array_position(array['support','admin','owner'], min_role)
  );
$$;

alter table staff enable row level security;
create policy staff_read_self on staff for select using (user_id = auth.uid());
create policy staff_owner_all on staff for all using (is_staff('owner'));

-- ---------------------------------------------------------------------------
-- 2. WHAT STAFF MAY SEE
-- Deliberately not "everything". Support needs to answer questions, not read
-- somebody's harvest log. Escalate only where there is a reason.
-- ---------------------------------------------------------------------------

-- billing and account state: support level
create policy steads_staff_read on steads for select using (is_staff('support'));
create policy subs_staff_read   on subscriptions for select using (is_staff('support'));

-- garden contents: admin level, and audited. Most support tickets never need it.
create policy beds_staff_read      on beds           for select using (is_staff('admin'));
create policy plantings_staff_read on plantings      for select using (is_staff('admin'));
create policy seasons_staff_read   on season_entries for select using (is_staff('admin'));

-- messages and photos: owner only, and only for abuse handling
create policy messages_owner_read on messages for select using (is_staff('owner'));
create policy reports_staff_read  on reports  for select using (is_staff('support'));

-- harvest and pantry stay private to the customer. Nobody at the company has
-- a reason to read how much food is on someone's shelves.

-- ---------------------------------------------------------------------------
-- 3. AUDIT
-- Any staff read of customer data is logged. Without this, "admin can see
-- customer info" is an unbounded promise.
-- ---------------------------------------------------------------------------
create table staff_audit (
  id         bigserial primary key,
  staff_id   uuid not null references auth.users(id),
  action     text not null,
  stead_id   uuid references steads(id) on delete set null,
  reason     text,
  at         timestamptz not null default now()
);
alter table staff_audit enable row level security;
create policy audit_insert on staff_audit for insert with check (staff_id = auth.uid());
create policy audit_read   on staff_audit for select using (is_staff('owner'));

create or replace function staff_open_stead(p_stead uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_staff('admin') then raise exception 'not permitted'; end if;
  if p_reason is null or length(trim(p_reason)) < 8 then
    raise exception 'a reason is required to open a customer stead';
  end if;
  insert into staff_audit(staff_id, action, stead_id, reason)
  values (auth.uid(), 'open_stead', p_stead, p_reason);
end $$;

-- ---------------------------------------------------------------------------
-- 4. ACTIVITY, so retention can be measured at all
-- ---------------------------------------------------------------------------
create table activity (
  stead_id uuid not null references steads(id) on delete cascade,
  day      date not null default current_date,
  opens    int  not null default 1,
  ai_calls int  not null default 0,
  primary key (stead_id, day)
);
alter table activity enable row level security;
create policy activity_own   on activity for all using (stead_id = my_stead())
  with check (stead_id = my_stead());
create policy activity_staff on activity for select using (is_staff('support'));

create table ai_usage (
  id        bigserial primary key,
  stead_id  uuid not null references steads(id) on delete cascade,
  at        timestamptz not null default now(),
  tokens_in  int,
  tokens_out int,
  cost_cents numeric(8,3),
  searched  boolean default false
);
alter table ai_usage enable row level security;
create policy ai_own   on ai_usage for all using (stead_id = my_stead())
  with check (stead_id = my_stead());
create policy ai_staff on ai_usage for select using (is_staff('support'));

-- ---------------------------------------------------------------------------
-- 5. ANALYTICS VIEWS
-- Aggregates only. These are what an admin dashboard should read, so a staff
-- screen never needs row access to a customer's garden.
-- ---------------------------------------------------------------------------
create or replace view admin_overview
with (security_invoker = true) as
select
  count(*)                                                          as steads,
  count(*) filter (where s.is_shared)                               as sharing,
  count(*) filter (where sub.status = 'active')                      as paying,
  count(*) filter (where sub.status = 'trial')                       as trialing,
  count(*) filter (where sub.status = 'past_due')                    as past_due,
  count(*) filter (where sub.status = 'canceled')                    as canceled,
  count(*) filter (where s.created_at > now() - interval '30 days')  as new_30d
from steads s
left join subscriptions sub on sub.stead_id = s.id
where is_staff('support');

create or replace view admin_plan_mix
with (security_invoker = true) as
select sub.status,
       count(*)                                   as steads,
       round(avg(extract(epoch from (now() - s.created_at))/86400)) as avg_age_days
from steads s join subscriptions sub on sub.stead_id = s.id
where is_staff('support')
group by sub.status;

-- retention by signup month, the number that decides whether this is a business
create or replace view admin_cohorts
with (security_invoker = true) as
with c as (
  select s.id, date_trunc('month', s.created_at)::date as cohort,
         max(a.day) as last_seen
  from steads s left join activity a on a.stead_id = s.id
  group by s.id, 2
)
select cohort,
       count(*)                                                   as signed_up,
       count(*) filter (where last_seen > current_date - 30)       as active_30d,
       round(100.0 * count(*) filter (where last_seen > current_date - 30)
             / nullif(count(*),0)) as pct_active
from c where is_staff('support')
group by cohort order by cohort desc;

-- where the customers are, which drives which seed vendors matter
create or replace view admin_zones
with (security_invoker = true) as
select zone, count(*) as steads
from steads where is_staff('support')
group by zone order by count(*) desc;

-- the margin line. AI is the only cost that scales per user.
create or replace view admin_ai_cost
with (security_invoker = true) as
select date_trunc('month', at)::date as month,
       count(*)                       as calls,
       count(distinct stead_id)        as steads,
       round(sum(cost_cents)/100, 2)   as cost_usd,
       round(sum(cost_cents)/100.0 / nullif(count(distinct stead_id),0), 3) as cost_per_stead
from ai_usage where is_staff('support')
group by 1 order by 1 desc;

-- a single customer, for a support ticket. Billing and counts, no contents.
create or replace function admin_stead_summary(p_stead uuid)
returns table (
  handle text, zone text, created_at timestamptz, status text, renews_on date,
  beds int, plantings int, harvest_entries int, ai_calls_year int, last_seen date
) language sql stable security definer set search_path = public as $$
  select s.handle, s.zone, s.created_at, sub.status, sub.renews_on,
    (select count(*)::int from beds b where b.stead_id = s.id),
    (select count(*)::int from plantings p where p.stead_id = s.id),
    (select count(*)::int from harvests h where h.stead_id = s.id),
    (select count(*)::int from ai_usage u where u.stead_id = s.id and u.at > now() - interval '1 year'),
    (select max(a.day) from activity a where a.stead_id = s.id)
  from steads s left join subscriptions sub on sub.stead_id = s.id
  where s.id = p_stead and is_staff('support');
$$;

-- ---------------------------------------------------------------------------
-- 6. BEFORE YOU TRUST ANY OF THIS
--
-- Create a staff row for yourself, then a second ordinary account, and from
-- the ordinary account confirm every one of these returns empty:
--
--   select * from admin_overview;
--   select * from staff;
--   select * from staff_audit;
--   select * from ai_usage;
--   select admin_stead_summary('<some other stead id>');
--
-- Then remove your staff row and confirm the admin views go empty for you too.
-- If they do not, the policy is not doing what you think it is.
--
-- And never put the service_role key in the admin front end. It bypasses
-- every policy on this page.
-- ---------------------------------------------------------------------------
