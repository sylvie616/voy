/*
  Purpose: standardize raw activity intervals and identify whether each record is valid for retention logic.
  Why: retention analysis depends on trustworthy date windows; malformed intervals must be flagged before they are used in customer-day or cohort logic.
*/
with source as (
    -- source: raw subscription activity seed; purpose: preserve original record structure before working with dates or business rules.
    select *
    from {{ ref('activity') }}
),
normalized as (
    -- purpose: coerce IDs and dates to clean typed values; why: date comparisons require consistent DATE values and trimmed strings.
    select
        trim(cast(customer_id as varchar)) as customer_id,
        trim(cast(subscription_id as varchar)) as subscription_id,
        cast(nullif(trim(cast(from_date as varchar)), '') as date) as from_date,
        cast(nullif(trim(cast(to_date as varchar)), '') as date) as to_date
    from source
),
flagged as (
    -- purpose: mark valid vs invalid intervals; why: the retention model must exclude malformed windows without losing them for audit and remediation.
    select
        *,
        case
            when customer_id is null or customer_id = '' then 0
            when subscription_id is null or subscription_id = '' then 0
            when from_date is null then 0
            when to_date is not null and to_date < from_date then 0
            else 1
        end as is_valid_interval
    from normalized
)
select
    customer_id,
    subscription_id,
    from_date,
    to_date,
    is_valid_interval
from flagged
