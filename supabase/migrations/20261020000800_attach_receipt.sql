-- Attach an already-registered receipt to an expense after the fact (receipts captured offline are
-- uploaded once the expense has synced). Not a financial edit: revision is unchanged, but updated_at
-- moves so incremental sync on other devices picks up the new receipt.
create or replace function public.attach_receipt(p_receipt_id uuid, p_expense_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_receipt public.receipts;
  v_expense_trip uuid;
begin
  select * into v_receipt from public.receipts where id = p_receipt_id and deleted_at is null for update;
  if not found then perform private.fail('not_found', 'Receipt not found.', 'PT404'); end if;
  perform private.require_role(v_receipt.trip_id, 'member', false);
  select trip_id into v_expense_trip from public.expenses where id = p_expense_id;
  if v_expense_trip is distinct from v_receipt.trip_id then
    perform private.fail('not_found', 'That expense is not in this trip.', 'PT404');
  end if;
  update public.receipts set expense_id = p_expense_id where id = p_receipt_id;
  update public.expenses set updated_at = now() where id = p_expense_id;
  return public.expense_json(p_expense_id);
end $$;

revoke all on function public.attach_receipt(uuid, uuid) from public, anon;
grant execute on function public.attach_receipt(uuid, uuid) to authenticated;
