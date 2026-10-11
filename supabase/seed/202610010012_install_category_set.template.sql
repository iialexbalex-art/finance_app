-- Replace exactly one placeholder with the target space UUID, review the
-- displayed owner/name, then run the SELECT manually as postgres after 012.
-- This file is intentionally invalid until the placeholder is replaced.
select id,owner_user_id,kind,name
from public.spaces
where id='{{TARGET_SPACE_UUID}}'::uuid;

select finance_private.install_category_set_2026_10_01(
  '{{TARGET_SPACE_UUID}}'::uuid
);
