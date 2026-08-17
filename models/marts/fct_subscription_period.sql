/*
  Purpose: expose the subscription lifecycle fact table.
  Why: while the daily customer fact is the primary retention base, subscription-level lifecycle detail remains useful for understanding when a customer starts, renews, or exits a specific period.
*/
select
    customer_id,
    subscription_id,
    start_date,
    end_date,
    duration_days,
    is_active,
    activity_rows
from {{ ref('int_subscription_periods') }}
