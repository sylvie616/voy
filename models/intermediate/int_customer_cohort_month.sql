/*
  Purpose: assign each customer to a cohort month.
  Why: retention must be compared relative to a customer cohort, not just in aggregate over all time.
*/
select
    customer_id,
    date_trunc(first_seen_date, month) as cohort_month
from {{ ref('int_customer_master') }}
where first_seen_date is not null
