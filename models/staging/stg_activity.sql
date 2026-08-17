/*
  Purpose: standardize raw activity intervals and identify whether each record is valid for retention logic.
  Why: retention analysis depends on trustworthy date windows; malformed intervals must be flagged before they are used in customer-day or cohort logic.
*/
with source as (
    -- source: BigQuery landing zone (voy-task.lz_ae_task.activity); purpose: preserve original record structure before working with dates or business rules.
    select *
    from {{ source('lz_ae_task', 'activity') }}
),
normalized as (
    -- purpose: coerce IDs and dates to clean typed values; why: date comparisons require consistent DATE values and trimmed strings.
    -- SAFE.PARSE_DATE silently returns NULL for any value that doesn't match %Y-%m-%d; is_parse_error flags these for audit.
    select
        trim(cast(customer_id as string)) as customer_id,
        trim(cast(subscription_id as string)) as subscription_id,
        safe.parse_date('%Y-%m-%d', nullif(trim(cast(from_date as string)), '')) as from_date,
        safe.parse_date('%Y-%m-%d', nullif(trim(cast(to_date as string)), '')) as to_date,
        case
            when nullif(trim(cast(from_date as string)), '') is not null
             and safe.parse_date('%Y-%m-%d', nullif(trim(cast(from_date as string)), '')) is null
            then 1 else 0
        end as is_from_date_parse_error
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
        end as is_valid_interval,
        -- zero-duration flag: same-day start/end may indicate a trial cancellation; exposed for analyst review rather than auto-excluded.
        case when to_date is not null and to_date = from_date then 1 else 0 end as is_zero_duration
    from normalized
)
select
    customer_id,
    subscription_id,
    from_date,
    to_date,
    is_valid_interval,
    is_zero_duration,
    is_from_date_parse_error
from flagged
