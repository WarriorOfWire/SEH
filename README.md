# SEH
Sequential Exponential Histograms for TimescaleDB


## About Sequential Exponential Histogram downsampling
Keep your dimensions and an idea of your measurements' behavior even when bucketed into very wide buckets.
Sequential Exponential Histograms (SEH) are jsonb and are sparse. If your service tends to be fairly consistent
or even consistently modal, your histograms will tend to be compact. If your measurements are random across a
huge spread, your histograms will be somewhat larger; they grow at the rate of:
`2 * log10(measurement cardinality per window)`
So if your service is slow during business hours and fast at night you will have different buckets predominantly
populated at different times, but no 0 buckets. The histograms are sparse, densely packed.
They are also re-combinable across grouping dimensions.

You can record a histogram per-(region, server, device) and seamlessly inspect behavior by any of those dimensions.

## Who is this for
SEH is lossy; however it tries to retain the high level shape of the original input data set. It is for service
owners who need a more compact representation of their high-frequency fine-grained measurements and who want to
retrieve better historical insights than answers seeded a priori (like bespoke avg or percentile_disc columns in
rollups)


## Example usage with TimescaleDB Continuous Aggregates

CREATE MATERIALIZED VIEW metrics_1h
WITH (timescaledb.continuous) AS
  SELECT
    time_bucket('1 hour', time) AS time, -- Select columns with the same names. This is a rollup table not a projection table.
    device_id,
    region,
    server,
    accumulate_seh(report_latency) as report_latency  -- Retain a sequential exponential histogram of report_latency per hour, per device, per region, per server
  from metrics
  group by 1, 2, 3, 4;
select add_continuous_aggregate_policy('metrics_1h', start_offset => interval '10 minutes', end_offset => interval '1 minute', schedule_interval => interval '1 minute');

grant select on metrics_1h to grafana_read_role;  -- You do have a limited role for grafana in your db right?


And in Grafana for latency of devices reporting to IAD:
Heatmap visualization with Data Format "Time series buckets"
```
select
  $__timeGroup(time, $__interval) as time,
  (buckets(accumulate_seh(report_latency))).*
from metrics_1h
where
  $__timeFilter(time)
  and region = 'IAD'
group by 1
ORDER BY 1
```


