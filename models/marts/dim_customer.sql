/*
  Purpose: create the customer dimension used by reporting and analysis.
  Why: dimensional reporting needs a stable, business-friendly customer record that can be joined to any retained fact without exposing raw source complexity.
*/
select
    customer_id,
    customer_country,
    taxonomy_business_category_group,
    first_seen_date,
    last_seen_date,
    has_open_subscription,
    is_active_customer
from {{ ref('int_customer_master') }}
