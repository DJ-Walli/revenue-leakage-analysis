-- Table: service_orders
-- Purpose: Stores service order lifecycle and billing information


DROP table if exists service_orders CASCADE;

CREATE TABLE service_orders(

	order_id varchar(50) PRIMARY KEY,
	customer_id varchar(50) NOT NULL,
	region varchar(50) NOT NULL,
	service_type varchar(50) NOT NULL,
	
	order_date date NOT NULL,
	completion_date date NOT NULL,
	invoice_date date,
	payment_date date,
	
	order_status varchar(50) NOT NULL 
		CHECK(order_status in('completed','cancelled')),
	invoice_status varchar(50) NOT NULL 
		CHECK(invoice_status in('invoiced','not_invoiced')),
	payment_status varchar(50) NOT NULL
		CHECK(payment_status in ('paid','pending','failed')),
	
	gross_amount decimal(10,2) NOT NULL,
	discount_amount decimal(10,2) NOT NULL,
	net_amount decimal(10,2) NOT NULL
		CHECK(net_amount = gross_amount - discount_amount)

	);


-- Base Metric: Total net revenue from completed orders
	
	SELECT 
    SUM(net_amount) AS total_net_revenue
	FROM service_orders
	WHERE order_status = 'completed';


--Unbilled completed orders → leaked revenue
	SELECT 
    SUM(net_amount) AS unbilled_leaked_revenue
	FROM service_orders
	WHERE order_status = 'completed'
	  AND invoice_status = 'not_invoiced';


--Discount leakage amount(only the portion of discount beyond 15% for completed orders)

	SELECT SUM( discount_amount - (0.15 * gross_amount)) AS discount_leaked_revenue
	FROM service_orders
	WHERE order_status = 'completed'
	  AND discount_amount / gross_amount > 0.15;


-- Payment leakage (at risk)
	  SELECT SUM(net_amount) AS payment_leakage_revenue
		FROM service_orders
		WHERE order_status = 'completed'
		  AND invoice_status = 'invoiced'
		  AND payment_status IN ('pending','failed')
		  AND CURRENT_DATE - invoice_date > 30;


-- Revenue Leakage Breakdown
	SELECT 
    SUM(net_amount) AS total_completed_revenue,

    SUM(net_amount) 
        FILTER (WHERE invoice_status = 'not_invoiced') 
        AS unbilled_leakage,

    SUM(discount_amount - (0.15 * gross_amount)) 
        FILTER (WHERE invoice_status = 'invoiced'
              AND discount_amount / gross_amount > 0.15) AS discount_leakage,

    SUM(net_amount) 
        FILTER (WHERE invoice_status = 'invoiced'
             	AND payment_status IN ('pending','failed')
              	AND invoice_date IS NOT NULL
              	AND CURRENT_DATE - invoice_date > 30) AS payment_leakage

		FROM service_orders
		WHERE order_status = 'completed';


-- Leakage by region for prioritization
	with regions_leakage as(
	SELECT region, sum(net_amount) as total_completed_revenue,

		sum(net_amount) FILTER( where invoice_status = 'not_invoiced') 
		as unbilled_leakage,
	
		sum(discount_amount - (0.15*gross_amount)) 
		FILTER (where discount_amount/gross_amount >0.15 
				and invoice_status = 'invoiced') 
		as discount_leakage,

		sum(net_amount) 
		FILTER( where invoice_status = 'invoiced'
				AND payment_status IN ('pending','failed')
				AND invoice_date IS NOT NULL
				AND CURRENT_DATE - invoice_date > 30) 
		as payment_leakage
	
	FROM service_orders
	WHERE order_status = 'completed' 
	group by region
	)
	
	select *
	from regions_leakage
	order by  
		(unbilled_leakage + discount_leakage+ payment_leakage) desc


-- Leakage by service types for prioritization
	WITH service_leakage AS (
    SELECT
        service_type,
        SUM(net_amount) AS total_completed_revenue,

        SUM(net_amount)
            FILTER (WHERE invoice_status = 'not_invoiced')
            AS unbilled_leakage,

        SUM(discount_amount - (0.15 * gross_amount))
            FILTER (
                WHERE discount_amount / gross_amount > 0.15
                  AND invoice_status = 'invoiced'
            ) AS discount_leakage,

        SUM(net_amount)
            FILTER (
                WHERE invoice_status = 'invoiced'
                  AND payment_status IN ('pending','failed')
                  AND invoice_date IS NOT NULL
                  AND CURRENT_DATE - invoice_date > 30
            ) AS payment_leakage

	    FROM service_orders
	    WHERE order_status = 'completed'
	    GROUP BY service_type
	)

	SELECT
	    service_type,
	    total_completed_revenue,
	    unbilled_leakage,
	    discount_leakage,
	    payment_leakage,
	
		    COALESCE(unbilled_leakage,0)
		  + COALESCE(discount_leakage,0)
		  + COALESCE(payment_leakage,0)
		    AS total_leakage,
	
	    CASE
	        WHEN total_completed_revenue > 0 THEN
	            100.0 * (
	                COALESCE(unbilled_leakage,0)
	              + COALESCE(discount_leakage,0)
	              + COALESCE(payment_leakage,0)
	            ) / total_completed_revenue
	        ELSE 0
	    END AS total_leakage_percentage
	
	FROM service_leakage
	ORDER BY total_leakage DESC;