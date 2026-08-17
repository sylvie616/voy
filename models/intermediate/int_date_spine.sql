/*
  Purpose: create a complete daily calendar backbone.
  Why: retention analysis requires a consistent time dimension so dates with no activity are still represented and metrics can be zero-filled and compared reliably.
*/
with calendar as (
    -- purpose: generate every date in the analysis window; why: customer-day logic needs every day, not just days with activity.
    -- note: the end date 2024-12-31 is hardcoded to match the known data window in lz_ae_task.
    -- TODO: parameterise this (e.g. via a dbt variable or a subquery on max activity date) if the source window is extended.
    select date_day
    from unnest(
        generate_date_array(date '2019-01-01', date '2024-12-31', interval 1 day)
    ) as date_day
)
select
    date_day,
    extract(year from date_day) as calendar_year,
    extract(month from date_day) as calendar_month,
    extract(day from date_day) as calendar_day,
    date_trunc(date_day, month) as month_start_date
from calendar
