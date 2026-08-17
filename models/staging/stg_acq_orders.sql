/*
  Purpose: create the canonical customer acquisition taxonomy.
  Why: acquisition category is a major segmentation axis for marketing quality and retention analysis, so it must be standardized and deduplicated before use.
*/
with source as (
    -- source: raw acquisition taxonomy seed; purpose: preserve the original data before normalization.
    select *
    from {{ ref('acq_orders') }}
),
normalized as (
    -- purpose: trim keys and category values; why: avoids whitespace and casing artifacts that distort segmentation.
    select
        trim(cast(customer_id as varchar)) as customer_id,
        nullif(trim(taxonomy_business_category_group), '') as taxonomy_business_category_group
    from source
),
deduped as (
    -- purpose: resolve duplicate customer classification rows; why: one customer should map to one canonical acquisition taxonomy for trustworthy marketing analysis.
    select
        *,
        row_number() over (
            partition by customer_id
            order by
                taxonomy_business_category_group is not null desc,
                taxonomy_business_category_group asc
        ) as row_num
    from normalized
)
select
    customer_id,
    case
        when taxonomy_business_category_group is null then 'Unknown'
        else trim(taxonomy_business_category_group)
    end as taxonomy_business_category_group
from deduped
where row_num = 1
