/*
  Purpose: create the canonical customer dimension from the raw BigQuery source table (voy-task.lz_ae_task.customers).
  Why: customer_id is the core business key and must be cleaned, deduplicated, and standardized before it can be trusted in downstream retention logic.
*/
with source as (
    -- source: BigQuery landing zone (voy-task.lz_ae_task.customers); purpose: preserve the original rows before standardization and deduplication.
    select *
    from {{ source('lz_ae_task', 'customers') }}
),
normalized as (
    -- purpose: trim whitespace and normalize country values; why: avoids casing and formatting drift across upstream files.
    select
        trim(cast(customer_id as string)) as customer_id,
        nullif(trim(customer_country), '') as customer_country
    from source
),
deduped as (
    -- purpose: keep one record per customer using a deterministic precedence rule; why: prevents duplicate rows from creating conflicting customer identities.
    -- tiebreak rule: prefer rows with a non-null country; where both are non-null, alphabetical order is the accepted last-resort deterministic rule.
    select
        *,
        row_number() over (
            partition by customer_id
            order by
                customer_country is not null desc,
                customer_country asc
        ) as row_num
    from normalized
)
select
    customer_id,
    case
        when customer_country is null then null
        when lower(trim(customer_country)) = 'brazil' then 'Brazil'
        when lower(trim(customer_country)) = 'united kingdom' then 'United Kingdom'
        else trim(customer_country)
    end as customer_country
from deduped
where row_num = 1
