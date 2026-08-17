/*
  Purpose: collapse valid activity rows into subscription lifecycles.
  Why: retention metrics need the subscription period as the unit of analysis, not the raw row-level event stream.
*/
with valid_intervals as (
    -- purpose: keep only valid intervals; why: malformed or invalid windows have already been quarantined and should not influence lifecycle calculations.
    select
        customer_id,
        subscription_id,
        from_date as start_date,
        to_date as end_date
    from {{ ref('stg_activity') }}
    where is_valid_interval = 1
),
ordered_intervals as (
    -- purpose: preserve chronology within each subscription; why: repeated subscription IDs may represent multiple distinct periods, which must be split into activity islands.
    select
        *,
        lag(end_date) over (
            partition by customer_id, subscription_id
            order by start_date, end_date
        ) as previous_end_date
    from valid_intervals
),
period_islands as (
    -- purpose: split repeated subscription IDs into separate lifecycle islands when a gap is detected; why: otherwise a reactivated or repeated subscription can be merged into a single invalid period.
    select
        *,
        case
            when previous_end_date is null then 1
            when start_date > previous_end_date + interval 1 day then 1
            else 0
        end as is_new_period
    from ordered_intervals
),
period_id as (
    -- purpose: assign an island number to each valid lifecycle segment; why: downstream aggregation should operate on each continuous subscription segment, not the entire raw subscription history.
    select
        *,
        sum(is_new_period) over (
            partition by customer_id, subscription_id
            order by start_date, end_date
            rows between unbounded preceding and current row
        ) as period_group
    from period_islands
),
period_agg as (
    -- purpose: aggregate each continuous subscription segment into one canonical lifecycle row; why: this preserves true churn/reactivation behavior while still normalizing raw repeated rows.
    select
        customer_id,
        subscription_id,
        min(start_date) as start_date,
        max(end_date) as end_date,
        max(case when end_date is null then 1 else 0 end) as is_current,
        count(*) as activity_rows
    from period_id
    group by customer_id, subscription_id, period_group
)
select
    customer_id,
    subscription_id,
    start_date,
    end_date,
    case when is_current = 1 then true else false end as is_active,
    case
        when end_date is null then datediff('day', start_date, current_date)
        else datediff('day', start_date, end_date)
    end as duration_days,
    activity_rows
from period_agg
