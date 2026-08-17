# VOY analytics engineering architecture proposal

## Problem and approach

The requirement is not simply to reshape three CSVs, but to build a resilient, reusable dbt analytics layer that gives revenue, growth, product, and leadership teams a common truth source for retention, acquisition quality, and customer lifecycle behaviour.

The core architecture should follow a three-layer medallion flow:

- Staging: 1:1, source-aligned, strongly typed representations of the raw seed files.
- Intermediate: business-meaningful transformations, interval logic, cohort construction, and identity reconciliation.
- Marts: dimensional tables and event-style fact tables built for decision-making and BI consumption.

The design is intentionally modular. It keeps raw-source concerns separate from business logic, creates reusable intermediate objects for downstream marts, and gives us a stable contract for stakeholders.

## 1) Data profiling and quality strategy

### Current raw profile observed in the workspace

- `customers.csv`
  - 532,848 rows
  - 2 columns: `customer_id`, `customer_country`
  - 0 nulls; 532,848 unique customer IDs
  - country values are limited to two canonical values in practice: `Brazil`, `United Kingdom`
  - This is a very clean dimension today, but the production pattern should still assume upstream noise: whitespace, inconsistent casing, duplicate rows, and invalid country values.

- `acq_orders.csv`
  - 508,694 rows
  - 2 columns: `customer_id`, `taxonomy_business_category_group`
  - 0 nulls; 508,694 distinct customer IDs
  - 7 acquisition groups, suggesting a category taxonomy used to segment acquisition cohorts.
  - No obvious broken IDs today, but this source can still accumulate duplicate customer acquisitions or missing taxonomies in future loads.

- `activity.csv`
  - 2,176,168 rows
  - 4 columns: `customer_id`, `subscription_id`, `from_date`, `to_date`
  - 512,366 distinct customer IDs; 1,482,002 unique `subscription_id`s; 316,334 `subscription_id`s repeat in the data
  - Date range spans 2019-01-04 to 2024-08-16
  - 0 null `from_date`/`to_date` values and no date inversions observed in the current extract
  - Overlap analysis shows 507,470 customers are present across all three data sets; 19,258 customers appear in `customers.csv` but not in acquisition/activity data, which should be treated as a data-completeness edge case rather than a schema error

### Expected dirty-data patterns and how to handle them

Even though the current files are relatively clean, a production-grade dbt architecture must account for the following issues:

1. Casing and whitespace inconsistency
   - Example: `United kingdom`, ` united kingdom `, `brazil`, mixed-case values
   - Resolution: perform `trim`, `lower`, and canonical mapping in staging, then enforce uppercase/lowercase normalization using a `country_lookup` or `accepted_values` test.
   - Quarantine: rows with unknown country values after normalization go to a `stg_customers_quarantine` table or a `source_error` model rather than silently being dropped.

2. Duplicate customer records
   - Example: multiple rows for same customer ID with conflicting country or acquisition category
   - Resolution: dedupe by `customer_id` in staging and keep the latest valid record using `row_number() over (partition by customer_id order by _loaded_at desc)` or a business-defined precedence rule.
   - Quarantine: duplicates that disagree on critical attributes are logged to a quarantine model and excluded from downstream dimensions until resolved.

3. Open-ended intervals where `to_date IS NULL` / no end date
   - Example: active subscription with no exit date
   - Resolution: represent as `to_date = NULL` in the raw staging model, but derive `is_current=true` and `days_active` logic in intermediate models using `coalesce(to_date, current_date)` for active-window calculations.
   - Quarantine: if an interval has `from_date` missing or `to_date` earlier than `from_date`, move to quarantine.

4. Date inversions and malformed dates
   - Example: `to_date < from_date`; impossible timestamps or strings that fail date parsing
   - Resolution: cast to `DATE` in staging and flag invalid intervals.
   - Quarantine: `invalid_subscription_interval` model captures these records and excludes them from active-state and retention calculations while keeping them auditable.

