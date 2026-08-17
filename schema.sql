-- ===========================================================================
-- SteadN — Postgres / Supabase schema
--
-- The one thing that matters here: sharing permissions are enforced by
-- row-level security in the database, not by the client. If the API can
-- return a hidden row, hiding it in the UI is decoration, not privacy.
--
-- Run in the Supabase SQL editor. Assumes auth.users exists.
-- ===========================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- 1. STEADS  one per user
-- ---------------------------------------------------------------------------
create type share_level as enum ('hidden','summary','detail');

create table steads (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null unique references auth.users(id) on delete cascade,
  handle        citext unique,
  name          text not null default 'My stead',
  zone          text not null default '7b',
  zip3          text,                       -- first 3 digits only, never the full ZIP
  near_city     text,                       -- reference city, never a street address
  elevation_ft  int  default 500,
  people        int  default 4 check (people between 1 and 30),
  years_in      int  default 1,
  bio           text check (char_length(bio) <= 400),

  is_shared     boolean not null default false,
  share_garden  share_level not null default 'summary',
  share_harvest share_level not null default 'hidden',
  share_animals share_level not null default 'hidden',
  share_seasons share_level not null default 'summary',
  share_pantry  share_level not null default 'hidden',
  share_location share_level not null default 'hidden',

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on column steads.zip3 is
  'Store only the first three ZIP digits. Enough for zone and elevation, not enough to find someone.';

-- Helper: does the viewer have at least the level needed on this scope?
create or replace function stead_allows(
  p_stead uuid, p_scope text, p_need share_level
) returns boolean language sql stable security definer set search_path = public as $$
  select case
    -- owners always see everything of their own
    when s.user_id = auth.uid() then true
    when not s.is_shared then false
    else (
      case p_scope
        when 'garden'   then s.share_garden
        when 'harvest'  then s.share_harvest
        when 'animals'  then s.share_animals
        when 'seasons'  then s.share_seasons
        when 'pantry'   then s.share_pantry
        when 'location' then s.share_location
      end
    )::text >= '' and
    array_position(array['hidden','summary','detail'],
      (case p_scope
        when 'garden'   then s.share_garden
        when 'harvest'  then s.share_harvest
        when 'animals'  then s.share_animals
        when 'seasons'  then s.share_seasons
        when 'pantry'   then s.share_pantry
        when 'location' then s.share_location
      end)::text)
    >= array_position(array['hidden','summary','detail'], p_need::text)
  end
  from steads s where s.id = p_stead;
$$;

-- ---------------------------------------------------------------------------
-- 2. GARDEN
-- ---------------------------------------------------------------------------
create table beds (
  id         uuid primary key default gen_random_uuid(),
  stead_id   uuid not null references steads(id) on delete cascade,
  name       text not null,
  length_ft  numeric(6,1) not null check (length_ft > 0 and length_ft <= 500),
  sort       int default 0,
  created_at timestamptz not null default now()
);
create index on beds(stead_id);

create table plantings (
  id           uuid primary key default gen_random_uuid(),
  stead_id     uuid not null references steads(id) on delete cascade,
  bed_id       uuid not null references beds(id) on delete cascade,
  crop_id      text not null,               -- matches the local crop table
  variety      text,
  feet         numeric(5,1) not null check (feet > 0),
  spacing_in   numeric(5,1) not null check (spacing_in > 0),
  dtm_override int,
  planted_on   date,
  removed_on   date,
  season_year  int not null default extract(year from now()),
  created_at   timestamptz not null default now()
);
create index on plantings(stead_id, season_year);
create index on plantings(bed_id);

-- ---------------------------------------------------------------------------
-- 3. HARVEST, PANTRY, CHORES
-- ---------------------------------------------------------------------------
create table harvests (
  id          uuid primary key default gen_random_uuid(),
  stead_id    uuid not null references steads(id) on delete cascade,
  planting_id uuid references plantings(id) on delete set null,
  crop_id     text not null,
  pounds      numeric(8,2) not null check (pounds >= 0),
  picked_on   date not null default current_date,
  season_year int not null default extract(year from now()),
  note        text
);
create index on harvests(stead_id, season_year);

create table pantry (
  stead_id  uuid not null references steads(id) on delete cascade,
  crop_id   text not null,
  quarts    numeric(6,1) not null default 0 check (quarts >= 0),
  updated_at timestamptz not null default now(),
  primary key (stead_id, crop_id)
);

create table chore_log (
  stead_id uuid not null references steads(id) on delete cascade,
  chore_id text not null,
  done_on  date not null default current_date,
  primary key (stead_id, chore_id, done_on)
);

create table task_done (
  stead_id uuid not null references steads(id) on delete cascade,
  task_key text not null,
  done_at  timestamptz not null default now(),
  primary key (stead_id, task_key)
);

-- ---------------------------------------------------------------------------
-- 4. ANIMALS
-- ---------------------------------------------------------------------------
create table flocks (
  id        uuid primary key default gen_random_uuid(),
  stead_id  uuid not null references steads(id) on delete cascade,
  species   text not null check (species in ('chicken','goat')),
  breed     text,
  head      int not null default 0 check (head >= 0),
  age_months int,
  not_laying int default 0,
  in_milk    int default 0,
  note      text
);
create index on flocks(stead_id);

-- ---------------------------------------------------------------------------
-- 5. SEASON LOG  the retention engine
-- ---------------------------------------------------------------------------
create table season_entries (
  id          uuid primary key default gen_random_uuid(),
  stead_id    uuid not null references steads(id) on delete cascade,
  season_year int not null,
  crop_id     text not null,
  variety     text,
  feet        numeric(6,1),
  pounds      numeric(8,2),
  lb_per_ft   numeric(6,2) generated always as
                (case when feet > 0 then pounds / feet else null end) stored,
  rating      int check (rating between 0 and 5),
  notes       text,
  closed_at   timestamptz not null default now(),
  unique (stead_id, season_year, crop_id, variety)
);
create index on season_entries(stead_id, season_year);

-- ---------------------------------------------------------------------------
-- 6. PHOTOS  metadata only, files live in Supabase Storage
--    Cap count and size here so a handful of users cannot eat the margin.
-- ---------------------------------------------------------------------------
create table photos (
  id          uuid primary key default gen_random_uuid(),
  stead_id    uuid not null references steads(id) on delete cascade,
  planting_id uuid references plantings(id) on delete cascade,
  scope       text not null default 'garden'
                check (scope in ('garden','harvest','animals','seasons')),
  storage_path text not null,
  bytes       int not null check (bytes <= 2097152),   -- 2 MB hard cap
  caption     text check (char_length(caption) <= 200),
  taken_on    date not null default current_date,
  created_at  timestamptz not null default now()
);
create index on photos(stead_id);

create or replace function photo_quota() returns trigger language plpgsql as $$
begin
  if (select count(*) from photos where stead_id = new.stead_id) >= 500 then
    raise exception 'Photo limit reached for this stead';
  end if;
  return new;
end $$;
create trigger photos_quota before insert on photos
  for each row execute function photo_quota();

-- ---------------------------------------------------------------------------
-- 7. MESSAGES  between two steads
-- ---------------------------------------------------------------------------
create table threads (
  id       uuid primary key default gen_random_uuid(),
  a_stead  uuid not null references steads(id) on delete cascade,
  b_stead  uuid not null references steads(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (a_stead < b_stead),          -- one thread per pair, order normalized
  unique (a_stead, b_stead)
);

create table messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references threads(id) on delete cascade,
  from_stead uuid not null references steads(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index on messages(thread_id, created_at desc);

create table blocks (
  blocker_stead uuid not null references steads(id) on delete cascade,
  blocked_stead uuid not null references steads(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_stead, blocked_stead)
);

create table reports (
  id           uuid primary key default gen_random_uuid(),
  reporter     uuid not null references steads(id) on delete cascade,
  target_stead uuid references steads(id) on delete set null,
  message_id   uuid references messages(id) on delete set null,
  reason       text not null,
  detail       text,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);

-- ---------------------------------------------------------------------------
-- 8. SUBSCRIPTIONS
-- ---------------------------------------------------------------------------
create table subscriptions (
  stead_id    uuid primary key references steads(id) on delete cascade,
  status      text not null default 'trial'
                check (status in ('trial','active','past_due','canceled')),
  stripe_customer_id     text,
  stripe_subscription_id text,
  trial_ends_on date default (current_date + 30),
  renews_on     date,
  updated_at    timestamptz not null default now()
);

-- ===========================================================================
-- ROW LEVEL SECURITY
-- This is where sharing is actually enforced.
-- ===========================================================================
alter table steads         enable row level security;
alter table beds           enable row level security;
alter table plantings      enable row level security;
alter table harvests       enable row level security;
alter table pantry         enable row level security;
alter table chore_log      enable row level security;
alter table task_done      enable row level security;
alter table flocks         enable row level security;
alter table season_entries enable row level security;
alter table photos         enable row level security;
alter table threads        enable row level security;
alter table messages       enable row level security;
alter table blocks         enable row level security;
alter table reports        enable row level security;
alter table subscriptions  enable row level security;

-- helper: the caller's own stead id
create or replace function my_stead() returns uuid
language sql stable security definer set search_path = public as $$
  select id from steads where user_id = auth.uid();
$$;

-- ---- steads -------------------------------------------------------------
create policy steads_own_all on steads
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- others may read a shared stead's row, but the location columns are
-- masked through a view rather than exposed here
create policy steads_read_shared on steads
  for select using (
    is_shared
    and not exists (select 1 from blocks b
                    where b.blocker_stead = steads.id and b.blocked_stead = my_stead())
  );

-- ---- garden -------------------------------------------------------------
create policy beds_own on beds for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy beds_shared_detail on beds for select
  using (stead_allows(stead_id, 'garden', 'detail'));

create policy plantings_own on plantings for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
-- summary shows crop and variety; the API selects only those columns.
-- detail is what unlocks feet, spacing, and bed placement.
create policy plantings_shared_summary on plantings for select
  using (stead_allows(stead_id, 'garden', 'summary'));

-- ---- harvest ------------------------------------------------------------
create policy harvests_own on harvests for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy harvests_shared_detail on harvests for select
  using (stead_allows(stead_id, 'harvest', 'detail'));

-- summary level gets a total only, through this view, never row access
create or replace view harvest_totals
with (security_invoker = true) as
  select h.stead_id, h.season_year, sum(h.pounds)::numeric(10,2) as total_lb
  from harvests h
  where stead_allows(h.stead_id, 'harvest', 'summary')
  group by h.stead_id, h.season_year;

-- ---- animals ------------------------------------------------------------
create policy flocks_own on flocks for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy flocks_shared_detail on flocks for select
  using (stead_allows(stead_id, 'animals', 'detail'));

create or replace view flock_species
with (security_invoker = true) as
  select f.stead_id, f.species
  from flocks f
  where stead_allows(f.stead_id, 'animals', 'summary')
  group by f.stead_id, f.species;

-- ---- seasons ------------------------------------------------------------
create policy seasons_own on season_entries for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy seasons_shared_detail on season_entries for select
  using (stead_allows(stead_id, 'seasons', 'detail'));

create or replace view season_ratings
with (security_invoker = true) as
  select s.stead_id, s.season_year, s.crop_id, s.variety, s.rating
  from season_entries s
  where stead_allows(s.stead_id, 'seasons', 'summary');

-- ---- pantry -------------------------------------------------------------
create policy pantry_own on pantry for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy pantry_shared_detail on pantry for select
  using (stead_allows(stead_id, 'pantry', 'detail'));

-- ---- private by definition ---------------------------------------------
create policy chores_own on chore_log for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy tasks_own on task_done for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy subs_own on subscriptions for select using (stead_id = my_stead());

-- ---- photos: inherit the scope they belong to ---------------------------
create policy photos_own on photos for all
  using (stead_id = my_stead()) with check (stead_id = my_stead());
create policy photos_shared on photos for select
  using (stead_allows(stead_id, photos.scope, 'detail'));

-- ---- messages ----------------------------------------------------------
create policy threads_mine on threads for select
  using (a_stead = my_stead() or b_stead = my_stead());
create policy threads_create on threads for insert
  with check (
    (a_stead = my_stead() or b_stead = my_stead())
    and not exists (
      select 1 from blocks b
      where (b.blocker_stead = a_stead and b.blocked_stead = b_stead)
         or (b.blocker_stead = b_stead and b.blocked_stead = a_stead))
  );

create policy messages_read on messages for select
  using (exists (select 1 from threads t where t.id = thread_id
                 and (t.a_stead = my_stead() or t.b_stead = my_stead())));
create policy messages_send on messages for insert
  with check (
    from_stead = my_stead()
    and exists (select 1 from threads t where t.id = thread_id
                and (t.a_stead = my_stead() or t.b_stead = my_stead()))
  );

create policy blocks_own on blocks for all
  using (blocker_stead = my_stead()) with check (blocker_stead = my_stead());
create policy reports_insert on reports for insert
  with check (reporter = my_stead());

-- ---------------------------------------------------------------------------
-- 9. NEIGHBOR DISCOVERY  masks location per the owner's setting
-- ---------------------------------------------------------------------------
create or replace view neighbors
with (security_invoker = true) as
select
  s.id, s.handle, s.name, s.zone, s.years_in, s.bio,
  case s.share_location
    when 'detail'  then s.near_city
    when 'summary' then split_part(s.near_city, ',', 2)
    else null
  end as location_text,
  s.share_garden, s.share_harvest, s.share_animals,
  s.share_seasons, s.share_pantry, s.share_location
from steads s
where s.is_shared
  and s.id <> my_stead()
  and not exists (select 1 from blocks b
                  where b.blocker_stead = s.id and b.blocked_stead = my_stead());

-- ---------------------------------------------------------------------------
-- 10. TOUCH updated_at
-- ---------------------------------------------------------------------------
create or replace function touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger steads_touch before update on steads
  for each row execute function touch();

-- ===========================================================================
-- WHAT TO VERIFY BEFORE LAUNCH
--
-- Sign in as user A, share nothing, then as user B try to read A's rows
-- directly through the REST endpoint. Every one should come back empty:
--
--   /rest/v1/plantings?stead_id=eq.<A>
--   /rest/v1/flocks?stead_id=eq.<A>
--   /rest/v1/harvests?stead_id=eq.<A>
--   /rest/v1/pantry?stead_id=eq.<A>
--
-- Then set A's garden to 'summary' and confirm B can read crop_id and
-- variety but that feet and bed placement are not returned by your API
-- layer. RLS grants the row at summary; your select list is what withholds
-- the columns, so that part is on the API and belongs in its tests.
--
-- Never ship with the service_role key in a client. It bypasses all of this.
-- ===========================================================================
