/*
  Purpose: aggregate daily customer activity into cohort retention curves.
  Why: leadership and marketing need a clean measure of cohort health over time, not just a list of daily customer states.
*/
with cohort_sizes as (
    -- purpose: compute the original size of each cohort; why: retention rate requires a denominator based on cohort size.
    select
        cohort_month,
        count(distinct customer_id) as cohort_size
    from {{ ref('int_customer_cohort_month') }}
    group by cohort_month
),
monthly_activity as (
    -- purpose: count active customers for each cohort at each month offset; why: this creates the retention curve needed for stakeholder dashboards and KPI analysis.
    select
        c.cohort_month,
        date_diff(date_trunc(f.date_day, month), c.cohort_month, month) as month_index,
        count(distinct f.customer_id) as active_customers
    from {{ ref('int_customer_cohort_month') }} c
    -- INNER JOIN: only retain active customer-day rows that belong to a valid cohort; the cohort lookup is required for retention calculation.
    inner join {{ ref('fct_customer_daily') }} f
        on f.customer_id = c.customer_id
    where f.is_active_on_date = 1
    group by c.cohort_month, date_diff(date_trunc(f.date_day, month), c.cohort_month, month)
)
select
    ma.cohort_month,
    ma.month_index,
    cs.cohort_size,
    ma.active_customers,
    round(ma.active_customers * 1.0 / nullif(cs.cohort_size, 0), 4) as retention_rate
from monthly_activity ma
-- INNER JOIN: only keep cohort-month records with a defined cohort size denominator.
inner join cohort_sizes cs on cs.cohort_month = ma.cohort_month
order by ma.cohort_month, ma.month_index
