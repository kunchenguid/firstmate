UPDATE participants SET host_id=CASE WHEN host_id=:legacy_host THEN :machine_host ELSE NULL END WHERE host_id IS NOT NULL;