5. Orphan foreign keys and missing references
   - Example: activity for a `customer_id` not present in `customers.csv` or an acquisition record that cannot be mapped to a valid customer
   - Resolution: preserve raw rows in staging and add explicit relationship tests using dbt `relationships` and custom tests.
   - Quarantine: build an `int_orphan_activity` or `int_unmatched_customer_activity` model with the unmatched keys, as an exception table for Ops review; do not let these records silently corrupt retention metrics.

6. Non-unique subscription IDs or overlapping subscription periods
   - Example: same `subscription_id` observed multiple times with different dates or repeated records
   - Resolution: normalize by `subscription_id` and define the canonical interval as the latest valid start/end pair; separate overlapping intervals into a review table if they indicate data quality or business reactivation logic.

### Data quality operating model

The final pipeline should treat staging as the “truth of the raw record” and quarantine as the “truth of the exception”:

- `models/staging/`:
  - Clean values, cast types, and standardize keys
  - Preserve raw row IDs and source metadata for lineage
  - Add `is_valid` flags and source-level null checks

- `models/intermediate/`:
  - Resolve duplicates, build canonical customer records, and create retention-relevant intervals
  - Exclude or isolate invalid rows so that business metrics remain reliable

- `models/marts/`:
  - Consume only valid, deduplicated records
  - Expose clean dimensions and fact tables to BI without needing to understand source anomalies

## 2) Data modelling architecture (medallion structure)

### Staging layer (`models/staging/`)

Target: 1:1 source replication with only necessary cleaning and dtype enforcement.

Proposed staging models:

- `stg_customers`
  - Source fields: `customer_id`, `customer_country`
  - Normalizations:
    - cast `customer_id` to string (or integer if warehouse-safe and consistent)
    - trim spaces, standardize country names
    - add `source_file`, `loaded_at` metadata
  - Tests: not_null on `customer_id`, unique on `customer_id`, accepted_values for country values once valid set is stabilized

- `stg_acq_orders`
  - Source fields: `customer_id`, `taxonomy_business_category_group`
  - Normalizations:
    - trim taxonomy strings
    - standardize category names to a canonical taxonomy mapping
    - deduplicate exact repeated rows
  - Tests: not_null on both fields, unique on `(customer_id, taxonomy_business_category_group)` if the business rule is “one acquisition label per customer”, otherwise use a row-level uniqueness rule that handles multiple acquisitions over time

- `stg_activity`
  - Source fields: `customer_id`, `subscription_id`, `from_date`, `to_date`
  - Normalizations:
    - cast date columns to `DATE`
    - trim string values
    - create `is_current` = `to_date IS NULL`
    - compute `interval_days = date_diff(to_date, from_date)` when both present
  - Tests: not_null on `customer_id`, `from_date`; accepted_values on date ordering after quarantine; relationship checks to `stg_customers.customer_id`

- `stg_activity_quarantine`
  - Contains invalid rows that fail interval validation: `to_date < from_date`, missing `from_date`, malformed `subscription_id`, or orphaned `customer_id`s
  - This model is critical because retention metrics should never silently count invalid subscription windows.

### Intermediate layer (`models/intermediate/`)

Target: business logic and reusable canonical datasets.

Recommended intermediate models:

1. `int_customer_master`
   - One row per customer
   - Built from `stg_customers` and a deduped acquisition table
   - Fields include:
     - `customer_id`
     - `customer_country`
     - `first_seen_date` (first activity or first acquisition event)
     - `acquisition_category`
     - `customer_status`
     - `is_active_customer`
   - Purpose: ensures a single canonical customer entity for all downstream marts.

2. `int_subscription_periods`
   - One row per valid `subscription_id` or per `(customer_id, subscription_id)` interval
   - Fields include:
     - `subscription_id`
     - `customer_id`
     - `start_date`
     - `end_date`
     - `interval_days`
     - `is_active`
     - `acquisition_category`
   - This is the core interval logic model for retention and churn calculations.

