/*
  Purpose: build the canonical customer master.
  Why: customer-level analytics needs one trusted record per customer that combines identity, acquisition source, and lifecycle signals without repeating raw source complexity.
*/
with activity_summary as (
    -- purpose: summarize valid activity history at customer level; why: we need first seen, last seen, and active/open status before building customer-day or retention logic.
    select
        customer_id,
        min(from_date) as first_seen_date,
        max(case when to_date is null then current_date else to_date end) as last_seen_date,
        -- has_open_subscription: count of valid open intervals (to_date IS NULL); indicates the customer has at least one currently running period.
        max(case when is_valid_interval = 1 and to_date is null then 1 else 0 end) as has_open_subscription,
        -- is_active_customer: 1 if the customer has any valid activity reaching current_date (open or closed but not yet ended).
        max(case when is_valid_interval = 1
                  and from_date <= current_date
                  and (to_date is null or to_date >= current_date)
             then 1 else 0 end) as is_active_customer
    from {{ ref('stg_activity') }}
    where is_valid_interval = 1
    group by customer_id
),
customer_base as (
    -- purpose: join customer identity with acquisition and activity summary; why: this creates the single master record used in all customer-level marts.
    select
        c.customer_id,
        c.customer_country,
        -- stg_acq_orders is already deduplicated to one row per customer; no further dedup needed here.
        a.taxonomy_business_category_group,
        s.first_seen_date,
        s.last_seen_date,
        coalesce(s.has_open_subscription, 0) as has_open_subscription,
        coalesce(s.is_active_customer, 0) as is_active_customer
    from {{ ref('stg_customers') }} c
    -- left join: keep every customer even if acquisition or activity data is missing; this preserves the full customer base while enriching with available detail.
    left join {{ ref('stg_acq_orders') }} a on a.customer_id = c.customer_id
    -- left join: keep every customer in the master table even when no valid activity window exists.
    left join activity_summary s on s.customer_id = c.customer_id
)
select
    customer_id,
    customer_country,
    coalesce(taxonomy_business_category_group, 'Unknown') as taxonomy_business_category_group,
    first_seen_date,
    last_seen_date,
    has_open_subscription,
    is_active_customer
from customer_base
