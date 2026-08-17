/*
  Purpose: create the canonical customer dimension from the raw customer seed.
  Why: customer_id is the core business key and must be cleaned, deduplicated, and standardized before it can be trusted in downstream retention logic.
*/
with source as (
    -- source: raw customer seed; purpose: preserve the original rows before standardization and deduplication.
    select *
    from {{ ref('customers') }}
),
normalized as (
    -- purpose: trim whitespace and normalize country values; why: avoids casing and formatting drift across upstream files.
    select
        trim(cast(customer_id as varchar)) as customer_id,
        nullif(trim(customer_country), '') as customer_country,
        current_timestamp as loaded_at
    from source
),
deduped as (
    -- purpose: keep the latest valid record per customer; why: prevents duplicate customer rows from creating conflicting customer identities.
    select
        *,
        row_number() over (
            partition by customer_id
            order by
                customer_country is not null desc,
                customer_country asc,
                loaded_at desc
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
    end as customer_country,
    loaded_at
from deduped
where row_num = 1
