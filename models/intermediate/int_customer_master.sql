/*
  Purpose: build the canonical customer master.
  Why: customer-level analytics needs one trusted record per customer that combines identity, acquisition source, and lifecycle signals without repeating raw source complexity.
*/
with acquisition_ranked as (
    -- purpose: choose a canonical acquisition label per customer; why: prevent duplicate customer-taxonomy rows from creating unstable customer definitions.
    select
        customer_id,
        taxonomy_business_category_group,
        row_number() over (
            partition by customer_id
            order by taxonomy_business_category_group
        ) as row_num
    from {{ ref('stg_acq_orders') }}
),
acquisition as (
    -- purpose: keep the selected acquisition label only; why: downstream analysis should rely on one acquisition category per customer.
    select
        customer_id,
        taxonomy_business_category_group
    from acquisition_ranked
    where row_num = 1
),
activity_summary as (
    -- purpose: summarize valid activity history at customer level; why: we need first seen, last seen, and active/open status before building customer-day or retention logic.
    select
        customer_id,
        min(from_date) as first_seen_date,
        max(case when to_date is null then current_date else to_date end) as last_seen_date,
        max(case when is_valid_interval = 1 and to_date is null then 1 else 0 end) as has_open_subscription,
        max(case when is_valid_interval = 1 and to_date is null then 1 else 0 end) as is_active_customer
    from {{ ref('stg_activity') }}
    where is_valid_interval = 1
    group by customer_id
),
customer_base as (
    -- purpose: join customer identity with acquisition and activity summary; why: this creates the single master record used in all customer-level marts.
    select
        c.customer_id,
        c.customer_country,
        a.taxonomy_business_category_group,
        s.first_seen_date,
        s.last_seen_date,
        coalesce(s.has_open_subscription, 0) as has_open_subscription,
        coalesce(s.is_active_customer, 0) as is_active_customer
    from {{ ref('stg_customers') }} c
    -- left join: keep every customer even if acquisition or activity data is missing; this preserves the full customer base while enriching with available detail.
    left join acquisition a on a.customer_id = c.customer_id
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
