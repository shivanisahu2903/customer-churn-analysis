/* ==========================================================================
   Customer Churn Analysis: SQL Queries
   Database : customer_churn_1.db (SQLite 3.25+)
   Tables   : db_customer (100,000) | db_subscription (100,000) | db_support (43,362)
   Run with : DB Browser for SQLite, DBeaver, or `sqlite3 customer_churn_1.db < churn_analysis_queries.sql`
   Churn definition: a customer has churned when cancellation_date IS NOT NULL
   ========================================================================== */


/* --------------------------------------------------------------------------
   0. CLEAN "CUSTOMER 360" VIEW
   Mirrors the cleaning done in the Python notebook:
     - gender labels standardised (Men -> Male, Women -> Female)
     - missing country imputed from other customers in the same state
     - one row per customer using the LATEST support ticket
     - unused columns (interests, pincode, col_1, comment) left out
   -------------------------------------------------------------------------- */
DROP VIEW IF EXISTS vw_customer_360;
CREATE VIEW vw_customer_360 AS
WITH latest_ticket AS (
    SELECT customerid, complaint_date, escalations, csat_score,
           COUNT(*)     OVER (PARTITION BY customerid) AS complaint_count,
           ROW_NUMBER() OVER (PARTITION BY customerid ORDER BY complaint_date DESC) AS rn
    FROM db_support
)
SELECT
    s.customerid,
    c.name                                                         AS customer_name,
    COALESCE(c.country,
             (SELECT MAX(c2.country) FROM db_customer c2
              WHERE c2.state = c.state AND c2.country IS NOT NULL)) AS country,
    c.state,
    CASE c.gender WHEN 'Men' THEN 'Male' WHEN 'Women' THEN 'Female' ELSE c.gender END AS gender,
    date(c.dob)                                                    AS dob,
    s.subscription_start_date,
    s.renewal_date,
    s.cancellation_date,
    s.cancellation_reason,
    s.subscription_type,
    s.plan_type,
    s.contract_type,
    s.monthly_charges,
    s.cltv,
    s.churn_score,
    CASE WHEN s.cancellation_date IS NOT NULL THEN 1 ELSE 0 END   AS churn_flag,
    COALESCE(t.complaint_count, 0)                                 AS complaint_count,
    t.escalations,
    t.csat_score
FROM db_subscription s
LEFT JOIN db_customer  c ON c.customerid = s.customerid
LEFT JOIN latest_ticket t ON t.customerid = s.customerid AND t.rn = 1;


/* --------------------------------------------------------------------------
   1. DATA QUALITY CHECKS
   -------------------------------------------------------------------------- */
-- Q1.1 Row counts and duplicate customer IDs
SELECT 'db_customer' AS table_name, COUNT(*) AS total_rows, COUNT(DISTINCT customerid) AS unique_customers FROM db_customer
UNION ALL
SELECT 'db_subscription', COUNT(*), COUNT(DISTINCT customerid) FROM db_subscription
UNION ALL
SELECT 'db_support',      COUNT(*), COUNT(DISTINCT customerid) FROM db_support;

-- Q1.2 Missing values in the customer table
SELECT
    SUM(country   IS NULL) AS missing_country,
    SUM(interests IS NULL) AS missing_interests,
    SUM(pincode   IS NULL) AS missing_pincode,
    ROUND(100.0 * SUM(country IS NULL) / COUNT(*), 2) AS pct_missing_country
FROM db_customer;

-- Q1.3 Inconsistent gender labels (before cleaning)
SELECT gender, COUNT(*) AS customers FROM db_customer GROUP BY gender;


/* --------------------------------------------------------------------------
   2. HEADLINE KPIs
   -------------------------------------------------------------------------- */
-- Q2.1 Churn rate, retention rate, ARPU and monthly revenue lost
SELECT
    COUNT(*)                                              AS customers,
    SUM(churn_flag)                                       AS churned,
    ROUND(100.0 * AVG(churn_flag), 2)                     AS churn_rate_pct,
    ROUND(100.0 * (1 - AVG(churn_flag)), 2)               AS retention_rate_pct,
    ROUND(AVG(monthly_charges), 2)                        AS arpu_monthly,
    ROUND(SUM(CASE WHEN churn_flag = 1 THEN monthly_charges END), 2) AS monthly_revenue_lost
FROM vw_customer_360;


/* --------------------------------------------------------------------------
   3. WHO CHURNS?  SEGMENT ANALYSIS
   -------------------------------------------------------------------------- */
-- Q3.1 Churn by plan type
SELECT plan_type,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct,
       ROUND(AVG(monthly_charges), 2)    AS avg_monthly_charge
FROM vw_customer_360
GROUP BY plan_type
ORDER BY churn_rate_pct DESC;

-- Q3.2 Churn by contract type
SELECT contract_type,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct
FROM vw_customer_360
GROUP BY contract_type;

-- Q3.3 Churn by acquisition channel (column subscription_type, source data spells it 'Refferal')
SELECT subscription_type,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct,
       ROUND(SUM(monthly_charges), 2)    AS monthly_revenue
FROM vw_customer_360
GROUP BY subscription_type
ORDER BY churn_rate_pct DESC;

