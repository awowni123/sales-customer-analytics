-- Changes over the year

SELECT DATETRUNC(MONTH, order_date) as order_year, SUM(sales_amount) as total_sales,
COUNT(DISTINCT customer_key) as total_customers,
SUM(quantity) as total_quantity
FROM gold.fact_sales
where order_date is not null
group by DATETRUNC(MONTH, order_date)
order by DATETRUNC(MONTH, order_date);

-- Cumulative Analysis 
-- Total sales per month and running total of sales with time


select order_date, total_sales, 
sum(total_sales) over(order by order_date) as 
running_total_sales from 
(
select datetrunc(month, order_date) as order_date, 
sum(sales_amount) as total_sales
from gold.fact_sales
where order_date is not null
group by datetrunc(month, order_date)
) as t;

-- Running total over year

select distinct year(order_date) as order_year, 
sum(sales_amount) over(partition 
by year(order_date)) as total_sales,
sum(sales_amount) over(order by year(order_date))
as running_total_sales
from gold.fact_sales
where order_date is not null
order by year(order_date);

-- Performance Analysis (year-on-year)

with yearly_product_sales as (
SELECT year(f.order_date) as order_year , p.product_name, 
sum(f.sales_amount) as current_sales
from gold.fact_sales as f
left join gold.dim_products as p
on f.product_key = p.product_key
where order_date is not null
group by year(f.order_date), p.product_name
)

select order_year, product_name, current_sales,
avg(current_sales)
over(partition by product_name) as avg_sales,
(current_sales - avg(current_sales)
over(partition by product_name)) as diff_avg,
lag(current_sales,1) over(partition by product_name
order by order_year) as last_year_sale,
CASE WHEN current_sales - 
lag(current_sales,1) over(partition by product_name
order by order_year) > 0 THEN 'Increase'
WHEN current_sales - 
lag(current_sales,1) over(partition by product_name
order by order_year) < 0 THEN 'Decrease'
ELSE 'No Change' END as py_change
from yearly_product_sales
order by product_name,order_year
;

-- Part-to-Whole Analysis 

-- Which categories contribute the most to overall sales?

WITH category_sales AS (
    SELECT 
        category, 
        SUM(sales_amount) AS total_sales
    FROM gold.fact_sales AS f
    LEFT JOIN gold.dim_products AS p
        ON p.product_key = f.product_key
    GROUP BY category
)
SELECT 
    category, 
    total_sales,
    SUM(total_sales) OVER() AS overall_sales,
    ROUND((CAST(total_sales AS FLOAT) / SUM(total_sales) OVER())*100,2) AS percent_of_total
FROM category_sales
ORDER BY total_sales DESC;

-- Data Segmentation 

-- Segment products into cost ranges and count how many products fall into each segment
WITH product_segments AS (
SELECT 
    product_key, 
    product_name, 
    cost,
    CASE 
        WHEN cost < 100 THEN 'below 100'
        WHEN cost BETWEEN 100 AND 500 THEN '100-500'
        WHEN cost BETWEEN 500 AND 1000 THEN '500-1000'
        ELSE 'above 1000'
    END AS cost_range
FROM gold.dim_products)

SELECT cost_range,COUNT(product_key)
as total_products from product_segments
group by cost_range
order by total_products desc

--Group customers as per their spending behaviour
  --VIP: atleast 12 months of history and spending more than 5000
  --Regular: atleast 12 months + spending 5000 or less
  --New: less than 12 months 
--Total number of customers by each group 


with customer_spending as (
select c.customer_key,
sum(sales_amount) as total_spending,
min(order_date) as first_order,
max(order_date) as last_order,
DATEDIFF(month, min(order_date), max(order_date))
as lifespan
from gold.fact_sales as f
left join gold.dim_customers as c
on f.customer_key = c.customer_key
group by c.customer_key)

select 
case when lifespan > 12 and total_spending > 5000
then 'VIP'
when lifespan > 12 and total_spending <= 5000 then 
'Regular'
else 'New' end as customer_type,
count(customer_key) as total_customers
from customer_spending
group by case when lifespan > 12 and total_spending > 5000
then 'VIP'
when lifespan > 12 and total_spending <= 5000 then 
'Regular'
else 'New' end
;


