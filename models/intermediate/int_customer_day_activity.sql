/*
  Purpose: create the daily customer activity fact used for retention and churn analysis.
  Why: this is the core analytic base for time-based customer health, allowing us to measure active state, inactivity, and day-based drop-off cliffs with a stable daily grain.
*/
with customer_dates as (
    -- purpose: expand each customer across the date spine only from their first valid activity date onward; why: pre-acquisition dates create false churn and meaningless negative day counts.
    select
        c.customer_id,
        d.date_day,
        c.first_seen_date,
        c.customer_country,
        c.taxonomy_business_category_group,
        c.is_active_customer
    from {{ ref('int_customer_master') }} c
    -- cross join: build the full date scaffold for each customer from first_seen_date onward so every customer-day slot exists for retention analysis.
    cross join {{ ref('int_date_spine') }} d
    where c.first_seen_date is not null
      and d.date_day >= c.first_seen_date
),
activity_intervals as (
    -- purpose: keep the valid subscription periods ready for daily overlap checks; why: daily activity is derived by checking whether each date falls inside a valid subscription window.
    select
        customer_id,
        subscription_id,
        start_date,
        end_date,
        coalesce(end_date, current_date) as effective_end_date,
        is_active
    from {{ ref('int_subscription_periods') }}
),
activity_daily as (
    -- purpose: assess each customer/date against active subscription windows; why: this produces the daily active-state and counts that power retention and churn analysis.
    select
        cd.customer_id,
        cd.date_day,
        cd.first_seen_date,
        cd.customer_country,
        cd.taxonomy_business_category_group,
        cd.is_active_customer,
        count(a.subscription_id) as subscription_count_on_date,
        max(case when cd.date_day between a.start_date and a.effective_end_date then 1 else 0 end) as is_active_on_date
    from customer_dates cd
    -- left join: retain all customer-day rows, attaching subscription activity only when a valid subscription window matches that date.
    left join activity_intervals a
        on a.customer_id = cd.customer_id
       and cd.date_day between a.start_date and a.effective_end_date
    group by
       cd.customer_id,
       cd.date_day,
       cd.first_seen_date,
       cd.customer_country,
       cd.taxonomy_business_category_group,
       cd.is_active_customer
),
final as (
    -- purpose: finalize customer-day metrics; why: the daily fact must expose premium analytic measures such as active state, days since first activity, and first-day flags.
    select
        customer_id,
        date_day,
        first_seen_date,
        customer_country,
        taxonomy_business_category_group,
        is_active_customer,
        coalesce(is_active_on_date, 0) as is_active_on_date,
        coalesce(subscription_count_on_date, 0) as subscription_count_on_date,
        date_diff(date_day, first_seen_date, day) as days_since_first_activity,
        case when date_day = first_seen_date then 1 else 0 end as is_new_customer,
        -- is_inactive_on_date: inverse of is_active_on_date; computed after coalesce to ensure NULL-safety.
        1 - coalesce(is_active_on_date, 0) as is_inactive_on_date,
        case when is_active_customer = 1 and is_active_on_date = 1 then 1 else 0 end as is_currently_active_customer
    from activity_daily
)
select *
from final
