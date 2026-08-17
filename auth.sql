-- ===========================================================================
-- SteadN — sign in and sync
-- Run this in the Supabase SQL editor. It is independent of schema.sql, which
-- stays the target for the normalised model later. This gets one account
-- syncing across devices today.
-- ===========================================================================

create table if not exists stead_state (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  state      jsonb not null,
  device     text,                       -- last device to write, for debugging
  rev        bigint not null default 1,  -- bumped on every write, drives conflict detection
  updated_at timestamptz not null default now()
);

alter table stead_state enable row level security;

-- A person can read and write their own row, and nothing else exists to them.
create policy state_select on stead_state for select using (user_id = auth.uid());
create policy state_insert on stead_state for insert with check (user_id = auth.uid());
create policy state_update on stead_state for update using (user_id = auth.uid())
                                          with check (user_id = auth.uid());
create policy state_delete on stead_state for delete using (user_id = auth.uid());

-- Save with a revision check. If another device wrote since this one last
-- read, the write is refused and the caller is told, rather than silently
-- flattening the other device's work.
create or replace function save_state(p_state jsonb, p_rev bigint, p_device text)
returns table (ok boolean, rev bigint, state jsonb)
language plpgsql security definer set search_path = public as $$
declare cur bigint;
begin
  select s.rev into cur from stead_state s where s.user_id = auth.uid();

  if cur is null then
    insert into stead_state(user_id, state, device, rev)
    values (auth.uid(), p_state, p_device, 1);
    return query select true, 1::bigint, p_state;
    return;
  end if;

  if p_rev is distinct from cur then          -- somebody else got there first
    return query select false, cur, (select s.state from stead_state s where s.user_id = auth.uid());
    return;
  end if;

  update stead_state
     set state = p_state, device = p_device, rev = cur + 1, updated_at = now()
   where user_id = auth.uid();
  return query select true, cur + 1, p_state;
end $$;

-- ===========================================================================
-- CHECK IT BEFORE YOU TRUST IT
--
-- Sign in as one account and save. Then from a second account:
--   select * from stead_state;              -- must return only that account's row
--   select save_state('{}'::jsonb, 1, 'x'); -- must only ever touch its own row
--
-- If the first query shows two rows, row level security is not on.
-- ===========================================================================