/*
Build Customer Report : consolidates key customer metrics and behaviour
===========================================================================

Highlights:

1. Gather essential fields like name, age and transaction details
2. Segment customers into categories(VIP,Regular,New)
and age groups 
3. Aggregates customer_level metrics:
    -total orders
    -total sales
    -total quantity purchased
    -total products
    -lifespan
4. Calculates valuable KPIs:
    -months since last order
    -AOV
    -average monthly spend
===============================================================
*/
 -- Base Query 
 
 with base_query as (
 select f.order_number, f.product_key,
 f.order_date, f.sales_amount, f.quantity, c.customer_key, 
 concat(c.first_name,' ', c.last_name) as customer_name, 
 c.customer_number,
 datediff(year, c.birthdate, getdate()) age
 from gold.fact_sales as f
 left join gold.dim_customers c
 on c.customer_key = f.customer_key
 where order_date is not null), customer_aggregation as (
 
 -- Customer Aggregations: key metrics at customer level

 select customer_key, customer_number, customer_name,
 age,
 count(distinct order_number) as total_orders,
 sum(sales_amount) as total_sales, 
 sum(quantity) as total_quantity,
 count(distinct product_key) as total_products,
 MAX(order_date) as last_order_date,
 DATEDIFF(month, min(order_date), max(order_date))
 as lifespan
 from base_query
 group by customer_key, customer_number, customer_name,
 age)
 select  customer_key, customer_number, customer_name,
 age, case when lifespan > 12 and total_sales > 5000
then 'VIP'
when lifespan > 12 and total_sales <= 5000 then 
'Regular'
else 'New' end as customer_type,
case
when age < 20 then 'under 20'
when age between 20 and 29 then '20-29'
when age between 30 and 39 then '30-39'
when age between 40 and 49 then '40-49'
else '50 and above' end as age_group,
total_orders, total_sales, total_quantity,
total_products,last_order_date ,lifespan,
datediff(month, last_order_date, getdate()) as recency,
total_sales/total_orders as average_order_value,
case when lifespan = 0 then total_sales
else total_sales/lifespan end as avg_monthly_spend

from customer_aggregation;

/*
Build Product Report : consolidates key product metrics and behaviour
========================================================================

Highlights:

1. Gather essential product information:
    - product name
    - category
    - subcategory
    - cost

2. Gather transaction-level details:
    - order number
    - order date
    - customer
    - sales amount
    - quantity

3. Prepare the base dataset for:
    - product-level aggregations
    - product performance segmentation
    - KPI calculations
========================================================================
*/

-- Base Query

WITH base_query AS (

    SELECT
        f.order_number,
        f.order_date,
        f.customer_key,
        f.product_key,
        f.sales_amount,
        f.quantity,
        p.product_name,
        p.category,
        p.subcategory,
        p.cost

    FROM gold.fact_sales AS f

    LEFT JOIN gold.dim_products AS p
        ON p.product_key = f.product_key

    WHERE f.order_date IS NOT NULL
),
product_aggregation AS (

    -- Product Aggregations: key metrics at product level

    SELECT
        product_key,
        product_name,
        category,
        subcategory,
        cost,

        COUNT(DISTINCT order_number) AS total_orders,

        SUM(sales_amount) AS total_sales,

        SUM(quantity) AS total_quantity,

        COUNT(DISTINCT customer_key) AS total_customers,

        MAX(order_date) AS last_sale_date,

        DATEDIFF(
            month,
            MIN(order_date),
            MAX(order_date)
        ) AS lifespan

    FROM base_query

    GROUP BY
        product_key,
        product_name,
        category,
        subcategory,
        cost
)
-- Final Query: product segmentation and KPI calculations

SELECT
    product_key,
    product_name,
    category,
    subcategory,
    cost,

    -- Product Performance Segmentation
    CASE
        WHEN total_sales > 50000 THEN 'High-Performer'
        WHEN total_sales >= 10000 THEN 'Mid-Range'
        ELSE 'Low-Performer'
    END AS product_segment,

    -- Key Product Metrics
    total_orders,
    total_sales,
    total_quantity,
    total_customers,
    last_sale_date,
    lifespan,

    -- KPIs
    DATEDIFF(month, last_sale_date, GETDATE()) AS recency,

    1.0 * total_sales / total_orders AS average_order_revenue,

    CASE
        WHEN lifespan = 0 THEN total_sales
        ELSE 1.0 * total_sales / lifespan
    END AS avg_monthly_revenue

FROM product_aggregation;

/* ============================================================
   RFM CUSTOMER SEGMENTATION

   Recency   = Days since last purchase
   Frequency = Number of unique orders
   Monetary  = Total customer spending
   ============================================================ */

WITH customer_rfm AS (

    SELECT
        customer_key,

        -- Calculate days since the customer's last purchase
        DATEDIFF(
            DAY,
            MAX(order_date),
            (SELECT MAX(order_date)
             FROM gold.fact_sales)
        ) AS recency,

        -- Count unique orders placed by the customer
        COUNT(DISTINCT order_number) AS frequency,

        -- Calculate total amount spent by the customer
        SUM(sales_amount) AS monetary

    FROM gold.fact_sales

    WHERE order_date IS NOT NULL

    GROUP BY customer_key
),

rfm_scores AS (

    SELECT
        customer_key,
        recency,
        frequency,
        monetary,

        -- Lower recency is better
        NTILE(3) OVER (
            ORDER BY recency DESC
        ) AS r_score,

        -- Higher order frequency is better
        NTILE(3) OVER (
            ORDER BY frequency
        ) AS f_score,

        -- Higher customer spending is better
        NTILE(3) OVER (
            ORDER BY monetary
        ) AS m_score

    FROM customer_rfm
)