3. `int_customer_day_activity`
   - Grain: one row per customer per day
   - This is the critical operational model for retention analysis.
   - Each row contains:
     - `customer_id`
     - `activity_date`
     - `is_active_on_date`
     - `subscription_count_on_date`
     - `days_since_first_activity`
     - `cohort_month`
   - This model feeds retention curves and churn cliffs.

4. `int_date_spine`
   - Daily date dimension from min to max date across the activity table or a fiscal calendar coverage range
   - Used to guarantee all retention calculations have explicit date coverage and to support time-series metrics with zero-fill reporting.

5. `int_customer_cohort_month`
   - One row per customer with a `cohort_month` value derived from first activity or first acquisition date
   - This becomes the foundation for cohort retention curves and acquisition quality comparisons.

### Mart layer (`models/marts/`)

#### 1. `dim_customer`
- Grain: one row per `customer_id`
- Primary key: `customer_id`
- Foreign keys: none; dimensions are self-contained
- Key fields:
  - `customer_id`
  - `customer_country`
  - `first_acquisition_date`
  - `acquisition_category`
  - `first_seen_date`
  - `is_active_customer`
  - `latest_subscription_status`
- Purpose: customer master for reporting and segmentation.

#### 2. `dim_date`
- Grain: one row per day
- Primary key: `date_day`
- Fields include calendar month, quarter, year, is_weekend, fiscal period if needed
- Purpose: shared time dimension for cohort analysis, retention curves, and trend reporting.

#### 3. `fct_customer_daily`
- Grain: one row per `customer_id` + `activity_date`
- Primary key: `(customer_id, activity_date)`
- Foreign keys:
  - `customer_id` -> `dim_customer.customer_id`
  - `activity_date` -> `dim_date.date_day`
- Measures:
  - `is_active_on_date`
  - `subscription_count_on_date`
  - `days_since_first_activity`
  - `is_new_customer`
  - `is_churned_on_date`
- Purpose: enables retention cliffs, daily active customer trends, and event-based health analysis.

#### 4. `fct_subscription_period`
- Grain: one row per `subscription_id`
- Primary key: `subscription_id`
- Foreign keys:
  - `customer_id` -> `dim_customer.customer_id`
  - `acquisition_category` -> taxonomy dimension if we expose an explicit category dimension
- Measures:
  - `start_date`, `end_date`, `duration_days`, `is_active`, `reactivation_flag`
- Purpose: subscription-level lifecycle and renewal analysis.

#### 5. `fct_customer_cohort_retention`
- Grain: one row per `cohort_month` + `month_index` + optional segmentation dimension
- Primary key: `(cohort_month, month_index, segment)`
- Foreign keys:
  - `cohort_month` -> `dim_date` or a separate cohort month dimension
  - `customer_id` is not stored at this grain; it is aggregated
- Measures:
  - `cohort_size`
  - `active_customers`
  - `retention_rate`
  - `churned_customers`
  - `revenue_proxy` if and when financial data is introduced
- Purpose: the central executive retention object used to show retention over time by cohort and category.

#### 6. Optional `fct_acquisition_performance`
- Grain: one row per `acquisition_month` + `taxonomy_business_category_group`
- Foreign keys: taxonomy dimension or customer-level reference
- Measures:
  - `new_customers`
  - `active_90_day_customers`
  - `retention_30d`, `retention_90d`
  - `cost_per_acquired_customer` (if CAC input is added)
- Purpose: supports marketing quality and category performance analysis.

## 3) Design justifications and trade-offs

### Why this structure is preferred

1. Separation of concerns
   - Staging is designed for source fidelity; intermediate is built for reusable business logic; marts are designed for consumption.
   - This allows the business to trust the reporting layer without re-deriving logic from raw files every time.

2. Retention logic is date-driven and should not be embedded in raw ingestion
   - The key business requirements (active status, churn cliffs, cohort retention) are inherently interval-based.
   - The date-spine and customer-day models make that logic explicit, consistent, and testable.