-- Q3.4 Channel x contract: is referral churn just a contract-mix effect?
SELECT subscription_type, contract_type,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct
FROM vw_customer_360
GROUP BY subscription_type, contract_type
ORDER BY subscription_type, contract_type;

-- Q3.5 Plan x contract
SELECT plan_type, contract_type,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct
FROM vw_customer_360
GROUP BY plan_type, contract_type
ORDER BY plan_type, contract_type;

-- Q3.6 Churn by state with customers and monthly revenue, ranked
SELECT state, country,
       COUNT(*)                                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2)                 AS churn_rate_pct,
       ROUND(SUM(monthly_charges), 2)                    AS monthly_revenue,
       RANK() OVER (ORDER BY AVG(churn_flag) DESC)       AS churn_rank
FROM vw_customer_360
GROUP BY state, country
ORDER BY churn_rank;

-- Q3.7 Churn by signup cohort (year)
SELECT strftime('%Y', subscription_start_date) AS signup_year,
       COUNT(*)                                AS customers,
       ROUND(100.0 * AVG(churn_flag), 2)       AS churn_rate_pct
FROM vw_customer_360
GROUP BY signup_year
ORDER BY signup_year;


/* --------------------------------------------------------------------------
   4. WHEN AND WHY?  TRENDS AND CANCELLATION REASONS
   -------------------------------------------------------------------------- */
-- Q4.1 Monthly churn trend with running total
SELECT strftime('%Y-%m', cancellation_date)                        AS cancel_month,
       COUNT(*)                                                    AS churned_customers,
       SUM(COUNT(*)) OVER (ORDER BY strftime('%Y-%m', cancellation_date)) AS cumulative_churned
FROM vw_customer_360
WHERE churn_flag = 1
GROUP BY cancel_month
ORDER BY cancel_month;

-- Q4.2 Cancellation reasons with share of total
SELECT cancellation_reason,
       COUNT(*)                                                    AS churned_customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)          AS pct_of_churn
FROM vw_customer_360
WHERE churn_flag = 1
GROUP BY cancellation_reason
ORDER BY churned_customers DESC;

-- Q4.3 Top cancellation reason within each plan (window function)
SELECT plan_type, cancellation_reason, churned_customers
FROM (
    SELECT plan_type, cancellation_reason, COUNT(*) AS churned_customers,
           ROW_NUMBER() OVER (PARTITION BY plan_type ORDER BY COUNT(*) DESC) AS rn
    FROM vw_customer_360
    WHERE churn_flag = 1
    GROUP BY plan_type, cancellation_reason
)
WHERE rn = 1;

-- Q4.4 Days from signup to cancellation (tenure of churned customers)
SELECT plan_type,
       ROUND(AVG(julianday(cancellation_date) - julianday(subscription_start_date)), 0) AS avg_days_to_cancel,
       MIN(CAST(julianday(cancellation_date) - julianday(subscription_start_date) AS INT)) AS min_days,
       MAX(CAST(julianday(cancellation_date) - julianday(subscription_start_date) AS INT)) AS max_days
FROM vw_customer_360
WHERE churn_flag = 1
GROUP BY plan_type;


/* --------------------------------------------------------------------------
   5. CUSTOMER SUPPORT AND CHURN
   -------------------------------------------------------------------------- */
-- Q5.1 Complained vs never complained
SELECT CASE WHEN complaint_count > 0 THEN 'Raised a complaint' ELSE 'Never complained' END AS segment,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct
FROM vw_customer_360
GROUP BY segment;

-- Q5.2 Escalation rate (of all tickets) and churn by escalation on latest ticket
SELECT ROUND(100.0 * SUM(escalations = 'Y') / COUNT(*), 2) AS escalation_rate_pct_of_tickets
FROM db_support;

SELECT escalations,
       COUNT(*)                          AS customers,
       ROUND(100.0 * AVG(churn_flag), 2) AS churn_rate_pct,
       ROUND(AVG(csat_score), 1)         AS avg_csat
FROM vw_customer_360
WHERE complaint_count > 0
GROUP BY escalations;

-- Q5.3 Average complaints per customer
SELECT ROUND(1.0 * (SELECT COUNT(*) FROM db_support) / (SELECT COUNT(*) FROM db_subscription), 2) AS avg_complaints_per_customer;


/* --------------------------------------------------------------------------
   6. RETENTION ACTION LISTS
   -------------------------------------------------------------------------- */
-- Q6.1 Active customers with an elevated churn score (>= 50), highest-value first
SELECT customerid, plan_type, contract_type, subscription_type,
       monthly_charges, churn_score, complaint_count, escalations
FROM vw_customer_360
WHERE churn_flag = 0 AND churn_score >= 50
ORDER BY monthly_charges DESC, churn_score DESC
LIMIT 25;

-- Q6.2 Size and value of the at-risk active base by plan
SELECT plan_type,
       COUNT(*)                       AS at_risk_customers,
       ROUND(SUM(monthly_charges), 2) AS monthly_revenue_at_risk
FROM vw_customer_360
WHERE churn_flag = 0 AND churn_score >= 50
GROUP BY plan_type
ORDER BY monthly_revenue_at_risk DESC;
