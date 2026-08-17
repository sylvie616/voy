/*
  Purpose: create a complete daily calendar backbone.
  Why: retention analysis requires a consistent time dimension so dates with no activity are still represented and metrics can be zero-filled and compared reliably.
*/
with recursive calendar as (
    -- purpose: create the continuous date range; why: customer-day logic needs every day in the analysis window, not just days with activity.
    select date '2019-01-01' as date_day
    union all
    select date_day + interval 1 day
    from calendar
    where date_day < date '2024-12-31'
)
select
    date_day,
    extract(year from date_day) as calendar_year,
    extract(month from date_day) as calendar_month,
    extract(day from date_day) as calendar_day,
    date_trunc('month', date_day) as month_start_date
from calendar
