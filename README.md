# VOY retention analytics dbt project

This project builds an analytics engineering foundation for VOY customer retention, acquisition quality, and lifecycle analysis using the raw CSV files in the workspace.

## Objective

The goal is not simply to reshape three files into a reporting table. Instead, the project implements a modular dbt architecture that supports:

- customer retention analysis by cohort and time
- acquisition taxonomy quality analysis
- customer activity and churn diagnostics
- operational product and clinical intervention windows
- trusted executive KPI reporting

## Architecture

The project uses a medallion-style build:

- Staging: source-aligned, cleaned 1:1 representations of the raw BigQuery source tables
- Intermediate: business logic, interval validation, date spine, and cohort assignment
- Marts: dimension and fact tables for downstream analysis and BI consumption

## Source data

Raw source tables are loaded in BigQuery (`voy-task.lz_ae_task`):

- `customers` — customer master data
- `acq_orders` — acquisition taxonomy / customer category mapping
- `activity` — customer subscription lifecycle activity with start and end dates

## Model summary

### Staging models

- `stg_customers`: clean customer IDs and normalize country values
- `stg_acq_orders`: standardize acquisition taxonomy and remove duplicate customer-category rows
- `stg_activity`: cast activity dates and flag invalid subscription intervals
- `stg_activity_quarantine`: isolate invalid rows excluded from valid retention logic

### Intermediate models

- `int_customer_master`: canonical customer-level master with acquisition and first/last activity metadata
- `int_subscription_periods`: valid subscription interval model with duration and active-state logic
- `int_date_spine`: daily calendar backbone used for retention and time analyses
- `int_customer_day_activity`: core daily customer fact used for churn and retention curve analysis
- `int_customer_cohort_month`: month-level cohort assignment used to compare retention by cohort

### Mart models

- `dim_customer`: used by analysts and BI for segmentation
- `dim_date`: calendar dimension for time-level analysis
- `fct_subscription_period`: used for lifecycle / renewal analysis
- `fct_customer_daily`: used for retention and customer health dashboards
- `fct_customer_cohort_retention`: used for cohort comparison and acquisition quality

### Commercial outcomes and stakeholders

- **Product:** use the daily activity and cohort models to identify drop-off points, onboarding friction, and retention cliffs.
- **Marketing:** compare acquisition quality by channel/category and focus spend on the cohorts that retain best.
- **Leadership / Finance:** rely on a single source of truth for active customers, retention, and cohort performance.

### Useful graphs and charts

- Daily active customers over time
- Retention cliff chart by cohort month
- Cohort heatmap of retention rates by month offset
- Active vs inactive customer trend
- Acquisition quality comparison by taxonomy/category
- Subscription lifecycle timeline / renewal window view

## Key business logic

### Active status rule

Customer activity is treated as a binary state at the customer-day grain. The number of subscriptions does not define whether a customer is active. This is intentional and matches the project brief.

### Retention logic

The core retention metric is derived from the daily activity fact. This enables analytics at the appropriate granularity for:

- day-level retention cliffs
- weekly/monthly summaries
- cohort retention curves
- acquisition-category comparisons

## Data quality handling

The project explicitly manages common quality issues including:

- casing and whitespace normalization
- duplicate customer records
- invalid or inverted date ranges
- open-ended intervals
- orphaned customer keys and unmatched activity rows

Invalid records are quarantined rather than silently dropped so the business can audit issues without corrupting the trusted reporting layer.

## KPI definitions

The project is designed around a small set of core metrics that are reusable across product, marketing, and executive reporting.

### Active Customers

**Definition:** Count of distinct customers with `is_active_on_date = 1` on a given date — i.e. customers with a valid subscription window covering that day.

**Purpose:** Tracks customer health over time and reveals onboarding and retention cliffs.

**Source:** `fct_customer_daily`

### Active Subscribers

**Definition:** Count of customers with at least one open subscription (`has_open_subscription = 1` in `dim_customer`) — i.e. a subscription where `to_date IS NULL` as of the current date.

**Difference from Active Customers:** Active Customers is a point-in-time daily measure across the full history; Active Subscribers is a current-state snapshot based on open intervals only.

**Source:** `dim_customer`

### Retention Rate

**Definition:** For a given cohort and month offset, the ratio of customers still active at that time relative to the original cohort size.

**Formula:** `active_customers / cohort_size`

**Purpose:** Shows how well a cohort performs over time and highlights the shape of churn behavior by acquisition period.

**Source:** `fct_customer_cohort_retention`

### Churn Rate

**Definition:** Share of customers who are no longer active within a defined period relative to the prior active base.

**Formula:** `1 - (active_customers_end_of_period / active_customers_start_of_period)`

**Purpose:** Indicates whether the business is retaining customers through key lifecycle moments.

**Source:** `fct_customer_daily`

### New Customers

**Definition:** Count of customers with `is_new_customer = 1` on the relevant date.

**Purpose:** Measures acquisition volume and supports campaign and acquisition-taxonomy analysis.

### Acquisition Category Performance

**Definition:** Measures of new customer counts and retention quality by acquisition taxonomy such as Hair Loss Group, ED Group, Weight Loss Group, and others.

**Purpose:** Helps marketing and commercial teams compare quality of acquisition by category, not just volume.

### Customer Cohort

**Definition:** Customers grouped by their first valid activity / acquisition month.

**Purpose:** Allows fair comparison of retention and churn by acquisition period and segmentation.

## Testing and validation

The project includes dbt tests for:

- primary key uniqueness
- not-null integrity
- relationship-level sanity checks
- date-based validity checks

## Setup and running

### Prerequisites

- Python 3.11+
- dbt-bigquery (`pip install dbt-bigquery`)
- Google Cloud SDK (gcloud CLI): https://cloud.google.com/sdk/docs/install-sdk#windows

### Authentication (one-time)

This project uses Application Default Credentials (ADC) — no service account key files are required or stored in this repo.

Run the following once to authenticate:

```
gcloud auth application-default login
```

Log in with the Google account that has BigQuery access to the `voy-task` project. Credentials are stored locally on your machine only.

### Warehouse

- GCP project: `voy-task`
- Landing zone dataset: `lz_ae_task` (source tables: `customers`, `acq_orders`, `activity`)
- Output dataset: `dbt_dev` (models are materialized here)
- Location: `EU`

### Running the project

```
dbt deps
dbt debug
dbt build
```

---

## Why this design

This is intentionally designed as a reusable analytics layer rather than a single reporting view. It supports:

- product and clinical operations decisions
- marketing acquisition quality analysis
- executive retention monitoring
- future AI-driven intervention and risk analysis

The architecture creates an explicit separation between source data, derived business logic, and consumer-ready mart tables so the business can trust the outputs and the analysts can iterate without damaging the data contract.