3. Dimensional structure gives clean BI navigation
   - Product, marketing, and finance all reason in terms of customer, date, and acquisition category dimensions.
   - The star schema is more consumable than a single monolithic reporting table and is easier to extend as new sources arrive.

4. A modular medallion design is easier to scale
   - New data feeds (subscription renewals, billing, CRM, product events) can plug into the same customer master and date-spine without breaking reporting models.

### Why not a monolithic reporting view?

A single report view may be faster to prototype, but it becomes brittle as soon as the business asks for different definitions of active, churn, or cohort. A modular architecture isolates that complexity and avoids repeated SQL logic spread across Looker or downstream dashboards.

### Materialization choices

- `staging`: `view`
  - Low cost and close to raw source; easy to inspect and debug during development.
  - Good for fast dbt builds and source-level lineage.

- `intermediate`: `table`
  - These models are reused across many downstream tables and deserve materialization for performance and testability.
  - They are business-critical enough to warrant stable, cached outputs.

- `marts`: `table`
  - Used repeatedly by BI and executive reporting; they should be optimized for predictable query performance.
  - Since the consumer is primarily BI and dashboards, table-based marts are the right trade-off.

- `incremental` (selective use)
  - Best on high-volume daily fact tables such as `fct_customer_daily` or future event-level customer activity fact tables if the pipeline grows beyond a single historical backfill.
  - Use incremental builds keyed on `(customer_id, activity_date)` or `(subscription_id)` depending model grain.
  - Keep the daily fact model incremental only after the historical logic is robust; do not start with incremental complexity if the project is still maturing.

## 4) Commercial and stakeholder value

### Marketing

The acquisition taxonomy and customer master support:

- acquisition quality by category and country
- CAC payback proxy when combined with revenue or billing data later
- campaign mix analysis across category segments
- identification of whether a category is bringing high-retention customers or short-lived ones

This matters because marketing wants to know not just how many customers were acquired, but whether those customers become active, retained, and worth the acquisition spend.

### Product and clinical operations

The daily activity and cohort models can surface:

- day 0–7 onboarding drop-off cliffs
- day 25 renewal reminder timing
- recurring product milestone triggers at day 90
- dormant customer reactivation opportunities

This matters because the business can intervene at the exact points where user behaviour changes, rather than waiting for a quarterly retrospective dashboard.

### Executive and finance

The key trusted metrics should include:

- Active Subscribers
- New Customer Count by acquisition group and month
- Retention Rate by cohort and month
- Churn Rate by country and category
- Net Revenue Retention proxy (when financial data becomes available)
- Acquisition efficiency and cohort-level value across categories

The primary executive deliverable is a single source of truth for retention, customer health, and category quality.

## 5) Step-by-step implementation roadmap

### 1. Project setup

- Create a dbt project structure with:
  - `dbt_project.yml`
  - `packages.yml`
  - `models/` with `staging/`, `intermediate/`, `marts/`
  - `analyses/` and `tests/` if needed
- Configure seed files as raw sources or staging seeds, depending warehouse architecture.
- Define `sources.yml` for the three CSVs and a clear contract for naming and lineage.

### 2. Model implementation sequence

1. Source staging and tests
   - `stg_customers`
   - `stg_acq_orders`
   - `stg_activity`
   - `stg_activity_quarantine`

2. Intermediate dedupe and interval logic
   - `int_customer_master`
   - `int_subscription_periods`
   - `int_customer_day_activity`
   - `int_date_spine`
   - `int_customer_cohort_month`

3. Core marts
   - `dim_customer`
   - `dim_date`
   - `fct_customer_daily`
   - `fct_subscription_period`
   - `fct_customer_cohort_retention`
   - optional `fct_acquisition_performance`

4. Reporting layer
   - Expose the marts to Looker or a BI tool with semantic definitions and reusable measures.

### 3. dbt tests and schema documentation

- Add tests for:
  - primary-key uniqueness
  - not_null checks
  - accepted_values for category/country dimensions
  - relationships between child and parent keys
  - date-validity checks for activity windows
