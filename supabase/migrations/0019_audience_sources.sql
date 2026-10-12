-- A broadcast audience can name several sources (any of them), not just one.
-- p_filter.sources: [{"source": "excel", "source_detail": "sept.xlsx"}, {"source": "meta_form"}]
-- The old single "source" / "source_detail" keys still work.

create or replace function private.wa_audience(p_filter jsonb)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select l.id
    from leads l
   where l.phone is not null
     and not l.wa_opt_out
     and (p_filter ->> 'status' is null or l.status = p_filter ->> 'status')
     and (p_filter ->> 'temperature' is null or l.temperature = p_filter ->> 'temperature')
     and (p_filter ->> 'assignee' is null
          or (p_filter ->> 'assignee' = 'unassigned' and l.assigned_to is null)
          or l.assigned_to::text = p_filter ->> 'assignee')
     and (p_filter ->> 'source' is null or l.source = p_filter ->> 'source')
     and (p_filter ->> 'source_detail' is null or l.source_detail = p_filter ->> 'source_detail')
     -- several sources: the lead matches any of them (a source without a detail means every lead of that source)
     and (jsonb_typeof(p_filter -> 'sources') is distinct from 'array'
          or jsonb_array_length(p_filter -> 'sources') = 0
          or exists (select 1 from jsonb_array_elements(p_filter -> 'sources') s
                      where l.source = s ->> 'source'
                        and (s ->> 'source_detail' is null or l.source_detail = s ->> 'source_detail')))
     and (p_filter ->> 'batch_id' is null or l.import_batch_id::text = p_filter ->> 'batch_id')
     and (p_filter ->> 'from' is null or l.created_at >= (p_filter ->> 'from')::timestamptz)
     and (p_filter ->> 'to' is null or l.created_at < (p_filter ->> 'to')::timestamptz)
     and (p_filter ->> 'wa' is null or l.wa_state = p_filter ->> 'wa')
     and (p_filter ->> 'webinar' is null or l.webinar_state = p_filter ->> 'webinar')
     and (p_filter ->> 'attended' is null
          or (p_filter ->> 'attended' = 'yes' and l.webinar_attended is true)
          or (p_filter ->> 'attended' = 'no' and l.webinar_attended is false))
     and (p_filter ->> 'appx' is null
          or (p_filter ->> 'appx' = 'not_purchased' and l.appx_state is distinct from 'purchased')
          or l.appx_state = p_filter ->> 'appx');
$$;
