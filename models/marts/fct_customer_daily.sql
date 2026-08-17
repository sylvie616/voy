/*
  Purpose: publish the daily customer activity fact used for retention and churn analysis.
  Why: this table is the analytic base for customer health questions, allowing business teams to analyze day-level activity, inactivity, and time-since-first-activity without depending on a BI-only aggregate.
*/
select
    cd.customer_id,
    d.date_day,
    cd.is_active_on_date,
    cd.subscription_count_on_date,
    cd.days_since_first_activity,
    cd.is_new_customer,
    cd.is_inactive_on_date,
    c.customer_country,
    c.taxonomy_business_category_group
from {{ ref('int_customer_day_activity') }} cd
-- INNER JOIN: only keep rows that have both a valid daily customer fact and an existing customer dimension key.
inner join {{ ref('dim_customer') }} c on c.customer_id = cd.customer_id
-- INNER JOIN: only keep rows that exist within the canonical date spine.
inner join {{ ref('dim_date') }} d on d.date_day = cd.date_day
