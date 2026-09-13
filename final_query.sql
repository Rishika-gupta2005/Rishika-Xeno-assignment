WITH RECURSIVE eligible AS (
  -- only campaigns whose creation workflow has cleared AND whose send pipeline finished
  SELECT id, merchant_id, parent_id, name
  FROM campaign
  WHERE merchant_id = 501
    AND name LIKE '%Diwali%'
    AND creation_status != 'approval_awaiting'   -- excludes 9004
    AND processing_status = 'processed'
),
roots AS (
  -- walk each eligible campaign up its parent chain to find the chain's ultimate root
  SELECT id AS campaign_id, id AS root_id, parent_id FROM eligible
  UNION ALL
  SELECT r.campaign_id, e.id AS root_id, e.parent_id
  FROM roots r
  JOIN eligible e ON r.parent_id = e.id
),
campaign_root AS (
  SELECT campaign_id, root_id
  FROM roots
  WHERE parent_id IS NULL
),
chain_size AS (
  -- chains with >1 campaign are true retry chains; chains with exactly 1 are standalone leaves
  SELECT root_id, COUNT(*) AS n_campaigns
  FROM campaign_root
  GROUP BY root_id
),
tagged_log AS (
  SELECT cl.*, cr.root_id, cs.n_campaigns
  FROM communication_log cl
  JOIN campaign_root cr ON cl.communication_id = cr.campaign_id
  JOIN chain_size cs ON cr.root_id = cs.root_id
)
SELECT
  -- retry chains: count each distinct customer once per chain
  (SELECT COUNT(DISTINCT root_id || '-' || customer_id) FROM tagged_log WHERE n_campaigns > 1)
  +
  -- standalone campaigns: count every send event, duplicates included
  (SELECT COUNT(*) FROM tagged_log WHERE n_campaigns = 1)
  AS target_base;
