/*
  Purpose: expose the date spine as a reusable calendar dimension.
  Why: time-based business logic should be able to join against a clean calendar with standard fiscal and weekday attributes rather than re-deriving date logic in every downstream model.
*/
select
    date_day,
    calendar_year,
    calendar_month,
    calendar_day,
    month_start_date,
    case
        when extract(dayofweek from date_day) in (1, 7) then true
        else false
    end as is_weekend
from {{ ref('int_date_spine') }}