SELECT
    customer_key,
    recency,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,

    -- Segment customers based on RFM scores
    CASE

        WHEN r_score = 3
             AND f_score = 3
             AND m_score = 3
        THEN 'High Value'

        WHEN r_score = 3
        THEN 'Active'

        WHEN r_score = 1
             AND (f_score = 3 OR m_score = 3)
        THEN 'At Risk'

        WHEN r_score = 1
             AND f_score = 1
             AND m_score = 1
        THEN 'Low Value'

        ELSE 'Regular'

    END AS customer_segment

FROM rfm_scores

ORDER BY monetary DESC;

/* ============================================================
   NEW VS RETURNING CUSTOMER ANALYSIS

   New Customer       = Customer purchasing for the first time
   Returning Customer = Customer who has purchased previously
   ============================================================ */

WITH customer_orders AS (

    SELECT DISTINCT
        customer_key,
        order_number,
        order_date

    FROM gold.fact_sales

    WHERE order_date IS NOT NULL
),

first_purchase AS (

    SELECT
        customer_key,

        -- Find the first purchase date for each customer
        MIN(order_date) AS first_order_date

    FROM customer_orders

    GROUP BY customer_key
),

customer_status AS (

    SELECT
        o.customer_key,
        o.order_number,
        o.order_date,

        -- Classify each purchase as New or Returning
        CASE
            WHEN o.order_date = f.first_order_date
            THEN 'New Customer'

            ELSE 'Returning Customer'
        END AS customer_type

    FROM customer_orders AS o

    LEFT JOIN first_purchase AS f
        ON o.customer_key = f.customer_key
)

-- Monthly New vs Returning customer trend
SELECT
    DATETRUNC(MONTH, order_date) AS order_month,
    customer_type,

    COUNT(DISTINCT customer_key) AS total_customers,
    COUNT(DISTINCT order_number) AS total_orders

FROM customer_status

GROUP BY
    DATETRUNC(MONTH, order_date),
    customer_type

ORDER BY
    order_month,
    customer_type;


    /* ============================================================
   REPEAT PURCHASE RATE

   Measures the percentage of customers
   who placed more than one order.
   ============================================================ */

WITH customer_orders AS (

    SELECT
        customer_key,

        -- Count unique orders placed by each customer
        COUNT(DISTINCT order_number) AS total_orders

    FROM gold.fact_sales

    WHERE order_date IS NOT NULL

    GROUP BY customer_key
)

SELECT
    COUNT(*) AS total_customers,

    -- Customers who purchased more than once
    SUM(
        CASE
            WHEN total_orders > 1 THEN 1
            ELSE 0
        END
    ) AS repeat_customers,

    -- Percentage of customers who made repeat purchases
    ROUND(
        100.0 *
        SUM(
            CASE
                WHEN total_orders > 1 THEN 1
                ELSE 0
            END
        )
        / COUNT(*),
        2
    ) AS repeat_purchase_rate

FROM customer_orders;

/* ============================================================
   ABC PRODUCT ANALYSIS

   Products are ranked based on revenue contribution.

   A = Products contributing to first 80% of revenue
   B = Products contributing from 80% to 95%
   C = Products contributing to remaining revenue
   ============================================================ */

WITH product_sales AS (

    SELECT
        f.product_key,
        p.product_name,

        -- Calculate total revenue generated by each product
        SUM(f.sales_amount) AS total_sales

    FROM gold.fact_sales AS f

    LEFT JOIN gold.dim_products AS p
        ON f.product_key = p.product_key

    WHERE f.order_date IS NOT NULL

    GROUP BY
        f.product_key,
        p.product_name
),

sales_analysis AS (

    SELECT
        product_key,
        product_name,
        total_sales,

        -- Calculate total revenue across all products
        SUM(total_sales) OVER() AS overall_sales,

        -- Calculate cumulative revenue from highest-selling products
        SUM(total_sales) OVER (
            ORDER BY total_sales DESC, product_key
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_sales

    FROM product_sales
),

product_contribution AS (

    SELECT
        product_key,
        product_name,
        total_sales,

        -- Individual product contribution to total revenue
        ROUND(
            100.0 * total_sales / overall_sales,
            2
        ) AS sales_percentage,

        -- Cumulative contribution to total revenue
        ROUND(
            100.0 * cumulative_sales / overall_sales,
            2
        ) AS cumulative_percentage

    FROM sales_analysis
)

SELECT
    product_key,
    product_name,
    total_sales,
    sales_percentage,
    cumulative_percentage,

    -- Divide products into ABC categories
    CASE
        WHEN cumulative_percentage <= 80
        THEN 'A'

        WHEN cumulative_percentage <= 95
        THEN 'B'

        ELSE 'C'
    END AS abc_category

FROM product_contribution

ORDER BY total_sales DESC;


