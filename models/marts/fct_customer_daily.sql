/*
  Purpose: publish the daily customer activity fact used for retention and churn analysis.
  Why: this table is the analytic base for customer health questions, allowing business teams to analyze day-level activity, inactivity, and time-since-first-activity without depending on a BI-only aggregate.
  Note: customer_country and taxonomy_business_category_group are carried through from int_customer_day_activity directly
  to avoid redundant joins to dim_customer and dim_date (which are themselves built from the same upstream models).
*/
select
    customer_id,
    date_day,
    is_active_on_date,
    subscription_count_on_date,
    days_since_first_activity,
    is_new_customer,
    is_inactive_on_date,
    customer_country,
    taxonomy_business_category_group
from {{ ref('int_customer_day_activity') }}
