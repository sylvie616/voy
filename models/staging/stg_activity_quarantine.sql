/*
  Purpose: isolate invalid activity records that should not feed retention or customer-day logic.
  Why: data quality exceptions are important to retain for audit and remediation without contaminating the canonical engagement metrics.
*/
select
    customer_id,
    subscription_id,
    from_date,
    to_date,
    is_valid_interval
from {{ ref('stg_activity') }}
where is_valid_interval = 0