- Use `schema.yml` to define:
  - model descriptions
  - field descriptions
  - tests and expected grain
  - source-to-mart lineage labels
- Add a concise README for the project explaining what each mart is used for and which business question it answers.

### 4. Production BI / visualisation specs

The underlying marts should support the following reporting flows:

- Executive dashboard:
  - Active subscribers over time
  - Cohort retention curves by month
  - Country and acquisition-category retention splits

- Marketing dashboard:
  - New customers by category and country
  - Retention by acquisition group at 30/90/180 days
  - CAC proxy and customer quality benchmark by acquisition taxonomy

- Product / Ops dashboard:
  - Active status by day since acquisition
  - Onboarding cliff at day 0–7 and retention at reminder checkpoints
  - Subscription lifecycle summary and reactivation windows

## Final recommendation

The recommended design is a modular medallion architecture anchored by a clean customer master, a date spine, and a customer-day retention fact table. That is the best fit for this dataset because the business problem is retention and lifecycle management, not just row-level transformation.

The value of the architecture is not only that the data loads into a warehouse; it is that it creates a trusted, decision-ready dataset for marketing, product, operations, and leadership to act on consistently. The business benefits come from reducing ambiguity in how active and retained are defined, making retention visible by cohort and category, and enabling interventions at the exact moments users are likely to drop off.

## Recent implementation refinements

The project has been tightened in a few areas since the initial draft to improve both correctness and traceability:

- Duplicate resolution is now deterministic rather than relying on a single timestamp field with no true precedence signal.
- Repeated `subscription_id` records are split into distinct lifecycle islands when a gap is detected, preventing reactivation or repeated periods from being silently merged together.
- The customer-day fact is now generated only from each customer's first valid activity date onward, which prevents false pre-acquisition rows and negative `days_since_first_activity` values.
- Weekend flags are aligned with DuckDB's actual `dayofweek` mapping so weekday/weekend reporting does not silently drift.

These refinements keep the design aligned with the original analytics intent while making the model more robust for production-quality analysis and stakeholder trust.

### Explicit join semantics used in the model layer

The implementation intentionally uses specific join types to preserve business meaning:

- `int_customer_master`: `left join` from `stg_customers` to `stg_acq_orders` and `stg_activity` so every customer remains in the master table even when acquisition or activity detail is missing.
- `int_customer_day_activity`: `cross join` from each customer to the date spine to create the full daily scaffold; then `left join` to valid subscription intervals so customer-day rows remain complete even when there is no matching activity on a given date.
- `fct_customer_daily`: `inner join` from the customer-day fact to `dim_customer` and `dim_date` so the final mart only includes rows with valid customer and date keys.
- `fct_customer_cohort_retention`: `inner join` from active cohort activity to the cohort-size denominator so retention rates are calculated only when a valid cohort exists.

## Design Decisions & Trade-offs

This section captures key architecture choices, alternatives considered, and why each decision was selected for the VOY analytics engineering context.

### 1) Runtime choice: DuckDB for local build, BigQuery for production

- **Decision:** Use DuckDB for local development and validation; target BigQuery for production deployment.
- **Alternative considered:** BigQuery-first implementation from day one.
- **Why this choice:** Local DuckDB removes credential and infra setup friction for interview execution, while preserving dbt model structure and SQL patterns that can be ported to BigQuery with adapter-aware adjustments.
- **Trade-off:** Faster iteration locally vs. not immediately validating warehouse-specific performance behavior in BigQuery.

### 2) Modular medallion architecture vs single monolithic reporting model

- **Decision:** Separate logic into staging, intermediate, and marts.
- **Alternative considered:** A single, end-to-end reporting model that does cleaning + joining + metric output in one file.
- **Why this choice:** Better testability, observability, maintainability, and reuse. Each transformation step has a clear contract and can be validated independently.
- **Trade-off:** More models and orchestration complexity up front vs significantly better long-term reliability and change agility.

### 3) Analytics-first base fact vs reporting-only aggregates

- **Decision:** Keep an analytics-grade customer-day fact (`fct_customer_daily`) as the canonical retention base.
- **Alternative considered:** Only publishing pre-aggregated reporting tables.
- **Why this choice:** Daily grain is needed to identify behavioral cliffs (D0-7 onboarding, D25 reminders, D90 milestones), support intervention logic, and allow dynamic slicing by cohort/country/taxonomy.
- **Trade-off:** Higher compute/storage cost vs richer analytical flexibility and better experimentation support.

### 4) Binary customer activity definition vs subscription-count-driven activity

- **Decision:** Treat active status as a customer-level binary state; do not let subscription count define whether a customer is active.
- **Alternative considered:** Defining activity intensity by number of subscriptions.
- **Why this choice:** It matches business intent from the brief ("how many subscriptions they have doesn’t affect how Active they are") and avoids metric distortion from customers with multiple overlapping subscriptions.
- **Trade-off:** Less granularity in the headline active KPI vs cleaner and more interpretable retention signals.

### 5) Daily grain with downstream rollups vs monthly-only base model

- **Decision:** Maintain daily canonical grain and derive weekly/monthly aggregates downstream.
- **Alternative considered:** Build only monthly cohort tables at base level.
- **Why this choice:** You can always aggregate daily to monthly, but you cannot reconstruct intra-month churn behavior from monthly-only data.
- **Trade-off:** More expensive model builds vs preserving analytical fidelity for operational use cases.

### 6) Quarantine-and-audit pattern vs silent row dropping

- **Decision:** Route invalid intervals/keys to quarantine models and keep them auditable.
- **Alternative considered:** Dropping bad rows silently during transformation.
- **Why this choice:** Silent drops hide quality issues and undermine trust. Quarantine maintains governance and supports data issue triage without corrupting trusted marts.
- **Trade-off:** Additional model artifacts and QA process vs stronger reliability and transparency.

### 7) dbt-owned metric logic vs LookML-only semantics

- **Decision:** Keep canonical metric logic in dbt models, with LookML as the presentation/consumption layer.
- **Alternative considered:** Defining key business logic only in LookML.
- **Why this choice:** dbt enables shared, testable, versioned metric definitions across teams and tools; LookML then focuses on explores, drill paths, and UX.
- **Trade-off:** Some duplication of metadata between dbt and BI semantic layers vs much stronger governance and portability.

### 8) Start with correctness, then optimize with incremental strategy

- **Decision:** Establish logically correct full-refresh models first; then introduce incremental materializations where appropriate (especially heavy daily facts).
- **Alternative considered:** Implement incremental logic from day one.
- **Why this choice:** Early optimization increases complexity and can obscure metric correctness. Correctness-first reduces risk during ambiguous problem framing.
- **Trade-off:** Slower initial builds vs safer business logic validation and cleaner onboarding for reviewers/stakeholders.

### 9) Not publishing a single "everything table"

- **Decision:** Avoid one oversized customer table containing mixed grains (customer, subscription, and day-level states together).
- **Alternative considered:** A wide "all-in-one" table for convenience.
- **Why this choice:** Mixed-grain tables create duplicate counting risk, ambiguous metric definitions, and poor maintainability.
- **Trade-off:** Consumers may need joins across a few curated marts vs higher semantic clarity and safer analytics.

### Summary statement for interview narrative

The architecture intentionally prioritizes **analytical correctness, business interpretability, and long-term reuse** over short-term convenience. The key principle is: maintain an analytics-grade canonical base, expose curated marts for consumption, and preserve governance via testable, modular dbt transformations.

## Current implementation status

The project has been built and validated as a local dbt implementation using DuckDB. The staging, intermediate, and mart layers are in place, layer-specific YAML documentation is applied, the README reflects the same logic, and the project successfully builds with dbt tests in this workspace. This is the local, interview-ready version of a design that would map directly to BigQuery or a similar warehouse in production.
